import Foundation
import CoreFoundation

enum DriveFailure: Error, CustomStringConvertible {
    case protocolViolation(String)
    case rejected(String)
    case transport(String)
    case deadline

    var description: String {
        switch self {
        case let .protocolViolation(message), let .rejected(message), let .transport(message): message
        case .deadline: "Drive deadline exceeded; transport is poisoned"
        }
    }
}

enum DriveJSON: Codable, Equatable {
    case object([String: DriveJSON]), array([DriveJSON]), string(String)
    case bool(Bool), int(Int), double(Double), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
        else if let decoded = try? value.decode(Int.self) { self = .int(decoded) }
        else if let decoded = try? value.decode(Double.self) { self = .double(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode([DriveJSON].self) { self = .array(decoded) }
        else { self = .object(try value.decode([String: DriveJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case let .object(v): try value.encode(v)
        case let .array(v): try value.encode(v)
        case let .string(v): try value.encode(v)
        case let .bool(v): try value.encode(v)
        case let .int(v): try value.encode(v)
        case let .double(v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }

    subscript(_ key: String) -> DriveJSON? {
        guard case let .object(value) = self else { return nil }
        return value[key]
    }

    var integer: Int? { if case let .int(v) = self { v } else { nil } }
    var string: String? { if case let .string(v) = self { v } else { nil } }
    var number: Double? {
        switch self {
        case let .double(v): v
        case let .int(v): Double(v)
        default: nil
        }
    }

    func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

struct DriveRequest {
    static let capabilities = [
        "click", "double-click", "long-click", "tap", "type", "key",
        "scroll", "drag", "screenshot", "settle",
    ]
    let request: Int
    let action: String
    let fields: DriveJSON

    init(line: Data, previousRequest: Int) throws {
        let value = try JSONDecoder().decode(DriveJSON.self, from: line)
        guard let raw = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw DriveFailure.protocolViolation("expected a JSON object")
        }
        guard case let .object(fields) = value,
              value["drive"]?.string == "action", value["version"]?.integer == 1,
              let request = value["request"]?.integer, request > 0,
              request <= 9_007_199_254_740_991, request == previousRequest + 1,
              let action = value["action"]?.string, Self.capabilities.contains(action)
        else { throw DriveFailure.protocolViolation("invalid Drive v1 action, capability, or sequential request ID") }
        let required: Set<String>
        switch action {
        case "click", "double-click", "long-click": required = ["id"]
        case "type": required = ["id", "text"]
        case "key": required = ["combo"]
        case "tap": required = ["x", "y"]
        case "scroll": required = ["id", "dx", "dy"]
        case "drag": required = ["id", "target"]
        default: required = []
        }
        guard Set(fields.keys) == required.union(["drive", "version", "request", "action"]) else {
            throw DriveFailure.protocolViolation("missing or unexpected action fields")
        }
        for key in ["version", "request", "id", "target"] where raw[key] != nil {
            guard let number = raw[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  !["f", "d"].contains(String(cString: number.objCType)) else {
                throw DriveFailure.protocolViolation("expected integer \(key)")
            }
        }
        for key in required {
            switch key {
            case "id", "target":
                guard let id = value[key]?.integer, id >= 0 else {
                    throw DriveFailure.protocolViolation("invalid node ID")
                }
            case "text", "combo":
                guard value[key]?.string != nil else { throw DriveFailure.protocolViolation("expected string") }
            default:
                guard let number = value[key]?.number, number.isFinite else {
                    throw DriveFailure.protocolViolation("expected finite viewport points")
                }
            }
        }
        self.request = request
        self.action = action
        self.fields = value
    }
}

struct DriveProbeSnapshot: Decodable {
    struct Identifier: Decodable {
        let identifier: String
        let explicit: Bool
    }
    let generation: Int
    let commitSequence: Int
    let committed: Bool
    let ops: [DriveJSON]
    let nodeIDs: [Int]
    let roots: [Int]
    let frames: [[Double]]
    let nativeIdentifiers: [String: Identifier]
    let viewport: [Double]
    let coordinateSpace: String
}

struct DriveProbeReply: Decodable {
    let probe: String
    let version: Int
    let request: Int
    let snapshot: DriveProbeSnapshot
}
