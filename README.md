# drive

Headless UI driver for [LUI](https://github.com/logseq/lui) applications —
mount a real LUI app (view + reducer), replay the emitted patch ops into a
queryable node tree, inject host events, and assert on the UI state. No
platform host required; tests run in microseconds.

Three ways to drive:

- **In-process** (`Drive.Session`): mount an app against a recording
  backend inside your test suite. Events go through
  `Lui_app.dispatch_event` — the same path a native host uses.
- **FFI** (`Drive.Ffi` / the `drive` CLI): dlopen a shared library
  exporting the `lui_ocaml_*` bridge ABI (the same ABI the SwiftUI host
  loads, e.g. `libmeng_editor.so` built via `ocamlopt
  -output-complete-obj`). Patches stream back as wire JSON and are
  replayed into the same `Model`.
- **Live** (`Drive.Live`): attach over Unix socket, loopback TCP or WebSocket. Use
  `--input semantic` (default) for injected LUI events, or `--input native`
  for capability-checked, acknowledged host input. Native input never
  falls back to semantic injection.

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
change kind:radio                     # Change (radio/select on_change)
value kind:slider 0.5
ext ext:web-view web-view navigated '{"url":"https://x"}'
tap 142 36                            # coordinate press (live attach only)
sleep 0.2
dump                                 # print the node tree
dump-frames                          # print host-reported node frames
poll                                 # drain async actions once
```

## CLI

```
drive --lib ./libmeng_editor.so --os macos --host swiftui \
      --env MENG_ROOT=/path/to/workspace scenario.drive
```

`--os`/`--host` select the backend profile the target is told to use
(any LUI profile — generic, macOS/SwiftUI, iOS); they do not launch a
simulator or implement native input. Failures print line
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

## Live attach (driving a running app)

Set `MENG_DRIVE_SOCKET=/path.sock` on the app before start; the app
opens a Unix socket that replays every patch batch emitted since boot
(one JSON object per line — the same stream the native renderer gets)
and accepts injected events as newline JSON. Then:

    drive --socket /path.sock scenario.drive

Event lines look like `{"event":"press","id":37}`,
`{"event":"text","id":22,"value":"hi"}`,
`{"event":"ext","id":24,"ident":"web-view","name":"navigate","fields":{"url":"..."}}`.
Because the scenario drives the *live* process, the real UI visibly
responds, but semantic events do not exercise native hit testing,
gesture recognition, or focus handling.

## Loopback TCP attach (`--tcp`)

Native test hosts can expose the same newline-delimited JSON protocol on a
loopback TCP listener. This also works across an explicit device port forward:

```sh
adb -s "$DEVICE" forward tcp:49377 tcp:49377
drive --tcp 127.0.0.1:49377 --input native scenario.drive
adb -s "$DEVICE" forward --remove tcp:49377
```

Start a compatible test host on the device first; port forwarding alone does
not provide native input. `--tcp` accepts only `127.0.0.1`, `localhost`
(mapped directly to IPv4 loopback), or `[::1]`, with a port from 1 to 65535.
No DNS lookup or external interface is allowed. It is mutually exclusive with
`--lib`, `--socket` and `--ws-listen`. There is no reconnect/retry: a timed-out
action may already have run. Close the host and start a new test session.

Embedding callers use `Drive.Live.connect_tcp ~host:"127.0.0.1" ~port:49377`,
then `Drive.Live.driver ~timeout:5.0` and `Drive.Live.close`, just as for Unix
socket attach. No native capability is implied by the transport: the host's
v1 handshake remains mandatory.

## Coordinate taps (`tap x y`)

In semantic mode, selector events target a node id directly; `tap x y`
instead resolves the node at a point in drive's model, not in the OS.
Hosts that support it interleave a frames snapshot on the same
socket:

    {"frames":[[id,x,y,w,h], ...]}   # window coords, top-left origin,
                                    # full snapshot (replaces the table)

A `tap` resolves the deepest node containing the point, then walks
ancestors to the first `press-enabled` node or `button` (an
`enabled=false` hit swallows the tap, like a real disabled control), and
emits a normal `press` for it. `tap <sel>` is shorthand for tapping the
center of the node's reported frame — so `dump-frames` + `tap` needs no
hand-picked coordinates. Works on any host that reports frames — SwiftUI
and Flutter adapters can implement this contract. In-process and FFI
drivers reject both tap forms. `tap <sel>` without a frame now fails;
use `press <sel>` when semantic injection is intended.

In native mode, both forms are sent to the host's input system. Selector
clicks use fresh host geometry, not cached frame-based semantic dispatch.

## Web attach (`--ws-listen`)

Browser pages can only dial out, so for web hosts the direction
inverts: drive listens, the page connects.

    drive --ws-listen 9222 scenario.drive

then open the host page with `?drive=ws://127.0.0.1:9222` (or call
`LuiDrive.attach(url)` from `web/lui-drive.js`). The page speaks the
same line protocol over a WebSocket — one text message per JSON line.

