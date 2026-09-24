(* FFI driver: drives a shared library exporting the lui_ocaml_* bridge
   ABI (the meng-style dylib/.so the SwiftUI host loads) headlessly.
   The C shim queues patch JSON; here we pop batches, decode the wire
   format into the same Model, and expose the generic `driver` surface. *)

open Lui_protocol

type t_ext (* opaque custom block holding the dlopen'd target *)

external c_open : string -> t_ext = "drive_target_open"
external c_start : t_ext -> int -> int -> int = "drive_target_start"
external c_event :
  t_ext -> string -> int64 -> string -> string -> string -> int -> float -> int
  = "drive_target_event_bc" "drive_target_event"
external c_poll : t_ext -> int = "drive_target_poll"
external c_next : t_ext -> string option = "drive_target_next"
external c_stop : t_ext -> int = "drive_target_stop"
external c_root : t_ext -> int64 = "drive_target_root"

type t = {
  handle : t_ext;
  tree : Model.t;
}

let os_code = function MacOS -> 1 | IOS -> 2 | _ -> 0
let host_code = function SwiftUIHost -> 2 | _ -> 0

let wire_json = function
  | StringValue s -> `String s
  | BoolValue b -> `Bool b
  | IntValue i -> `Int i
  | FloatValue f -> `Float f

(* Drain queued patch JSON into the model. Returns true if anything arrived. *)
let drain t =
  let rec loop saw =
    match c_next t.handle with
    | Some json -> (
      match Yojson.Safe.from_string json with
      | batch ->
        Model.apply_wire_batch t.tree batch;
        loop true
      | exception _ -> loop saw)
    | None -> saw
  in
  loop false

let poll t =
  ignore (c_poll t.handle);
  drain t

let send t name node a b c iv fv =
  ignore (c_event t.handle name node a b c iv fv);
  (* Events are queued to the target's dispatcher thread; give it a brief
     grace window so an emitted patch usually lands before we continue.
     Scenario `wait` does the real waiting for slower effects. *)
  let deadline = Unix.gettimeofday () +. 0.2 in
  while not (drain t) && Unix.gettimeofday () < deadline do
    Unix.sleepf 0.005
  done;
  ignore (drain t)

let send_event t = function
  | Press n -> send t "press" (Int64.of_int n) "" "" "" 0 0.0
  | LongPress n -> send t "long_press" (Int64.of_int n) "" "" "" 0 0.0
  | DoublePress n -> send t "double_press" (Int64.of_int n) "" "" "" 0 0.0
  | Appear n -> send t "appear" (Int64.of_int n) "" "" "" 0 0.0
  | Submit n -> send t "submit" (Int64.of_int n) "" "" "" 0 0.0
  | Dismiss n -> send t "dismiss" (Int64.of_int n) "" "" "" 0 0.0
  | Change n -> send t "radio_changed" (Int64.of_int n) "" "" "" 0 0.0
  | TextChanged (n, text) -> send t "text_changed" (Int64.of_int n) text "" "" 0 0.0
  | ToggleChanged (n, checked) ->
    send t "toggle_changed" (Int64.of_int n) "" "" "" (if checked then 1 else 0) 0.0
  | ValueChanged (n, v) -> send t "slider_changed" (Int64.of_int n) "" "" "" 0 v
  | ExtensionEvent (n, identifier, name, fields) ->
    let fields_json =
      `Assoc (String_map.fold (fun k v acc -> (k, wire_json v) :: acc) fields [])
      |> Yojson.Safe.to_string
    in
    send t "extension" (Int64.of_int n) identifier name fields_json 0 0.0

let stop t = ignore (c_stop t.handle)
let root_node t = c_root t.handle

let open_target ~path ~os ~host =
  (* The target process talks to children over pipes; a dead child's
     write would otherwise kill the whole process via SIGPIPE. *)
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  let handle = c_open path in
  let t = { handle; tree = Model.create () } in
  if c_start handle (os_code os) (host_code host) = 0 then
    failwith "drive: lui_ocaml_start failed";
  (* The mount patch arrives asynchronously on the target's threads. *)
  let deadline = Unix.gettimeofday () +. 5.0 in
  while Model.node_count t.tree = 0 && Unix.gettimeofday () < deadline do
    if not (drain t) then Unix.sleepf 0.01
  done;
  t

let driver t =
  { Session.tree = t.tree; send_event = (fun ev -> send_event t ev); poll = (fun () -> (ignore (poll t) : unit)) }
