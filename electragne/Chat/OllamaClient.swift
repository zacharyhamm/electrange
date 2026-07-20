import Foundation

/// One decoded line of the NDJSON stream from /api/chat.
nonisolated struct OllamaChatChunk: Equatable {
    var content: String
    var done: Bool
    var toolCalls: [ChatToolCall] = []
}

/// Minimal streaming client for a local Ollama server.
nonisolated struct OllamaClient: ChatProviderBackend, ChatClient {
    nonisolated static let defaultBaseURL = URL(string: "http://localhost:11434")!
    nonisolated static let systemPrompt = ChatSystemPrompt.make(providerDetails: """
        Markdown formatting is welcome: bold, italics, [title](url) links, \
        bullet lists using "-", headings, and tables; avoid code blocks. \
        You can manage Apple Reminders and Notes, manage countdown timers, open \
        apps and websites, search approved folders by file name, reveal search \
        results in Finder, use Gmail and Google Calendar from connected Google accounts, and search the web. \
        Creating a Calendar event requires owner confirmation. \
        Gmail draft creation and sending are separate actions that each require owner confirmation. \
        Use web_search when asked to search, or for \
        current events and facts you are not sure about. When you answer \
        from web search results, always share links to the sources you used \
        (markdown [title](url) links are fine). Use image_search when the owner asks \
        to find or show images. Use timer tools only when the \
        owner asks, and never claim an action succeeded until the tool reports success.
        """)

    /// The full system prompt, personalized with the owner's name when known.
    nonisolated static func makeSystemPrompt(
        userName: String?,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        ChatSystemPrompt.personalized(systemPrompt, userName: userName, now: now, timeZone: timeZone)
    }

    let baseURLOverride: URL?
    let modelOverride: String?
    let transport: any ChatHTTPTransport
    let config: ChatConfig
    /// Resolved per request so Settings changes apply immediately.
    var baseURL: URL { baseURLOverride ?? Self.resolvedBaseURL }
    /// Resolved per request so model-picker/Settings changes apply immediately.
    var model: String { modelOverride ?? UserPreferences.ollamaModel() }
    /// Resolved per request so Settings changes apply immediately.
    var userName: String? { UserPreferences.resolvedUserName() }

    /// The base URL from Settings, or the localhost default.
    nonisolated static var resolvedBaseURL: URL {
        UserPreferences.ollamaBaseURL().flatMap { URL(string: $0) } ?? defaultBaseURL
    }

    init(
        baseURL: URL? = nil,
        model: String? = nil,
        transport: any ChatHTTPTransport = LoggingTransport(proxied: UserPreferences.useProxy(for: .ollama)),
        config: ChatConfig = .default
    ) {
        self.baseURLOverride = baseURL
        self.modelOverride = model
        self.transport = transport
        self.config = config
    }

    private nonisolated struct TagsResponse: Decodable {
        struct Model: Decodable { let name: String }
        let models: [Model]
    }

    /// The models pulled into the local Ollama server, via GET api/tags.
    static func listModels(
        baseURL: URL? = nil,
        transport: any ChatHTTPTransport = LoggingTransport(proxied: UserPreferences.useProxy(for: .ollama))
    ) async throws -> [String] {
        let baseURL = baseURL ?? resolvedBaseURL
        let request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        let (data, response) = try await transport.data(for: request)
        try ChatProviderError.checkOK(response)
        return try JSONDecoder().decode(TagsResponse.self, from: data).models.map(\.name)
    }

    private nonisolated struct ChatRequest: Encodable {
        struct Options: Encodable {
            let numCtx: Int

            enum CodingKeys: String, CodingKey {
                case numCtx = "num_ctx"
            }
        }

        struct ToolDefinition: Encodable {
            struct Function: Encodable {
                struct Parameters: Encodable {
                    struct Property: Encodable {
                        let type: String
                        let description: String
                    }

                    let type = "object"
                    let properties: [String: Property]
                    let required: [String]
                }

                let name: String
                let description: String
                let parameters: Parameters
            }

            let type = "function"
            let function: Function

            init(_ definition: ChatToolDefinition) {
                function = Function(
                    name: definition.name,
                    description: definition.description,
                    parameters: Function.Parameters(
                        properties: definition.properties.mapValues { parameter in
                            Function.Parameters.Property(
                                type: parameter.type.rawValue,
                                description: parameter.description
                            )
                        },
                        required: definition.required
                    )
                )
            }
        }

        let model: String
        let messages: [ChatMessage]
        let stream: Bool
        let options: Options
        let tools: [ToolDefinition]
    }


    private nonisolated struct ChatResponseLine: Decodable {
        struct Message: Decodable {
            let content: String?
            let toolCalls: [ChatToolCall]?

            enum CodingKeys: String, CodingKey {
                case content
                case toolCalls = "tool_calls"
            }
        }

        let message: Message?
        let done: Bool?
    }

    nonisolated static func makeRequestBody(
        model: String,
        history: [ChatMessage],
        userName: String? = nil,
        contextWindowTokens: Int = ChatConfig.default.contextWindowTokens,
        webSearchAvailable: Bool = true
    ) throws -> Data {
        let definitions = ChatToolRegistry.definitions(for: .ollama).filter {
            $0.family != .webSearch || webSearchAvailable
        }
        let wireHistory = history.map { message in
            var message = message
            message.images = nil
            return message
        }
        let request = ChatRequest(
            model: model,
            messages: [ChatMessage(role: "system", content: makeSystemPrompt(userName: userName))]
                + wireHistory,
            stream: true,
            options: ChatRequest.Options(numCtx: contextWindowTokens),
            tools: definitions.map(ChatRequest.ToolDefinition.init)
        )
        return try JSONEncoder().encode(request)
    }

    /// Decodes one NDJSON line. Returns nil for blank or malformed lines; the
    /// final `done: true` line may carry no message content.
    nonisolated static func decodeChunk(fromLine line: String) -> OllamaChatChunk? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        guard let decoded = try? JSONDecoder().decode(ChatResponseLine.self, from: data) else {
            return nil
        }
        return OllamaChatChunk(
            content: decoded.message?.content ?? "",
            done: decoded.done ?? false,
            toolCalls: decoded.message?.toolCalls ?? []
        )
    }

    func stream(messages: [ChatMessage]) async throws
        -> AsyncThrowingStream<ProviderEvent, Error> {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.makeRequestBody(
            model: model,
            history: messages,
            userName: userName,
            contextWindowTokens: config.contextWindowTokens,
            webSearchAvailable: UserPreferences.searxngEndpoint() != nil
        )

        let (lines, response) = try await transport.lines(for: request)
        try ChatProviderError.checkOK(response)

        return .fromTask { continuation in
            for try await line in lines {
                guard let chunk = Self.decodeChunk(fromLine: line) else { continue }
                if !chunk.content.isEmpty { continuation.yield(.token(chunk.content)) }
                chunk.toolCalls.forEach { continuation.yield(.toolCall($0)) }
                if chunk.done { break }
            }
        }
    }

    func appendToolResult(
        _ result: ChatToolResult,
        for call: ChatToolCall,
        to messages: inout [ChatMessage]
    ) {
        let data = (try? JSONEncoder().encode(result.response)) ?? Data("{}".utf8)
        messages.append(ChatMessage(
            role: "tool",
            content: String(decoding: data, as: UTF8.self),
            toolName: call.name
        ))
    }
}
