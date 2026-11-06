(* Native actions must be implemented by the host's input system, never
   translated back to LUI semantic events. Coordinates are viewport units. *)
type mode = Semantic | Native

type action =
  | Click of int
  | Double_click of int
  | Long_click of int
  | Type_text of int * string
  | Key of string
  | Tap of float * float
  | Scroll of int * float * float
  | Drag of int * int
  | Screenshot
  | Settle

type output = Completed | Png of string

let request = function
  | Click id -> ("click", [ ("id", `Int id) ])
  | Double_click id -> ("double-click", [ ("id", `Int id) ])
  | Long_click id -> ("long-click", [ ("id", `Int id) ])
  | Type_text (id, text) -> ("type", [ ("id", `Int id); ("text", `String text) ])
  | Key combo -> ("key", [ ("combo", `String combo) ])
  | Tap (x, y) -> ("tap", [ ("x", `Float x); ("y", `Float y) ])
  | Scroll (id, dx, dy) ->
    ("scroll", [ ("id", `Int id); ("dx", `Float dx); ("dy", `Float dy) ])
  | Drag (id, target) -> ("drag", [ ("id", `Int id); ("target", `Int target) ])
  | Screenshot -> ("screenshot", [])
  | Settle -> ("settle", [])

let unsupported _ = Error "native input requires a capable live host; no semantic fallback"
