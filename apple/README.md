# Drive iOS native host (source-only)

This adapter is implementation source, **not yet Apple-SDK compiled or
Simulator-validated**. Linux core checks do not validate XCTest, UIKit, Network,
Swift concurrency annotations, keyboard behavior, or native coordinate transforms.
Do not treat this directory as a validated platform release until the integrating
application builds it with Xcode and exercises it through its UI-testing target.

## Two processes, no semantic fallback

1. A DEBUG iOS app links `LUIAppleBackend` and explicitly retains an opt-in
   `LUIDriveSnapshotProbe`. The probe only reads the retained LUI tree and geometry.
2. An **XCTest UI-testing target** compiles `DriveWire.swift`, `DriveTCP.swift`,
   and `DriveXCTestRunner.swift`. Copy/adapt `DriveUITests.example.swift` into that
   target for an entrypoint. Do not add any of these files to the application,
   a production framework, or a unit-test target hosted inside the application.
3. Drive connects to the runner's `127.0.0.1:49379` newline-JSON v1 listener.
   The runner obtains read-only snapshots from the app on `127.0.0.1:49378`.
   Both sockets bind IPv4 loopback explicitly and reject other peers. There is no
   wildcard bind, Bonjour advertisement, remote hostname, or authentication token.
   Other local processes can connect: use an isolated development machine/device,
   not this opt-in debug probe as a security boundary against local processes.

All input is public XCTest input: `XCUIElement.tap`, `doubleTap`,
`press(forDuration:)`, `typeText`, and `XCUICoordinate` press/drag APIs. No
`Press`/`TextChanged` dispatch, `sendActions`, accessibility `setValue`, private
HID/touch construction, or synthetic fallback is present. App launch and teardown
belong to the UI test, never the production runtime.

## App hookup

Use the matching LUI Apple backend change providing `debugDriveSnapshot()` and
`LUIDriveSnapshotProbe`. See `platform/apple/DriveProbe.md` in LUI for an exact
Navigation demo host hookup without changing OCaml view code.

Retain the probe after the app's single foreground key window is available and
call `stop()` during host teardown. Wrap all probe references in `#if DEBUG`.
Release builds contain neither the probe nor the debug snapshot API. Adding the
source alone opens no listener, including in DEBUG builds. The factory returns
`nil` unless the app's environment explicitly contains `LUI_DRIVE_PROBE=1`.

The sample UI test passes that app launch environment; do not enable it in the
shipping app's launch defaults. Frame reporting/collection are enabled only for
the active probe and restored on `stop()` or probe deinitialization. Existing
frame callbacks are never replaced.

## Xcode Test action / Test Plan environment

### Standalone compile gate (no UI execution)

Python 3 and a selected Xcode 26+ installation with an iOS Simulator SDK are the
only prerequisites. From the Drive repository root:

```sh
python3 apple/generate-project.py --app-bundle-id dev.lui.components
xcodebuild \
  -project apple/.generated/DriveApple.xcodeproj \
  -scheme DriveApple -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath apple/.generated/DerivedData \
  CODE_SIGNING_ALLOWED=NO build-for-testing
```

The generator uses only Python's standard library, references the four local
Swift files directly, creates a shared scheme, and writes only ignored generated
project/build artifacts. The project has **one UI-testing target and no app
target/dependencies**; Target Application is intentionally None because the
entrypoint uses `XCUIApplication(bundleIdentifier:)`. The app need not be built
or installed for this compile gate. The command does not run UI tests or launch
a Simulator. **The generator was exercised on Linux; this Xcode command has not
been executed or verified yet.**

For an actual UI run, separately build and install the matching DEBUG app on the
selected Simulator first (the standalone project does not install the app under
test). Then use the generated scheme's Test action, or adapt the sample into
the application's own UI-testing scheme, which can own app build/install. The
generated Test action enables `DRIVE_XCTEST=1` and the supplied bundle ID; the
other environment values below can be edited in Xcode. Never run this long-lived
Drive session test as part of an ordinary unattended full UI suite.

### Runner environment

Configure these on the **UI-test runner's Test action or Test Plan**, not merely
as arbitrary shell variables passed to `xcodebuild`:

| Variable | Default | Purpose |
|---|---|---|
| `DRIVE_XCTEST` | absent | Must equal `1`; otherwise the example skips |
| `DRIVE_APP_BUNDLE_ID` | none | Bundle ID of the already-built DEBUG app |
| `LUI_DRIVE_PROBE_PORT` | `49378` | Explicit app/runner loopback probe port |
| `DRIVE_RUNNER_PORT` | `49379` | Runner loopback listener; must differ from probe |
| `DRIVE_ACTION_TIMEOUT` | `4` | Runner deadline in seconds, `0.5...120` |
| `DRIVE_SESSION_TIMEOUT` | `300` | Includes waiting for Drive to attach, `1...3600` |

The example launches the app with `-AppleLanguages (en) -AppleLocale en_US` so
native **Select All** lookup is deterministic. Custom launch arguments and app
login/fixture setup remain the integrating test's responsibility. Run only this
test (no parallel test workers) on the selected Simulator, then attach Drive:

```sh
# On the Mac host; --tcp is supplied by the integrating Drive CLI change.
drive --tcp 127.0.0.1:49379 --input native --action-timeout 5 scenario.drive
```

