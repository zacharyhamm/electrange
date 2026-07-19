import Foundation
import Testing
@testable import electragne

struct ChatProviderEngineTests {
    @Test func trimsHistoryAndOwnsToolRounds() async throws {
        let call = ChatToolCall(id: "1", name: "list_timers", arguments: [:])
        let backend = StubProviderBackend(replies: [
            [.toolCall(call)],
            [.token("Done")],
        ])
        var output = ""
        var imageBatches: [ChatImageBatch] = []
        let image = try #require(ChatImage(
            url: "https://images.example/sheep.jpg",
            sourceURL: "https://example.com/sheep",
            title: "Sheep"
        ))

        try await ChatProviderEngine(backend: backend).streamChat(
            history: [
                ChatMessage(role: "user", content: "discard me"),
                ChatMessage(role: "assistant", content: "keep me"),
                ChatMessage(role: "user", content: "run it"),
            ],
            onToolCall: { _ in ChatToolResult(
                response: ["status": .string("ok")],
                imageBatch: ChatImageBatch(images: [image], presentation: .gallery)
            ) },
            onImages: { imageBatches.append($0) },
            onToken: { output += $0 }
        )

        #expect(output == "Done")
        #expect(backend.histories.first?.map(\.content) == ["keep me", "run it"])
        #expect(backend.histories.last?.suffix(2).map(\.role) == ["assistant", "tool"])
        #expect(imageBatches.first?.images == [image])
    }
}

private nonisolated final class StubProviderBackend: ChatProviderBackend, @unchecked Sendable {
    let config = ChatConfig(maxToolRounds: 2, maxHistoryMessages: 2)
    private let lock = NSLock()
    private var replies: [[ProviderEvent]]
    private var capturedHistories: [[ChatMessage]] = []

    init(replies: [[ProviderEvent]]) { self.replies = replies }

    var histories: [[ChatMessage]] { lock.withLock { capturedHistories } }

    func stream(messages: [ChatMessage]) async throws
        -> AsyncThrowingStream<ProviderEvent, Error> {
        let events = lock.withLock {
            capturedHistories.append(messages)
            return replies.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            events.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    func appendToolResult(
        _ result: ChatToolResult,
        for call: ChatToolCall,
        to messages: inout [ChatMessage]
    ) {
        messages.append(ChatMessage(role: "tool", content: "ok", toolName: call.name))
    }
}
