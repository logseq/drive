(* drive — CLI: run a .drive scenario against a shared library that
   exports the lui_ocaml_* bridge ABI.

     drive --lib ./libmeng_editor.so [--os macos] [--host swiftui] app.drive

   The script may set env for the target via lines like `env NAME=value`
   (handled here, before dlopen). *)

let usage =
  "usage: drive (--lib <path> [--os macos|ios|generic] [--host swiftui|generic] \\\n\
  \        [--env NAME=VALUE]... | --socket <path>) <scenario.drive>"

let () =
  let lib = ref "" in
  let socket = ref "" in
  let os = ref "generic" in
  let host = ref "generic" in
  let env = ref [] in
  let scenario = ref "" in
  let anon s =
    if !scenario = "" then scenario := s
    else failwith ("unexpected argument: " ^ s)
  in
  Arg.parse
    [
      ("--lib", Arg.Set_string lib, "shared library exporting lui_ocaml_* ABI");
      ("--socket", Arg.Set_string socket, "attach to a live app's MENG_DRIVE_SOCKET");
      ("--os", Arg.Set_string os, "target os profile (default generic)");
      ("--host", Arg.Set_string host, "target host profile (default generic)");
      ("--env", Arg.String (fun kv -> env := kv :: !env), "NAME=VALUE for the target process env");
    ]
    anon usage;
  if (!lib = "" && !socket = "") || !scenario = "" then begin
    prerr_endline usage;
    exit 2
  end;
  List.iter
    (fun kv ->
      match String.index_opt kv '=' with
      | Some i ->
        Unix.putenv (String.sub kv 0 i)
          (String.sub kv (i + 1) (String.length kv - i - 1))
      | None -> failwith ("bad --env: " ^ kv))
    !env;
  let os_kind =
    match !os with
    | "macos" -> Lui_protocol.MacOS
    | "ios" -> Lui_protocol.IOS
    | "generic" -> Lui_protocol.GenericOS
    | other -> failwith ("bad --os: " ^ other)
  in
  let host_kind =
    match !host with
    | "swiftui" -> Lui_protocol.SwiftUIHost
    | "generic" -> Lui_protocol.GenericHost
    | other -> failwith ("bad --host: " ^ other)
  in
  let source =
    let ic = open_in !scenario in
    let n = in_channel_length ic in
    let s = really_input_string ic n in
    close_in ic;
    s
  in
  let driver, stop =
    if !socket <> "" then
      let live =
        try Drive.Live.connect ~socket_path:!socket
        with Unix.Unix_error (e, _, _) ->
          Printf.eprintf "drive: connect %s: %s\n" !socket
            (Unix.error_message e);
          exit 2
      in
      (Drive.Live.driver live, fun () -> ())
    else
      let target =
        try Drive.Ffi.open_target ~path:!lib ~os:os_kind ~host:host_kind
        with Failure msg ->
          prerr_endline msg;
          exit 2
      in
      (Drive.Ffi.driver target, fun () -> ignore (Drive.Ffi.stop target))
  in
  let failures = Drive.Scenario.run ~emit:print_endline driver source in
  List.iter
    (fun (f : Drive.Scenario.failure) ->
      Printf.eprintf "line %d: %s\n" f.line f.message)
    failures;
  stop ();
  exit (if failures = [] then 0 else 1)