For a slower native keyboard operation, increase both timeouts, with Drive's
deadline longer than the runner's. Port collisions fail rather than binding a
different interface. Project generation creates no simulator or app under test;
Xcode build-for-testing creates the UI-test bundle/runner. Physical devices need explicit secure port
forwarding for a Mac-hosted Drive client; automatic device transport is not
implemented. Multiple scenes/windows and rotation during an action are rejected
when native/probe viewport sizes disagree; use a fixed-orientation single-window
test fixture.

## Supported actions and limits

The runner advertises exactly `click`, `double-click`, `long-click`, `tap`,
`type`, `key`, `scroll`, `drag`, `screenshot`, and `settle`.

- Target actions require an explicit, nonempty, stable LUI
  `accessibility-identifier`, unique among effective LUI identifiers and native
  accessibility elements. The runner matches the **native identifier property**,
  never a label fallback, and freshly checks existence, enabled, and hittable.
  Untagged controls, inaccessible custom canvas controls, hidden/offscreen
  controls, and identifier propagation creating multiple native matches fail
  explicitly. Extension authors must expose the same identifier on the actual
  native control. There is no coordinate fallback for target actions and no
  automatic scrolling to a target.
- Click/double-click/long-click use element-native hit points. Long-click holds
  for `0.8s`. Drag uses center-to-center public coordinate gestures; both native
  centers must fit in the current viewport. This is a pointer gesture, not an
  assertion that the app implements a drop operation; fixtures need unobscured
  endpoint centers.
- Coordinate tap uses top-left **window-local logical points** and the native
  window's coordinate transform, checks bounds, and does not scale by screenshot
  pixels. The app's native window size must match the probe viewport.
- `type` means replacement, including empty and Unicode strings, on a native
  editable text/search/secure field or text view with retained `text`. It focuses
  the field, uses the native **Select All** edit menu for nonempty text, sends
  native Delete, then native `typeText`. The resulting retained `text` must match
  before success. Read-only controls, missing Select All, suppressed software
  keyboards, custom input methods unsupported by XCTest, and nonselectable fields
  fail; values are never assigned programmatically. A rejection after a native
  menu/gesture may leave that native UI visible; it is not rolled back.
- `key` supports only `Enter`/`Return`, `Backspace`, and `Space` with an active
  software keyboard. Desktop modifiers/chords, Tab, arrows, forward Delete,
  Escape, and hardware-keyboard-only input are explicitly rejected. Use `type`
  for arbitrary text; unsupported combinations are not advertised as desktop
  keyboard parity merely because the action capability is named `key`.
- Scroll positive `dx`/`dy` means content right/down, so fingers move left/up.
  Deltas are logical gesture-travel points, not guaranteed exact content offset:
  platform scrolling, clamping, and app behavior still apply. Large moves are
  split into at most 64 native strokes, with a 10000-point per-axis budget, and
  reacquire the current native target/frame before every stroke.
- Screenshot uses `XCUIApplication.screenshot().pngRepresentation` and returns
  base64 `png`. Image pixels and logical frame points intentionally differ.

## Completion, snapshots, and failure

After native XCTest calls return, the runner polls the probe and native
accessibility frames until the retained generation/commit state, tree, geometry,
and native frame/enabled/hittable observations are unchanged for at least 100ms.
It refuses pending retained commits and has a hard action deadline. The 20ms
poll interval is a sampling cadence, not an unconditional settle delay.

**Limit:** public XCTest does not expose exhaustive finite-animation state.
This is bounded sampled tree/native-frame quiet plus XCTest call completion,
not universal animation completion, network idle, or async application-task
completion. Assert/wait for business state explicitly in the Drive scenario.

The runner is a single serial writer. On initial attachment it sends
`hello -> full frames -> initial ops` (ops mark Drive readiness). After each
action it sends `full replacement ops -> full frames -> correlated result`.
Replacement first drops **all** previously published IDs, then reconstructs the
current tree, including extension fingerprints and scalar wire values; vanished
nodes and removed properties cannot linger. Probe-only metadata is not forwarded
to Drive. Every frame publication replaces the complete frame table. Action
lookup never reads a cached target frame.

Malformed/unknown messages, versions, fields, capabilities, and duplicate,
out-of-order, or nonpositive request IDs close the session. Valid requests must
start at 1 and increase by exactly 1. JSON input buffers, session duration,
partial probe requests, and action duration are bounded. Action rejections return
`ok:false,error` only after publishing current state. A deadline or disconnect
poisons/closes transport, discards buffered requests, and prevents subsequent
native operations and success replies. There is no cross-request held pointer:
each gesture is one atomic XCTest call. **An already-running XCTest call cannot
be forcibly interrupted via public APIs**; its completion/release can outlive
the transport deadline. The adapter does not claim otherwise.

## Integration validation still required

Build the LUI Apple package in DEBUG and Release (the latter must not export the
probe), then compile the three runner files and sample in a real iOS UI-testing
target. With approval, exercise tagged controls, Unicode/empty replacement,
native scroll/drag, screenshots, removed properties/nodes, initial attach
ordering, malformed/duplicate IDs, timeout/disconnect, obscured/disabled targets,
and non-1x Simulator scaling. UI-driven testing/recordings are a separate testing
agent task; none was run for this source-only handoff.
