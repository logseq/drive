(* .drive scenario DSL: line-oriented commands driving a `driver`.
     # comment
     press <sel> | tap <sel>
     type <sel> "text"          — TextChanged
     key "cmd+p"                — ExtensionEvent on ext:key-surface
     ext <sel> <identifier> <name> '<json fields>'
     submit|dismiss|appear|long-press|double-press <sel>
     toggle <sel> true|false
     value <sel> 0.5
     poll                       — drain async actions once
     wait <sel> [seconds]       — poll until selector matches (default 5s)
     expect <sel>
     expect-absent <sel>
     expect-prop <sel> <name> <value>
     sleep <seconds>
     dump

   <sel> = id:N | kind:name | ext:identifier | text:needle | prop:name=value
   Bare words without a prefix are treated as text: selectors. *)

open Lui_protocol

type failure = { line : int; message : string }

exception Script_error of string


(* Minimal tokenizer: splits on spaces but keeps quoted spans together;
   quotes may appear mid-token (e.g. kind:button&text:"Open dialog"). *)
let tokens line =
  let n = String.length line in
  let buf = Buffer.create 16 in
  let rec next i acc =
    if i >= n then List.rev (if Buffer.length buf > 0 then Buffer.contents buf :: acc else acc)
    else
      match line.[i] with
      | ' ' | '\t' ->
        if Buffer.length buf > 0 then begin
          let tok = Buffer.contents buf in
          Buffer.clear buf;
          next (i + 1) (tok :: acc)
        end
        else next (i + 1) acc
      | ('"' | '\'') as q ->
        let rec find j = if j >= n || line.[j] = q then j else find (j + 1) in
        let j = find (i + 1) in
        Buffer.add_string buf (String.sub line (i + 1) (j - i - 1));
        next (min n (j + 1)) acc
      | c ->
        Buffer.add_char buf c;
        next (i + 1) acc
  in
  next 0 []

let selector tok =
  match Model.selector_of_string tok with
  | Some s -> s
  | None -> raise (Script_error ("bad selector: " ^ tok))

let node d sel = Session.resolve d sel

let string_map fields =
  List.fold_left (fun acc (k, v) -> String_map.add k v acc) String_map.empty fields

let json_to_fields json_str =
  match Yojson.Safe.from_string json_str with
  | `Assoc fields ->
    List.filter_map
      (fun (k, v) ->
        match Model.wire_value_of_json v with
        | Some w -> Some (k, w)
        | None -> None)
      fields
    |> string_map
  | _ -> String_map.empty

let wait_for (d : Session.driver) sel timeout =
  let deadline = Unix.gettimeofday () +. timeout in
  let rec loop () =
    if Model.exists d.Session.tree sel then ()
    else if Unix.gettimeofday () > deadline then
      raise (Script_error "timeout")
    else begin
      d.Session.poll ();
      if Model.exists d.Session.tree sel then ()
      else begin
        Unix.sleepf 0.02;
        loop ()
      end
    end
  in
  loop ()

let run_line ~emit (d : Session.driver) lineno line =
  let line = String.trim line in
  if line = "" || line.[0] = '#' then []
  else
    let ts = tokens line in
    let fail msg = [ { line = lineno; message = msg } ] in
    try
      match ts with
      | ("press" | "tap") :: sel :: _ ->
        let n = node d (selector sel) in
        d.Session.send_event (Press n.Model.id);
        []
      | "long-press" :: sel :: _ ->
        let n = node d (selector sel) in
        d.Session.send_event (LongPress n.id);
        []
      | "double-press" :: sel :: _ ->
        let n = node d (selector sel) in
        d.Session.send_event (DoublePress n.id);
        []
      | "type" :: sel :: rest ->
        let n = node d (selector sel) in
        d.Session.send_event (TextChanged (n.id, String.concat " " rest));
        []
      | "key" :: combo :: _ ->
        let surface =
          match Model.first d.Session.tree (Ext "key-surface") with
          | Some n -> n
          | None -> raise (Script_error "no key-surface node")
        in
        let parts = String.split_on_char '+' combo in
        let mods, key =
          match List.rev parts with
          | k :: ms -> (String.concat "," ms, k)
          | [] -> ("", combo)
        in
        let fields =
          string_map [ ("key", StringValue key); ("mods", StringValue mods) ]
        in
        d.Session.send_event (ExtensionEvent (surface.id, "key-surface", "key", fields));
        []
      | "ext" :: sel :: identifier :: name :: rest ->
        let n = node d (selector sel) in
        let fields = json_to_fields (String.concat " " rest) in
        d.Session.send_event (ExtensionEvent (n.id, identifier, name, fields));
        []
      | "submit" :: sel :: _ ->
        let n = node d (selector sel) in
        d.Session.send_event (Submit n.id);
        []
      | "dismiss" :: sel :: _ ->
        let n = node d (selector sel) in
        d.Session.send_event (Dismiss n.id);
        []
      | "appear" :: sel :: _ ->
        let n = node d (selector sel) in
        d.Session.send_event (Appear n.id);
        []
      | "toggle" :: sel :: v :: _ ->
        let n = node d (selector sel) in
        d.Session.send_event (ToggleChanged (n.id, v = "true" || v = "1"));
        []
      | "value" :: sel :: v :: _ ->
        let n = node d (selector sel) in
        d.Session.send_event (ValueChanged (n.id, float_of_string v));
        []
      | "poll" :: _ ->
        d.Session.poll ();
        []
      | ("wait" | "expect") :: sel :: rest ->
        let timeout =
          match rest with
          | v :: _ -> (try float_of_string v with _ -> 5.0)
          | [] -> (if List.hd ts = "wait" then 5.0 else 0.0)
        in
        if timeout <= 0.0 then begin
          d.Session.poll ();
          if Model.exists d.Session.tree (selector sel) then []
          else fail ("expected node: " ^ sel)
        end
        else begin
          try wait_for d (selector sel) timeout; []
          with Script_error _ -> fail ("timed out waiting for: " ^ sel)
        end
      | "expect-absent" :: sel :: _ ->
        d.Session.poll ();
        if Model.exists d.Session.tree (selector sel) then fail ("unexpected node present: " ^ sel)
        else []
      | "expect-prop" :: sel :: name :: v :: _ ->
        d.Session.poll ();
        let n = node d (selector sel) in
        (match Model.prop d.Session.tree n.id name with
         | Some (StringValue s) when s = v -> []
         | Some (BoolValue b) when string_of_bool b = v -> []
         | Some (IntValue i) when string_of_int i = v -> []
         | Some w ->
           fail
             (Printf.sprintf "prop %s on #%d = %s, want %s" name n.id
                (Model.string_of_wire_value w) v)
         | None -> fail (Printf.sprintf "no prop %s on #%d" name n.id))
      | "sleep" :: v :: _ ->
        Unix.sleepf (float_of_string v);
        []
      | "dump" :: _ ->
        emit (Model.dump d.Session.tree);
        []
      | cmd :: _ -> fail ("unknown command: " ^ cmd)
      | [] -> []
    with
    | Script_error msg -> fail msg
    | Failure msg -> fail msg
    | e -> fail (Printexc.to_string e)

let run ?(emit = print_endline) (d : Session.driver) source =
  let failures =
    String.split_on_char '\n' source
    |> List.mapi (fun i line -> (i + 1, line))
    |> List.concat_map (fun (i, line) -> run_line ~emit d i line)
  in
  d.Session.poll ();
  failures
