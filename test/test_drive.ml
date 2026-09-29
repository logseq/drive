open Drive
open Drive.Model
open Lui_protocol

let mount_demo () =
  Session.mount ~profile:Drive.profile_generic ~initial:Demo_app.initial
    ~reducer:Demo_app.reducer ~view:Demo_app.view ()

(* ---------- model: op replay ---------- *)

let test_op_replay () =
  let m = Model.create () in
  Model.apply_op m (CreateNode (1, Column));
  Model.apply_op m (CreateNode (2, Button));
  Model.apply_op m (InsertChild (1, 2, 0));
  Model.apply_op m (SetProp (2, TextValue, StringValue "Save"));
  Alcotest.(check int) "two nodes" 2 (Model.node_count m);
  Alcotest.(check bool) "text found" true
    (Model.exists m (Model.Text "Save"));
  let kids = Model.children m 1 in
  Alcotest.(check int) "one child" 1 (List.length kids);
  Model.apply_op m (DropNode 1);
  Alcotest.(check int) "drop removes subtree" 0 (Model.node_count m)

let test_selector_parse () =
  let open Model in
  Alcotest.(check bool) "kind" true
    (selector_of_string "kind:dialog" = Some (Kind "dialog"));
  Alcotest.(check bool) "ext" true
    (selector_of_string "ext:web-view" = Some (Ext "web-view"));
  Alcotest.(check bool) "id" true (selector_of_string "id:42" = Some (Id 42));
  Alcotest.(check bool) "bare id" true (selector_of_string "42" = Some (Id 42));
  Alcotest.(check bool) "quoted text" true
    (selector_of_string "text:\"hello world\"" = Some (Text "hello world"));
  Alcotest.(check bool) "prop" true
    (selector_of_string "prop:placeholder=Search"
    = Some (Prop ("placeholder", StringValue "Search")));
  Alcotest.(check bool) "prop prefix" true
    (selector_of_string "prop:id=block-content-*"
    = Some (PropPrefix ("id", "block-content-")))

let test_wire_batch () =
  let m = Model.create () in
  let batch =
    Yojson.Safe.from_string
      {|{"generation":3,"ops":[
         {"op":"create-node","id":1,"kind":"column"},
         {"op":"create-node","id":2,"kind":"text-field"},
         {"op":"insert-child","parent":1,"child":2,"index":0},
         {"op":"set-prop","id":2,"property":"placeholder","value":"Search"},
         {"op":"create-extension","id":3,"identifier":"web-view","fingerprint":"abc"},
         {"op":"insert-child","parent":1,"child":3,"index":1}
       ]}|}
  in
  Model.apply_wire_batch m batch;
  Alcotest.(check bool) "text-field" true (Model.exists m (Kind "text-field"));
  Alcotest.(check bool) "extension" true (Model.exists m (Ext "web-view"));
  Alcotest.(check bool) "prop" true
    (Model.exists m (Prop ("placeholder", StringValue "Search")));
  Alcotest.(check bool) "prop prefix hit" true
    (Model.exists m (PropPrefix ("placeholder", "Sea")));
  Alcotest.(check bool) "prop prefix miss" false
    (Model.exists m (PropPrefix ("placeholder", "rch")));
  Alcotest.(check int) "generation" 3 (Model.generation m)

(* ---------- in-process session ---------- *)

let test_mount () =
  let s = mount_demo () in
  Alcotest.(check bool) "counter" true
    (Model.exists s.Session.tree (Text "count=0"));
  Alcotest.(check bool) "button" true
    (Model.exists s.tree (Kind "button"));
  Alcotest.(check bool) "field" true
    (Model.exists s.tree (Kind "text-field"));
  Alcotest.(check bool) "no dialog" false
    (Model.exists s.tree (Kind "dialog"))

let test_press_increments () =
  let s = mount_demo () in
  let btn = Session.resolve (Session.driver s) (All [Kind "button"; Text "Increment"]) in
  Session.press s btn.id;
  Alcotest.(check bool) "count=1" true
    (Model.exists s.tree (Text "count=1"));
  Session.press s btn.id;
  Alcotest.(check bool) "count=2" true
    (Model.exists s.tree (Text "count=2"));
  Alcotest.(check int) "model" 2
    (Session.read_model s).Demo_app.count