`web/lui-drive.js` is the reference host adapter: elements tagged
`data-lui-node-id`/`data-lui-kind` are reported as the node tree,
`getBoundingClientRect()` feeds the frames snapshots, and incoming
events are injected synthetically (`press` → `el.click()`). This adapter
advertises **no native capabilities**; it is not trusted browser input. Everything is
gated on a live connection — without `?drive=` the file registers no
observers, listeners, or timers, so it costs nothing on a page that
isn't being driven. See `web/demo.html` for a runnable target.

## Native Chromium input

Requires Node.js 22+ and a Chromium instance exposing a **loopback-only**
CDP HTTP endpoint. Launch an isolated browser profile, serve `web/` locally,
and open `demo.html` without `?drive=`. Then, in separate terminals:

```sh
drive --ws-listen 9223 --input native scenario.drive
node web/cdp-host.mjs --cdp http://127.0.0.1:9222 \
  --url http://127.0.0.1:8000/demo.html --drive ws://127.0.0.1:9223
```

`--url` must identify exactly one open tab. Enable `data-lui-node-id` tagging
in the application before attaching. The CDP adapter injects the shared
snapshot reader; the page need not load `lui-drive.js` itself.

The same `press`, `tap`, `type`, and `key` scenario commands now use
`Input.dispatchMouseEvent`, `Input.dispatchKeyEvent`, and `Input.insertText`.
`type` replaces the editable value through focus, Select All, and input,
not assignment to `input.value`. Additional native commands:

```text
press testid:capture
type testid:editor "hello"
key "mod+a"
scroll testid:list 0 300
drag testid:source testid:target
settle
screenshot result.png
```

Actions resolve exactly one node; `testid:` maps to LUI's
`accessibility-identifier`, and `label:` matches its exact label. For Web,
test IDs come from `data-testid`, `data-lui-accessibility-identifier`, or
the DOM `id`; labels come from `data-lui-label` or `aria-label`.
Existence assertions still permit multiple matches.

Chromium selector actions scroll into view, check enabled state and
occlusion, and use actual browser input. The host waits for 100ms of
DOM/geometry quiet and finite Web Animations (at most 2s), publishes the
latest tree/frames, then acknowledges the action. This is **not** network
idle or application-task completion: use `wait` for async business state.
`--action-timeout SECONDS` controls the driver deadline (default 5s).
Native scenarios stop at the first failure.

| Host | Semantic input | Native input |
|---|---|---|
| In-process / FFI | Yes | No |
| `web/lui-drive.js` | Synthetic DOM events | No |
| `web/cdp-host.mjs` | No | Chromium mouse, text, keys, wheel, pointer drag, PNG |
| Android | Existing host-specific semantic attach | Optional LUI debug instrumentation host, API 30+; device input unverified |
| iOS | Existing host-specific semantic attach | [Separate XCTest runner](apple/README.md) + DEBUG LUI read-only probe; Apple validation pending |
| MyGo | Existing host-specific semantic attach | Unsupported: the pinned SDK has no public live-window input dispatcher |

Android's optional host lives in [LUI](https://github.com/logseq/lui), under
`platform/android/drive`; its sample launcher explicitly preserves/restores a
test-device IME and TCP forwarding. Text requires deliberately selecting the
test IME; the SDK never changes it automatically. Compilation and protocol
tests are not evidence of actual device input. Unsupported geometry/input fails
instead of falling back to semantic events.

The iOS runner is a separate UI-testing target, not app code. It uses public
XCTest input and reads the app through an explicitly enabled DEBUG probe;
stable native accessibility identifiers are required. The standalone generated
project compiles the runner only, not the app under test. Follow the
[Apple guide](apple/README.md) for build/install steps and public XCTest limits.
Neither mobile adapter implies MyGo support or universal animation/network idle.

CDP currently targets tagged light DOM, not iframes or shadow roots.
Drag is a pointer gesture, not a promised HTML5 drag-and-drop operation;
both endpoints must fit in one viewport. Long press holds the primary
mouse button for 600ms. Supported keys are letters, digits, Enter, Tab,
Escape, Backspace, Delete, Space, arrows, Home/End and PageUp/PageDown;
combine with `mod`, `cmd`/`meta`, `ctrl`, `alt` and `shift`. Use `type` for
arbitrary text. Semantic-only commands (`ext`, `toggle`, `value`, `submit`,
`dismiss`, `appear`, `change`, `goto`) explicitly fail in native mode.

See [protocol and API migrations](docs/api-migrations.md) before updating
a custom driver or implementing a native host.
