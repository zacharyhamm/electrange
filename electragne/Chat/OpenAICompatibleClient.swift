import Foundation

nonisolated struct OpenAICompatibleChunk: Equatable {
    struct ToolCall: Equatable {
        var index: Int
        var id: String? = nil
        var name: String? = nil
        var arguments: String? = nil
    }

    var content: String = ""
    var reasoningContent: String = ""
    var toolCalls: [ToolCall] = []
    var done = false
}

/// Minimal OpenAI Chat Completions client. DeepSeek-only fields are gated by
/// the official host so other compatible servers receive the standard shape.
nonisolated struct OpenAICompatibleClient: ChatProviderBackend, ChatClient {
    static let defaultBaseURL = URL(string: ChatConfig.default.openAICompatibleBaseURL)!
    static let defaultModels = ["deepseek-v4-flash", "deepseek-v4-pro"]
    static let systemPrompt = ChatSystemPrompt.make(providerDetails: """
        Markdown formatting is welcome. You can manage Apple Reminders and Notes, +        manage countdown timers, open apps and websites, search approved folders +        by file name, reveal search results in Finder, and search or read Gmail, +        Google Calendar, Slack, and Linear. Use tools only when the owner asks. +        Never claim an action succeeded until its tool reports success.
        """)

    let baseURLOverride: URL?
    let modelOverride: String?
    let thinkingOverride: Bool?
    let transport: any ChatHTTPTransport
    let config: ChatConfig
    let apiKeyOverride: (@Sendable () -> String?)?

    var baseURL: URL? {
        baseURLOverride ?? URL(string: UserPreferences.openAICompatibleBaseURL())
    }
    var model: String { modelOverride ?? UserPreferences.openAICompatibleModel() }
    var thinking: Bool { thinkingOverride ?? UserPreferences.deepSeekThinking() }

    init(
        baseURL: URL? = nil,
        model: String? = nil,
        thinking: Bool? = nil,
        transport: any ChatHTTPTransport = LoggingTransport(),
        config: ChatConfig = .default,
        apiKey: (@Sendable () -> String?)? = nil
    ) {
        baseURLOverride = baseURL
        modelOverride = model
        thinkingOverride = thinking
        self.transport = transport
        self.config = config
        apiKeyOverride = apiKey
    }

    private struct RequestBody: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
            var reasoningContent: String?
            var toolCalls: [ToolCall]?
            var toolCallID: String?

            enum CodingKeys: String, CodingKey {
                case role, content
                case reasoningContent = "reasoning_content"
                case toolCalls = "tool_calls"
                case toolCallID = "tool_call_id"
            }
        }

        struct ToolCall: Encodable {
            struct Function: Encodable { let name: String; let arguments: String }
            let id: String
            let type = "function"
            let function: Function
        }

        struct Tool: Encodable {
            struct Function: Encodable {
                let name: String
                let description: String
                let parameters: ChatToolValue
            }
            let type = "function"
            let function: Function
        }

        struct Thinking: Encodable { let type: String }

        let model: String
        let messages: [Message]
        let tools: [Tool]
        let stream = true
        let thinking: Thinking?
    }

    private struct ResponseChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                struct ToolCall: Decodable {
                    struct Function: Decodable {
                        let name: String?
                        let arguments: String?
                    }
                    let index: Int
                    let id: String?
                    let function: Function?
                }
                let content: String?
                let reasoningContent: String?
                let toolCalls: [ToolCall]?

                enum CodingKeys: String, CodingKey {
                    case content
                    case reasoningContent = "reasoning_content"
                    case toolCalls = "tool_calls"
                }
            }
            let delta: Delta
        }
        let choices: [Choice]
    }

    static func isOfficialDeepSeek(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "api.deepseek.com"
    }

    static func makeRequestBody(
        baseURL: URL,
        model: String,
        thinking: Bool,
        history: [ChatMessage],
        webSearchAvailable: Bool = false,
        mcpTools: [MCPToolDescriptor]? = nil
    ) throws -> Data {
        let definitions = ChatToolRegistry.definitions(for: .openAICompatible).filter {
            $0.family != .webSearch || webSearchAvailable
        }
        let tools = definitions.map { definition in
            RequestBody.Tool(function: .init(
                name: definition.name,
                description: definition.description,
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object(definition.properties.mapValues { parameter in
                        .object([
                            "type": .string(parameter.type.rawValue),
                            "description": .string(parameter.description),
                        ])
                    }),
                    "required": .array(definition.required.map(ChatToolValue.string)),
                ])
            ))
        } + (mcpTools ?? MCPToolCatalog.offeredTools()).map { descriptor in
            RequestBody.Tool(function: .init(
                name: descriptor.namespacedName,
                description: descriptor.description,
                parameters: descriptor.inputSchema
            ))
        }
        let historyMessages = try history.map(message(from:))
        let messages = [RequestBody.Message(role: "system", content: systemPrompt)]
            + historyMessages
        return try JSONEncoder().encode(RequestBody(
            model: model,
            messages: messages,
            tools: tools,
            thinking: isOfficialDeepSeek(baseURL)
                ? .init(type: thinking ? "enabled" : "disabled")
                : nil
        ))
    }

    private static func message(from message: ChatMessage) throws -> RequestBody.Message {
        if message.role == "assistant", let calls = message.toolCalls {
            let reasoning = calls.first?.providerContext?.objectValue?["reasoning_content"]?.stringValue
            return RequestBody.Message(
                role: message.role,
                content: message.content,
                reasoningContent: reasoning,
                toolCalls: try calls.map { call in
                    let data = try JSONEncoder().encode(call.arguments)
                    return .init(
                        id: call.id,
                        function: .init(name: call.name, arguments: String(decoding: data, as: UTF8.self))
                    )
                }
            )
        }
        return RequestBody.Message(
            role: message.role,
            content: message.content,
            toolCallID: message.toolCallID ?? message.toolCalls?.first?.id
        )
    }

    static func decodeChunk(fromLine line: String) -> OpenAICompatibleChunk? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return OpenAICompatibleChunk(done: true) }
        guard let data = payload.data(using: .utf8),
              let delta = try? JSONDecoder().decode(ResponseChunk.self, from: data).choices.first?.delta
        else { return nil }
        return OpenAICompatibleChunk(
            content: delta.content ?? "",
            reasoningContent: delta.reasoningContent ?? "",
            toolCalls: (delta.toolCalls ?? []).map {
                .init(index: $0.index, id: $0.id, name: $0.function?.name, arguments: $0.function?.arguments)
            }
        )
    }

    func stream(messages: [ChatMessage]) async throws
        -> AsyncThrowingStream<ProviderEvent, Error> {
        guard let baseURL, baseURL.scheme != nil, baseURL.host != nil else {
            throw ChatProviderError.invalidEndpoint
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatProviderError.invalidModelName
        }
        guard let key = resolvedAPIKey(baseURL: baseURL) else {
            throw ChatProviderError.missingAPIKey(.openAICompatible)
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try Self.makeRequestBody(
            baseURL: baseURL,
            model: model,
            thinking: thinking,
            history: messages,
            webSearchAvailable: UserPreferences.searxngEndpoint() != nil
        )

        let (lines, response) = try await transport.lines(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ChatProviderError.badStatus(http.statusCode)
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var reasoning = ""
                    var thinkingAloud = false
                    var fragments: [Int: OpenAICompatibleChunk.ToolCall] = [:]
                    for try await line in lines {
                        guard let chunk = Self.decodeChunk(fromLine: line), !chunk.done else { continue }
                        if !chunk.content.isEmpty {
                            thinkingAloud = false
                            continuation.yield(.token(chunk.content))
                        }
                        if !chunk.reasoningContent.isEmpty, !thinkingAloud {
                            thinkingAloud = true
                            continuation.yield(.status("Thinking…"))
                        }
                        reasoning += chunk.reasoningContent
                        for fragment in chunk.toolCalls {
                            var call = fragments[fragment.index] ?? .init(index: fragment.index)
                            if let id = fragment.id { call.id = id }
                            call.name = (call.name ?? "") + (fragment.name ?? "")
                            call.arguments = (call.arguments ?? "") + (fragment.arguments ?? "")
                            fragments[fragment.index] = call
                        }
                    }
                    for fragment in fragments.values.sorted(by: { $0.index < $1.index }) {
                        guard let id = fragment.id, let name = fragment.name,
                              let data = fragment.arguments?.data(using: .utf8),
                              let arguments = try? JSONDecoder().decode([String: ChatToolValue].self, from: data)
                        else { throw ChatProviderError.invalidToolArguments }
                        continuation.yield(.toolCall(ChatToolCall(
                            id: id,
                            name: name,
                            arguments: arguments,
                            providerContext: .object(["reasoning_content": .string(reasoning)])
                        )))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func resolvedAPIKey(baseURL: URL) -> String? {
        if let apiKeyOverride { return apiKeyOverride() }
        return Self.resolveAPIKey(
            baseURL: baseURL,
            keychainKey: ChatAPIKeyStore.key(for: .openAICompatible)
        )
    }

    static func resolveAPIKey(
        baseURL: URL,
        keychainKey: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let name = Self.isOfficialDeepSeek(baseURL) ? "DEEPSEEK_API_KEY" : "OPENAI_API_KEY"
        return [keychainKey, environment[name]].compactMap {
            $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }.first
    }

    struct Model: Equatable, Sendable { let id: String }
    private struct ModelsResponse: Decodable { struct Model: Decodable { let id: String }; let data: [Model] }

    static func listModels(
        baseURL: URL,
        apiKey: String,
        transport: any ChatHTTPTransport = LoggingTransport()
    ) async throws -> [Model] {
        guard baseURL.scheme != nil, baseURL.host != nil else { throw ChatProviderError.invalidEndpoint }
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ChatProviderError.badStatus(http.statusCode)
        }
        return try JSONDecoder().decode(ModelsResponse.self, from: data).data.map { Model(id: $0.id) }
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
            toolCallID: call.id
        ))
    }
}

private extension String {
    nonisolated var nilIfEmpty: String? { isEmpty ? nil : self }
}
