(* Live attach driver: connect to a running app's MENG_DRIVE_SOCKET
   Unix socket. The app replays every patch batch emitted since start
   (one JSON object per line) then streams live ones — the exact same
   stream the native renderer sees. Events are injected as newline JSON
   { "event": "press", "id": N, ... }. *)
open Lui_protocol

type t = {
  oc : out_channel;
  queue : string Queue.t;
  mu : Mutex.t;
  tree : Model.t;
}

let connect ~socket_path =
  let sock = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.connect sock (Unix.ADDR_UNIX socket_path);
  let t =
    {
      oc = Unix.out_channel_of_descr sock;
      queue = Queue.create ();
      mu = Mutex.create ();
      tree = Model.create ();
    }
  in
  ignore
    (Thread.create
       (fun () ->
          let ic = Unix.in_channel_of_descr sock in
          try
            while true do
              let line = input_line ic in
              Mutex.lock t.mu;
              Queue.add line t.queue;
              Mutex.unlock t.mu
            done
          with _ -> ())
       ());
  t

let drain t =
  Mutex.lock t.mu;
  let lines = List.of_seq (Queue.to_seq t.queue) in
  Queue.clear t.queue;
  Mutex.unlock t.mu;
  List.iter
    (fun line -> Model.apply_wire_batch t.tree (Yojson.Safe.from_string line))
    lines;
  lines <> []

let poll t = ignore (drain t)

let send t json =
  output_string t.oc (Yojson.Safe.to_string json);
  output_char t.oc '\n';
  flush t.oc

let wire_to_json = function
  | StringValue s -> `String s
  | BoolValue b -> `Bool b
  | IntValue i -> `Int i
  | FloatValue f -> `Float f

let id_fields name id = [ ("event", `String name); ("id", `Int id) ]

let send_event t = function
  | Press id -> send t (`Assoc (id_fields "press" id))
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

let driver t =
  {
    Session.tree = t.tree;
    send_event = (fun ev -> send_event t ev; poll t);
    poll = (fun () -> poll t);
  }
