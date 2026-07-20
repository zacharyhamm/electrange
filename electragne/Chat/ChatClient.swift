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

nonisolated struct ChatImage: Equatable, Codable, Sendable, Identifiable {
    let url: String
    let sourceURL: String
    let title: String

    var id: String { url }

    init?(url: String?, sourceURL: String?, title: String?) {
        guard let url, Self.webURL(url) != nil,
              let sourceURL, Self.webURL(sourceURL) != nil else { return nil }
        self.url = url
        self.sourceURL = sourceURL
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.title = trimmedTitle.isEmpty ? "Search result image" : trimmedTitle
    }

    static func webURL(_ string: String) -> URL? {
        guard let url = URL(string: string),
              ["http", "https"].contains(url.scheme?.lowercased()),
              url.host?.isEmpty == false else { return nil }
        return url
    }
}

nonisolated enum ChatImagePresentation: Equatable, Sendable {
    case thumbnails
    case gallery
}

nonisolated struct ChatImageBatch: Equatable, Sendable {
    let images: [ChatImage]
    let presentation: ChatImagePresentation
}

nonisolated struct ChatToolResult: Equatable, Sendable {
    let response: [String: ChatToolValue]
    var imageBatch: ChatImageBatch? = nil

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
    var images: [ChatImage]? = nil
    var toolName: String? = nil
    var toolCallID: String? = nil
    var toolCalls: [ChatToolCall]? = nil

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case images
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

    /// The owner's current local date and time, formatted per request so it is
    /// never stale, for resolving relative dates like "tomorrow".
    static func dateLine(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a XXXXX"
        return " The owner's current local date and time is \(formatter.string(from: now))"
            + " (\(timeZone.identifier)). Use this when resolving relative dates and times."
    }

    /// A provider's base prompt plus the date line and, when known, the
    /// owner's name.
    static func personalized(
        _ systemPrompt: String,
        userName: String?,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        var prompt = systemPrompt + dateLine(now: now, timeZone: timeZone)
        if let userName, !userName.isEmpty {
            prompt += " The owner you are chatting with is named \(userName), but there "
                + "is no need to keep repeating their name — use it sparingly."
        }
        return prompt
    }
}

/// A chat backend the bubble can stream a reply from.
protocol ChatClient {
    func streamChat(
        history: [ChatMessage],
        onStatus: (String) -> Void,
        onToolCall: (ChatToolCall) async -> ChatToolResult,
        onImages: (ChatImageBatch) -> Void,
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

    /// Fresh client for this provider. `thinking` only applies to
    /// OpenAI-compatible backends; nil keeps the stored preference.
    func makeClient(model: String? = nil, thinking: Bool? = nil) -> any ChatClient {
        switch self {
        case .ollama: OllamaClient(model: model)
        case .gemini: GeminiClient(model: model)
        case .openAICompatible: OpenAICompatibleClient(model: model, thinking: thinking)
        }
    }

    /// Providers usable right now: local Ollama needs no key, the rest need one.
    static func configured() -> [ChatProvider] {
        allCases.filter { provider in
            switch provider {
            case .ollama: true
            case .gemini: ChatAPIKeyStore.load(for: .gemini) != nil
            case .openAICompatible: ChatAPIKeyStore.load(for: .openAICompatible) != nil
            }
        }
    }

    /// The UserDefaults key holding the model picked for this provider.
    var modelKey: String {
        switch self {
        case .ollama: UserPreferences.ollamaModelKey
        case .gemini: UserPreferences.geminiModelKey
        case .openAICompatible: UserPreferences.openAICompatibleModelKey
        }
    }

    /// The model picked for this provider, or its ChatConfig default.
    func storedModel() -> String {
        switch self {
        case .ollama: UserPreferences.ollamaModel()
        case .gemini: UserPreferences.geminiModel()
        case .openAICompatible: UserPreferences.openAICompatibleModel()
        }
    }

    /// The provider's live model list, for pickers.
    func listModelIDs() async throws -> [String] {
        switch self {
        case .ollama:
            return try await OllamaClient.listModels()
        case .gemini:
            guard let key = ChatAPIKeyStore.load(for: .gemini) else { return [] }
            return try await GeminiClient.listModels(apiKey: key).map(\.id)
        case .openAICompatible:
            guard let baseURL = URL(string: UserPreferences.openAICompatibleBaseURL()),
                  let key = OpenAICompatibleClient.resolveAPIKey(
                    baseURL: baseURL,
                    keychainKey: ChatAPIKeyStore.key(for: .openAICompatible)
                  ) else { return [] }
            return try await OpenAICompatibleClient.listModels(
                baseURL: baseURL,
                apiKey: key
            ).map(\.id)
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
        // Deliberate write-during-read: migrates the legacy useGemini bool to
        // providerKey the first time the preference is consulted.
        let provider: ChatProvider = defaults.bool(forKey: useGeminiKey) ? .gemini : .ollama
        defaults.set(provider.rawValue, forKey: providerKey)
        return provider
    }

    static var selected: ChatProvider { selected() }

    static func set(_ provider: ChatProvider, in defaults: UserDefaults = .standard) {
        defaults.set(provider.rawValue, forKey: providerKey)
    }
}

/// Which backend forms memories after each exchange. Unset (the default)
/// follows the chat provider and its model.
enum MemoryProviderPreference {
    nonisolated static let providerKey = "memoryProvider"
    nonisolated static let modelKey = "memoryModel"

    /// nil means "same as chat".
    nonisolated static func selected(in defaults: UserDefaults = .standard) -> ChatProvider? {
        defaults.string(forKey: providerKey).flatMap(ChatProvider.init(rawValue:))
    }

    static var selected: ChatProvider? { selected() }

    /// nil means the provider's normally configured model.
    nonisolated static func model(in defaults: UserDefaults = .standard) -> String? {
        guard let value = defaults.string(forKey: modelKey), !value.isEmpty else { return nil }
        return value
    }

    static var model: String? { model() }
}
