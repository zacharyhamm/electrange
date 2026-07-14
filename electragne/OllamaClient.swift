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

/// A tool invocation requested by the model. Only web_search exists, so the
/// arguments are modeled concretely rather than as arbitrary JSON.
nonisolated struct OllamaToolCall: Equatable, Codable {
    struct Function: Equatable, Codable {
        struct Arguments: Equatable, Codable {
            var query: String?
        }

        var name: String
        var arguments: Arguments
    }

    var function: Function
}

/// One turn of the conversation sent to /api/chat.
nonisolated struct OllamaMessage: Equatable, Encodable {
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
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = realHomeDirectory()
    ) -> String? {
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
struct OllamaClient {
    nonisolated static let defaultBaseURL = URL(string: "http://localhost:11434")!
    nonisolated static let defaultModel = "gemma4:latest"
    nonisolated static let systemPrompt = """
        You are a highly intelligent sheep living as a desktop pet, chatting \
        with your owner. Respond as if chatting: short and succinct, a \
        sentence or two, no long paragraphs. Plain text only — no markdown, \
        no bullet lists, no headings, no code formatting. You have a \
        web_search tool: use it when asked to search, or for current events \
        and facts you are not sure about. When you answer from web search \
        results, always share the links (plain URLs) to the sources you used.
        """

    /// The full system prompt, personalized with the owner's name when known.
    nonisolated static func makeSystemPrompt(userName: String?) -> String {
        guard let userName, !userName.isEmpty else { return systemPrompt }
        return systemPrompt + " The owner you are chatting with is named \(userName)."
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
    var userName: String? = detectedUserName()

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
        }

        let model: String
        let messages: [OllamaMessage]
        let stream: Bool
        let options: Options
        let tools: [ToolDefinition]
    }

    private nonisolated static let webSearchTool = ChatRequest.ToolDefinition(
        function: ChatRequest.ToolDefinition.Function(
            name: "web_search",
            description: "Search the web and return the top results.",
            parameters: ChatRequest.ToolDefinition.Function.Parameters(
                properties: [
                    "query": ChatRequest.ToolDefinition.Function.Parameters.Property(
                        type: "string",
                        description: "The search query"
                    )
                ],
                required: ["query"]
            )
        )
    )

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
            tools: [webSearchTool]
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
                let query = call.function.arguments.query ?? ""
                onStatus("Searching the web: \(query)")
                let resultText: String
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
                messages.append(
                    OllamaMessage(role: "tool", content: resultText, toolName: call.function.name)
                )
            }
            onStatus("Thinking…")
        }
    }
}
