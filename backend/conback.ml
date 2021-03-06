(*
 * Copyright (c) 2010-2011 Anil Madhavapeddy <anil@recoil.org>
 * Copyright (c) 2012-14 Citrix Systems Inc
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Lwt
open Printf
open Conproto
open Gnt

module type ACTIVATIONS = sig

  (** Event channels handlers. *)

  type event
  (** identifies the an event notification received from xen *)

  val program_start: event
  (** represents an event which 'fired' when the program started *)

  val after: Eventchn.t -> event -> event Lwt.t
  (** [next channel event] blocks until the system receives an event
      newer than [event] on channel [channel]. If an event is received
      while we aren't looking then this will be remembered and the
      next call to [after] will immediately unblock. If the system
      is suspended and then resumed, all event channel bindings are invalidated
      and this function will fail with Generation.Invalid *)
end


type stats = {
  mutable total_read: int; (* bytes read *)
  mutable total_write: int; (* bytes written *)
}

type t = {
  domid:  int;
  xg:     Gnttab.interface;
  xe:     Eventchn.handle;
  evtchn: Eventchn.t;
  ring:   Cstruct.t;
}

module ConsoleError = struct
  open Lwt
  let (>>=) x f = x >>= function
  | `Ok x -> f x
  | `Error (`Invalid_console x) -> fail (Failure (Printf.sprintf "Invalid_console %s" x))
  | `Error _ -> fail (Failure "unknown console device failure")
end


module Make(A: ACTIVATIONS)(X: Xs_client_lwt.S)(C: S.CONSOLE) = struct

  let service_thread t c stats =

    let (>>|=) m f =
      let open Lwt in
      m >>= function
      | `Ok x -> f x
      | `Eof -> fail (Failure "End of file")
      | `Error (`Invalid_console x) -> fail (Failure (Printf.sprintf "Invalid_console %s" x)) in

    let rec read_the_ring after =
      let open Lwt in
      let seq, avail = Console_ring.Ring.Front.Reader.read t.ring in
      C.write c avail >>|= fun () ->
      let n = Cstruct.len avail in
      stats.total_read <- stats.total_read + n;
      let seq = Int32.(add seq (of_int n)) in
      Console_ring.Ring.Front.Reader.advance t.ring seq;
      Eventchn.notify t.xe t.evtchn;
      A.after t.evtchn after >>= fun next ->
      read_the_ring next in

    let rec read_the_console after =
      let open Lwt in
      C.read c >>|= fun buffer ->
      let rec loop after buffer =
        if Cstruct.len buffer = 0
        then return after
        else begin
          let seq, avail = Console_ring.Ring.Back.Writer.write t.ring in
          if Cstruct.len avail = 0 then begin
            A.after t.evtchn after >>= fun next ->
            loop next buffer
          end else begin
            let n = min (Cstruct.len avail) (Cstruct.len buffer) in
            Cstruct.blit buffer 0 avail 0 n;
            let seq = Int32.(add seq (of_int n)) in
            Console_ring.Ring.Back.Writer.advance t.ring seq;
            Eventchn.notify t.xe t.evtchn;
            loop after (Cstruct.shift buffer n)
          end
        end in
      loop after buffer >>= fun after ->
      read_the_console after in

    let (a: unit Lwt.t) = read_the_ring A.program_start in
    let (b: unit Lwt.t) = read_the_console A.program_start in
    Lwt.join [a; b]

  let init xg xe domid ring_info c =
    let evtchn = Eventchn.bind_interdomain xe domid ring_info.RingInfo.event_channel in
    let grant = { Gnttab.domid = domid; ref = Int32.to_int ring_info.RingInfo.ref } in
    match Gnttab.mapv xg [ grant ] true with
    | None ->
      failwith "Gnttab.mapv failed"
    | Some mapping ->
      let ring = Io_page.to_cstruct (Gnttab.Local_mapping.to_buf mapping) in
      let t = { domid; xg; xe; evtchn; ring } in
      let stats = { total_read = 0; total_write = 0 } in
      let th = service_thread t c stats in
      on_cancel th (fun () ->
        let () = Gnttab.unmap_exn xg mapping in ()
      );
      th, stats

  open X

  let get_my_domid client =
    immediate client (fun xs ->
      try_lwt
        lwt domid = read xs "domid" in
        return (int_of_string domid)
      with Xs_protocol.Enoent _ -> return 0)

  let mk_backend_path client backend_name (domid,devid) =
    lwt self = get_my_domid client in
    return (Printf.sprintf "/local/domain/%d/backend/%s/%d/%d" self backend_name domid devid)

  let mk_frontend_path client (domid,devid) =
    return (Printf.sprintf "/local/domain/%d/device/console/%d" domid devid)

  let writev client pairs =
    transaction client (fun xs ->
      Lwt_list.iter_s (fun (k, v) -> write xs k v) pairs
    )

  let readv client path keys =
    lwt options = immediate client (fun xs ->
      Lwt_list.map_s (fun k ->
        try_lwt
          lwt v = read xs (path ^ "/" ^ k) in
          return (Some (k, v))
        with _ -> return None) keys
    ) in
    return (List.fold_left (fun acc x -> match x with None -> acc | Some y -> y :: acc) [] options)

  let read_one client k = immediate client (fun xs ->
    try_lwt
      lwt v = read xs k in
      return (`OK v)
    with _ -> return (`Error ("failed to read: " ^ k)))

  let write_one client k v = immediate client (fun xs -> write xs k v)

  let exists client k = match_lwt read_one client k with `Error _ -> return false | _ -> return true

  (* Request a hot-unplug *)
  let request_close backend_name (domid, devid) =
    lwt client = make () in
    lwt backend_path = mk_backend_path client backend_name (domid,devid) in
    writev client (List.map (fun (k, v) -> backend_path ^ "/" ^ k, v) (Conproto.State.to_assoc_list Conproto.State.Closing))

  let force_close (domid, device) =
    lwt client = make () in
    lwt frontend_path = mk_frontend_path client (domid, device) in
    write_one client (frontend_path ^ "/state") (Conproto.State.to_string Conproto.State.Closed)

  let run (id: string) backend_name (domid,devid) =
    lwt client = make () in
    let xg = Gnttab.interface_open () in
    let xe = Eventchn.init () in

    let open ConsoleError in
    C.connect id >>= fun t ->
    let ( >>= ) = Lwt.bind in
    lwt backend_path = mk_backend_path client backend_name (domid,devid) in

    try_lwt

      ( read_one client (backend_path ^ "/frontend") >>= function
        | `Error x -> fail (Failure x)
        | `OK x -> return x ) >>= fun frontend_path ->

      (* wait for the frontend to enter state Initialised *)
      wait client (fun xs ->
        try_lwt
          lwt state = read xs (frontend_path ^ "/" ^ Conproto.State._state) in
          if Conproto.State.of_string state = Some Conproto.State.Initialised
          || Conproto.State.of_string state = Some Conproto.State.Connected
          then return ()
          else raise Xs_protocol.Eagain
        with Xs_protocol.Enoent _ -> raise Xs_protocol.Eagain
      ) >>= fun () ->

      lwt frontend = readv client frontend_path Conproto.RingInfo.keys in
      let ring_info = match Conproto.RingInfo.of_assoc_list frontend with
        | `OK x -> x
        | `Error x -> failwith x in
      printf "%s\n%!" (Conproto.RingInfo.to_string ring_info);

      let be_thread, stats = init xg xe domid ring_info t in
      lwt () = writev client (List.map (fun (k, v) -> backend_path ^ "/" ^ k, v) (Conproto.State.to_assoc_list Conproto.State.Connected)) in
      (* wait for the frontend to disappear or enter a Closed state *)
      lwt () = wait client (fun xs ->
        try_lwt
          lwt state = read xs (frontend_path ^ "/state") in
          if Conproto.State.of_string state <> (Some Conproto.State.Closed)
          then raise Xs_protocol.Eagain
          else return ()
        with Xs_protocol.Enoent _ ->
          return ()
      ) in
      Lwt.cancel be_thread;
      Lwt.return stats
    with e ->
      printf "conback caught %s\n%!" (Printexc.to_string e);
      lwt () = C.disconnect t in
      fail e

  let create ?backend_domid ?name backend_name (domid, device) =
    lwt client = make () in
    (* Construct the device: *)
    lwt backend_path = mk_backend_path client backend_name (domid, device) in
    lwt frontend_path = mk_frontend_path client (domid, device) in
    lwt backend_domid = match backend_domid with
    | None -> get_my_domid client
    | Some x -> return x in
    let c = Conproto.Connection.({
      virtual_device = device;
      backend_path;
      backend_domid;
      frontend_path;
      frontend_domid = domid;
      protocol = Conproto.Protocol.Vt100;
      name = name;
    }) in
    transaction client (fun xs ->
      Lwt_list.iter_s (fun (acl, (k, v)) ->
        lwt () = write xs k v in
        lwt () = setperms xs k acl in
        return ()
      ) (Conproto.Connection.to_assoc_list c)
    )

  let destroy backend_name (domid, device) =
    lwt client = make () in
    lwt backend_path = mk_backend_path client backend_name (domid, device) in
    lwt frontend_path = mk_frontend_path client (domid, device) in
    immediate client (fun xs ->
      lwt () = try_lwt rm xs backend_path with _ -> return () in
      lwt () = try_lwt rm xs frontend_path with _ -> return () in
      return ()
    )
end
