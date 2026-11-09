(* Live attach driver: connect to a running app's MENG_DRIVE_SOCKET
   Unix socket. The app replays every patch batch emitted since start
   (one JSON object per line) then streams live ones — the exact same
   stream the native renderer sees. Events are injected as newline JSON
   { "event": "press", "id": N, ... }.

   Frames support legacy geometry-assisted semantic dispatch. Native
   input uses a versioned capability handshake and request/result pairs. *)
open Lui_protocol

type t = {
  send_line : string -> unit;
  send_line_until : (deadline:float -> string -> unit) option;
  queue : string Queue.t;
  mu : Mutex.t;
  tree : Model.t;
  frames : (int, Model.rect) Hashtbl.t;
  mutable capabilities : string list option;
  mutable protocol_error : string option;
  mutable ready : bool;
  mutable next_request : int;
  mutable pending : int option;
  mutable reply : Yojson.Safe.t option;
  mutable disconnected : bool;
  mutable closed : bool;
  close_transport : unit -> unit;
}

let create ?(close = fun () -> ()) ?send_line_until ~send_line () =
  { send_line; send_line_until; queue = Queue.create (); mu = Mutex.create ();
    tree = Model.create (); frames = Hashtbl.create 64;
    capabilities = None; protocol_error = None; ready = false;
    next_request = 0; pending = None; reply = None; disconnected = false; closed = false;
    close_transport = close }

let mark_disconnected t =
  Mutex.lock t.mu;
  t.disconnected <- true;
  Mutex.unlock t.mu

let close t =
  Mutex.lock t.mu;
  let closing = not t.closed in
  t.closed <- true;
  t.disconnected <- true;
  Mutex.unlock t.mu;
  if closing then t.close_transport ()

let enqueue t line =
  Mutex.lock t.mu;
  Queue.add line t.queue;
  Mutex.unlock t.mu

external send_nonblocking : Unix.file_descr -> string -> int -> int -> int
  = "drive_send_nonblocking"

let socket_io sock ic =
  let closed = Atomic.make false in
  let write_mu = Mutex.create () in
  let check deadline =
    if Atomic.get closed then failwith "drive: live host disconnected";
    if Unix.gettimeofday () >= deadline then failwith "host write timed out"
  in
  let write_until ~deadline parts =
    let rec lock () =
      check deadline;
      if not (Mutex.try_lock write_mu) then begin
        Unix.sleepf (min 0.005 (max 0.0 (deadline -. Unix.gettimeofday ())));
        lock ()
      end
    in
    lock ();
    Fun.protect ~finally:(fun () -> Mutex.unlock write_mu) (fun () ->
      List.iter (fun data ->
        let rec write offset =
          check deadline;
          if offset < String.length data then
            match send_nonblocking sock data offset (String.length data - offset) with
            | 0 -> failwith "drive: live host disconnected"
            | n -> write (offset + n)
            | exception Unix.Unix_error (Unix.EINTR, _, _) -> write offset
            | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) ->
              let remaining = deadline -. Unix.gettimeofday () in
              let wait = if Float.is_finite remaining then max 0.0 remaining else -1.0 in
              (try ignore (Unix.select [] [sock] [] wait)
               with Unix.Unix_error (Unix.EINTR, _, _) -> ());
              write offset
        in
        write 0) parts)
  in
  let close () =
    Atomic.set closed true;
    (try Unix.shutdown sock Unix.SHUTDOWN_ALL with Unix.Unix_error _ -> ());
    Mutex.lock write_mu;
    Fun.protect ~finally:(fun () -> Mutex.unlock write_mu) (fun () -> close_in_noerr ic)
  in
  write_until, close

let connect_stream ~domain address =
  let sock = Unix.socket domain Unix.SOCK_STREAM 0 in
  (try Unix.connect sock address with exn -> Unix.close sock; raise exn);
  let ic = Unix.in_channel_of_descr sock in
  let write_until, close = socket_io sock ic in
  let send_line_until ~deadline s = write_until ~deadline [s; "\n"] in
  let t =
    create ~close ~send_line_until
      ~send_line:(send_line_until ~deadline:infinity) ()
  in
  ignore
    (Thread.create
       (fun () ->
          try
            while true do
              enqueue t (input_line ic)
            done
          with _ -> mark_disconnected t)
       ());
  t

let connect ~socket_path =
  connect_stream ~domain:Unix.PF_UNIX (Unix.ADDR_UNIX socket_path)

