(* Tiny LUI app used by the drive test suite: a counter, a text field
   mirroring its input, and a button that opens a dialog. Exercises
   press / text input / conditional mount / dismiss. *)

module E = Lui_elements
open Lui_protocol

type model = { count : int; typed : string; dialog_open : bool; picked : bool }
type action =
  | Increment
  | Typed of string
  | Open_dialog
  | Close_dialog
  | Pick

let initial = { count = 0; typed = ""; dialog_open = false; picked = false }

let reducer m = function
  | Increment -> { m with count = m.count + 1 }
  | Typed s -> { m with typed = s }
  | Open_dialog -> { m with dialog_open = true }
  | Close_dialog -> { m with dialog_open = false }
  | Pick -> { m with picked = true }

let view _ctx model_signal send =
  E.column
    [
      E.text
        ~value_signal:(Signal.map (fun m -> Printf.sprintf "count=%d" m.count) model_signal)
        [];
      E.text_field ~placeholder:"type here"
        ~on_input:(fun ev ->
          match ev with
          | TextChanged (_, s) -> ignore (send (Typed s))
          | _ -> ())
        [];
      E.text
        ~value_signal:(Signal.map (fun m -> "typed:" ^ m.typed) model_signal)
        [];
      E.button ~text:"Open dialog" ~on_press:(fun _ -> ignore (send Open_dialog)) [];
      E.button ~text:"Increment" ~on_press:(fun _ -> ignore (send Increment)) [];
      E.radio_group
        [
          E.radio ~text:"Pick me"
            ~on_change:(fun _ -> ignore (send Pick))
            [];
        ];
      E.text
        ~value_signal:(Signal.map (fun m -> "picked:" ^ string_of_bool m.picked) model_signal)
        [];
      E.if_
        ~test:(Signal.map (fun m -> m.dialog_open) model_signal)
        (E.dialog ~text:"Demo dialog"
           ~on_dismiss:(fun _ -> ignore (send Close_dialog))
           [ E.text ~value:"dialog body" [] ]);
    ]
