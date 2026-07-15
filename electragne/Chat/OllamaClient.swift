import Foundation

nonisolated enum OllamaError: Error, Equatable {
    case badStatus(Int)
    case missingAPIKey
}

/// One decoded line of the NDJSON stream from /api/chat.
nonisolated struct OllamaChatChunk: Equatable {
    var content: String
    var done: Bool
    var toolCalls: [OllamaToolCall] = []
}

nonisolated struct OllamaToolCall: Equatable, Codable {
    struct Function: Equatable, Codable {
        var name: String
        var arguments: [String: ChatToolValue]
    }

    var function: Function
}

/// One turn of the conversation sent to /api/chat.
nonisolated struct OllamaMessage: Equatable, Codable {
    var role: String
    var content: String
    var toolName: String? = nil
    var toolCalls: [OllamaToolCall]? = nil

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolName = "tool_name"
        case toolCalls = "tool_calls"
    }
}

/// Client for Ollama's hosted web search API (requires an ollama.com API key).
nonisolated struct OllamaWebSearch {
    static let endpoint = URL(string: "https://ollama.com/api/web_search")!
    static let maxResults = 4
    static let maxResultCharacters = 1500

    private struct SearchRequest: Encodable {
        let query: String
        let maxResults: Int

        enum CodingKeys: String, CodingKey {
            case query
            case maxResults = "max_results"
        }
    }

    private struct SearchResponse: Decodable {
        struct Result: Decodable {
            let title: String?
            let url: String?
            let content: String?
        }

        let results: [Result]
    }

    /// The env var works for terminal launches; the key file works when the
    /// app is launched from Finder (GUI apps don't inherit shell env).
    nonisolated static func loadAPIKey(
        keychainKey: String? = ChatAPIKeyStore.key(for: .ollama),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = realHomeDirectory()
    ) -> String? {
        if let key = keychainKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            return key
        }
        if let key = environment["OLLAMA_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            return key
        }
        let keyFile = URL(fileURLWithPath: homeDirectory).appendingPathComponent(".ollama/api_key")
        if let key = try? String(contentsOf: keyFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            return key
        }
        return nil
    }

    /// The sandbox reports the container as home; the key file lives in the
    /// user's real home directory.
    nonisolated static func realHomeDirectory() -> String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    func resultsText(query: String) async throws -> String {
        guard let key = Self.loadAPIKey() else { throw OllamaError.missingAPIKey }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(
            SearchRequest(query: query, maxResults: Self.maxResults)
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw OllamaError.badStatus(http.statusCode)
        }
        return Self.formatResults(from: data)
    }

    nonisolated static func formatResults(from data: Data) -> String {
        guard let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data),
              !decoded.results.isEmpty else {
            return "No results found."
        }
        return decoded.results.enumerated().map { index, result in
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
struct OllamaClient: ChatClient {
    nonisolated static let defaultBaseURL = URL(string: "http://localhost:11434")!
    nonisolated static let defaultModel = "gemma4:latest"
    nonisolated static let systemPrompt = """
        You are Baaz, a highly intelligent sheep living as a desktop pet, \
        chatting with your owner. Respond as if chatting: keep replies short and \
        chat-sized — a sentence or two, or a brief list when that is clearer. \
        Markdown formatting is welcome: bold, italics, [title](url) links, \
        and bullet lists using "-"; avoid headings, tables, and code blocks. \
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
        """

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
    nonisolated static let contextWindowTokens = 32768
    /// Bound on search → answer round-trips per user message.
    nonisolated static let maxToolRounds = 3

    var baseURL = defaultBaseURL
    var model = defaultModel
    var webSearch = OllamaWebSearch()
    /// Resolved per request so Settings changes apply immediately.
    var userName: String? { UserPreferences.resolvedUserName() }

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
        let messages: [OllamaMessage]
        let stream: Bool
        let options: Options
        let tools: [ToolDefinition]
    }


    private nonisolated struct ChatResponseLine: Decodable {
        struct Message: Decodable {
            let content: String?
            let toolCalls: [OllamaToolCall]?

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
        history: [OllamaMessage],
        userName: String? = nil
    ) throws -> Data {
        let request = ChatRequest(
            model: model,
            messages: [OllamaMessage(role: "system", content: makeSystemPrompt(userName: userName))]
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

    /// Streams the model's answer, executing web_search tool calls as they
    /// arrive and feeding results back until the model produces a final reply.
    func streamChat(
        history: [OllamaMessage],
        onStatus: (String) -> Void = { _ in },
        onToolCall: (ChatToolCall) async -> ChatToolResult = { _ in
            .error("This chat provider does not support that tool.")
        },
        onToken: (String) -> Void
    ) async throws {
        var messages = history

        for round in 0...Self.maxToolRounds {
            var toolCalls: [OllamaToolCall] = []
            var roundContent = ""

            var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Self.makeRequestBody(
                model: model,
                history: messages,
                userName: userName
            )

            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw OllamaError.badStatus(http.statusCode)
            }

            for try await line in bytes.lines {
                guard let chunk = Self.decodeChunk(fromLine: line) else { continue }
                if !chunk.content.isEmpty {
                    roundContent += chunk.content
                    onToken(chunk.content)
                }
                toolCalls.append(contentsOf: chunk.toolCalls)
                if chunk.done { break }
            }

            guard !toolCalls.isEmpty, round < Self.maxToolRounds else { return }

            messages.append(
                OllamaMessage(role: "assistant", content: roundContent, toolCalls: toolCalls)
            )
            for call in toolCalls {
                let resultText: String
                if call.function.name == "web_search" {
                    let query = call.function.arguments["query"]?.stringValue ?? ""
                    onStatus("Searching the web: \(query)")
                    do {
                        resultText = try await webSearch.resultsText(query: query)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch OllamaError.missingAPIKey {
                        throw OllamaError.missingAPIKey
                    } catch let error as URLError where error.code == .cancelled {
                        throw CancellationError()
                    } catch {
                        // Let the model explain the failure instead of aborting.
                        resultText = "Web search failed: \(error.localizedDescription)"
                    }
                } else {
                    onStatus(ChatToolRegistry.definition(named: call.function.name)?.initialStatus
                        ?? "Confirm action…")
                    let call = ChatToolCall(
                        id: UUID().uuidString,
                        name: call.function.name,
                        arguments: call.function.arguments
                    )
                    let result = await onToolCall(call)
                    let data = try JSONEncoder().encode(result.response)
                    resultText = String(decoding: data, as: UTF8.self)
                }
                messages.append(
                    OllamaMessage(role: "tool", content: resultText, toolName: call.function.name)
                )
            }
            onStatus("Thinking…")
        }
    }
}