let connect_tcp ~host ~port =
  if port < 1 || port > 65535 then
    invalid_arg "drive: TCP port must be between 1 and 65535";
  let domain, address =
    match host with
    | "127.0.0.1" | "localhost" -> Unix.PF_INET, Unix.inet_addr_loopback
    | "::1" -> Unix.PF_INET6, Unix.inet6_addr_loopback
    | _ -> invalid_arg "drive: TCP attach must use 127.0.0.1, localhost or [::1]"
  in
  connect_stream ~domain (Unix.ADDR_INET (address, port))

(* Browser hosts cannot accept connections, so for web attach the page
   dials out: `drive --ws-listen <port>` accepts a WebSocket and speaks
   the same line protocol (each text message = one line). *)
let listen_ws ~port =
  let srv = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt srv Unix.SO_REUSEADDR true;
  Unix.bind srv (Unix.ADDR_INET (Unix.inet_addr_loopback, port));
  Unix.listen srv 1;
  Printf.eprintf
    "drive: ws listening on 127.0.0.1:%d — open the host page with\n\
     drive:   ?drive=ws://127.0.0.1:%d\n%!"
    port port;
  let conn, _ = Unix.accept srv in
  Unix.close srv;
  Unix.setsockopt conn Unix.TCP_NODELAY true;
  let ic = Unix.in_channel_of_descr conn
  and oc = Unix.out_channel_of_descr (Unix.dup conn) in
  let accepted =
    try Fun.protect ~finally:(fun () -> close_out_noerr oc)
      (fun () -> Ws.accept_handshake ic oc)
    with exn -> close_in_noerr ic; raise exn
  in
  if not accepted then begin
    close_in_noerr ic;
    failwith "drive: bad websocket handshake"
  end;
  let write_until, close = socket_io conn ic in
  let write ?(opcode = 1) ~deadline s =
    write_until ~deadline [Ws.frame_header ~opcode (String.length s); s]
  in
  let t =
    create ~close ~send_line_until:(fun ~deadline s -> write ~deadline s)
      ~send_line:(fun s -> write ~deadline:infinity s) ()
  in
  ignore
    (Thread.create
       (fun () ->
          try
            let frags = Buffer.create 4096 in
            let rec loop () =
              match Ws.read_frame ic with
              | `Text (payload, true) ->
                if Buffer.length frags = 0 then enqueue t payload
                else begin
                  Buffer.add_string frags payload;
                  enqueue t (Buffer.contents frags);
                  Buffer.clear frags
                end;
                loop ()
              | `Text (payload, false) ->
                Buffer.add_string frags payload;
                loop ()
              | `Cont (payload, fin) ->
                Buffer.add_string frags payload;
                if fin then begin
                  enqueue t (Buffer.contents frags);
                  Buffer.clear frags
                end;
                loop ()
              | `Ping payload ->
                write ~opcode:10 ~deadline:infinity payload;
                loop ()
              | `Pong | `Skip -> loop ()
              | `Close | `Eof -> mark_disconnected t
            in
            loop ()
          with _ -> mark_disconnected t)
       ());
  t

(* One line from the socket: either a frames snapshot or a patch batch.
   Exposed for tests — the reader thread queues raw lines and drain
   applies them through here. *)
