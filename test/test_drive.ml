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
    = Some (Prop ("placeholder", StringValue "Search")))

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
        ] );
    ]
