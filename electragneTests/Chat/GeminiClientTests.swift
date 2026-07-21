import Foundation
import Testing
@testable import electragne

struct GeminiClientTests {
    @Test func streamAssemblesTokensStatusesAndMultipleToolRounds() async throws {
        let transport = StubChatHTTPTransport([
            .init(lines: [#"data: {"candidates":[{"content":{"role":"model","parts":[{"functionCall":{"name":"list_timers","id":"one","args":{}},"thoughtSignature":"a"}]}}]}"#]),
            .init(lines: [#"data: {"candidates":[{"content":{"role":"model","parts":[{"functionCall":{"name":"open_app","id":"two","args":{"name":"Notes"}},"thoughtSignature":"b"}]}}]}"#]),
            .init(lines: [
                #"data: {"candidates":[{"content":{"role":"model","parts":[{"text":"Hel"}]}}]}"#,
                #"data: {"candidates":[{"content":{"role":"model","parts":[{"text":"lo"}]}}]}"#,
            ]),
        ])
        let client = GeminiClient(transport: transport, apiKey: { "test-key" })
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
        #expect(String(decoding: transport.requests[1].httpBody ?? Data(), as: UTF8.self).contains("functionResponse"))
    }

    @Test func streamThrowsHTTPAndQuotaErrors() async {
        let quota = GeminiClient(
            transport: StubChatHTTPTransport([.init(status: 429)]),
            apiKey: { "test-key" }
        )
        await #expect(throws: ChatProviderError.quotaExceeded) {
            try await quota.streamChat(history: [], onStatus: { _ in }, onToolCall: { _ in .error("") }, onToken: { _ in })
        }

        let server = GeminiClient(
            transport: StubChatHTTPTransport([.init(status: 500)]),
            apiKey: { "test-key" }
        )
        await #expect(throws: ChatProviderError.badStatus(500)) {
            try await server.streamChat(history: [], onStatus: { _ in }, onToolCall: { _ in .error("") }, onToken: { _ in })
        }
    }

    @Test func streamPropagatesCancellation() async {
        let client = GeminiClient(
            transport: StubChatHTTPTransport([.init(error: CancellationError())]),
            apiKey: { "test-key" }
        )
        await #expect(throws: CancellationError.self) {
            try await client.streamChat(history: [], onStatus: { _ in }, onToolCall: { _ in .error("") }, onToken: { _ in })
        }
    }

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
            ChatMessage(role: "user", content: "What's your name?"),
            ChatMessage(role: "assistant", content: "I'm a sheep!"),
            ChatMessage(role: "user", content: "Search for sheep facts"),
        ]
        let body = try GeminiClient.makeRequestBody(history: history, userName: "Zed", mcpTools: [])

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
        #expect(functions.count == 44)
        #expect(Set(functions.compactMap { $0["name"] as? String }) == [
            "image_search",
            "create_reminder", "list_reminders", "update_reminder", "delete_reminder",
            "list_notes", "search_notes", "create_note", "update_note", "append_to_note", "delete_note",
            "open_app", "open_url", "find_files", "reveal_in_finder",
            "create_timer", "list_timers", "cancel_timer",
            "create_automation", "list_automations", "update_automation", "cancel_automation",
            "report_app_status",
            "list_google_accounts", "search_gmail", "read_gmail_message",
            "create_gmail_draft", "send_gmail_draft",
            "list_google_calendars", "list_calendar_events", "create_calendar_event",
            "search_slack", "get_slack_messages", "get_slack_thread",
            "list_slack_users", "get_slack_permalink", "send_slack_message",
            "list_linear_teams", "search_linear_issues", "search_linear_projects",
            "list_my_linear_issues", "get_linear_issue", "create_linear_issue",
            "recall_memory"
        ])
        let reminder = try #require(functions.first { $0["name"] as? String == "create_reminder" })
        let parameters = try #require(reminder["parameters"] as? [String: Any])
        #expect(parameters["required"] as? [String] == ["title"])

        let toolConfig = try #require(json["toolConfig"] as? [String: Any])
        #expect(toolConfig["includeServerSideToolInvocations"] as? Bool == true)
    }

    @Test func requestBodyPassesMCPSchemasThroughUntouched() throws {
        let descriptor = MCPToolDescriptor(
            serverID: UUID(),
            serverName: "docs",
            toolName: "search",
            description: "Searches the docs",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object(["type": .string("string")]),
                    "filters": .object([
                        "type": .string("object"),
                        "properties": .object(["tag": .object(["type": .string("string")])]),
                    ]),
                ]),
                "required": .array([.string("query")]),
            ])
        )
        let body = try GeminiClient.makeRequestBody(
            history: [ChatMessage(role: "user", content: "hi")],
            mcpTools: [descriptor]
        )

        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let tools = try #require(json["tools"] as? [[String: Any]])
        let functions = try #require(tools[1]["functionDeclarations"] as? [[String: Any]])
        let mcp = try #require(functions.first { $0["name"] as? String == "mcp__docs__search" })
        #expect(mcp["description"] as? String == "Searches the docs")
        let parameters = try #require(mcp["parameters"] as? [String: Any])
        #expect(parameters["required"] as? [String] == ["query"])
        let properties = try #require(parameters["properties"] as? [String: Any])
        let filters = try #require(properties["filters"] as? [String: Any])
        #expect((filters["properties"] as? [String: Any])?.keys.contains("tag") == true)
    }

    @Test func imageSearchToolRequiresConfiguredSearXNG() throws {
        func names(available: Bool) throws -> [String] {
            let body = try GeminiClient.makeRequestBody(
                history: [],
                imageSearchAvailable: available,
                mcpTools: []
            )
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let tools = try #require(json["tools"] as? [[String: Any]])
            let functions = try #require(tools[1]["functionDeclarations"] as? [[String: Any]])
            return functions.compactMap { $0["name"] as? String }
        }

        #expect(try !names(available: false).contains("image_search"))
        #expect(try names(available: true).contains("image_search"))
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

    @Test func listModelsFiltersPaginatesAndStripsPrefix() async throws {
        let page1 = #"""
        {"models":[
            {"name":"models/gemini-3.1-pro","displayName":"Gemini 3.1 Pro","supportedGenerationMethods":["generateContent","countTokens"]},
            {"name":"models/embedding-001","displayName":"Embedding","supportedGenerationMethods":["embedContent"]}
        ],"nextPageToken":"page-2"}
        """#
        let page2 = #"""
        {"models":[{"name":"gemini-3.1-flash-lite","supportedGenerationMethods":["generateContent"]}]}
        """#
        let transport = StubChatHTTPTransport([
            .init(data: Data(page1.utf8)),
            .init(data: Data(page2.utf8)),
        ])

        let models = try await GeminiClient.listModels(apiKey: "test-key", transport: transport)

        #expect(models == [
            GeminiClient.GeminiModel(id: "gemini-3.1-pro", displayName: "Gemini 3.1 Pro"),
            GeminiClient.GeminiModel(id: "gemini-3.1-flash-lite", displayName: "gemini-3.1-flash-lite"),
        ])
        #expect(transport.requests.count == 2)
        #expect(transport.requests[0].value(forHTTPHeaderField: "x-goog-api-key") == "test-key")
        #expect(transport.requests[1].url?.query?.contains("pageToken=page-2") == true)
    }

    @Test func modelPreferenceFallsBackToConfigDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: "gemini-model-test-\(UUID().uuidString)"))
        #expect(UserPreferences.geminiModel(in: defaults) == ChatConfig.default.geminiModel)
        defaults.set("  ", forKey: UserPreferences.geminiModelKey)
        #expect(UserPreferences.geminiModel(in: defaults) == ChatConfig.default.geminiModel)
        defaults.set("gemini-3.1-pro", forKey: UserPreferences.geminiModelKey)
        #expect(UserPreferences.geminiModel(in: defaults) == "gemini-3.1-pro")
    }

    @Test func apiKeyComesFromEnvironmentFirstThenFile() throws {
        #expect(
            ChatAPIKeyStore.load(
                for: .gemini,
                keychainKey: nil,
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

        #expect(ChatAPIKeyStore.load(for: .gemini, keychainKey: nil, environment: [:], homeDirectory: home.path) == "gm-key-file")
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
