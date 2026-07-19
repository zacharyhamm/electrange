import Foundation

/// One decoded line of the NDJSON stream from /api/chat.
nonisolated struct OllamaChatChunk: Equatable {
    var content: String
    var done: Bool
    var toolCalls: [ChatToolCall] = []
}

/// Client for a self-hosted SearXNG instance's JSON search API.
nonisolated struct SearXNGSearch {
    static let maxResults = 4
    static let maxResultCharacters = 1500
    let transport: any ChatHTTPTransport

    init(transport: any ChatHTTPTransport = LoggingTransport()) {
        self.transport = transport
    }

    private struct SearchResponse: Decodable {
        struct Result: Decodable {
            let title: String?
            let url: String?
            let content: String?
        }

        let results: [Result]
    }

    /// GET {endpoint}/search?q={query}&format=json for the configured endpoint.
    nonisolated static func searchURL(endpoint: String, query: String) -> URL? {
        guard var components = URLComponents(string: endpoint) else { return nil }
        components.path = components.path.hasSuffix("/search")
            ? components.path : components.path + "/search"
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
        ]
        return components.url.flatMap { $0.scheme == nil ? nil : $0 }
    }

    func resultsText(query: String) async throws -> String {
        guard let endpoint = UserPreferences.searxngEndpoint(),
              let url = Self.searchURL(endpoint: endpoint, query: query) else {
            throw ChatProviderError.invalidEndpoint
        }

        let (data, response) = try await transport.data(for: URLRequest(url: url))
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ChatProviderError.badStatus(http.statusCode)
        }
        return Self.formatResults(from: data)
    }

    nonisolated static func formatResults(from data: Data) -> String {
        guard let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data),
              !decoded.results.isEmpty else {
            return "No results found."
        }
        return decoded.results.prefix(maxResults).enumerated().map { index, result in
            let content = String((result.content ?? "").prefix(maxResultCharacters))
            return """
                Result \(index + 1): \(result.title ?? "Untitled")
                URL: \(result.url ?? "unknown")
                \(content)
                """
        }.joined(separator: "\n\n")
    }
}

/// Minimal streaming client for a local Ollama server.
nonisolated struct OllamaClient: ChatProviderBackend, ChatClient {
    nonisolated static let defaultBaseURL = URL(string: "http://localhost:11434")!
    nonisolated static let defaultModel = ChatConfig.default.ollamaModel
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
        (markdown [title](url) links are fine). Use timer tools only when the \
        owner asks, and never claim an action succeeded until the tool reports success.
        """)

    /// The full system prompt, personalized with the owner's name when known.
    nonisolated static func makeSystemPrompt(userName: String?) -> String {
        guard let userName, !userName.isEmpty else { return systemPrompt }
        return systemPrompt
            + " The owner you are chatting with is named \(userName), but there "
            + "is no need to keep repeating their name — use it sparingly."
    }

    /// The owner's name from macOS account info, for the system prompt.
    nonisolated static func detectedUserName() -> String? {
        let fullName = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        if !fullName.isEmpty { return fullName }
        let shortName = NSUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return shortName.isEmpty ? nil : shortName
    }
    /// Ollama defaults num_ctx to a few thousand tokens; raise it so long
    /// conversations keep their earlier turns in context.
    nonisolated static let contextWindowTokens = ChatConfig.default.contextWindowTokens
    /// Bound on search → answer round-trips per user message.
    nonisolated static let maxToolRounds = ChatConfig.default.maxToolRounds

    var baseURL: URL
    let modelOverride: String?
    let transport: any ChatHTTPTransport
    let config: ChatConfig
    /// Resolved per request so model-picker/Settings changes apply immediately.
    var model: String { modelOverride ?? UserPreferences.ollamaModel() }
    /// Resolved per request so Settings changes apply immediately.
    var userName: String? { UserPreferences.resolvedUserName() }

    init(
        baseURL: URL = defaultBaseURL,
        model: String? = nil,
        transport: any ChatHTTPTransport = LoggingTransport(),
        config: ChatConfig = .default
    ) {
        self.baseURL = baseURL
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
        baseURL: URL = defaultBaseURL,
        transport: any ChatHTTPTransport = LoggingTransport()
    ) async throws -> [String] {
        let request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        let (data, response) = try await transport.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ChatProviderError.badStatus(http.statusCode)
        }
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
        contextWindowTokens: Int = ChatConfig.default.contextWindowTokens
    ) throws -> Data {
        let request = ChatRequest(
            model: model,
            messages: [ChatMessage(role: "system", content: makeSystemPrompt(userName: userName))]
                + history,
            stream: true,
            options: ChatRequest.Options(numCtx: contextWindowTokens),
            tools: ChatToolRegistry.definitions(for: .ollama).map(ChatRequest.ToolDefinition.init)
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
            contextWindowTokens: config.contextWindowTokens
        )

        let (lines, response) = try await transport.lines(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ChatProviderError.badStatus(http.statusCode)
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in lines {
                        guard let chunk = Self.decodeChunk(fromLine: line) else { continue }
                        if !chunk.content.isEmpty { continuation.yield(.token(chunk.content)) }
                        chunk.toolCalls.forEach { continuation.yield(.toolCall($0)) }
                        if chunk.done { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
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