let test_typing () =
  let s = mount_demo () in
  let field = Session.resolve (Session.driver s) (Kind "text-field") in
  Session.text_changed s field.id "hello";
  Alcotest.(check bool) "echo" true
    (Model.exists s.tree (Text "typed:hello"))

let test_dialog_open_dismiss () =
  let s = mount_demo () in
  let btn = Session.resolve (Session.driver s) (All [Kind "button"; Text "Open dialog"]) in
  Session.press s btn.id;
  let dlg =
    match Model.first s.tree (Kind "dialog") with
    | Some n -> n
    | None -> Alcotest.fail "dialog not mounted"
  in
  Alcotest.(check bool) "body" true
    (Model.exists s.tree (Text "dialog body"));
  Session.dismiss s dlg.id;
  Alcotest.(check bool) "dialog gone" false
    (Model.exists s.tree (Kind "dialog"))

(* ---------- coordinate hit-testing ---------- *)

(* Tree: 1 column > 2 button ("Increment", press-enabled)
              > 3 text inside 2
   Frames: column fills window, button smaller rect. *)
let frame_tree () =
  let m = Model.create () in
  Model.apply_op m (CreateNode (1, Column));
  Model.apply_op m (CreateNode (2, Button));
  Model.apply_op m (CreateNode (3, Text));
  Model.apply_op m (InsertChild (1, 2, 0));
  Model.apply_op m (InsertChild (2, 3, 0));
  Model.apply_op m (SetProp (2, PressEnabled, BoolValue true));
  Model.apply_op m (SetProp (2, TextValue, StringValue "Increment"));
  m

let frames entries =
  let t = Hashtbl.create 8 in
  List.iter
    (fun (id, rx, ry, rw, rh) ->
      Hashtbl.replace t id { Model.rx; ry; rw; rh })
    entries;
  t

let test_hit_deepest_wins () =
  let m = frame_tree () in
  let fs =
    frames [ (1, 0.0, 0.0, 400.0, 300.0); (2, 10.0, 10.0, 100.0, 40.0);
             (3, 12.0, 12.0, 50.0, 20.0) ]
  in
  (* point inside the label (3) resolves to its pressable parent (2) *)
  Alcotest.(check (option int)) "label -> button" (Some 2)
    (Model.hit_test m ~frames:fs ~x:15.0 ~y:15.0);
  Alcotest.(check (option int)) "button body" (Some 2)
    (Model.hit_test m ~frames:fs ~x:60.0 ~y:30.0)

let test_hit_disabled_blocks () =
  let m = frame_tree () in
  Model.apply_op m (SetProp (2, Enabled, BoolValue false));
  let fs = frames [ (1, 0.0, 0.0, 400.0, 300.0); (2, 0.0, 0.0, 100.0, 40.0) ] in
  Alcotest.(check (option int)) "disabled swallows" None
    (Model.hit_test m ~frames:fs ~x:20.0 ~y:20.0);
  Alcotest.(check (option int)) "miss" None
    (Model.hit_test m ~frames:fs ~x:500.0 ~y:500.0)

let test_hit_overlap_and_stale () =
  let m = Model.create () in
  Model.apply_op m (CreateNode (1, Column));
  Model.apply_op m (CreateNode (2, Button));
  Model.apply_op m (CreateNode (3, Button));
  Model.apply_op m (InsertChild (1, 2, 0));
  Model.apply_op m (InsertChild (1, 3, 1));
  (* 2 and 3 overlap at the same depth; 3 is later in document order and
     paints on top, so it wins the contested point *)
  let fs =
    frames [ (1, 0.0, 0.0, 400.0, 300.0); (2, 10.0, 10.0, 100.0, 40.0);
             (3, 50.0, 10.0, 100.0, 40.0) ]
  in
  Alcotest.(check (option int)) "later sibling on top" (Some 3)
    (Model.hit_test m ~frames:fs ~x:60.0 ~y:30.0);
  (* node 3 is gone from the tree but its frame lingers between
     snapshots: it must not mask node 2 behind it *)
  Model.apply_op m (DropNode 3);
  Alcotest.(check (option int)) "stale frame ignored" (Some 2)
    (Model.hit_test m ~frames:fs ~x:60.0 ~y:30.0)

