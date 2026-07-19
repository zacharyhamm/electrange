import Foundation
import Testing
@testable import electragne

struct OllamaClientTests {
    @Test func streamAssemblesTokensStatusesAndMultipleToolRounds() async throws {
        let transport = StubChatHTTPTransport([
            .init(lines: [#"{"message":{"content":"","tool_calls":[{"function":{"name":"list_timers","arguments":{}}}]},"done":true}"#]),
            .init(lines: [#"{"message":{"content":"","tool_calls":[{"function":{"name":"open_app","arguments":{"name":"Notes"}}}]},"done":true}"#]),
            .init(lines: [
                #"{"message":{"content":"Hel"},"done":false}"#,
                #"{"message":{"content":"lo"},"done":true}"#,
            ]),
        ])
        let client = OllamaClient(transport: transport)
        var tokens = ""
        var statuses: [String] = []
        var calls: [String] = []

        try await client.streamChat(
            history: [ChatMessage(role: "user", content: "Do two things")],
            onStatus: { statuses.append($0) },
            onToolCall: { call in
                calls.append(call.name)
                return .make(status: "ok", message: "done")
            },
            onToken: { tokens += $0 }
        )

        #expect(tokens == "Hello")
        #expect(calls == ["list_timers", "open_app"])
        #expect(statuses.last == "Thinking…")
        #expect(transport.requests.count == 3)
        #expect(String(decoding: transport.requests[1].httpBody ?? Data(), as: UTF8.self).contains("tool_name"))
    }

    @Test func listModelsDecodesTagNames() async throws {
        let transport = StubChatHTTPTransport([
            .init(data: Data(#"{"models":[{"name":"gemma4:latest"},{"name":"qwen3:8b"}]}"#.utf8)),
        ])

        let models = try await OllamaClient.listModels(transport: transport)

        #expect(models == ["gemma4:latest", "qwen3:8b"])
        #expect(transport.requests.first?.url?.path == "/api/tags")
    }

    @Test func streamThrowsHTTPError() async {
        let client = OllamaClient(transport: StubChatHTTPTransport([.init(status: 503)]))
        await #expect(throws: ChatProviderError.badStatus(503)) {
            try await client.streamChat(history: [], onToken: { _ in })
        }
    }

    @Test func streamPropagatesCancellation() async {
        let client = OllamaClient(transport: StubChatHTTPTransport([
            .init(error: CancellationError()),
        ]))
        await #expect(throws: CancellationError.self) {
            try await client.streamChat(history: [], onToken: { _ in })
        }
    }

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

    @Test func decodesToolCallLine() {
        let line = #"{"model":"gemma4:latest","message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"web_search","arguments":{"query":"weather today"}}}]},"done":false}"#

        let chunk = OllamaClient.decodeChunk(fromLine: line)

        #expect(chunk?.toolCalls.count == 1)
        #expect(chunk?.toolCalls.first?.name == "web_search")
        #expect(chunk?.toolCalls.first?.arguments["query"]?.stringValue == "weather today")
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
            history: [ChatMessage(role: "user", content: "Hello, sheep!")]
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
            ChatMessage(role: "user", content: "What's your name?"),
            ChatMessage(role: "assistant", content: "I'm a sheep!"),
            ChatMessage(role: "user", content: "What did I just ask you?"),
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

    @Test func systemPromptIncludesUserNameWhenKnown() throws {
        #expect(OllamaClient.makeSystemPrompt(userName: nil) == OllamaClient.systemPrompt)
        #expect(OllamaClient.makeSystemPrompt(userName: "") == OllamaClient.systemPrompt)

        let personalized = OllamaClient.makeSystemPrompt(userName: "Zachary Hamm")
        #expect(personalized.hasPrefix(OllamaClient.systemPrompt))
        #expect(personalized.contains("named Zachary Hamm"))

        let body = try OllamaClient.makeRequestBody(
            model: "gemma4:latest",
            history: [],
            userName: "Zachary Hamm"
        )
        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect((messages[0]["content"] as? String)?.contains("Zachary Hamm") == true)
    }

    @Test func requestBodyDeclaresWebSearchAndAllLocalTools() throws {
        let body = try OllamaClient.makeRequestBody(model: "gemma4:latest", history: [])

        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.count == ChatToolRegistry.definitions(for: .ollama).count)
        let function = try #require(tools[0]["function"] as? [String: Any])
        #expect(function["name"] as? String == "web_search")
        let parameters = try #require(function["parameters"] as? [String: Any])
        #expect(parameters["required"] as? [String] == ["query"])
        let names = Set(tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
        #expect(names == Set(ChatToolRegistry.definitions(for: .ollama).map(\.name)))
    }

    @Test func toolMessagesEncodeOllamaFieldNames() throws {
        let history = [
            ChatMessage(
                role: "assistant",
                content: "",
                toolCalls: [ChatToolCall(
                    id: "",
                    name: "web_search",
                    arguments: ["query": .string("news")]
                )]
            ),
            ChatMessage(role: "tool", content: "Result 1: …", toolName: "web_search"),
        ]
        let body = try OllamaClient.makeRequestBody(model: "gemma4:latest", history: history)

        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let messages = try #require(json["messages"] as? [[String: Any]])

        let assistant = messages[1]
        let toolCalls = try #require(assistant["tool_calls"] as? [[String: Any]])
        let function = try #require(toolCalls[0]["function"] as? [String: Any])
        #expect(function["name"] as? String == "web_search")
        #expect((function["arguments"] as? [String: Any])?["query"] as? String == "news")

        let tool = messages[2]
        #expect(tool["role"] as? String == "tool")
        #expect(tool["tool_name"] as? String == "web_search")
        // Plain chat messages must not carry tool keys.
        #expect(messages[0]["tool_calls"] == nil)
        #expect(messages[0]["tool_name"] == nil)
    }

    @Test func requestOmitsUnavailableSearchToolsAndStoredImages() throws {
        let image = try #require(ChatImage(
            url: "https://images.example/sheep.jpg",
            sourceURL: "https://example.com/sheep",
            title: "Sheep"
        ))
        let body = try OllamaClient.makeRequestBody(
            model: "gemma4:latest",
            history: [ChatMessage(role: "assistant", content: "Baa", images: [image])],
            webSearchAvailable: false
        )
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let tools = try #require(json["tools"] as? [[String: Any]])
        let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        let messages = try #require(json["messages"] as? [[String: Any]])

        #expect(!names.contains("web_search"))
        #expect(!names.contains("image_search"))
        #expect(messages[1]["images"] == nil)
    }

    @Test func formatsSearchResultsWithTruncation() throws {
        let longContent = String(repeating: "x", count: 5000)
        let payload = """
            {"results":[
              {"title":"First","url":"https://example.com/a","content":"short answer"},
              {"title":"Second","url":"https://example.com/b","content":"\(longContent)"}
            ]}
            """
        let text = SearXNGSearch.formatResults(from: Data(payload.utf8))

        #expect(text.contains("Result 1: First"))
        #expect(text.contains("URL: https://example.com/a"))
        #expect(text.contains("short answer"))
        #expect(text.contains("Result 2: Second"))
        #expect(text.count < 2500 + longContent.count - SearXNGSearch.maxResultCharacters)
    }

    @Test func extractsValidatedSearchImagesWithModeLimits() throws {
        let results = (1...8).map {
            #"{"title":"T\#($0)","url":"https://example.com/\#($0)","thumbnail_src":"https://img.example.com/\#($0).jpg","content":"c"}"#
        }.joined(separator: ",")
        let data = Data(#"{"results":[\#(results)]}"#.utf8)

        let thumbnails = SearXNGSearch.formatOutput(from: data)
        let gallery = SearXNGSearch.formatOutput(from: data, category: .images)

        #expect(thumbnails.images.count == SearXNGSearch.maxThumbnails)
        #expect(gallery.images.count == SearXNGSearch.maxGalleryImages)
        #expect(gallery.images.first?.sourceURL == "https://example.com/1")

        let invalid = Data(#"{"results":[{"title":"bad","url":"file:///tmp/page","img_src":"file:///tmp/image"}]}"#.utf8)
        #expect(SearXNGSearch.formatOutput(from: invalid).images.isEmpty)
    }

    @Test func formatsOnlyTheFirstMaxResults() throws {
        let results = (1...10).map {
            #"{"title":"T\#($0)","url":"https://example.com/\#($0)","content":"c"}"#
        }.joined(separator: ",")
        let text = SearXNGSearch.formatResults(from: Data(#"{"results":[\#(results)]}"#.utf8))

        #expect(text.contains("Result \(SearXNGSearch.maxResults): T\(SearXNGSearch.maxResults)"))
        #expect(!text.contains("T\(SearXNGSearch.maxResults + 1)"))
    }

    @Test func searchURLAppendsSearchPathAndQuery() {
        let url = SearXNGSearch.searchURL(endpoint: "http://localhost:8888", query: "hello world")
        #expect(url?.absoluteString == "http://localhost:8888/search?q=hello%20world&format=json")
        #expect(SearXNGSearch.searchURL(endpoint: "", query: "x") == nil)
        #expect(
            SearXNGSearch.searchURL(
                endpoint: "http://localhost:8888",
                query: "sheep",
                category: .images
            )?.absoluteString
                == "http://localhost:8888/search?q=sheep&format=json&categories=images"
        )
    }

    @Test func emptyOrMalformedSearchResponsesReadAsNoResults() {
        #expect(SearXNGSearch.formatResults(from: Data(#"{"results":[]}"#.utf8)) == "No results found.")
        #expect(SearXNGSearch.formatResults(from: Data("garbage".utf8)) == "No results found.")
    }

    @Test func apiKeyComesFromEnvironmentFirstThenFile() throws {
        #expect(
            ChatAPIKeyStore.load(
                for: .gemini,
                keychainKey: nil,
                environment: ["GEMINI_API_KEY": " key-from-env\n"],
                homeDirectory: "/nonexistent"
            ) == "key-from-env"
        )

        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini-key-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "key-from-file\n".write(
            to: home.appendingPathComponent(".gemini.api.key"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(ChatAPIKeyStore.load(for: .gemini, keychainKey: nil, environment: [:], homeDirectory: home.path) == "key-from-file")
        #expect(ChatAPIKeyStore.load(for: .gemini, keychainKey: nil, environment: [:], homeDirectory: "/nonexistent") == nil)
        #expect(
            ChatAPIKeyStore.load(
                for: .gemini,
                keychainKey: " key-from-keychain ",
                environment: ["GEMINI_API_KEY": "key-from-env"],
                homeDirectory: home.path
            ) == "key-from-keychain"
        )
    }
}
