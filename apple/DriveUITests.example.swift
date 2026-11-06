#if os(iOS)
import XCTest

@MainActor
final class DriveUITests: XCTestCase {
    func testDriveSession() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DRIVE_XCTEST"] == "1" else { throw XCTSkip("Set DRIVE_XCTEST=1 to run the Drive host") }
        guard let bundleID = environment["DRIVE_APP_BUNDLE_ID"], !bundleID.isEmpty,
              let probePort = UInt16(environment["LUI_DRIVE_PROBE_PORT"] ?? "49378"),
              let runnerPort = UInt16(environment["DRIVE_RUNNER_PORT"] ?? "49379"),
              let actionTimeout = Double(environment["DRIVE_ACTION_TIMEOUT"] ?? "4"),
              let sessionTimeout = Double(environment["DRIVE_SESSION_TIMEOUT"] ?? "300"),
              probePort != runnerPort else {
            throw DriveFailure.rejected("invalid Drive UI-test environment")
        }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: bundleID)
        app.launchEnvironment["LUI_DRIVE_PROBE"] = "1"
        app.launchEnvironment["LUI_DRIVE_PROBE_PORT"] = String(probePort)
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let runner = try DriveXCTestRunner(app: app, probePort: probePort, actionTimeout: actionTimeout)
        try runner.run(port: runnerPort, sessionTimeout: sessionTimeout)
    }
}
#endif
