# drive

Headless UI driver for [LUI](https://github.com/logseq/lui) applications —
mount a real LUI app (view + reducer), replay the emitted patch ops into a
queryable node tree, inject host events, and assert on the UI state. No
platform host required; tests run in microseconds.

Two ways to drive:

- **In-process** (`Drive.Session`): mount an app against a recording
  backend inside your test suite. Events go through
  `Lui_app.dispatch_event` — the same path a native host uses.
- **FFI** (`Drive.Ffi` / the `drive` CLI): dlopen a shared library
  exporting the `lui_ocaml_*` bridge ABI (the same ABI the SwiftUI host
  loads, e.g. `libmeng_editor.so` built via `ocamlopt
  -output-complete-obj`). Patches stream back as wire JSON and are
  replayed into the same `Model`.

## Scenario scripts (`.drive`)

```
press kind:button&text:Increment     # selectors: id:, kind:, ext:, text:, prop:n=v, &-conjuncts
type kind:text-field "hello"         # TextChanged
key "cmd+p"                          # ExtensionEvent on ext:key-surface
expect text:count=2                  # assert node exists
expect-absent kind:dialog            # assert node absent
wait ext:code-editor 10              # poll until match (seconds)
dismiss kind:dialog
toggle kind:toggle true
value kind:slider 0.5
ext ext:web-view web-view navigated '{"url":"https://x"}'
sleep 0.2
dump                                 # print the node tree
poll                                 # drain async actions once
```

## CLI

```
drive --lib ./libmeng_editor.so --os macos --host swiftui \
      --env MENG_ROOT=/path/to/workspace scenario.drive
```

`--os`/`--host` select the backend profile the target is told to use
(any LUI profile — generic, macOS/SwiftUI, iOS). Failures print line
numbers; exit code is non-zero on any failure.

## Library sketch

```ocaml
let s =
  Drive.Session.mount ~profile:Drive.profile_generic
    ~initial:Model.initial ~reducer:Update.reducer ~view:View.view ()
let d = Drive.Session.driver s
let btn = Drive.Session.resolve d (All [Kind "button"; Text "Save"])
let () = Drive.Session.press s btn.id
let () = assert (Drive.Model.exists s.tree (Text "saved"))
```

For apps with async effects (plugin hosts, LSP sessions), pass
`~drain` to `mount` — a function returning pending actions that drive
sends into the reducer whenever the session is polled (after every
event and during `wait`).

## Speed

Events are in-memory dispatches, assertions are tree lookups. The whole
suite in `test/` (mount + press + type + dialog + a scripted scenario)
runs in ~1ms.
