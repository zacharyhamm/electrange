import Foundation

enum GeminiError: Error, Equatable {
    case badStatus(Int)
    case quotaExceeded
    case missingAPIKey
    case toolRoundLimit
    case invalidModelName
}

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
struct GeminiClient: ChatClient {
    nonisolated static let defaultBaseURL = URL(string: "https://generativelanguage.googleapis.com")!
    nonisolated static let defaultModel = ChatConfig.default.geminiModel
    nonisolated static let systemPrompt = """
        You are Baaz, a highly intelligent sheep living as a desktop pet, \
        chatting with your owner. Respond as if chatting: keep replies short and \
        chat-sized — a sentence or two, or a brief list when that is clearer. \
        Markdown formatting is welcome: bold, italics, [title](url) links, \
        bullet lists using "-", and inline math using $...$ or \\(...\\); \
        avoid headings, tables, code blocks, and display-math delimiters. \
        You have Google Search available: use it when asked to search, or \
        for current events and facts you are not sure about. You can manage \
        Apple Reminders and Notes, manage countdown timers, open apps and websites, \
        search approved folders by file name, reveal search results in Finder, and search or read \
        Gmail and Google Calendar from connected Google accounts. Gmail draft creation and sending \
        are separate actions that each require owner confirmation; Calendar event creation also \
        requires owner confirmation. Use these tools only \
        when the owner asks. Never claim an action succeeded until its tool \
        reports success.
        """
    nonisolated static let maxSourceLinks = 3
    nonisolated static let maxToolRounds = ChatConfig.default.maxToolRounds

    var baseURL: URL
    var model: String
    let transport: any ChatHTTPTransport
    let config: ChatConfig
    let apiKey: @Sendable () -> String?
    var userName: String? { UserPreferences.resolvedUserName() }

    init(
        baseURL: URL = defaultBaseURL,
        model: String? = nil,
        transport: any ChatHTTPTransport = URLSessionTransport(session: .shared),
        config: ChatConfig = .default,
        apiKey: @escaping @Sendable () -> String? = { ChatAPIKeyStore.load(for: .gemini) }
    ) {
        self.baseURL = baseURL
        self.model = model ?? config.geminiModel
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
            struct Parameters: Encodable {
                struct Property: Encodable {
                    let type: String
                    let description: String
                }

                let type = "OBJECT"
                let properties: [String: Property]
                let required: [String]
            }

            let name: String
            let description: String
            let parameters: Parameters

            init(_ definition: ChatToolDefinition) {
                name = definition.name
                description = definition.description
                parameters = Parameters(
                    properties: definition.properties.mapValues { parameter in
                        Parameters.Property(
                            type: parameter.type.rawValue.uppercased(),
                            description: parameter.description
                        )
                    },
                    required: definition.required
                )
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
        history: [OllamaMessage],
        userName: String? = nil,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) throws -> Data {
        try makeRequestBody(
            contents: history.map { turn in
                GeminiContent(
                    role: turn.role == "assistant" ? "model" : "user",
                    parts: [.object(["text": .string(turn.content)])]
                )
            },
            userName: userName,
            now: now,
            timeZone: timeZone
        )
    }

    nonisolated static func makeRequestBody(
        contents: [GeminiContent],
        userName: String? = nil,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) throws -> Data {
        let request = GenerateRequest(
            systemInstruction: GenerateRequest.SystemInstruction(
                parts: [.object([
                    "text": .string(makeSystemPrompt(userName: userName, now: now, timeZone: timeZone))
                ])]
            ),
            contents: contents,
            tools: [
                .search,
                .functions(functionDeclarations),
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
                arguments: call["args"]?.objectValue ?? [:]
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

    func streamChat(
        history: [OllamaMessage],
        onStatus: (String) -> Void,
        onToolCall: (ChatToolCall) async -> ChatToolResult,
        onToken: (String) -> Void
    ) async throws {
        guard let key = apiKey() else { throw GeminiError.missingAPIKey }

        var contents = history.map { turn in
            GeminiContent(
                role: turn.role == "assistant" ? "model" : "user",
                parts: [.object(["text": .string(turn.content)])]
            )
        }
        var sources: [GeminiSource] = []
        let requestNow = Date()
        let requestTimeZone = TimeZone.current

        for round in 0...config.maxToolRounds {
            let url = baseURL.appendingPathComponent("v1beta/models/\(model):streamGenerateContent")
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw GeminiError.invalidModelName
            }
            components.queryItems = [URLQueryItem(name: "alt", value: "sse")]

            guard let requestURL = components.url else { throw GeminiError.invalidModelName }
            var request = URLRequest(url: requestURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            request.httpBody = try Self.makeRequestBody(
                contents: contents,
                userName: userName,
                now: requestNow,
                timeZone: requestTimeZone
            )

            let (lines, response) = try await transport.lines(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw http.statusCode == 429
                    ? GeminiError.quotaExceeded
                    : GeminiError.badStatus(http.statusCode)
            }

            var modelParts: [ChatToolValue] = []
            var toolCalls: [ChatToolCall] = []
            for try await line in lines {
                guard let chunk = Self.decodeChunk(fromLine: line) else { continue }
                modelParts.append(contentsOf: chunk.modelParts)
                if !chunk.text.isEmpty { onToken(chunk.text) }
                for call in chunk.toolCalls where !toolCalls.contains(where: { $0.id == call.id }) {
                    toolCalls.append(call)
                }
                for source in chunk.sources where !sources.contains(where: { $0.uri == source.uri }) {
                    sources.append(source)
                }
            }

            guard !toolCalls.isEmpty else {
                let sourcesText = Self.formatSources(sources)
                if !sourcesText.isEmpty { onToken(sourcesText) }
                return
            }
            guard round < config.maxToolRounds else { throw GeminiError.toolRoundLimit }

            contents.append(GeminiContent(role: "model", parts: modelParts))
            var responseParts: [ChatToolValue] = []
            for call in toolCalls {
                onStatus(ChatToolRegistry.definition(named: call.name)?.initialStatus
                    ?? "Confirm action…")
                let result = await onToolCall(call)
                responseParts.append(.object([
                    "functionResponse": .object([
                        "name": .string(call.name),
                        "id": .string(call.id),
                        "response": .object(result.response),
                    ])
                ]))
            }
            contents.append(GeminiContent(role: "user", parts: responseParts))
            onStatus("Thinking…")
        }
    }
}