(* ---------- live attach (socketpair-fed) ---------- *)

let live_stub () =
  let a, b = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  let oc = Unix.out_channel_of_descr a in
  ( {
      Live.send_line =
        (fun s ->
          output_string oc s;
          output_char oc '\n';
          flush oc);
      queue = Queue.create ();
      mu = Mutex.create ();
      tree = Model.create ();
      frames = Hashtbl.create 8;
    },
    b )

let test_live_frames_ingest () =
  let t, peer = live_stub () in
  Live.ingest_line t
    {|{"frames":[[1,0,0,400,300],[2,10.5,20.0,100.0,40.0]]}|};
  Live.ingest_line t
    {|{"generation":1,"ops":[{"op":"create-node","id":1,"kind":"column"},
        {"op":"create-node","id":2,"kind":"button"},
        {"op":"insert-child","parent":1,"child":2,"index":0},
        {"op":"set-prop","id":2,"property":"press-enabled","value":true}]}|};
  Alcotest.(check int) "two frames" 2
    (List.length ((Live.driver t).Session.frames ()));
  Alcotest.(check bool) "button in tree" true
    (Model.exists t.Live.tree (Model.Kind "button"));
  (* tap inside the button frame sends a press for node 2 *)
  (match Live.tap t ~x:20.0 ~y:30.0 with
   | Ok id -> Alcotest.(check int) "hit node 2" 2 id
   | Error msg -> Alcotest.fail msg);
  let ic = Unix.in_channel_of_descr peer in
  let sent = input_line ic in
  Alcotest.(check string) "press emitted" {|{"event":"press","id":2}|}
    sent;
  (* frames snapshots fully replace *)
  Live.ingest_line t {|{"frames":[[9,0,0,10,10]]}|};
  Alcotest.(check int) "replaced" 1
    (List.length ((Live.driver t).Session.frames ()))

let test_live_tap_miss () =
  let t, _ = live_stub () in
  Live.ingest_line t {|{"frames":[[1,0,0,100,100]]}|};
  Model.apply_op t.Live.tree (CreateNode (1, Column));
  (match Live.tap t ~x:200.0 ~y:200.0 with
   | Ok _ -> Alcotest.fail "expected miss"
   | Error msg -> Alcotest.(check bool) "reports miss" true
                    (String.length msg > 0));
  let t2, _ = live_stub () in
  match Live.tap t2 ~x:1.0 ~y:1.0 with
  | Ok _ -> Alcotest.fail "expected frames error"
  | Error msg ->
    Alcotest.(check string) "no frames"
      "no frames reported — is the host's frame reporting on?" msg

(* ---------- scenario DSL ---------- *)

let test_scenario_pass () =
  let s = mount_demo () in
  let src =
    {|
# drive the demo app
press kind:button&text:Increment
press kind:button&text:Increment
expect text:count=2
type kind:text-field "world"
expect text:typed:world
press kind:button&text:"Open dialog"
wait kind:dialog
expect text:"dialog body"
dismiss kind:dialog
expect-absent kind:dialog
change kind:radio&text:"Pick me"
expect text:picked:true
|}
  in
  let failures = Scenario.run (Session.driver s) src in
  Alcotest.(check int) "no failures" 0 (List.length failures)

let test_scenario_fails () =
  let s = mount_demo () in
  let failures =
    Scenario.run (Session.driver s) "expect kind:nonexistent-widget\n"
  in
  Alcotest.(check int) "one failure" 1 (List.length failures)

let test_scenario_tap_needs_live () =
  let s = mount_demo () in
  let failures =
    Scenario.run (Session.driver s) "tap 10 20\n"
  in
  match failures with
  | [ f ] ->
    Alcotest.(check int) "line 1" 1 f.Scenario.line;
    Alcotest.(check bool) "mentions live attach" true
      (f.message
      = "coordinate tap needs host-reported frames (live attach only)")
  | _ -> Alcotest.fail "expected one failure"

(* ---------- websocket ---------- *)

