import Foundation
import Testing
@testable import electragne

struct GeminiClientTests {
    @Test func decodesTextFromSSEDataLine() {
        let line = #"data: {"candidates":[{"content":{"parts":[{"text":"Baa! "},{"text":"Hello."}],"role":"model"}}],"modelVersion":"gemini-3.1-flash-lite"}"#

        let chunk = GeminiClient.decodeChunk(fromLine: line)

        #expect(chunk?.text == "Baa! Hello.")
        #expect(chunk?.sources.isEmpty == true)
        #expect(chunk?.toolCalls.isEmpty == true)
    }

    @Test func decodesGroundingSourcesFromSSEDataLine() {
        let line = #"data: {"candidates":[{"content":{"parts":[{"text":"87F"}],"role":"model"},"groundingMetadata":{"groundingChunks":[{"web":{"uri":"https://example.com/wx","title":"Weather"}},{"web":{"uri":"https://example.org/kc"}}]}}]}"#

        let chunk = GeminiClient.decodeChunk(fromLine: line)

        #expect(chunk?.text == "87F")
        #expect(chunk?.sources == [
            GeminiSource(title: "Weather", uri: "https://example.com/wx"),
            GeminiSource(title: nil, uri: "https://example.org/kc"),
        ])
    }

    @Test func formatsSourcesAsShortMarkdownLinks() {
        let text = GeminiClient.formatSources([
            GeminiSource(title: "kcstar.com", uri: "https://vertexaisearch.cloud.google.com/grounding-api-redirect/AbC"),
            GeminiSource(title: nil, uri: "https://example.org/some/long/path"),
        ])

        #expect(text == "\n\nSources: [kcstar.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AbC) · [example.org](https://example.org/some/long/path)")
    }

    @Test func sourceFormattingCapsCountAndHandlesEmpty() {
        #expect(GeminiClient.formatSources([]) == "")

        let many = (1...5).map { GeminiSource(title: "s\($0)", uri: "https://example.com/\($0)") }
        let text = GeminiClient.formatSources(many)
        #expect(text.contains("[s3]"))
        #expect(!text.contains("[s4]"))
    }

    @Test func rejectsNonDataAndMalformedLines() {
        #expect(GeminiClient.decodeChunk(fromLine: "") == nil)
        #expect(GeminiClient.decodeChunk(fromLine: "event: ping") == nil)
        #expect(GeminiClient.decodeChunk(fromLine: "data:") == nil)
        #expect(GeminiClient.decodeChunk(fromLine: "data: not json") == nil)
        #expect(GeminiClient.decodeChunk(fromLine: #"{"candidates":[]}"#) == nil)
    }

    @Test func requestBodyMapsRolesAndDeclaresSearchAndReminderTools() throws {
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
        #expect(tools.count == 2)
        #expect(tools[0]["googleSearch"] != nil)
        let functions = try #require(tools[1]["functionDeclarations"] as? [[String: Any]])
        #expect(functions.count == 17)
        #expect(Set(functions.compactMap { $0["name"] as? String }) == [
            "create_reminder", "list_reminders", "update_reminder", "delete_reminder",
            "list_notes", "search_notes", "create_note", "update_note", "append_to_note", "delete_note",
            "open_app", "open_url", "find_files", "reveal_in_finder",
            "create_timer", "list_timers", "cancel_timer"
        ])
        let reminder = try #require(functions.first { $0["name"] as? String == "create_reminder" })
        let parameters = try #require(reminder["parameters"] as? [String: Any])
        #expect(parameters["required"] as? [String] == ["title"])

        let toolConfig = try #require(json["toolConfig"] as? [String: Any])
        #expect(toolConfig["includeServerSideToolInvocations"] as? Bool == true)
    }

    @Test func decodesFunctionCallAndPreservesOpaqueModelParts() throws {
        let line = #"data: {"candidates":[{"content":{"role":"model","parts":[{"functionCall":{"name":"create_reminder","id":"call-7","args":{"title":"Buy oats","due":"2026-07-15"}},"thoughtSignature":"opaque-signature"}]}}]}"#

        let chunk = try #require(GeminiClient.decodeChunk(fromLine: line))

        #expect(chunk.text.isEmpty)
        #expect(chunk.toolCalls == [ChatToolCall(
            id: "call-7",
            name: "create_reminder",
            arguments: [
                "title": .string("Buy oats"),
                "due": .string("2026-07-15"),
            ]
        )])
        #expect(chunk.modelParts.first?.objectValue?["thoughtSignature"] == .string("opaque-signature"))
    }

    @Test func followUpBodyReturnsMatchingFunctionIDAndOpaqueParts() throws {
        let modelPart: ChatToolValue = .object([
            "functionCall": .object([
                "name": .string("create_reminder"),
                "id": .string("call-9"),
                "args": .object(["title": .string("Call Mom")]),
            ]),
            "thoughtSignature": .string("keep-me"),
        ])
        let responsePart: ChatToolValue = .object([
            "functionResponse": .object([
                "name": .string("create_reminder"),
                "id": .string("call-9"),
                "response": .object(["status": .string("created")]),
            ])
        ])

        let body = try GeminiClient.makeRequestBody(contents: [
            GeminiContent(role: "user", parts: [.object(["text": .string("Remind me")])]),
            GeminiContent(role: "model", parts: [modelPart]),
            GeminiContent(role: "user", parts: [responsePart]),
        ])
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let contents = try #require(json["contents"] as? [[String: Any]])
        let modelParts = try #require(contents[1]["parts"] as? [[String: Any]])
        #expect(modelParts[0]["thoughtSignature"] as? String == "keep-me")
        let userParts = try #require(contents[2]["parts"] as? [[String: Any]])
        let functionResponse = try #require(userParts[0]["functionResponse"] as? [String: Any])
        #expect(functionResponse["id"] as? String == "call-9")
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
