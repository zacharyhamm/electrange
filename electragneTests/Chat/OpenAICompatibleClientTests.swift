import Foundation
import Testing
@testable import electragne

struct OpenAICompatibleClientTests {
    @Test func requestUsesChatCompletionsShapeAndGatesDeepSeekThinking() throws {
        let body = try OpenAICompatibleClient.makeRequestBody(
            baseURL: OpenAICompatibleClient.defaultBaseURL,
            model: "deepseek-v4-flash",
            thinking: true,
            history: [ChatMessage(role: "user", content: "hello")],
            mcpTools: []
        )
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "deepseek-v4-flash")
        #expect(json["stream"] as? Bool == true)
        #expect((json["thinking"] as? [String: String])?["type"] == "enabled")
        #expect((json["messages"] as? [[String: Any]])?.map { $0["role"] as? String } == ["system", "user"])
        #expect((json["tools"] as? [[String: Any]])?.isEmpty == false)

        let compatible = try OpenAICompatibleClient.makeRequestBody(
            baseURL: URL(string: "https://example.com/v1")!,
            model: "custom",
            thinking: true,
            history: [],
            mcpTools: []
        )
        let compatibleJSON = try #require(JSONSerialization.jsonObject(with: compatible) as? [String: Any])
        #expect(compatibleJSON["thinking"] == nil)
    }

    @Test func requestOnlyOffersWebSearchWhenEndpointIsConfigured() throws {
        func toolNames(webSearchAvailable: Bool) throws -> [String] {
            let body = try OpenAICompatibleClient.makeRequestBody(
                baseURL: OpenAICompatibleClient.defaultBaseURL,
                model: "test",
                thinking: false,
                history: [],
                webSearchAvailable: webSearchAvailable,
                mcpTools: []
            )
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let tools = try #require(json["tools"] as? [[String: Any]])
            return tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        }

        #expect(try !toolNames(webSearchAvailable: false).contains("web_search"))
        #expect(try !toolNames(webSearchAvailable: false).contains("image_search"))
        #expect(try toolNames(webSearchAvailable: true).contains("web_search"))
        #expect(try toolNames(webSearchAvailable: true).contains("image_search"))
    }

    @Test func streamAssemblesParallelCallsAndReplaysReasoningAndIDs() async throws {
        let transport = StubChatHTTPTransport([
            .init(lines: [
                #"data: {"choices":[{"delta":{"reasoning_content":"think "}}]}"#,
                #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"list_","arguments":"{"}},{"index":1,"id":"call_2","function":{"name":"open_","arguments":"{\"na"}}]}}]}"#,
                #"data: {"choices":[{"delta":{"reasoning_content":"first","tool_calls":[{"index":0,"function":{"name":"timers","arguments":"}"}},{"index":1,"function":{"name":"app","arguments":"me\":\"Notes\"}"}}]}}]}"#,
                "data: [DONE]",
            ]),
            .init(lines: [
                #"data: {"choices":[{"delta":{"content":"Done"}}]}"#,
                "data: [DONE]",
            ]),
        ])
        let client = OpenAICompatibleClient(
            baseURL: OpenAICompatibleClient.defaultBaseURL,
            model: "deepseek-v4-pro",
            thinking: true,
            transport: transport,
            apiKey: { "secret" }
        )
        var calls: [ChatToolCall] = []
        var output = ""
        try await client.streamChat(
            history: [ChatMessage(role: "user", content: "do both")],
            onToolCall: { call in
                calls.append(call)
                return .make(status: "ok", message: "done")
            },
            onToken: { output += $0 }
        )

        #expect(output == "Done")
        #expect(calls.map(\.id) == ["call_1", "call_2"])
        #expect(calls.map(\.name) == ["list_timers", "open_app"])
        #expect(calls[1].arguments == ["name": .string("Notes")])
        #expect(transport.requests.count == 2)
        #expect(transport.requests[0].url?.absoluteString == "https://api.deepseek.com/chat/completions")
        #expect(transport.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer secret")

        let followUpData = try #require(transport.requests[1].httpBody)
        let followUp = try #require(JSONSerialization.jsonObject(with: followUpData) as? [String: Any])
        let messages = try #require(followUp["messages"] as? [[String: Any]])
        let assistant = try #require(messages.first { $0["role"] as? String == "assistant" })
        #expect(assistant["reasoning_content"] as? String == "think first")
        let results = messages.filter { $0["role"] as? String == "tool" }
        #expect(results.compactMap { $0["tool_call_id"] as? String } == ["call_1", "call_2"])
    }

    @Test func reasoningDeltasSurfaceThinkingStatusOncePerRun() async throws {
        let transport = StubChatHTTPTransport([
            .init(lines: [
                #"data: {"choices":[{"delta":{"reasoning_content":"hmm "}}]}"#,
                #"data: {"choices":[{"delta":{"reasoning_content":"okay"}}]}"#,
                #"data: {"choices":[{"delta":{"content":"Hi"}}]}"#,
                #"data: {"choices":[{"delta":{"reasoning_content":"more"}}]}"#,
                #"data: {"choices":[{"delta":{"content":"!"}}]}"#,
                "data: [DONE]",
            ]),
        ])
        let client = OpenAICompatibleClient(
            baseURL: OpenAICompatibleClient.defaultBaseURL,
            model: "deepseek-v4-pro",
            thinking: true,
            transport: transport,
            apiKey: { "secret" }
        )
        var statuses: [String] = []
        var output = ""
        try await client.streamChat(
            history: [ChatMessage(role: "user", content: "hi")],
            onStatus: { statuses.append($0) },
            onToken: { output += $0 }
        )

        #expect(output == "Hi!")
        #expect(statuses == ["Thinking…", "Thinking…"])
    }

    @Test func decodesDoneTextAndFragments() throws {
        #expect(OpenAICompatibleClient.decodeChunk(fromLine: "data: [DONE]")?.done == true)
        let chunk = try #require(OpenAICompatibleClient.decodeChunk(fromLine:
            #"data: {"choices":[{"delta":{"content":"Hi","reasoning_content":"hmm","tool_calls":[{"index":2,"id":"x","function":{"name":"f","arguments":"{}"}}]}}]}"#
        ))
        #expect(chunk.content == "Hi")
        #expect(chunk.reasoningContent == "hmm")
        #expect(chunk.toolCalls.first?.index == 2)
        #expect(OpenAICompatibleClient.decodeChunk(fromLine: "event: ping") == nil)
    }

    @Test func listsModelsAndReportsConfigurationAndHTTPFailures() async throws {
        let modelData = Data(#"{"object":"list","data":[{"id":"deepseek-v4-flash"},{"id":"deepseek-v4-pro"}]}"#.utf8)
        let transport = StubChatHTTPTransport([.init(data: modelData)])
        let models = try await OpenAICompatibleClient.listModels(
            baseURL: OpenAICompatibleClient.defaultBaseURL,
            apiKey: "key",
            transport: transport
        )
        #expect(models.map(\.id) == OpenAICompatibleClient.defaultModels)
        #expect(transport.requests.first?.url?.absoluteString == "https://api.deepseek.com/models")

        await #expect(throws: ChatProviderError.missingAPIKey(.openAICompatible)) {
            try await OpenAICompatibleClient(
                baseURL: OpenAICompatibleClient.defaultBaseURL,
                apiKey: { nil }
            ).streamChat(history: [], onToken: { _ in })
        }
        await #expect(throws: ChatProviderError.badStatus(401)) {
            try await OpenAICompatibleClient(
                baseURL: OpenAICompatibleClient.defaultBaseURL,
                transport: StubChatHTTPTransport([.init(status: 401)]),
                apiKey: { "key" }
            ).streamChat(history: [], onToken: { _ in })
        }
    }

    @Test func choosesEnvironmentKeyByHostAndMigratesLegacyProviderPreference() throws {
        #expect(OpenAICompatibleClient.resolveAPIKey(
            baseURL: OpenAICompatibleClient.defaultBaseURL,
            keychainKey: nil,
            environment: ["DEEPSEEK_API_KEY": "deep", "OPENAI_API_KEY": "open"]
        ) == "deep")
        #expect(OpenAICompatibleClient.resolveAPIKey(
            baseURL: URL(string: "https://example.com/v1")!,
            keychainKey: nil,
            environment: ["DEEPSEEK_API_KEY": "deep", "OPENAI_API_KEY": "open"]
        ) == "open")
        #expect(OpenAICompatibleClient.resolveAPIKey(
            baseURL: OpenAICompatibleClient.defaultBaseURL,
            keychainKey: "stored",
            environment: ["DEEPSEEK_API_KEY": "deep"]
        ) == "stored")

        let suite = "OpenAICompatibleClientTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: ChatProviderPreference.useGeminiKey)
        #expect(ChatProviderPreference.selected(in: defaults) == .gemini)
        #expect(defaults.string(forKey: ChatProviderPreference.providerKey) == ChatProvider.gemini.rawValue)
        ChatProviderPreference.set(.openAICompatible, in: defaults)
        #expect(ChatProviderPreference.selected(in: defaults) == .openAICompatible)
    }
}