let test_ws_accept_key () =
  (* RFC 6455 section 1.3 example *)
  Alcotest.(check string)
    "accept key" "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
    (Drive.Ws.base64
       (Drive.Ws.sha1
          ("dGhlIHNhbXBsZSBub25jZQ==" ^ Drive.Ws.websocket_guid)))

let test_ws_frame_codec () =
  let r, w = Unix.pipe () in
  let ic = Unix.in_channel_of_descr r
  and oc = Unix.out_channel_of_descr w in
  (* a masked client text frame "hello" *)
  let mask = "\x01\x02\x03\x04" in
  let masked =
    String.init 5 (fun i ->
        Char.chr (Char.code "hello".[i] lxor Char.code mask.[i mod 4]))
  in
  output_char oc '\x81';
  output_char oc (Char.chr (0x80 lor 5));
  output_string oc mask;
  output_string oc masked;
  flush oc;
  (match Drive.Ws.read_frame ic with
   | `Text (s, fin) ->
     Alcotest.(check string) "payload" "hello" s;
     Alcotest.(check bool) "fin" true fin
   | _ -> Alcotest.fail "expected text frame");
  (* fragmented text: fin=0 text frame + continuation reassembles *)
  output_char oc '\x01';
  output_char oc (Char.chr (0x80 lor 3));
  output_string oc mask;
  output_string oc (String.sub masked 0 3);
  output_char oc '\x80';
  output_char oc (Char.chr (0x80 lor 2));
  output_string oc mask;
  (* each frame's mask restarts at offset 0 *)
  output_string oc
    (String.init 2 (fun i ->
         Char.chr (Char.code "lo".[i] lxor Char.code mask.[i])));
  flush oc;
  (match Drive.Ws.read_frame ic with
   | `Text (s, fin) ->
     Alcotest.(check string) "fragment head" "hel" s;
     Alcotest.(check bool) "fin" false fin
   | _ -> Alcotest.fail "expected fragment head");
  (match Drive.Ws.read_frame ic with
   | `Cont (s, fin) ->
     Alcotest.(check string) "fragment tail" "lo" s;
     Alcotest.(check bool) "fin" true fin
   | _ -> Alcotest.fail "expected continuation");
  (* server frames go out unmasked with fin+opcode in byte 0 *)
  Drive.Ws.write_frame oc "hi";
  Alcotest.(check string)
    "server frame" "\x81\x02hi" (really_input_string ic 4);
  Unix.close r;
  Unix.close w

let () =
  Alcotest.run "drive"
    [
      ( "model",
        [
          Alcotest.test_case "op replay" `Quick test_op_replay;
          Alcotest.test_case "selector parse" `Quick test_selector_parse;
          Alcotest.test_case "wire batch" `Quick test_wire_batch;
        ] );
      ( "session",
        [
          Alcotest.test_case "mount" `Quick test_mount;
          Alcotest.test_case "press increments" `Quick test_press_increments;
          Alcotest.test_case "typing" `Quick test_typing;
          Alcotest.test_case "dialog" `Quick test_dialog_open_dismiss;
        ] );
      ( "scenario",
        [
          Alcotest.test_case "passing script" `Quick test_scenario_pass;
          Alcotest.test_case "failing script" `Quick test_scenario_fails;
          Alcotest.test_case "coordinate tap needs live" `Quick
            test_scenario_tap_needs_live;
        ] );
      ( "hit-test",
        [
          Alcotest.test_case "deepest + pressable ancestor" `Quick
            test_hit_deepest_wins;
          Alcotest.test_case "disabled + miss" `Quick test_hit_disabled_blocks;
          Alcotest.test_case "overlap order + stale frame" `Quick
            test_hit_overlap_and_stale;
        ] );
      ( "live",
        [
          Alcotest.test_case "frames ingest + tap" `Quick
            test_live_frames_ingest;
          Alcotest.test_case "tap miss / no frames" `Quick
            test_live_tap_miss;
        ] );
      ( "ws",
        [
          Alcotest.test_case "accept key (rfc)" `Quick test_ws_accept_key;
          Alcotest.test_case "frame codec" `Quick test_ws_frame_codec;
        ] );
    ]
