import Foundation

nonisolated enum ProviderEvent: Sendable {
    case status(String)
    case token(String)
    case toolCall(ChatToolCall)
}

nonisolated protocol ChatProviderBackend: Sendable {
    var config: ChatConfig { get }

    func stream(messages: [ChatMessage]) async throws
        -> AsyncThrowingStream<ProviderEvent, Error>
    func appendToolResult(
        _ result: ChatToolResult,
        for call: ChatToolCall,
        to messages: inout [ChatMessage]
    )
}

nonisolated enum ChatProviderError: LocalizedError, Equatable {
    case badStatus(Int)
    case missingAPIKey(ChatAPIProvider)
    case quotaExceeded
    case toolRoundLimit
    case invalidModelName
    case invalidEndpoint
    case invalidToolArguments

    var errorDescription: String? {
        switch self {
        case .badStatus:
            "The chat provider returned an error."
        case .missingAPIKey(.ollama):
            "Web search needs an ollama.com API key — add it in Electragne Settings"
        case .missingAPIKey(.gemini):
            "Gemini needs an API key — add it in Electragne Settings"
        case .missingAPIKey(.openAICompatible):
            "The OpenAI-compatible provider needs an API key — add it in Electragne Settings"
        case .missingAPIKey(.dobbs):
            "Slack needs a dobbs token — add it in Electragne Settings"
        case .missingAPIKey(.linear):
            "Linear needs an API key — add it in Electragne Settings"
        case .quotaExceeded:
            "Gemini quota exceeded — try again later"
        case .toolRoundLimit:
            "The chat provider used too many tool steps — try a simpler request"
        case .invalidModelName:
            "The configured chat model name is invalid."
        case .invalidEndpoint:
            "The configured chat provider URL is invalid."
        case .invalidToolArguments:
            "The chat provider returned invalid tool arguments."
        }
    }
}

struct ChatProviderEngine: ChatClient {
    let backend: any ChatProviderBackend

    func streamChat(
        history: [ChatMessage],
        onStatus: (String) -> Void = { _ in },
        onToolCall: (ChatToolCall) async -> ChatToolResult = { _ in
            .error("This chat provider does not support that tool.")
        },
        onToken: (String) -> Void
    ) async throws {
        var messages = Array(history.suffix(backend.config.maxHistoryMessages))

        for round in 0...backend.config.maxToolRounds {
            var content = ""
            var toolCalls: [ChatToolCall] = []

            for try await event in try await backend.stream(messages: messages) {
                switch event {
                case .status(let status):
                    onStatus(status)
                case .token(let token):
                    content += token
                    onToken(token)
                case .toolCall(let call):
                    if !toolCalls.contains(call) {
                        toolCalls.append(call)
                    }
                }
            }

            guard !toolCalls.isEmpty else { return }
            guard round < backend.config.maxToolRounds else {
                throw ChatProviderError.toolRoundLimit
            }

            messages.append(ChatMessage(role: "assistant", content: content, toolCalls: toolCalls))
            for call in toolCalls {
                onStatus(Self.initialStatus(for: call.name))
                let result = await onToolCall(call)
                if call.name == "web_search",
                   result.response["status"] == .string("error"),
                   result.response["message"]?.stringValue?.contains("API key") == true {
                    throw ChatProviderError.missingAPIKey(.ollama)
                }
                backend.appendToolResult(result, for: call, to: &messages)
            }
            onStatus("Thinking…")
        }
    }

    /// MCP tools are not in ChatToolRegistry, and whether they confirm
    /// depends on their policy — so don't promise a confirmation.
    private static func initialStatus(for name: String) -> String {
        if name.hasPrefix("mcp__") {
            return "Calling \(MCPToolCatalog.descriptor(named: name)?.toolName ?? "MCP tool")…"
        }
        return ChatToolRegistry.definition(named: name)?.initialStatus ?? "Confirm action…"
    }
}

extension ChatProviderBackend {
    func streamChat(
        history: [ChatMessage],
        onStatus: (String) -> Void = { _ in },
        onToolCall: (ChatToolCall) async -> ChatToolResult = { _ in
            .error("This chat provider does not support that tool.")
        },
        onToken: (String) -> Void
    ) async throws {
        try await ChatProviderEngine(backend: self).streamChat(
            history: history,
            onStatus: onStatus,
            onToolCall: onToolCall,
            onToken: onToken
        )
    }
}
