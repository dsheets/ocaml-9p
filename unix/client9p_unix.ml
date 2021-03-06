(*
 * Copyright (C) 2015 David Sheets <david.sheets@unikernel.com>
 * Copyright (C) 2015 David Scott <dave.scott@unikernel.com>
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
 *
 *)

open Lwt
open Protocol_9p

module Make(Log: S.LOG) = struct

  module Client = Client.Make(Log)(Flow_lwt_unix)

  type t = {
    client: Client.t;
    flow: Flow_lwt_unix.flow;
  }

  type connection = t

  let open_tcp hostname port =
    Lwt_unix.gethostbyname hostname
    >>= fun h ->
    (* This should probably be a Result error and not an Lwt error. *)
    ( if Array.length h.Lwt_unix.h_addr_list = 0
      then
        let msg =
          Printf.sprintf "gethostbyname returned 0 addresses for '%s'" hostname
        in
        fail (Failure msg)
      else return h.Lwt_unix.h_addr_list.(0)
    ) >>= fun inet_addr ->
    let s = Lwt_unix.socket h.Lwt_unix.h_addrtype Lwt_unix.SOCK_STREAM 0 in
    Lwt_unix.connect s (Lwt_unix.ADDR_INET (inet_addr, port))
    >>= fun () ->
    Lwt.return s

  let open_unix path =
    let s = Lwt_unix.socket Lwt_unix.PF_UNIX Lwt_unix.SOCK_STREAM 0 in
    Lwt_unix.connect s (Lwt_unix.ADDR_UNIX path)
    >>= fun () ->
    Lwt.return s

  let connect proto address ?msize ?username ?aname () =
    ( match proto with
      | "tcp" ->
        begin match Stringext.split ~on:':' address with
        | [ hostname; port ] -> open_tcp hostname (int_of_string port)
        | [ hostname ] -> open_tcp hostname 5640
        | _ -> Lwt.fail (Failure (Printf.sprintf "Unable to parse %s %s" proto address))
        end
      | "unix" ->
        open_unix address
      | _ -> Lwt.fail (Failure (Printf.sprintf "Unknown protocol %s" proto)) )
    >>= fun s ->
    let flow = Flow_lwt_unix.connect s in
    Client.connect flow ?msize ?username ?aname ()
    >>= function
    | Result.Error _ as err -> Lwt.return err
    | Result.Ok client ->
      Log.debug "Successfully negotiated a connection.";
      Lwt.return (Result.Ok { client; flow; })

  let disconnect { client; flow } =
    Client.disconnect client
    >>= fun () ->
    Flow_lwt_unix.close flow

  let create { client } = Client.create client

  let read { client } = Client.read client

  let write { client } = Client.write client

  let mkdir { client } = Client.mkdir client

  let remove { client } = Client.remove client

  let readdir { client } = Client.readdir client

  let stat { client } = Client.stat client

  module KV_RO = struct
    open Client

    type t = connection

    type error = KV_RO.error = Unknown_key of string

    type 'a io = 'a KV_RO.io

    type id = KV_RO.id

    type page_aligned_buffer = KV_RO.page_aligned_buffer

    let disconnect { client } = KV_RO.disconnect client

    let read { client } = KV_RO.read client

    let size { client } = KV_RO.size client
  end

  module LowLevel = struct
    open Client

    let walk { client } = LowLevel.walk client

    let openfid { client } = LowLevel.openfid client

    let create { client } = LowLevel.create client

    let stat { client } = LowLevel.stat client

    let wstat { client } = LowLevel.wstat client

    let read { client } = LowLevel.read client

    let write { client } = LowLevel.write client

    let clunk { client } = LowLevel.clunk client

    let remove { client } = LowLevel.remove client

    let update { client } = LowLevel.update client
  end

  let walk_from_root { client } = Client.walk_from_root client
  let with_fid { client } = Client.with_fid client
end
