import Foundation

enum GeminiError: Error, Equatable {
    case badStatus(Int)
    case quotaExceeded
    case missingAPIKey
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
}

/// Streaming client for the Gemini API with Google Search grounding. Search
/// runs server-side, so unlike the Ollama client there is no tool loop —
/// grounded answers stream back directly, with sources in metadata.
struct GeminiClient: ChatClient {
    nonisolated static let defaultBaseURL = URL(string: "https://generativelanguage.googleapis.com")!
    nonisolated static let defaultModel = "gemini-3.1-flash-lite"
    nonisolated static let systemPrompt = """
        You are a highly intelligent sheep living as a desktop pet, chatting \
        with your owner. Respond as if chatting: keep replies short and \
        chat-sized — a sentence or two, or a brief list when that is clearer. \
        Markdown formatting is welcome: bold, italics, [title](url) links, \
        and bullet lists using "-"; avoid headings, tables, and code blocks. \
        You have Google Search available: use it when asked to search, or \
        for current events and facts you are not sure about.
        """
    /// Cap on grounding source links appended after a searched answer.
    nonisolated static let maxSourceLinks = 3

    var baseURL = defaultBaseURL
    var model = defaultModel
    var userName: String? = OllamaClient.detectedUserName()

    private nonisolated struct GenerateRequest: Encodable {
        struct Part: Encodable {
            let text: String
        }

        struct Content: Encodable {
            let role: String
            let parts: [Part]
        }

        struct SystemInstruction: Encodable {
            let parts: [Part]
        }

        struct Tool: Encodable {
            struct GoogleSearch: Encodable {}

            let googleSearch = GoogleSearch()

            enum CodingKeys: String, CodingKey {
                case googleSearch = "google_search"
            }
        }

        let systemInstruction: SystemInstruction
        let contents: [Content]
        let tools: [Tool]

        enum CodingKeys: String, CodingKey {
            case systemInstruction = "system_instruction"
            case contents
            case tools
        }
    }

    private nonisolated struct ResponseChunk: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable {
                    let text: String?
                }

                let parts: [Part]?
            }

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

            let content: Content?
            let groundingMetadata: GroundingMetadata?
        }

        let candidates: [Candidate]?
    }

    nonisolated static func makeSystemPrompt(userName: String?) -> String {
        guard let userName, !userName.isEmpty else { return systemPrompt }
        return systemPrompt
            + " The owner you are chatting with is named \(userName), but there "
            + "is no need to keep repeating their name — use it sparingly."
    }

    nonisolated static func makeRequestBody(
        history: [OllamaMessage],
        userName: String? = nil
    ) throws -> Data {
        let request = GenerateRequest(
            systemInstruction: GenerateRequest.SystemInstruction(
                parts: [GenerateRequest.Part(text: makeSystemPrompt(userName: userName))]
            ),
            contents: history.map { turn in
                GenerateRequest.Content(
                    role: turn.role == "assistant" ? "model" : "user",
                    parts: [GenerateRequest.Part(text: turn.content)]
                )
            },
            tools: [GenerateRequest.Tool()]
        )
        return try JSONEncoder().encode(request)
    }

    /// Decodes one SSE line ("data: {json}"). Returns nil for anything else
    /// (blank keep-alives, event names, malformed payloads).
    nonisolated static func decodeChunk(fromLine line: String) -> GeminiChunk? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, let data = payload.data(using: .utf8) else { return nil }
        guard let decoded = try? JSONDecoder().decode(ResponseChunk.self, from: data),
              let candidate = decoded.candidates?.first else {
            return nil
        }

        let text = (candidate.content?.parts ?? []).compactMap(\.text).joined()
        let sources = (candidate.groundingMetadata?.groundingChunks ?? []).compactMap { chunk in
            chunk.web?.uri.map { GeminiSource(title: chunk.web?.title, uri: $0) }
        }
        return GeminiChunk(text: text, sources: sources)
    }

    /// Formats grounding sources as short markdown links so the long
    /// grounding-redirect URLs don't fill the bubble.
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

    /// The env var works for terminal launches; the key file works when the
    /// app is launched from Finder (GUI apps don't inherit shell env).
    nonisolated static func loadAPIKey(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = OllamaWebSearch.realHomeDirectory()
    ) -> String? {
        if let key = environment["GEMINI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            return key
        }
        let keyFile = URL(fileURLWithPath: homeDirectory).appendingPathComponent(".gemini.api.key")
        if let key = try? String(contentsOf: keyFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            return key
        }
        return nil
    }

    func streamChat(
        history: [OllamaMessage],
        onStatus: (String) -> Void,
        onToken: (String) -> Void
    ) async throws {
        guard let key = Self.loadAPIKey() else { throw GeminiError.missingAPIKey }

        let url = baseURL.appendingPathComponent("v1beta/models/\(model):streamGenerateContent")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "alt", value: "sse")]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try Self.makeRequestBody(history: history, userName: userName)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw http.statusCode == 429
                ? GeminiError.quotaExceeded
                : GeminiError.badStatus(http.statusCode)
        }

        var sources: [GeminiSource] = []
        for try await line in bytes.lines {
            guard let chunk = Self.decodeChunk(fromLine: line) else { continue }
            if !chunk.text.isEmpty {
                onToken(chunk.text)
            }
            for source in chunk.sources where !sources.contains(where: { $0.uri == source.uri }) {
                sources.append(source)
            }
        }

        // Grounding sources arrive as metadata, not text; append them as
        // markdown links so the bubble renders short clickable titles.
        let sourcesText = Self.formatSources(sources)
        if !sourcesText.isEmpty {
            onToken(sourcesText)
        }
    }
}