let ingest_line t line =
  let json = Yojson.Safe.from_string line in
  let member name = Yojson.Safe.Util.member name json in
  match member "drive" with
  | `String kind ->
    if member "version" <> `Int 1 then
      t.protocol_error <- Some "unsupported drive protocol version (expected 1)"
    else if kind = "hello" then (
      match member "capabilities" with
      | `List xs when List.for_all (function `String _ -> true | _ -> false) xs ->
        t.capabilities <- Some (List.map Yojson.Safe.Util.to_string xs)
      | _ -> t.protocol_error <- Some "invalid host capabilities")
    else if kind = "result" then (
      match member "request", t.pending with
      | `Int request, Some expected when request = expected -> t.reply <- Some json
      | _ -> ())
    else t.protocol_error <- Some ("unknown drive message: " ^ kind)
  | `Null -> (
  match member "frames" with
  | `List entries ->
    Hashtbl.reset t.frames;
    List.iter
      (fun entry ->
        match entry with
        | `List (`Int id :: rest) -> (
          try
            match List.map Yojson.Safe.Util.to_number rest with
            | [ x; y; w; h ] ->
              Hashtbl.replace t.frames id
                { Model.rx = x; ry = y; rw = w; rh = h }
            | _ -> ()
          with _ -> ())
        | _ -> ())
      entries
  | _ ->
    Model.apply_wire_batch t.tree json;
    if (match member "ops" with `List _ -> true | _ -> false) then t.ready <- true)
  | _ -> t.protocol_error <- Some "invalid drive message"

let drain t =
  Mutex.lock t.mu;
  let lines = List.of_seq (Queue.to_seq t.queue) in
  Queue.clear t.queue;
  Mutex.unlock t.mu;
  List.iter (ingest_line t) lines;
  lines <> []

let poll t =
  ignore (drain t);
  Option.iter failwith t.protocol_error;
  if t.disconnected then failwith "drive: live host disconnected"

let send t json = t.send_line (Yojson.Safe.to_string json)

let await_until t ~deadline predicate =
  let rec loop () =
    poll t;
    if Unix.gettimeofday () >= deadline then Error "host completion timed out"
    else if predicate () then Ok ()
    else (Unix.sleepf (min 0.005 (max 0.0 (deadline -. Unix.gettimeofday ()))); loop ())
  in
  loop ()

let await t ~timeout predicate =
  await_until t ~deadline:(Unix.gettimeofday () +. timeout) predicate

let abort t msg =
  t.protocol_error <- Some msg;
  (try close t with _ -> ());
  Error msg

let native_request t ~timeout action =
  let deadline = Unix.gettimeofday () +. timeout in
  let name, fields = Input.request action in
  let context request msg =
    Printf.sprintf "native %s request %d: %s" name request msg
  in
  poll t;
  match t.protocol_error, t.capabilities with
  | Some msg, _ -> Error msg
  | None, None -> Error "native input requires a versioned host capability handshake; no semantic fallback"
  | None, Some caps when not (List.mem name caps) ->
    Error ("native host does not support: " ^ name)
  | None, Some _ ->
    t.next_request <- t.next_request + 1;
    let request = t.next_request in
    t.pending <- Some request;
    t.reply <- None;
    Fun.protect ~finally:(fun () -> t.pending <- None; t.reply <- None) (fun () ->
      let line = Yojson.Safe.to_string (`Assoc
        ([ ("drive", `String "action"); ("version", `Int 1);
           ("request", `Int request); ("action", `String name) ] @ fields)) in
      if Unix.gettimeofday () >= deadline then failwith "host write timed out";
      (match t.send_line_until with
       | Some write -> write ~deadline line
       | None -> t.send_line line);
      match await_until t ~deadline (fun () -> Option.is_some t.reply) with
      | Error msg ->
        abort t (context request msg)
      | Ok () ->
        match t.reply with
        | None -> Error (context request "missing result")
        | Some reply ->
          let member key = Yojson.Safe.Util.member key reply in
          match member "ok" with
          | `Bool false ->
            let msg = match member "error" with
              | `String s -> s | _ -> "host rejected action without an error message"
            in
            Error (context request msg)
          | `Bool true when action = Input.Screenshot -> (
            match member "png" with
            | `String data -> (
              match Base64.decode data with
              | Ok png when String.starts_with ~prefix:"\137PNG\r\n\026\n" png -> Ok (Input.Png png)
              | _ -> Error (context request "invalid PNG screenshot"))
            | _ -> Error (context request "missing PNG screenshot"))
          | `Bool true -> Ok Input.Completed
          | _ -> Error (context request "invalid completion result"))

let native t ~timeout action =
  if not (Float.is_finite timeout) || timeout <= 0.0 then
    invalid_arg "drive: timeout must be a finite positive number";
  let fail msg =
    let name, _ = Input.request action in
    let msg = Printf.sprintf "native %s request %d: %s" name t.next_request msg in
    abort t msg
  in
  match t.protocol_error with
  | Some msg -> Error msg
  | None ->
    try native_request t ~timeout action with
    | Failure msg | Sys_error msg | Yojson.Json_error msg -> fail msg
    | Yojson.Safe.Util.Type_error (msg, _) -> fail ("invalid host message: " ^ msg)
    | Unix.Unix_error (e, _, _) -> fail (Unix.error_message e)

let send_nav t hash =
  send t (`Assoc [ ("event", `String "nav"); ("hash", `String hash) ])

let wire_to_json = function
  | StringValue s -> `String s
  | BoolValue b -> `Bool b
  | IntValue i -> `Int i
  | FloatValue f -> `Float f

let id_fields name id = [ ("event", `String name); ("id", `Int id) ]

let detail_fields (d : pointer_detail) =
  [ ("x", `Float d.x); ("y", `Float d.y); ("modifiers", `Int d.modifiers)
  ; ("button", `Int d.button); ("target_class", `String d.target_class) ]

let send_event t = function
  | NavigatePrevious _ | NavigateNext _ | NavigationKey _ | ScrollEdges _
  | VirtualWindow _ | PointerMove _ | PointerCancel _ | ToggleChangedDetail _
  | FocusWithinChanged _ ->
    failwith "drive: semantic event is not supported by the live bridge"
  | Press id -> send t (`Assoc (id_fields "press" id))
  | PressModifiers (id, modifiers) ->
    send t (`Assoc (id_fields "press-modifiers" id @ [ ("modifiers", `Int modifiers) ]))
  | PressDetail (id, d) ->
    send t (`Assoc (id_fields "press-detail" id @ detail_fields d))
  | PointerDown (id, d) ->
    send t (`Assoc (id_fields "pointer-down" id @ detail_fields d))
  | PointerUp (id, d) ->
    send t (`Assoc (id_fields "pointer-up" id @ detail_fields d))
  | PointerEnter id -> send t (`Assoc (id_fields "pointer-enter" id))
  | PointerLeave id -> send t (`Assoc (id_fields "pointer-leave" id))
  | ContextMenuPress (id, d) ->
    send t (`Assoc (id_fields "context-menu" id @ detail_fields d))
  | Load id -> send t (`Assoc (id_fields "load" id))
  | LongPress id -> send t (`Assoc (id_fields "long-press" id))
  | DoublePress id -> send t (`Assoc (id_fields "double-press" id))
  | Appear id -> send t (`Assoc (id_fields "appear" id))
  | Submit id -> send t (`Assoc (id_fields "submit" id))
  | Dismiss id -> send t (`Assoc (id_fields "dismiss" id))
  | Change id -> send t (`Assoc (id_fields "change" id))
  | TextChanged (id, value) ->
    send t (`Assoc (id_fields "text" id @ [ ("value", `String value) ]))
  | ToggleChanged (id, value) ->
    send t (`Assoc (id_fields "toggle" id @ [ ("value", `Bool value) ]))
  | ValueChanged (id, value) ->
    send t (`Assoc (id_fields "value" id @ [ ("value", `Float value) ]))
  | ScrollCompleted (id, offset, direction) ->
    send
      t
      (`Assoc
        (id_fields "scroll-completed" id
        @ [ ("offset", `Int offset); ("direction", `String direction) ]))
  | VisibleRange (id, first, last) ->
    send
      t
      (`Assoc
        (id_fields "visible-range" id
        @ [ ("first", `Int first); ("last", `Int last) ]))
  | Picked (id, value) ->
    send t (`Assoc (id_fields "picked" id @ [ ("value", `String value) ]))
  | ExtensionEvent (id, ident, name, fields) ->
    let fields_json =
      `Assoc
        (String_map.fold
           (fun k v acc -> (k, wire_to_json v) :: acc)
           fields [])
    in
    send
      t
      (`Assoc
         (id_fields "ext" id
         @ [ ("ident", `String ident); ("name", `String name); ("fields", fields_json) ]))

