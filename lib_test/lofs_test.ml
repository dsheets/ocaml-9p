(*
 * Copyright (c) 2015 David Sheets <sheets@alum.mit.edu>
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

open Protocol_9p
open Lwt
open Infix
open Result

module LogServer  = Log9p_unix.StdoutPrefix(struct let prefix = "S" end)
module LogClient1 = Log9p_unix.StdoutPrefix(struct let prefix = "C1" end)
module LogClient2 = Log9p_unix.StdoutPrefix(struct let prefix = "C2" end)
module Server = Server9p_unix.Make(LogServer)(Lofs9p)
module Client1 = Client9p_unix.Make(LogClient1)
module Client2 = Client9p_unix.Make(LogClient2)

let proto = "unix"
let address = "/tmp/lofs.test"

let finally f g =
 Lwt.catch
   (fun () ->
      f () >>= fun result ->
      g () >>= fun _ignored ->
      Lwt.return result
   ) (fun e ->
     g () >>= fun _ignored ->
     Lwt.fail e)

let with_server f =
  let path = ["tmp"] in
  let (_: Unix.process_status) = Unix.system "chmod -R u+rw tmp/*" in
  let (_: Unix.process_status) = Unix.system "rm -rf tmp/*" in
  (try Unix.mkdir "tmp" 0o700 with Unix.Unix_error(Unix.EEXIST, _, _) -> ());
  let fs = Lofs9p.make path in
  Server.listen fs proto address
  >>= function
  | Result.Error (`Msg m) -> Lwt.fail (Failure m)
  | Result.Ok server ->
    Lwt.async (fun () -> Server.serve_forever server);
    finally f
      (fun () ->
        Server.shutdown server
      )

let with_client1 f =
  Client1.connect proto address ()
  >>= function
  | Error (`Msg err) -> Alcotest.fail ("client1: "^err)
  | Ok client ->
    Lwt.catch (fun () ->
      f client
      >>= fun () ->
      Client1.disconnect client
    ) (fun exn ->
      Client1.disconnect client
      >>= fun () ->
      fail exn
    )

let with_client2 f =
  Client2.connect proto address ()
  >>= function
  | Error (`Msg err) -> Alcotest.fail ("client2: "^err)
  | Ok client ->
    Lwt.catch (fun () ->
      f client
      >>= fun () ->
      Client2.disconnect client
    ) (fun exn ->
      Client2.disconnect client
      >>= fun () ->
      fail exn
    )

let connect1 () =
  with_client1 (fun _client1 -> return_unit)

let connect2 () =
  with_client1 (fun _client1 ->
    with_client2 (fun _client2 -> return_unit)
  )

let create_rebind_fid () =
  with_client1 (fun _client1 ->
    Client1.with_fid _client1
      (fun fid ->
        Client1.walk_from_root _client1 fid []
        >>= function
        | Error (`Msg err) ->
          Alcotest.fail ("client1: walk_from_root []: " ^ err)
        | Ok _ ->
          let filemode = Types.FileMode.make ~owner:[`Write] () in
          let openmode = Types.OpenMode.read_write in
          (* create should rebind the fid to refer to the file foo... *)
          Client1.LowLevel.create _client1 fid "foo"  filemode openmode
          >>= function
          | Error (`Msg err) ->
          Alcotest.fail ("client1: create foo: " ^ err)
          | Ok _ ->
            let buf = Cstruct.create 16 in
            Cstruct.memset buf 0;
            (* ... so a write should succeed (but would fail on a directory) *)
            Client1.LowLevel.write _client1 fid 0L buf
            >>= function
            | Error (`Msg err) ->
             Alcotest.fail ("client1: write: " ^ err)
            | Ok _ ->
                Lwt.return ()
      )
  )

let create_remove_file () =
  with_client1 (fun _client1 ->
    Client1.with_fid _client1
      (fun fid ->
        Client1.walk_from_root _client1 fid []
        >>= function
        | Error (`Msg err) -> Alcotest.fail ("client1: walk_from_root []: " ^ err)
        | Ok _ ->
          let filemode = Types.FileMode.make ~owner:[`Write] () in
          let openmode = Types.OpenMode.read_write in
          (* create should rebind the fid to refer to the file foo... *)
          Client1.LowLevel.create _client1 fid "foo"  filemode openmode
          >>= function
          | Error (`Msg err) ->
            Alcotest.fail ("client1: create foo: " ^ err)
          | Ok _ ->
          Client1.remove _client1 [ "foo" ]
          >>= function
          | Error (`Msg err) ->
            Alcotest.fail ("client1: remove foo: " ^ err)
          | Ok () ->
            Lwt.return ()
      )
    )

let create_remove_dir () =
  with_client1 (fun _client1 ->
    let filemode = Types.FileMode.make ~owner:[`Read; `Write] () in
    Client1.mkdir _client1 [] "foo" filemode
    >>= function
    | Error (`Msg err) -> Alcotest.fail ("client1: mkdir [] foo: " ^ err)
    | Ok _ ->
    Client1.remove _client1 ["foo"]
    >>= function
    | Error (`Msg err) -> Alcotest.fail ("client1: rm [foo]: " ^ err)
    | Ok () ->
      Lwt.return ()
  )

let failed_remove_clunk_fid () =
  with_client1 (fun _client1 ->
    let filemode = Types.FileMode.make ~owner:[`Read; `Write; `Execute] () in
    Client1.mkdir _client1 [] "foo" filemode
    >>= function
    | Error (`Msg err) -> Alcotest.fail ("client1: mkdir [] foo: " ^ err)
    | Ok _ ->
    Client1.mkdir _client1 ["foo"] "bar" filemode
    >>= function
    | Error (`Msg err) -> Alcotest.fail ("client1: mkdir [foo] bar: " ^ err)
    | Ok _ ->
    Client1.with_fid _client1
      (fun fid ->
        Client1.walk_from_root _client1 fid ["foo"]
        >>= function
        | Error (`Msg err) -> Alcotest.fail ("client1: walk_from_root [foo]: " ^ err)
        | Ok _ ->
        Client1.LowLevel.remove _client1 fid
        >>= function
        | Ok () -> Alcotest.fail ("client1: remove a non-empty dir should fail")
        | Error (`Msg _) ->
          (* The fid should have been clunked so I can now re-use it *)
          Client1.walk_from_root _client1 fid []
          >>= function
          | Error (`Msg err) -> Alcotest.fail ("client1: walk_from_root after failed remove: " ^ err)
          | Ok _ ->
            Lwt.return ()
      )
  )

let check_directory_boundary_read () =
  with_client1 (fun _client1 ->
    let filemode = Types.FileMode.make ~owner:[`Read; `Execute] () in
    Client1.mkdir _client1 [] "foo" filemode
    >>= function
    | Error (`Msg err) -> Alcotest.fail ("client1: mkdir [] foo: " ^ err)
    | Ok _ ->
    Client1.with_fid _client1
      (fun fid ->
        Client1.walk_from_root _client1 fid ["foo"]
        >>= function
        | Error (`Msg err) -> Alcotest.fail ("client1: walk_from_root [foo]: " ^ err)
        | Ok _ ->
        Client1.LowLevel.openfid _client1 fid Types.OpenMode.read_only
        >>= function
        | Error (`Msg err) ->
          Alcotest.fail ("client1: open: " ^ err)
        | Ok _ ->
        Client1.LowLevel.read _client1 fid 1024L 16l
        >>= function
        | Error (`Msg err) ->
          Alcotest.fail ("client1: read: " ^ err)
        | Ok { Response.Read.data } ->
          let n = Cstruct.len data in
          if n = 0
          then Lwt.return ()
          else Alcotest.fail ("client1: read non-zero: " ^ (string_of_int n))
      )
  )

let () = LogServer.print_debug := false
let () = LogClient1.print_debug := false
let () = LogClient2.print_debug := false

let lwt_test name f =
  name, `Quick, (fun () -> Lwt_main.run (f ()))

let test_client = [
  lwt_test "connect1" (fun () -> with_server connect1);
  lwt_test "connect2" (fun () -> with_server connect2);
  lwt_test "check that create rebinds fids" (fun () -> with_server create_rebind_fid);
  lwt_test "check that we can remove a file" (fun () -> with_server create_remove_file);
  lwt_test "check that we can remove a directory" (fun () -> with_server create_remove_dir);
  lwt_test "failed remove should clunk the fid" (fun () -> with_server failed_remove_clunk_fid);
  lwt_test "check reading out-of-bounds on a directory doesn't fail badly" (fun () -> with_server check_directory_boundary_read);
]

let tests = [
  "client", test_client;
]

let () = Alcotest.run "client server" tests
