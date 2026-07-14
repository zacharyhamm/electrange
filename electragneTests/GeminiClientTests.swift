import Foundation
import Testing
@testable import electragne

struct GeminiClientTests {
    @Test func decodesTextFromSSEDataLine() {
        let line = #"data: {"candidates":[{"content":{"parts":[{"text":"Baa! "},{"text":"Hello."}],"role":"model"}}],"modelVersion":"gemini-3.1-flash-lite"}"#

        let chunk = GeminiClient.decodeChunk(fromLine: line)

        #expect(chunk == GeminiChunk(text: "Baa! Hello."))
    }

    @Test func decodesGroundingSourcesFromSSEDataLine() {
        let line = #"data: {"candidates":[{"content":{"parts":[{"text":"87F"}],"role":"model"},"groundingMetadata":{"groundingChunks":[{"web":{"uri":"https://example.com/wx","title":"Weather"}},{"web":{"uri":"https://example.org/kc"}}]}}]}"#

        let chunk = GeminiClient.decodeChunk(fromLine: line)

        #expect(chunk?.text == "87F")
        #expect(chunk?.sourceURLs == ["https://example.com/wx", "https://example.org/kc"])
    }

    @Test func rejectsNonDataAndMalformedLines() {
        #expect(GeminiClient.decodeChunk(fromLine: "") == nil)
        #expect(GeminiClient.decodeChunk(fromLine: "event: ping") == nil)
        #expect(GeminiClient.decodeChunk(fromLine: "data:") == nil)
        #expect(GeminiClient.decodeChunk(fromLine: "data: not json") == nil)
        #expect(GeminiClient.decodeChunk(fromLine: #"{"candidates":[]}"#) == nil)
    }

    @Test func requestBodyMapsRolesAndDeclaresSearchTool() throws {
        let history = [
            OllamaMessage(role: "user", content: "What's your name?"),
            OllamaMessage(role: "assistant", content: "I'm a sheep!"),
            OllamaMessage(role: "user", content: "Search for sheep facts"),
        ]
        let body = try GeminiClient.makeRequestBody(history: history, userName: "Zed")

        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )

        let system = try #require(json["system_instruction"] as? [String: Any])
        let systemParts = try #require(system["parts"] as? [[String: Any]])
        let systemText = try #require(systemParts[0]["text"] as? String)
        #expect(systemText.hasPrefix(GeminiClient.systemPrompt))
        #expect(systemText.contains("named Zed"))

        let contents = try #require(json["contents"] as? [[String: Any]])
        #expect(contents.count == 3)
        #expect(contents.map { $0["role"] as? String } == ["user", "model", "user"])
        let firstParts = try #require(contents[0]["parts"] as? [[String: Any]])
        #expect(firstParts[0]["text"] as? String == "What's your name?")

        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["google_search"] != nil)
    }

    @Test func apiKeyComesFromEnvironmentFirstThenFile() throws {
        #expect(
            GeminiClient.loadAPIKey(
                environment: ["GEMINI_API_KEY": " gm-key-env\n"],
                homeDirectory: "/nonexistent"
            ) == "gm-key-env"
        )

        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini-key-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "gm-key-file\n".write(
            to: home.appendingPathComponent(".gemini.api.key"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(GeminiClient.loadAPIKey(environment: [:], homeDirectory: home.path) == "gm-key-file")
        #expect(GeminiClient.loadAPIKey(environment: [:], homeDirectory: "/nonexistent") == nil)
    }
}