(* Resolve (x, y) against the latest reported frames, then press the
   node a gesture recognizer would fire on: deepest containing node,
   walking ancestors to the first pressable one. *)
let tap t ~x ~y =
  poll t;
  if Hashtbl.length t.frames = 0 then
    Error "no frames reported — is the host's frame reporting on?"
  else
    match Model.hit_test t.tree ~frames:t.frames ~x ~y with
    | Some id ->
      Printf.eprintf "[tap] (%.1f,%.1f) -> #%d\n%!" x y id;
      send t (`Assoc (id_fields "press" id));
      Ok id
    | None ->
      Error (Printf.sprintf "no pressable node at (%.1f, %.1f)" x y)

let frames_list t =
  Hashtbl.fold (fun id r acc -> (id, r) :: acc) t.frames []

let driver ?(timeout = 5.0) t =
  if not (Float.is_finite timeout) || timeout <= 0.0 then
    invalid_arg "drive: timeout must be a finite positive number";
  (match await t ~timeout (fun () -> t.ready) with
   | Ok () -> ()
   | Error msg -> failwith ("drive: initial host snapshot: " ^ msg));
  {
    Session.tree = t.tree;
    send_event = (fun ev -> send_event t ev; poll t);
    poll = (fun () -> poll t);
    tap = (fun ~x ~y -> tap t ~x ~y);
    frames = (fun () -> frames_list t);
    native = (fun action -> native t ~timeout action);
    send_nav = (fun h -> send_nav t h);
  }
