#if os(iOS)
import Foundation
import Network

// All mutable state crossing the Network callback queue is protected by condition.
final class DriveTCPChannel: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.lui.drive.tcp")
    private let condition = NSCondition()
    private var buffer = Data()
    private var closed: DriveFailure?
    private var deadlineToken = UUID()
    private let maximumLine: Int

    init(connection: NWConnection, maximumLine: Int = 1_048_576) {
        self.connection = connection
        self.maximumLine = maximumLine
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case let .failed(error): self?.close(.transport(String(describing: error)))
            case .cancelled: self?.close(.transport("connection cancelled"))
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    convenience init(loopbackPort: UInt16) {
        self.init(connection: NWConnection(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: loopbackPort)!, using: .tcp
        ), maximumLine: 33_554_432)
    }

    deinit { connection.cancel() }

    func close(_ reason: DriveFailure = .transport("disconnected")) {
        condition.lock()
        if closed == nil { closed = reason }
        buffer.removeAll(keepingCapacity: false)
        condition.broadcast()
        condition.unlock()
        connection.cancel()
    }

    func check(deadline: TimeInterval) throws {
        condition.lock()
        let failure = closed
        condition.unlock()
        if let failure { throw failure }
        if ProcessInfo.processInfo.systemUptime >= deadline {
            close(.deadline)
            throw DriveFailure.deadline
        }
    }

    func arm(deadline: TimeInterval) {
        let token = UUID()
        condition.lock()
        deadlineToken = token
        condition.unlock()
        queue.asyncAfter(deadline: .now() + max(0, deadline - ProcessInfo.processInfo.systemUptime)) { [weak self] in
            guard let self else { return }
            self.condition.lock()
            let expired = self.deadlineToken == token && self.closed == nil
            if expired {
                self.closed = .deadline
                self.buffer.removeAll(keepingCapacity: false)
                self.condition.broadcast()
            }
            self.condition.unlock()
            if expired { self.connection.cancel() }
        }
    }

    func disarm() {
        condition.lock()
        deadlineToken = UUID()
        condition.unlock()
    }

    func readLine(until deadline: TimeInterval) throws -> Data? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let closed { throw closed }
            if let index = buffer.firstIndex(of: 10) {
                let line = Data(buffer.prefix(upTo: index))
                buffer.removeSubrange(...index)
                guard !line.isEmpty else { throw DriveFailure.protocolViolation("empty JSON line") }
                return line
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return nil }
            _ = condition.wait(until: Date(timeIntervalSinceNow: remaining))
        }
    }

    private final class Receipt: @unchecked Sendable {
        let condition = NSCondition()
        var complete = false
        var error: String?

        func finish(_ error: NWError?) {
            condition.lock()
            self.error = error.map { String(describing: $0) }
            complete = true
            condition.broadcast()
            condition.unlock()
        }
    }

    func send(_ value: DriveJSON, deadline: TimeInterval) throws {
        try check(deadline: deadline)
        var data = try value.data()
        data.append(10)
        let receipt = Receipt()
        connection.send(content: data, completion: .contentProcessed { receipt.finish($0) })
        receipt.condition.lock()
        while !receipt.complete {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { break }
            _ = receipt.condition.wait(until: Date(timeIntervalSinceNow: remaining))
        }
        let complete = receipt.complete
        let error = receipt.error
        receipt.condition.unlock()
        guard complete else { close(.deadline); throw DriveFailure.deadline }
        if let error { close(.transport(error)); throw DriveFailure.transport(error) }
        try check(deadline: deadline)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            self.condition.lock()
            if let data, self.closed == nil { self.buffer.append(data) }
            let overflow = self.buffer.count > self.maximumLine
            self.condition.broadcast()
            self.condition.unlock()
            if overflow { self.close(.protocolViolation("JSON line buffer limit exceeded")) }
            else if let error { self.close(.transport(String(describing: error))) }
            else if done { self.close() }
            else { self.receive() }
        }
    }
}

final class DriveTCPServer: @unchecked Sendable {
    private let listener: NWListener
    private let condition = NSCondition()
    private var channel: DriveTCPChannel?
    private var accepted = false
    private var failure: String?

    init(port: UInt16) throws {
        guard port >= 1024 else { throw DriveFailure.rejected("runner port must be 1024...65535") }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, case let .hostPort(host, _) = connection.endpoint,
                  host == .ipv4(.loopback) else { connection.cancel(); return }
            self.condition.lock()
            if self.accepted { self.condition.unlock(); connection.cancel(); return }
            self.accepted = true
            self.channel = DriveTCPChannel(connection: connection)
            self.condition.broadcast()
            self.condition.unlock()
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, case let .failed(error) = state else { return }
            self.condition.lock()
            self.failure = String(describing: error)
            self.condition.broadcast()
            self.condition.unlock()
        }
        listener.start(queue: DispatchQueue(label: "dev.lui.drive.listener"))
    }

    func accept(deadline: TimeInterval) throws -> DriveTCPChannel {
        condition.lock()
        defer { condition.unlock() }
        while channel == nil && failure == nil {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw DriveFailure.deadline }
            _ = condition.wait(until: Date(timeIntervalSinceNow: remaining))
        }
        if let failure { throw DriveFailure.transport(failure) }
        guard let channel else { throw DriveFailure.transport("listener closed") }
        return channel
    }

    func stop() {
        listener.cancel()
        condition.lock()
        accepted = true
        failure = "listener stopped"
        let channel = channel
        condition.broadcast()
        condition.unlock()
        channel?.close()
    }

    deinit { listener.cancel() }
}
#endif
