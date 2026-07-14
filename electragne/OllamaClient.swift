import Foundation

enum OllamaError: Error, Equatable {
    case badStatus(Int)
}

/// One decoded line of the NDJSON stream from /api/chat.
struct OllamaChatChunk: Equatable {
    let content: String
    let done: Bool
}

/// One turn of the conversation sent to /api/chat.
struct OllamaMessage: Equatable, Encodable {
    let role: String
    let content: String
}

/// Minimal streaming client for a local Ollama server.
struct OllamaClient {
    static let defaultBaseURL = URL(string: "http://localhost:11434")!
    static let defaultModel = "gemma4:latest"
    static let systemPrompt = """
        You are a small desktop pet chatting with your owner. Respond as if \
        chatting: short and succinct, a sentence or two, no long paragraphs. \
        Plain text only — no markdown, no bullet lists, no headings, no code \
        formatting.
        """
    /// Ollama defaults num_ctx to a few thousand tokens; raise it so long
    /// conversations keep their earlier turns in context.
    static let contextWindowTokens = 32768

    var baseURL = defaultBaseURL
    var model = defaultModel

    private struct ChatRequest: Encodable {
        struct Options: Encodable {
            let numCtx: Int

            enum CodingKeys: String, CodingKey {
                case numCtx = "num_ctx"
            }
        }

        let model: String
        let messages: [OllamaMessage]
        let stream: Bool
        let options: Options
    }

    private struct ChatResponseLine: Decodable {
        struct Message: Decodable {
            let content: String?
        }

        let message: Message?
        let done: Bool?
    }

    nonisolated static func makeRequestBody(model: String, history: [OllamaMessage]) throws -> Data {
        let request = ChatRequest(
            model: model,
            messages: [OllamaMessage(role: "system", content: systemPrompt)] + history,
            stream: true,
            options: ChatRequest.Options(numCtx: contextWindowTokens)
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
            done: decoded.done ?? false
        )
    }

    func streamChat(history: [OllamaMessage], onToken: (String) -> Void) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.makeRequestBody(model: model, history: history)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw OllamaError.badStatus(http.statusCode)
        }

        for try await line in bytes.lines {
            guard let chunk = Self.decodeChunk(fromLine: line) else { continue }
            if !chunk.content.isEmpty {
                onToken(chunk.content)
            }
            if chunk.done { break }
        }
    }
}
