(* drive — CLI: run a .drive scenario against a shared library that
   exports the lui_ocaml_* bridge ABI.

     drive --lib ./libmeng_editor.so [--os macos] [--host swiftui] app.drive

   The script may set env for the target via lines like `env NAME=value`
   (handled here, before dlopen). *)

let usage =
  "usage: drive (--lib <path> [--os macos|ios|android|linux|windows|generic] \\\n\
  \        [--host swiftui|web|kotlin|generic] \\\n\
  \        [--env NAME=VALUE]... | --socket <path> | --tcp <host:port> | --ws-listen <port>) \\\n\
  \        <scenario.drive>"

let main () =
  (* a dead host ws must not kill the scenario mid-send — surface the
     write error as an exception instead of a SIGPIPE exit *)
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  let lib = ref "" in
  let socket = ref "" in
  let tcp = ref "" in
  let ws_listen = ref 0 in
  let os = ref "generic" in
  let host = ref "generic" in
  let env = ref [] in
  let scenario = ref "" in
  let input = ref Drive.Input.Semantic in
  let timeout = ref 5.0 in
  let anon s =
    if !scenario = "" then scenario := s
    else failwith ("unexpected argument: " ^ s)
  in
  Arg.parse
    [
      ("--lib", Arg.Set_string lib, "shared library exporting lui_ocaml_* ABI");
      ("--socket", Arg.Set_string socket, "attach to a live app's MENG_DRIVE_SOCKET");
      ("--tcp", Arg.Set_string tcp, "HOST:PORT  attach to a loopback native host (e.g. 127.0.0.1:49377)");
      ( "--ws-listen",
        Arg.Set_int ws_listen,
        "PORT  accept a WebSocket host attach (web: page dials out to drive)" );
      ("--os", Arg.Set_string os, "target os profile (default generic)");
      ("--input", Arg.Symbol ([ "semantic"; "native" ],
        (function "native" -> input := Drive.Input.Native | _ -> input := Drive.Input.Semantic)),
        "MODE  semantic injection (default) or acknowledged native host input");
      ("--action-timeout", Arg.Set_float timeout, "SECONDS  host snapshot/action timeout (default 5)");
      ("--host", Arg.Set_string host, "target host profile (default generic)");
      ("--env", Arg.String (fun kv -> env := kv :: !env), "NAME=VALUE for the target process env");
    ]
    anon usage;
  let targets = List.filter Fun.id [ !lib <> ""; !socket <> ""; !tcp <> ""; !ws_listen <> 0 ] in
  if List.length targets <> 1 || !scenario = "" then begin
    prerr_endline usage;
    exit 2
  end;
  if !input = Drive.Input.Native && !lib <> "" then
    failwith "drive: native input requires --socket, --tcp or --ws-listen; FFI only supports semantic injection";
  if not (Float.is_finite !timeout) || !timeout <= 0.0 then
    failwith "drive: --action-timeout must be a finite positive number";
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
    | "android" -> Lui_protocol.AndroidOS
    | "linux" -> Lui_protocol.LinuxOS
    | "windows" -> Lui_protocol.WindowsOS
    | "generic" -> Lui_protocol.GenericOS
    | other -> failwith ("bad --os: " ^ other)
  in
  let host_kind =
    match !host with
    | "swiftui" -> Lui_protocol.SwiftUIHost
    | "web" -> Lui_protocol.WebHost
    | "kotlin" -> Lui_protocol.KotlinHost
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
      (Drive.Live.driver ~timeout:!timeout live, fun () -> Drive.Live.close live)
    else if !tcp <> "" then
      let host, port =
        match String.rindex_opt !tcp ':' with
        | Some colon ->
          let host = String.sub !tcp 0 colon in
          let host = if host = "[::1]" then "::1" else host in
          let port =
            String.sub !tcp (colon + 1) (String.length !tcp - colon - 1)
          in
          (match int_of_string_opt port with
          | Some port -> host, port
          | None -> failwith "drive: --tcp expects a loopback HOST:PORT")
        | None -> failwith "drive: --tcp expects a loopback HOST:PORT"
      in
      let live = Drive.Live.connect_tcp ~host ~port in
      (Drive.Live.driver ~timeout:!timeout live, fun () -> Drive.Live.close live)
    else if !ws_listen <> 0 then
      let live =
        try Drive.Live.listen_ws ~port:!ws_listen
        with
        | Unix.Unix_error (e, _, _) ->
          Printf.eprintf "drive: ws-listen %d: %s\n" !ws_listen
            (Unix.error_message e);
          exit 2
        | Failure msg ->
          Printf.eprintf "drive: ws-listen %d: %s\n" !ws_listen msg;
          exit 2
      in
      (Drive.Live.driver ~timeout:!timeout live, fun () -> Drive.Live.close live)
    else
      let target =
        try Drive.Ffi.open_target ~path:!lib ~os:os_kind ~host:host_kind
        with Failure msg ->
          prerr_endline msg;
          exit 2
      in
      (Drive.Ffi.driver target, fun () -> ignore (Drive.Ffi.stop target))
  in
  let failures =
    Fun.protect ~finally:stop (fun () ->
      Drive.Scenario.run ~input:!input ~emit:print_endline driver source)
  in
  List.iter
    (fun (f : Drive.Scenario.failure) ->
      Printf.eprintf "line %d: %s\n" f.line f.message)
    failures;
  exit (if failures = [] then 0 else 1)

let () =
  try main () with
  | Failure msg | Invalid_argument msg | Sys_error msg -> prerr_endline msg; exit 2
  | Unix.Unix_error (e, call, _) ->
    Printf.eprintf "drive: %s: %s\n" call (Unix.error_message e);
    exit 2
