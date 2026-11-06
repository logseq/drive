# API and wire migrations

## iOS content-window selection with the software keyboard

The XCTest runner selects exactly one application window containing a native
descendant whose identifier equals an **explicit**, nonempty LUI identifier
from the current read-only snapshot. It uses public XCTest `containing`
predicates, not window order, private class names or hittability filtering.
The software keyboard and text-service windows can coexist with that content
window when they contain none of those identifiers. All anchored windows count:
zero or multiple matching content windows reject, even if one is hidden.
Foreground state and the selected window's probe-viewport size must still match.

Empty/unanchored native trees are now explicitly unsupported, including for
settle/screenshot. Add a stable `accessibility-identifier` to a real LUI control
or content node (for example `counter` on the existing count label), then rebuild
the app/runner; no new wire fields or probe behavior are required. Only windows
represented by the snapshot's identifiers can be recognized as content; this
does not add support for multiple independent scenes or uninstrumented content
windows. Keep one fixed-orientation app scene. Control uniqueness, enabled and
hittable checks, window-local coordinates, input deadlines and poisoned-session
behavior are unchanged.

## iOS native editor target selection

The XCTest runner now resolves standard LUI editor nodes by their explicit
identifier **and native editor type**, for both frame publication/settling and
target actions. SwiftUI can propagate an editor identifier to a zero-size
auxiliary `Other` element as well as the real native editor; this no longer
makes the editor query ambiguous.

