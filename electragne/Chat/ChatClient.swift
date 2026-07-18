import Foundation

/// JSON-compatible values used at the boundary between model tool calls and
/// local executors. Keeping this type provider-neutral makes subsequent tools
/// reusable without introducing an arguments struct into ChatClient itself.
nonisolated enum ChatToolValue: Equatable, Codable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: ChatToolValue])
    case array([ChatToolValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: ChatToolValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([ChatToolValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported tool JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var objectValue: [String: ChatToolValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var numberValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    var arrayValue: [ChatToolValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }
}

nonisolated struct ChatToolCall: Equatable, Codable, Sendable {
    let id: String
    let name: String
    let arguments: [String: ChatToolValue]

    /// Provider-only context needed during a tool round (for example Gemini
    /// thought signatures). It is transient and never persisted in chat JSON.
    var providerContext: ChatToolValue? = nil

    private struct Function: Codable {
        let name: String
        let arguments: [String: ChatToolValue]
    }

    private enum CodingKeys: String, CodingKey { case id, function }

    init(
        id: String,
        name: String,
        arguments: [String: ChatToolValue],
        providerContext: ChatToolValue? = nil
    ) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.providerContext = providerContext
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        let function = try container.decode(Function.self, forKey: .function)
        name = function.name
        arguments = function.arguments
        providerContext = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !id.isEmpty { try container.encode(id, forKey: .id) }
        try container.encode(Function(name: name, arguments: arguments), forKey: .function)
    }

    static func == (lhs: ChatToolCall, rhs: ChatToolCall) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.arguments == rhs.arguments
    }
}

nonisolated struct ChatToolResult: Equatable, Sendable {
    let response: [String: ChatToolValue]

    static func error(_ message: String) -> ChatToolResult {
        ChatToolResult(response: [
            "status": .string("error"),
            "message": .string(message),
        ])
    }

    /// The common status+message result shape shared by every tool executor.
    static func make(status: String, message: String) -> ChatToolResult {
        ChatToolResult(response: [
            "status": .string(status),
            "message": .string(message),
        ])
    }
}

/// Provider-neutral chat history. Its coding keys intentionally match the
/// legacy OllamaMessage format so existing stored chats decode unchanged.
nonisolated struct ChatMessage: Equatable, Codable, Sendable {
    var role: String
    var content: String
    var toolName: String? = nil
    var toolCallID: String? = nil
    var toolCalls: [ChatToolCall]? = nil

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolName = "tool_name"
        case toolCallID = "tool_call_id"
        case toolCalls = "tool_calls"
    }
}

nonisolated enum ChatSystemPrompt {
    static func make(providerDetails: String) -> String {
        """
        You are Baaz, a highly intelligent sheep living as a desktop pet, \
        chatting with your owner. Respond as if chatting: keep replies short and \
        chat-sized — a sentence or two, or a brief list when that is clearer. \
        \(providerDetails)
        """
    }
}

/// A chat backend the bubble can stream a reply from.
protocol ChatClient {
    func streamChat(
        history: [ChatMessage],
        onStatus: (String) -> Void,
        onToolCall: (ChatToolCall) async -> ChatToolResult,
        onToken: (String) -> Void
    ) async throws
}

nonisolated enum ChatProvider: String, CaseIterable, Sendable {
    case ollama
    case gemini
    case openAICompatible

    var displayName: String {
        switch self {
        case .ollama: "Ollama"
        case .gemini: "Gemini"
        case .openAICompatible: "OpenAI-compatible"
        }
    }
}

/// Which backend the menu-bar provider submenu has selected.
enum ChatProviderPreference {
    nonisolated static let providerKey = "chatProvider"
    nonisolated static let useGeminiKey = "useGeminiChat"

    nonisolated static func selected(in defaults: UserDefaults = .standard) -> ChatProvider {
        if let raw = defaults.string(forKey: providerKey), let provider = ChatProvider(rawValue: raw) {
            return provider
        }
        let provider: ChatProvider = defaults.bool(forKey: useGeminiKey) ? .gemini : .ollama
        defaults.set(provider.rawValue, forKey: providerKey)
        return provider
    }

    static var selected: ChatProvider { selected() }

    static func set(_ provider: ChatProvider, in defaults: UserDefaults = .standard) {
        defaults.set(provider.rawValue, forKey: providerKey)
    }
}
