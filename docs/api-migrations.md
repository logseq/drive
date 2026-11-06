# API and wire migrations

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