`text-field`/`input` require `TextField`, `secure-field` requires
`SecureTextField`, `search-field` accepts `SearchField`/`TextField`, and
`textarea` accepts `TextView`/`TextField` (SwiftUI's vertical TextField).
Exactly one matching editor must exist, including hidden/disabled matches in
the count; multiple equivalent editors still reject before input. Effective
LUI identifier uniqueness and fresh enabled/hittable checks are unchanged.
Other node kinds retain all-types native uniqueness. There is no first-match,
label, coordinate or semantic fallback, and no event/wire changes.

No scenario migration is required: keep, for example, `type testid:editor "hello"`
with an explicit `accessibility-identifier="editor"` on the LUI text-field node.
Rebuild the UI-test runner. Native replacement still uses public XCTest
Select All/Delete/typing and verifies exact retained text before success.

## Live transport deadlines and fatal polling errors

Native actions now use **one deadline for sending and completion**, including
write serialization, socket backpressure and WebSocket framing. Previously the
completion timeout started after a potentially blocking write. Built-in Unix,
TCP and WebSocket transports use per-call nonblocking socket sends without
changing the concurrent reader's socket mode. There is no background action
sender that can keep submitting input after the caller reports a timeout.

A native write/completion timeout or transport failure poisons and closes the
connection. Late results cannot revive it; start a fresh session rather than
retrying an action that may already have run. `Live.close` is now idempotent,
including its custom close callback, so existing `Fun.protect` cleanup remains
safe after automatic closure. These deadlines do not cover TCP connect or the
WebSocket HTTP upgrade.

`Live.poll` now raises `Failure` for a recorded fatal protocol error, not only
for disconnect. This includes polling inside assertions and the final scenario
poll: an invalid/version-incompatible session can no longer pass merely because
no further native action is sent. Embedding callers must treat this as a fatal
session error and close the transport.

### Custom transports

Existing `Live.create ~send_line ~close ()` calls remain source-compatible.
Arbitrary application callbacks cannot be preempted safely: `send_line` must
return promptly and must not leave an asynchronous sender running after failure.
A late callback return is rejected, but its blocking time cannot be bounded by
Drive. Custom transports that may block should provide the new optional writer:

```ocaml
let live =
  Drive.Live.create ~send_line:send_semantic ~close:close_transport
    ~send_line_until:(fun ~deadline json ->
      write_json_before ~deadline json)
    ()
```

`deadline` is an absolute `Unix.gettimeofday ()` timestamp, shared with the
completion wait. The callback receives the same serialized JSON string without
a newline as `send_line`; it owns transport framing and must honor the deadline
for lock acquisition and every partial write. Raise `Failure` (for example,
`Failure "host write timed out"`) or `Unix.Unix_error` on failure/expiration.
It must stop sending before returning/raising and must not enqueue work that can emit late
input. Drive then poisons/closes the session and returns an action/request error.
The optional writer is used for native actions; legacy semantic sends continue
to use `send_line`. The default action timeout remains 5 seconds.

## Loopback TCP native host attach

`Live.connect_tcp ~host ~port` and `drive --tcp HOST:PORT` add an optional
newline-delimited TCP transport for native test hosts and device port forwards.
The wire protocol and capability requirements remain v1; existing Unix socket,
WebSocket and semantic/FFI integrations do not change.

Only `127.0.0.1`, `localhost` (without DNS, mapped to IPv4 loopback), and `::1`
are accepted by the library. Use `[::1]:PORT` at the CLI. Ports must be in
1..65535. Other hosts are rejected before connecting. Hosts must independently
bind loopback and opt in to test control; do not ship an auto-starting listener.

```ocaml
let live = Drive.Live.connect_tcp ~host:"127.0.0.1" ~port:49377 in
Fun.protect ~finally:(fun () -> Drive.Live.close live) (fun () ->
  let driver = Drive.Live.driver ~timeout:5.0 live in
  Drive.Scenario.run ~input:Drive.Input.Native driver source)
```

```sh
# With a compatible Android test host already running:
adb -s "$DEVICE" forward tcp:49377 tcp:49377
drive --tcp 127.0.0.1:49377 --input native smoke.drive
adb -s "$DEVICE" forward --remove tcp:49377
```

TCP is mutually exclusive with the other CLI transports. It does not launch
an app, simulator, emulator, test IME or native input adapter, and never changes
the default semantic mode. Unsupported native actions still fail explicitly.

## Explicit input modes and native host protocol v1

The default remains `Drive.Input.Semantic`. Existing in-process, FFI, and
unversioned live semantic scenarios retain their event transport. Geometry
is not proof of native input: legacy `Live.tap` still hit-tests in drive
and emits a semantic `press`.

### Intentional behavior changes

- `Session.resolve` polls and requires exactly one match. Zero or multiple
  matches fail, including action targets and `expect-prop`. Use
  `kind:button&text:Save`, `testid:save`, or `label:Save`; use `Model.find`
  explicitly for queries intended to return many nodes. `expect`,
  `expect-absent`, and `wait` remain existence queries.
- `tap <selector>` without a reported frame fails in semantic mode. Replace
  it with `press <selector>` for headless/FFI behavior tests. Native
  selector taps ask the host to locate and click the node.
- Native scenarios stop at the first failure and never emit semantic
  events, including unsupported DSL actions. A timeout poisons the native
  connection: reconnect rather than retry an action that may have run.
- Live drivers wait for an initial patch snapshot, even for an empty tree.
  A host that sends only frames must also send `{"ops":[]}`. The deadline
  defaults to 5s; `Live.driver ~timeout` / `--action-timeout` sets it.
- A live disconnect is an explicit error instead of an inert poll loop.
- Recent LUI events not implemented by the FFI/live semantic bridges
  (navigation, virtual-window, pointer-move/cancel, detailed toggle)
  are explicitly rejected; they are not silently discarded.

### Driver/API migration

`Session.driver` gains one required field:

```ocaml
native : Input.action -> (Input.output, string) result
```

For semantic-only custom drivers, set `native = Drive.Input.unsupported`.
Do not implement this callback by translating native actions to
`send_event`. A successful return means the host has completed the action
and published its resulting UI updates.

```ocaml
let failures =
  Drive.Scenario.run ~input:Drive.Input.Native driver source
```

`Input.action` defines `Click`, `Double_click`, `Long_click`, `Type_text`,
`Key`, `Tap`, `Scroll`, `Drag`, `Screenshot`, and `Settle`. The result is
`Completed`, or `Png` containing decoded PNG bytes for a screenshot.
The caller writes screenshots locally; the host is never sent a file path.

Use `Live.create ~send_line ()` to embed a custom transport and
`Live.enqueue` to deliver incoming JSON safely. `Live.ingest_line` applies
JSON on the driver thread. `Live.close` closes built-in transports; custom
transports can pass a `~close` callback. Calls on one driver are sequential,
with at most one native action in flight.

### Host handshake

Native hosts must send a handshake **before** the initial tree snapshot:

```json
{"drive":"hello","version":1,"capabilities":["click","type","key","tap","scroll","drag","screenshot","settle"]}
```

Advertise only implemented capabilities. Additional supported names are
`double-click` and `long-click`. A missing handshake, unsupported version,
missing capability, or unknown native message is an error; none enables
fallback. Semantic DOM hosts send an empty capability list.

The existing `{"ops":[...]}` patch and `{"frames":[[id,x,y,w,h],...]}`
streams remain unchanged. Coordinates and wheel deltas are logical
viewport units, top-left origin; frame messages replace the whole table.

### Actions and completions

```json
{"drive":"action","version":1,"request":1,"action":"click","id":37}
{"drive":"result","version":1,"request":1,"ok":true}
```

Every request has a monotonically increasing integer ID, scoped to its
connection. Only a result matching the current pending request unblocks
the scenario; stale or unrelated results are ignored, not cached.

| Action | Additional fields |
|---|---|
| `click`, `double-click`, `long-click` | `id` |
| `type` | `id`, `text` (replacement text) |
| `key` | `combo` (e.g. `mod+a`) |
| `tap` | `x`, `y` |
| `scroll` | `id`, `dx`, `dy` (positive right/down) |
| `drag` | `id` (source), `target` (destination node ID) |
| `settle`, `screenshot` | None |

The host resolves node IDs against its current UI, rejects stale,
disabled, hidden, offscreen or occluded targets, and may scroll a target
into view before input. It must use platform input APIs, not dispatch
LUI semantic events. Send all resulting patches/frames before success.
Define bounded settle behavior for the platform; do not wait forever for
infinite animations or claim application/network idle without evidence.

Failures preserve the request ID and explain what prevented input:

```json
{"drive":"result","version":1,"request":1,"ok":false,"error":"target is occluded"}
```

Screenshot results carry base64-encoded PNG data:

```json
{"drive":"result","version":1,"request":2,"ok":true,"png":"iVBORw0KGgo..."}
```

The driver validates base64 and the PNG signature before exposing bytes.
Bind all test/debug transports to loopback and use isolated browser
profiles. These endpoints grant control over the attached application;
they are development facilities, not production remote-control APIs.

## Optional iOS XCTest native runner

`apple/` adds source for a separate XCTest UI-testing target and a standard
library Python Xcode project generator. It does not change Drive protocol v1,
semantic defaults or existing transports. Compile the runner with the documented
`build-for-testing` command; separately build/install a matching DEBUG LUI app
before an actual UI run. Never link the runner into the application binary.

The app explicitly opts into LUI's read-only snapshot probe on IPv4 loopback
port 49378. The runner exposes the native Drive endpoint on loopback port 49379:

```sh
drive --tcp 127.0.0.1:49379 --input native --action-timeout 5 scenario.drive
```

Initial hello and full frames precede ops readiness. Replacement snapshots
drop previously published IDs before rebuilding nodes/properties/links;
fresh ops and frames precede every result. Selector actions require explicit,
unique native accessibility identifiers and current enabled/hittable controls.
There is no label, coordinate or semantic fallback for selector input.
Coordinates are window-local logical points; screenshots are PNG pixels.
Typing is native replacement, including empty text, using the English Select
All edit menu and software keyboard. Unsupported key combinations/editors
fail explicitly. Settling samples retained/native-frame quiet, not exhaustive
animation, network or application-task completion.

Deadline/disconnect poisons and closes transport and discards subsequent input.
Public XCTest cannot forcibly interrupt an atomic gesture already in flight;
that call may finish after the transport deadline. No retry or late success is
issued. Physical-device forwarding, multiple scenes, and arbitrary custom
canvas targeting are not supplied. See [`apple/README.md`](../apple/README.md)
for compile validation, app hookup, exact capabilities and platform limits.
