import Foundation

/// One grounding source (search result) attached to a Gemini answer.
struct GeminiSource: Equatable {
    let title: String?
    let uri: String
}

/// One decoded SSE data line from streamGenerateContent.
struct GeminiChunk: Equatable {
    var text: String
    var sources: [GeminiSource] = []
    var modelParts: [ChatToolValue] = []
    var toolCalls: [ChatToolCall] = []
}

/// A Gemini content turn. Parts remain JSON-shaped so opaque server tool
/// context and thought signatures can be sent back byte-for-byte in meaning.
nonisolated struct GeminiContent: Equatable, Codable, Sendable {
    var role: String?
    var parts: [ChatToolValue]
}

/// Streaming Gemini client with Google Search grounding and local function
/// execution. Server tool context stays inside a request's bounded tool loop;
/// stored chat history remains provider-neutral user/model text.
nonisolated struct GeminiClient: ChatProviderBackend, ChatClient {
    nonisolated static let defaultBaseURL = URL(string: "https://generativelanguage.googleapis.com")!
    nonisolated static let defaultModel = ChatConfig.default.geminiModel
    nonisolated static let systemPrompt = ChatSystemPrompt.make(providerDetails: """
        Markdown formatting is welcome: bold, italics, [title](url) links, \
        bullet lists using "-", headings, tables, and inline math using $...$ or \\(...\\); \
        avoid code blocks and display-math delimiters. \
        You have Google Search available: use it when asked to search, or \
        for current events and facts you are not sure about. You can manage \
        Apple Reminders and Notes, manage countdown timers, open apps and websites, \
        search approved folders by file name, reveal search results in Finder, and search or read \
        Gmail and Google Calendar from connected Google accounts. Gmail draft creation and sending \
        are separate actions that each require owner confirmation; Calendar event creation also \
        requires owner confirmation. Use these tools only \
        when the owner asks. Never claim an action succeeded until its tool \
        reports success.
        """)
    nonisolated static let maxSourceLinks = 3
    nonisolated static let maxToolRounds = ChatConfig.default.maxToolRounds

    var baseURL: URL
    let modelOverride: String?
    let transport: any ChatHTTPTransport
    let config: ChatConfig
    let apiKey: @Sendable () -> String?
    var userName: String? { UserPreferences.resolvedUserName() }
    /// Resolved per request so a Settings change applies without restart.
    var model: String { modelOverride ?? UserPreferences.geminiModel() }

    init(
        baseURL: URL = defaultBaseURL,
        model: String? = nil,
        transport: any ChatHTTPTransport = URLSessionTransport(session: .shared),
        config: ChatConfig = .default,
        apiKey: @escaping @Sendable () -> String? = { ChatAPIKeyStore.load(for: .gemini) }
    ) {
        self.baseURL = baseURL
        self.modelOverride = model
        self.transport = transport
        self.config = config
        self.apiKey = apiKey
    }

    private nonisolated struct GenerateRequest: Encodable {
        struct SystemInstruction: Encodable {
            let parts: [ChatToolValue]
        }

        struct Empty: Encodable {}

        struct FunctionDeclaration: Encodable {
            let name: String
            let description: String
            /// JSON-shaped so runtime MCP schemas pass through untouched.
            let parameters: ChatToolValue

            init(_ definition: ChatToolDefinition) {
                name = definition.name
                description = definition.description
                parameters = .object([
                    "type": .string("OBJECT"),
                    "properties": .object(definition.properties.mapValues { parameter in
                        .object([
                            "type": .string(parameter.type.rawValue.uppercased()),
                            "description": .string(parameter.description),
                        ])
                    }),
                    "required": .array(definition.required.map(ChatToolValue.string)),
                ])
            }

            init(_ descriptor: MCPToolDescriptor) {
                name = descriptor.namespacedName
                description = descriptor.description
                parameters = descriptor.inputSchema
            }
        }

        struct Tool: Encodable {
            var googleSearch: Empty?
            var functionDeclarations: [FunctionDeclaration]?

            static let search = Tool(googleSearch: Empty(), functionDeclarations: nil)
            static func functions(_ declarations: [FunctionDeclaration]) -> Tool {
                Tool(googleSearch: nil, functionDeclarations: declarations)
            }
        }

        struct ToolConfig: Encodable {
            let includeServerSideToolInvocations = true
        }

        let systemInstruction: SystemInstruction
        let contents: [GeminiContent]
        let tools: [Tool]
        let toolConfig = ToolConfig()

        enum CodingKeys: String, CodingKey {
            case systemInstruction = "system_instruction"
            case contents
            case tools
            case toolConfig
        }
    }

    private nonisolated struct ResponseChunk: Decodable {
        struct Candidate: Decodable {
            struct GroundingMetadata: Decodable {
                struct GroundingChunk: Decodable {
                    struct Web: Decodable {
                        let uri: String?
                        let title: String?
                    }

                    let web: Web?
                }

                let groundingChunks: [GroundingChunk]?
            }

            let content: GeminiContent?
            let groundingMetadata: GroundingMetadata?
        }

        let candidates: [Candidate]?
    }

    private nonisolated static let functionDeclarations =
        ChatToolRegistry.definitions(for: .gemini).map(GenerateRequest.FunctionDeclaration.init)

    nonisolated static func makeSystemPrompt(
        userName: String?,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a XXXXX"

        var prompt = systemPrompt
            + " The owner's current local date and time is \(formatter.string(from: now))"
            + " (\(timeZone.identifier)). Use this when resolving relative reminder dates."
        if let userName, !userName.isEmpty {
            prompt += " The owner you are chatting with is named \(userName), but there "
                + "is no need to keep repeating their name — use it sparingly."
        }
        return prompt
    }

    nonisolated static func makeRequestBody(
        history: [ChatMessage],
        userName: String? = nil,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        mcpTools: [MCPToolDescriptor]? = nil
    ) throws -> Data {
        try makeRequestBody(
            contents: contents(from: history),
            userName: userName,
            now: now,
            timeZone: timeZone,
            mcpTools: mcpTools
        )
    }

    private nonisolated static func contents(from messages: [ChatMessage]) -> [GeminiContent] {
        messages.map { message in
            if message.role == "assistant", let calls = message.toolCalls {
                return GeminiContent(role: "model", parts: calls.map { call in
                    call.providerContext ?? .object([
                        "functionCall": .object([
                            "name": .string(call.name),
                            "id": .string(call.id),
                            "args": .object(call.arguments),
                        ])
                    ])
                })
            }
            if message.role == "tool", let call = message.toolCalls?.first {
                let response = (try? JSONDecoder().decode(
                    [String: ChatToolValue].self,
                    from: Data(message.content.utf8)
                )) ?? [:]
                return GeminiContent(role: "user", parts: [.object([
                    "functionResponse": .object([
                        "name": .string(call.name),
                        "id": .string(call.id),
                        "response": .object(response),
                    ])
                ])])
            }
            return GeminiContent(
                role: message.role == "assistant" ? "model" : "user",
                parts: [.object(["text": .string(message.content)])]
            )
        }
    }

    nonisolated static func makeRequestBody(
        contents: [GeminiContent],
        userName: String? = nil,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        mcpTools: [MCPToolDescriptor]? = nil
    ) throws -> Data {
        // Resolved per request, like the model name, so Settings changes and
        // newly connected MCP servers apply without restart.
        let mcpDeclarations = (mcpTools ?? MCPToolCatalog.offeredTools())
            .map(GenerateRequest.FunctionDeclaration.init)
        let request = GenerateRequest(
            systemInstruction: GenerateRequest.SystemInstruction(
                parts: [.object([
                    "text": .string(makeSystemPrompt(userName: userName, now: now, timeZone: timeZone))
                ])]
            ),
            contents: contents,
            tools: [
                .search,
                .functions(functionDeclarations + mcpDeclarations),
            ]
        )
        return try JSONEncoder().encode(request)
    }

    /// Decodes one SSE line, including opaque parts required for follow-up
    /// function responses. Blank, non-data, and malformed lines are ignored.
    nonisolated static func decodeChunk(fromLine line: String) -> GeminiChunk? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, let data = payload.data(using: .utf8) else { return nil }
        guard let decoded = try? JSONDecoder().decode(ResponseChunk.self, from: data),
              let candidate = decoded.candidates?.first else {
            return nil
        }

        let parts = candidate.content?.parts ?? []
        let text = parts.compactMap { $0.objectValue?["text"]?.stringValue }.joined()
        let calls = parts.compactMap { part -> ChatToolCall? in
            guard let call = part.objectValue?["functionCall"]?.objectValue,
                  let id = call["id"]?.stringValue,
                  let name = call["name"]?.stringValue else { return nil }
            return ChatToolCall(
                id: id,
                name: name,
                arguments: call["args"]?.objectValue ?? [:],
                providerContext: part
            )
        }
        let sources = (candidate.groundingMetadata?.groundingChunks ?? []).compactMap { chunk in
            chunk.web?.uri.map { GeminiSource(title: chunk.web?.title, uri: $0) }
        }
        return GeminiChunk(text: text, sources: sources, modelParts: parts, toolCalls: calls)
    }

    nonisolated static func formatSources(_ sources: [GeminiSource]) -> String {
        guard !sources.isEmpty else { return "" }
        let links = sources.prefix(maxSourceLinks).map { source in
            var title = source.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if title.isEmpty {
                title = URLComponents(string: source.uri)?.host ?? source.uri
            }
            return "[\(title)](\(source.uri))"
        }
        return "\n\nSources: " + links.joined(separator: " · ")
    }

    func stream(messages: [ChatMessage]) async throws
        -> AsyncThrowingStream<ProviderEvent, Error> {
        guard let key = apiKey() else { throw ChatProviderError.missingAPIKey(.gemini) }

        let requestNow = Date()
        let requestTimeZone = TimeZone.current

        let url = baseURL.appendingPathComponent("v1beta/models/\(model):streamGenerateContent")
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ChatProviderError.invalidModelName
        }
        components.queryItems = [URLQueryItem(name: "alt", value: "sse")]

        guard let requestURL = components.url else { throw ChatProviderError.invalidModelName }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try Self.makeRequestBody(
            contents: Self.contents(from: messages),
            userName: userName,
            now: requestNow,
            timeZone: requestTimeZone
        )

        let (lines, response) = try await transport.lines(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw http.statusCode == 429
                ? ChatProviderError.quotaExceeded
                : ChatProviderError.badStatus(http.statusCode)
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var sources: [GeminiSource] = []
                    for try await line in lines {
                        guard let chunk = Self.decodeChunk(fromLine: line) else { continue }
                        if !chunk.text.isEmpty { continuation.yield(.token(chunk.text)) }
                        chunk.toolCalls.forEach { continuation.yield(.toolCall($0)) }
                        for source in chunk.sources where !sources.contains(where: { $0.uri == source.uri }) {
                            sources.append(source)
                        }
                    }
                    let sourceText = Self.formatSources(sources)
                    if !sourceText.isEmpty { continuation.yield(.token(sourceText)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One chat-capable model from the ListModels endpoint.
    nonisolated struct GeminiModel: Equatable, Sendable {
        let id: String
        let displayName: String
    }

    private nonisolated struct ModelsPage: Decodable {
        struct Model: Decodable {
            let name: String
            let displayName: String?
            let supportedGenerationMethods: [String]?
        }

        let models: [Model]?
        let nextPageToken: String?
    }

    /// Fetches every model the key can use for generateContent, following
    /// pagination. Model ids come back without the "models/" prefix.
    static func listModels(
        baseURL: URL = defaultBaseURL,
        apiKey: String,
        transport: any ChatHTTPTransport = URLSessionTransport(session: .shared)
    ) async throws -> [GeminiModel] {
        var models: [GeminiModel] = []
        var pageToken: String?
        repeat {
            let url = baseURL.appendingPathComponent("v1beta/models")
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw ChatProviderError.invalidModelName
            }
            if let pageToken {
                components.queryItems = [URLQueryItem(name: "pageToken", value: pageToken)]
            }
            guard let requestURL = components.url else { throw ChatProviderError.invalidModelName }
            var request = URLRequest(url: requestURL)
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

            let (data, response) = try await transport.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw http.statusCode == 429
                    ? ChatProviderError.quotaExceeded
                    : ChatProviderError.badStatus(http.statusCode)
            }
            let page = try JSONDecoder().decode(ModelsPage.self, from: data)
            for model in page.models ?? []
            where model.supportedGenerationMethods?.contains("generateContent") == true {
                let id = model.name.hasPrefix("models/")
                    ? String(model.name.dropFirst("models/".count))
                    : model.name
                models.append(GeminiModel(id: id, displayName: model.displayName ?? id))
            }
            pageToken = page.nextPageToken
        } while pageToken != nil
        return models
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
            toolName: call.name,
            toolCalls: [call]
        ))
    }
}
