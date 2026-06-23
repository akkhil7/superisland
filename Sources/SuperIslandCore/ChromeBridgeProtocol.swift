import Foundation

public enum JSONRPCID: Codable, Equatable, Sendable {
    case string(String)
    case number(Int)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            self = .string(s)
        } else {
            self = .number(try c.decode(Int.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        }
    }
}

public indirect enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public var intValue: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let value = try? c.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? c.decode(Double.self) {
            self = .number(value)
        } else if let value = try? c.decode(String.self) {
            self = .string(value)
        } else if let value = try? c.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try c.decode([JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .bool(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .null: try c.encodeNil()
        }
    }
}

public enum ChromeBridgeTool: String, Codable, CaseIterable, Sendable {
    case listTabs = "chrome.list_tabs"
    case captureActiveTabState = "chrome.capture_active_tab_state"
    case captureTabDOMSummary = "chrome.capture_tab_dom_summary"
    case refocusTab = "chrome.refocus_tab"
    case observeTabTask = "chrome.observe_tab_task"
    case getTabStatus = "chrome.get_tab_status"
}

public struct ChromeBridgeToolCall: Codable, Equatable, Sendable {
    public struct Params: Codable, Equatable, Sendable {
        public var name: String
        public var arguments: [String: JSONValue]?
    }

    public var jsonrpc: String
    public var id: JSONRPCID
    public var method: String
    public var params: Params

    public var tool: ChromeBridgeTool { ChromeBridgeTool(rawValue: params.name)! }
    public var arguments: [String: JSONValue] { params.arguments ?? [:] }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try c.decode(String.self, forKey: .jsonrpc)
        id = try c.decode(JSONRPCID.self, forKey: .id)
        method = try c.decode(String.self, forKey: .method)
        params = try c.decode(Params.self, forKey: .params)
        guard method == "tools/call", ChromeBridgeTool(rawValue: params.name) != nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .params,
                in: c,
                debugDescription: "Unsupported Chrome bridge tool call"
            )
        }
    }
}

public struct ChromeBridgeError: Codable, Equatable, Sendable {
    public var code: Int
    public var message: String
}

public struct ChromeBridgeResponse: Codable, Equatable, Sendable {
    public var jsonrpc: String
    public var id: JSONRPCID
    public var result: [String: JSONValue]?
    public var error: ChromeBridgeError?

    public static func success(
        id: JSONRPCID,
        result: [String: JSONValue]
    ) -> ChromeBridgeResponse {
        ChromeBridgeResponse(jsonrpc: "2.0", id: id, result: result, error: nil)
    }

    public static func failure(
        id: JSONRPCID,
        code: Int,
        message: String
    ) -> ChromeBridgeResponse {
        ChromeBridgeResponse(
            jsonrpc: "2.0",
            id: id,
            result: nil,
            error: ChromeBridgeError(code: code, message: message)
        )
    }
}

public enum ChromeBridgeEventType: String, Codable, Sendable {
    case tabState = "tab_state"
    case taskSignal = "task_signal"
    case commandPoll = "command_poll"
}

public struct ChromeTabState: Codable, Equatable, Sendable {
    public var tabID: Int
    public var windowID: Int
    public var index: Int
    public var url: String?
    public var title: String?
    public var documentID: String?
    public var status: DropStatus?

    enum CodingKeys: String, CodingKey {
        case tabID = "tabId"
        case windowID = "windowId"
        case index, url, title
        case documentID = "documentId"
        case status
    }
}

public struct ChromeDOMSummary: Codable, Equatable, Sendable {
    public var title: String?
    public var text: String?
    public var taskState: DropStatus?
}

public struct ChromeBridgeExtensionEvent: Codable, Equatable, Sendable {
    public var type: ChromeBridgeEventType
    public var tab: ChromeTabState?
    public var domSummary: ChromeDOMSummary?
}
