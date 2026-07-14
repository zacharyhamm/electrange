import Foundation
import Testing
@testable import electragne

struct OllamaClientTests {
    @Test func decodesStreamingContentLine() {
        let line = #"{"model":"gemma4:latest","created_at":"2026-07-14T00:00:00Z","message":{"role":"assistant","content":"Hel"},"done":false}"#

        let chunk = OllamaClient.decodeChunk(fromLine: line)

        #expect(chunk == OllamaChatChunk(content: "Hel", done: false))
    }

    @Test func decodesFinalDoneLineWithoutContent() {
        let line = #"{"model":"gemma4:latest","created_at":"2026-07-14T00:00:00Z","done":true,"total_duration":123456,"eval_count":42}"#

        let chunk = OllamaClient.decodeChunk(fromLine: line)

        #expect(chunk == OllamaChatChunk(content: "", done: true))
    }

    @Test func rejectsBlankAndMalformedLines() {
        #expect(OllamaClient.decodeChunk(fromLine: "") == nil)
        #expect(OllamaClient.decodeChunk(fromLine: "   ") == nil)
        #expect(OllamaClient.decodeChunk(fromLine: "not json") == nil)
        #expect(OllamaClient.decodeChunk(fromLine: "[1, 2, 3]") == nil)
    }

    @Test func requestBodyContainsModelMessageAndStreamFlag() throws {
        let body = try OllamaClient.makeRequestBody(
            model: "gemma4:latest",
            history: [OllamaMessage(role: "user", content: "Hello, sheep!")]
        )

        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(json["model"] as? String == "gemma4:latest")
        #expect(json["stream"] as? Bool == true)

        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == OllamaClient.systemPrompt)
        #expect(messages[1]["role"] as? String == "user")
        #expect(messages[1]["content"] as? String == "Hello, sheep!")
    }

    @Test func requestBodyConfiguresLargeContextWindow() throws {
        let body = try OllamaClient.makeRequestBody(model: "gemma4:latest", history: [])

        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let options = try #require(json["options"] as? [String: Any])
        #expect(options["num_ctx"] as? Int == OllamaClient.contextWindowTokens)
        #expect(OllamaClient.contextWindowTokens >= 32768)
    }

    @Test func requestBodyPreservesConversationHistoryOrder() throws {
        let history = [
            OllamaMessage(role: "user", content: "What's your name?"),
            OllamaMessage(role: "assistant", content: "I'm a sheep!"),
            OllamaMessage(role: "user", content: "What did I just ask you?"),
        ]
        let body = try OllamaClient.makeRequestBody(model: "gemma4:latest", history: history)

        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 4)
        #expect(messages[0]["role"] as? String == "system")
        for (index, turn) in history.enumerated() {
            #expect(messages[index + 1]["role"] as? String == turn.role)
            #expect(messages[index + 1]["content"] as? String == turn.content)
        }
    }
}
