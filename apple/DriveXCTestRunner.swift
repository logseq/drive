#if os(iOS)
import Foundation
import XCTest

/// Compile into an XCTest UI-testing target only, never the application target.
@MainActor
public final class DriveXCTestRunner {
    private let app: XCUIApplication
    private let probe: DriveTCPChannel
    private let actionTimeout: TimeInterval
    private var probeRequest = 0
    private var publishedIDs: [Int] = []
    private var publishedSignature: Data?

    public init(app: XCUIApplication, probePort: UInt16 = 49378, actionTimeout: TimeInterval = 4) throws {
        guard probePort >= 1024, actionTimeout.isFinite, (0.5...120).contains(actionTimeout) else {
            throw DriveFailure.rejected("invalid probe port or action timeout (0.5...120 seconds)")
        }
        self.app = app
        self.actionTimeout = actionTimeout
        probe = DriveTCPChannel(loopbackPort: probePort)
    }

    /// Blocks this UI test until Drive disconnects or the bounded session expires.
    public func run(port: UInt16 = 49379, sessionTimeout: TimeInterval = 300) throws {
        guard sessionTimeout.isFinite, (1...3600).contains(sessionTimeout) else {
            throw DriveFailure.rejected("session timeout must be 1...3600 seconds")
        }
        let end = now + sessionTimeout
        let server = try DriveTCPServer(port: port)
        defer { server.stop(); probe.close() }
        let client = try server.accept(deadline: end)
        var previousRequest = 0
        let initialDeadline = min(end, now + actionTimeout)
        client.arm(deadline: initialDeadline)
        try client.send(.object([
            "drive": .string("hello"), "version": .int(1),
            "capabilities": .array(DriveRequest.capabilities.map { .string($0) }),
        ]), deadline: initialDeadline)
        let initial = try quietSnapshot(client: client, deadline: initialDeadline)
        // Live.driver becomes ready on ops, so initial frames must precede it.
        try publish(initial, client: client, deadline: initialDeadline, initial: true)
        client.disarm()
        while now < end {
            let line: Data?
            do { line = try client.readLine(until: min(end, now + 0.05)) }
            catch let failure as DriveFailure {
                if case .transport = failure { return }
                throw failure
            }
            if let line {
                let request = try DriveRequest(line: line, previousRequest: previousRequest)
                previousRequest = request.request
                let deadline = min(end, now + actionTimeout)
                client.arm(deadline: deadline)
                var rejection: String?
                do { try perform(request, client: client, deadline: deadline) }
                catch let failure as DriveFailure {
                    if case let .rejected(message) = failure { rejection = message }
                    else { throw failure }
                }
                let latest = try quietSnapshot(client: client, deadline: deadline)
                if rejection == nil, request.action == "type",
                   let id = request.fields["id"]?.integer,
                   retainedText(id, snapshot: latest.snapshot) != request.fields["text"]?.string {
                    rejection = "native text replacement did not produce the requested retained text"
                }
                var result: [String: DriveJSON] = [
                    "drive": .string("result"), "version": .int(1),
                    "request": .int(request.request), "ok": .bool(rejection == nil),
                ]
                if let rejection { result["error"] = .string(rejection) }
                if rejection == nil && request.action == "screenshot" {
                    try client.check(deadline: deadline)
                    result["png"] = .string(app.screenshot().pngRepresentation.base64EncodedString())
                }
                // A fresh capture after screenshot also catches layout changes during capture.
                let final: Capture
                if request.action == "screenshot" {
                    final = try quietSnapshot(client: client, deadline: deadline)
                } else {
                    final = latest
                }
                try publish(final, client: client, deadline: deadline)
                try client.send(.object(result), deadline: deadline)
                client.disarm()
            } else {
                let deadline = min(end, now + actionTimeout)
                client.arm(deadline: deadline)
                let latest = try capture(client: client, deadline: deadline)
                if latest.signature != publishedSignature {
                    try publish(latest, client: client, deadline: deadline)
                }
                client.disarm()
            }
        }
        client.close(.deadline)
        throw DriveFailure.deadline
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private struct Capture {
        let snapshot: DriveProbeSnapshot
        let frames: DriveJSON
        let signature: Data
    }

    private func snapshot(client: DriveTCPChannel, deadline: TimeInterval) throws -> (DriveProbeSnapshot, Data) {
        try client.check(deadline: deadline)
        probeRequest += 1
        try probe.send(.object([
            "probe": .string("snapshot"), "version": .int(1), "request": .int(probeRequest),
        ]), deadline: deadline)
        guard let data = try probe.readLine(until: deadline) else {
            client.close(.deadline); probe.close(.deadline); throw DriveFailure.deadline
        }
        try client.check(deadline: deadline)
        let reply = try JSONDecoder().decode(DriveProbeReply.self, from: data)
        let value = reply.snapshot
        guard reply.probe == "snapshot", reply.version == 1, reply.request == probeRequest,
              value.coordinateSpace == "window-top-left-points",
              value.viewport.count == 4, value.viewport.allSatisfy(\.isFinite),
              value.viewport[0] == 0, value.viewport[1] == 0,
              value.viewport[2] > 0, value.viewport[3] > 0,
              Set(value.nodeIDs).count == value.nodeIDs.count,
              value.frames.allSatisfy({ $0.count == 5 && $0.allSatisfy(\.isFinite) }) else {
            throw DriveFailure.protocolViolation("invalid or mismatched LUI probe snapshot")
        }
        return (value, data)
    }

    private func window(_ snapshot: DriveProbeSnapshot) throws -> XCUIElement {
        guard app.state == .runningForeground else { throw DriveFailure.rejected("app is not foreground") }
        let windows = app.windows.allElementsBoundByIndex.filter { $0.exists && !$0.frame.isEmpty }
        guard windows.count == 1 else {
            throw DriveFailure.rejected("Drive iOS requires exactly one visible application window")
        }
        let window = windows[0]
        let frame = window.frame
        guard abs(frame.width - snapshot.viewport[2]) <= 1,
              abs(frame.height - snapshot.viewport[3]) <= 1 else {
            throw DriveFailure.rejected("native window and probe viewport disagree; rotation/multiple scenes unsupported")
        }
        return window
    }

    private func capture(client: DriveTCPChannel, deadline: TimeInterval) throws -> Capture {
        let (snapshot, data) = try snapshot(client: client, deadline: deadline)
        let window = try window(snapshot)
        let origin = window.frame.origin
        let ids = Set(snapshot.nodeIDs)
        var frames: [Int: [DriveJSON]] = [:]
        for frame in snapshot.frames {
            guard frame[0] >= 0, frame[0] < Double(Int.max), frame[0].rounded() == frame[0] else {
                throw DriveFailure.protocolViolation("invalid probe frame ID")
            }
            let id = Int(frame[0])
            guard ids.contains(id), frame[3] >= 0, frame[4] >= 0 else {
                throw DriveFailure.protocolViolation("orphan or negative probe frame")
            }
            frames[id] = [.int(id)] + frame.dropFirst().map { .double($0) }
        }
        var nativeState: [DriveJSON] = []
        for key in snapshot.nativeIdentifiers.keys.sorted() {
            try client.check(deadline: deadline)
            guard let id = Int(key), ids.contains(id), let info = snapshot.nativeIdentifiers[key] else {
                throw DriveFailure.protocolViolation("orphan native identifier")
            }
            // Retained SwiftUI geometry is not used for native target actions.
            frames.removeValue(forKey: id)
            let query = nativeQuery(identifier: info.identifier)
            let count = info.identifier.isEmpty ? 0 : query.count
            var state: [DriveJSON] = [.int(id), .int(count)]
            if count == 1 {
                let element = query.element(boundBy: 0)
                let rect = element.frame.offsetBy(dx: -origin.x, dy: -origin.y)
                let valid = element.exists && rect.minX.isFinite && rect.minY.isFinite &&
                    rect.width.isFinite && rect.height.isFinite && !rect.isEmpty
                if valid {
                    let entry: [DriveJSON] = [.int(id), .double(rect.minX), .double(rect.minY),
                                              .double(rect.width), .double(rect.height)]
                    frames[id] = entry
                    state += [.array(entry), .bool(element.isEnabled), .bool(element.isHittable)]
                }
            }
            nativeState.append(.array(state))
        }
        try client.check(deadline: deadline)
        let wireFrames = DriveJSON.object([
            "frames": .array(frames.keys.sorted().compactMap { frames[$0].map { .array($0) } }),
        ])
        // Probe request IDs are excluded from stability; the actual tree and native state are included.
        let raw = try JSONDecoder().decode(DriveJSON.self, from: data)
        let signature = try DriveJSON.array([
            raw["snapshot"] ?? .null, .array(nativeState), wireFrames,
        ]).data()
        return Capture(snapshot: snapshot, frames: wireFrames, signature: signature)
    }

    private func quietSnapshot(client: DriveTCPChannel, deadline: TimeInterval) throws -> Capture {
        var previous: Data?
        var quietSince = now
        while true {
            try client.check(deadline: deadline)
            let current = try capture(client: client, deadline: deadline)
            if current.signature != previous || !current.snapshot.committed { quietSince = now }
            previous = current.signature
            if current.snapshot.committed && now - quietSince >= 0.1 { return current }
            // Polling cadence, not an unconditional settle or a network-idle claim.
            RunLoop.current.run(until: Date(timeIntervalSinceNow: min(0.02, max(0, deadline - now))))
        }
    }

    private func publish(_ current: Capture, client: DriveTCPChannel, deadline: TimeInterval, initial: Bool = false) throws {
        let drops = publishedIDs.map { DriveJSON.object(["op": .string("drop-node"), "id": .int($0)]) }
        let batch = DriveJSON.object([
            "generation": .int(current.snapshot.generation), "ops": .array(drops + current.snapshot.ops),
        ])
        if initial { try client.send(current.frames, deadline: deadline) }
        try client.send(batch, deadline: deadline)
        if !initial { try client.send(current.frames, deadline: deadline) }
        publishedIDs = current.snapshot.nodeIDs
        publishedSignature = current.signature
    }

    private func target(_ id: Int, snapshot: DriveProbeSnapshot) throws -> XCUIElement {
        guard snapshot.committed else {
            throw DriveFailure.rejected("LUI has a pending native commit; settle before resolving the target")
        }
        guard snapshot.nodeIDs.contains(id), let info = snapshot.nativeIdentifiers[String(id)],
              info.explicit, !info.identifier.isEmpty else {
            throw DriveFailure.rejected("node \(id) requires an explicit stable accessibility-identifier and a native accessible control")
        }
        guard snapshot.nativeIdentifiers.values.filter({ $0.identifier == info.identifier }).count == 1 else {
            throw DriveFailure.rejected("effective accessibility-identifier is not unique in LUI")
        }
        let query = nativeQuery(identifier: info.identifier)
        guard query.count == 1 else {
            throw DriveFailure.rejected("node \(id) has no unique native accessibility element (hidden/custom controls are unsupported)")
        }
        let element = query.element(boundBy: 0)
        guard element.identifier == info.identifier, element.exists, element.isEnabled, element.isHittable else {
            throw DriveFailure.rejected("node \(id) is not enabled and hittable")
        }
        return element
    }

    private func nativeQuery(identifier: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", identifier))
    }

    private func coordinate(_ point: CGPoint, window: XCUIElement) throws -> XCUICoordinate {
        let size = window.frame.size
        guard point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0,
              point.x < size.width, point.y < size.height else {
            throw DriveFailure.rejected("coordinate is outside the logical app viewport")
        }
        return window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: point.x, dy: point.y))
    }

    private func perform(_ request: DriveRequest, client: DriveTCPChannel, deadline: TimeInterval) throws {
        let (snapshot, _) = try snapshot(client: client, deadline: deadline)
        let window = try window(snapshot)
        try client.check(deadline: deadline)
        switch request.action {
        case "click", "double-click", "long-click", "type":
            guard let id = request.fields["id"]?.integer else { throw DriveFailure.protocolViolation("missing id") }
            let element = try target(id, snapshot: snapshot)
            try client.check(deadline: deadline)
            switch request.action {
            case "click": element.tap()
            case "double-click": element.doubleTap()
            case "long-click": element.press(forDuration: 0.8)
            default:
                try replaceText(element, id: id, text: request.fields["text"]?.string ?? "",
                                snapshot: snapshot, client: client, deadline: deadline)
            }
        case "tap":
            guard let x = request.fields["x"]?.number, let y = request.fields["y"]?.number else {
                throw DriveFailure.protocolViolation("missing coordinates")
            }
            let point = try coordinate(CGPoint(x: x, y: y), window: window)
            try client.check(deadline: deadline)
            point.tap()
        case "drag":
            guard let id = request.fields["id"]?.integer, let destination = request.fields["target"]?.integer else {
                throw DriveFailure.protocolViolation("missing drag targets")
            }
            let source = try target(id, snapshot: snapshot)
            let target = try target(destination, snapshot: snapshot)
            let from = source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let to = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            try validateVisibleCenter(source, window: window)
            try validateVisibleCenter(target, window: window)
            try client.check(deadline: deadline)
            from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.1)
        case "scroll":
            guard let id = request.fields["id"]?.integer, let dx = request.fields["dx"]?.number,
                  let dy = request.fields["dy"]?.number else { throw DriveFailure.protocolViolation("missing scroll fields") }
            try scroll(id, dx: dx, dy: dy, client: client, deadline: deadline)
        case "key":
            let combo = request.fields["combo"]?.string ?? ""
            let text: String
            switch combo {
            case "Enter", "Return": text = XCUIKeyboardKey.return.rawValue
            case "Backspace": text = XCUIKeyboardKey.delete.rawValue
            case "Space": text = " "
            default:
                throw DriveFailure.rejected("unsupported iOS key combo; supported: Enter, Return, Backspace, Space (software keyboard only)")
            }
            guard app.keyboards.count == 1 else { throw DriveFailure.rejected("software keyboard is not active") }
            try client.check(deadline: deadline)
            app.typeText(text)
        case "screenshot", "settle": break
        default: throw DriveFailure.protocolViolation("unsupported capability")
        }
        try client.check(deadline: deadline)
    }

    private func validateVisibleCenter(_ element: XCUIElement, window: XCUIElement) throws {
        guard window.frame.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) else {
            throw DriveFailure.rejected("drag endpoint center is outside the app viewport")
        }
    }

    private func replaceText(_ element: XCUIElement, id: Int, text: String, snapshot: DriveProbeSnapshot,
                             client: DriveTCPChannel, deadline: TimeInterval) throws {
        guard [.textField, .secureTextField, .textView, .searchField].contains(element.elementType) else {
            throw DriveFailure.rejected("type requires a native editable text field, search field, or text view")
        }
        let current = retainedText(id, snapshot: snapshot)
        guard let current else { throw DriveFailure.rejected("text replacement requires a retained text property") }
        if snapshot.ops.contains(where: {
            $0["id"]?.integer == id && $0["property"]?.string == "read-only" && $0["value"] == .bool(true)
        }) {
            throw DriveFailure.rejected("text replacement does not support read-only controls")
        }
        try client.check(deadline: deadline)
        element.tap()
        try client.check(deadline: deadline)
        guard app.keyboards.count == 1 else { throw DriveFailure.rejected("software keyboard is not active") }
        if !current.isEmpty {
            element.press(forDuration: 1.1)
            try client.check(deadline: deadline)
            let items = app.menuItems.matching(identifier: "Select All")
            let buttons = app.buttons.matching(identifier: "Select All")
            let selectAll: XCUIElement
            if items.count == 1 { selectAll = items.element(boundBy: 0) }
            else if buttons.count == 1 { selectAll = buttons.element(boundBy: 0) }
            else { throw DriveFailure.rejected("native Select All edit menu unavailable; use an English edit menu and a selectable field") }
            guard selectAll.isEnabled, selectAll.isHittable else {
                throw DriveFailure.rejected("native Select All is not hittable")
            }
            try client.check(deadline: deadline)
            selectAll.tap()
            try client.check(deadline: deadline)
            let (fresh, _) = try self.snapshot(client: client, deadline: deadline)
            let input = try target(id, snapshot: fresh)
            try client.check(deadline: deadline)
            input.typeText(XCUIKeyboardKey.delete.rawValue)
        }
        if !text.isEmpty {
            let (fresh, _) = try self.snapshot(client: client, deadline: deadline)
            let input = try target(id, snapshot: fresh)
            try client.check(deadline: deadline)
            input.typeText(text)
        }
    }

    private func retainedText(_ id: Int, snapshot: DriveProbeSnapshot) -> String? {
        snapshot.ops.first { $0["id"]?.integer == id && $0["property"]?.string == "text" }?["value"]?.string
    }

    private func scroll(_ id: Int, dx: Double, dy: Double,
                        client: DriveTCPChannel, deadline: TimeInterval) throws {
        guard abs(dx) <= 10_000, abs(dy) <= 10_000 else {
            throw DriveFailure.rejected("scroll exceeds the bounded 10000-point gesture budget")
        }
        if dx == 0 && dy == 0 {
            let (snapshot, _) = try snapshot(client: client, deadline: deadline)
            _ = try target(id, snapshot: snapshot)
            return
        }
        var remaining = CGVector(dx: dx, dy: dy)
        var strokes = 0
        while abs(remaining.dx) > 0.01 || abs(remaining.dy) > 0.01 {
            strokes += 1
            guard strokes <= 64 else { throw DriveFailure.rejected("scroll exceeds 64 native strokes") }
            let (snapshot, _) = try snapshot(client: client, deadline: deadline)
            let window = try window(snapshot)
            let element = try target(id, snapshot: snapshot)
            let rect = element.frame.intersection(window.frame).insetBy(dx: 8, dy: 8)
            guard !rect.isNull, rect.width >= 16, rect.height >= 16 else {
                throw DriveFailure.rejected("scroll control has no visible gesture area")
            }
            let scale = min(1, rect.width * 0.7 / max(abs(remaining.dx), 0.01),
                            rect.height * 0.7 / max(abs(remaining.dy), 0.01))
            let step = CGVector(dx: remaining.dx * scale, dy: remaining.dy * scale)
            let origin = window.frame.origin
            // Positive content motion is opposite the finger gesture.
            let from = try coordinate(CGPoint(x: rect.midX + step.dx / 2 - origin.x,
                                              y: rect.midY + step.dy / 2 - origin.y), window: window)
            let to = try coordinate(CGPoint(x: rect.midX - step.dx / 2 - origin.x,
                                            y: rect.midY - step.dy / 2 - origin.y), window: window)
            try client.check(deadline: deadline)
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.1)
            try client.check(deadline: deadline)
            remaining.dx -= step.dx
            remaining.dy -= step.dy
        }
    }
}
#endif
