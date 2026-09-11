import Foundation

struct RPCResponse<Result: Decodable & Sendable>: Decodable, Sendable {
    let jsonrpc: String
    let id: Int?
    let result: Result?
    let error: RPCErrorDTO?
}

/// Typed recovery derived from the sidecar's stable error code and its optional
/// `data.recovery` hint. Views switch on this; they never inspect message text.
enum RecoveryAction: Equatable, Sendable {
    case retry
    case refresh
    case chooseAnotherFolder
    case installTmux
    case installBinary
    case keepWorktreeOrForce
    case none
}

struct RPCErrorDTO: Decodable, LocalizedError, Equatable, Sendable {
    let code: Int
    let message: String
    let recovery: String?
    let detail: String?

    private enum CodingKeys: String, CodingKey {
        case code
        case message
        case data
    }

    private enum DataKeys: String, CodingKey {
        case recovery
        case detail
    }

    init(code: Int, message: String, recovery: String? = nil, detail: String? = nil) {
        self.code = code
        self.message = message
        self.recovery = recovery
        self.detail = detail
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(Int.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)

        if let data = try? container.nestedContainer(keyedBy: DataKeys.self, forKey: .data) {
            recovery = try data.decodeIfPresent(String.self, forKey: .recovery)
            detail = try data.decodeIfPresent(String.self, forKey: .detail)
        } else {
            recovery = nil
            detail = nil
        }
    }

    var errorDescription: String? {
        if let detail, !detail.isEmpty, detail != message { return "\(message): \(detail)" }
        return message
    }

    var recoveryAction: RecoveryAction {
        switch recovery {
        case "install_tmux": return .installTmux
        case "install_binary": return .installBinary
        case "keep_worktree_or_force": return .keepWorktreeOrForce
        default: break
        }
        switch code {
        case -32001: return .chooseAnotherFolder
        case -32002, -32005: return .retry
        case -32004: return .refresh
        default: return .none
        }
    }
}

struct EmptyResult: Decodable, Sendable {}

enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case integer(Int)
    case double(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct RPCRequest: Encodable, Sendable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: [String: JSONValue]?

    static func encode(
        id: Int,
        method: String,
        params: [String: JSONValue] = [:]
    ) throws -> Data {
        let request = RPCRequest(
            id: id,
            method: method,
            params: params.isEmpty ? nil : params
        )
        var data = try JSONEncoder().encode(request)
        data.append(0x0A)
        return data
    }
}

extension JSONDecoder {
    static var oma: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)

            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value) {
                return date
            }
            if let date = try? Date.ISO8601FormatStyle().parse(value) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Invalid ISO 8601 date: \(value)"
            )
        }
        return decoder
    }
}
