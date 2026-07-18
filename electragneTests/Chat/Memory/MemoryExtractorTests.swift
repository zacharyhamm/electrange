import Foundation
import Testing
@testable import electragne

struct MemoryExtractorTests {
    @Test func parsesJSONWrappedInCodeFences() {
        let text = """
        ```json
        {"ownerMemory": {"summary": "Owner mentioned a wedding", "topic": "family", \
        "entities": ["mara"], "facts": ["sister is getting married"]}, \
        "assistantOutcome": null}
        ```
        """
        let extraction = MemoryExtractor.parse(text)
        #expect(extraction?.ownerMemory?.summary == "Owner mentioned a wedding")
        #expect(extraction?.ownerMemory?.entities == ["mara"])
        #expect(extraction?.ownerMemory?.facts == ["sister is getting married"])
        #expect(extraction?.assistantOutcome == nil)
    }

    @Test func parseReturnsNilForGarbage() {
        #expect(MemoryExtractor.parse("no json here") == nil)
        #expect(MemoryExtractor.parse("{broken") == nil)
    }

    @Test func extractStreamsThroughTheClientAndParses() async {
        let client = CannedChatClient(
            reply: #"{"ownerMemory": null, "assistantOutcome": null}"#
        )
        let extraction = await MemoryExtractor.extract(
            userText: "hi",
            assistantText: "hello!",
            client: client
        )
        #expect(extraction?.ownerMemory == nil)
        #expect(extraction?.assistantOutcome == nil)
        #expect(client.histories.count == 1)
        let prompt = client.histories[0].first?.content ?? ""
        #expect(prompt.contains("Owner text: hi"))
        #expect(prompt.contains("Assistant text: hello!"))
        #expect(prompt.contains("repeat known context"))
    }

    @Test func extractReturnsNilOnClientFailure() async {
        let client = CannedChatClient(reply: "", throwError: true)
        let extraction = await MemoryExtractor.extract(
            userText: "hi",
            assistantText: "hello!",
            client: client
        )
        #expect(extraction == nil)
    }
}

/// Replays one canned reply for extraction tests.
final class CannedChatClient: ChatClient {
    private let reply: String
    private let throwError: Bool
    var histories: [[ChatMessage]] = []

    init(reply: String, throwError: Bool = false) {
        self.reply = reply
        self.throwError = throwError
    }

    func streamChat(
        history: [ChatMessage],
        onStatus: (String) -> Void,
        onToolCall: (ChatToolCall) async -> ChatToolResult,
        onToken: (String) -> Void
    ) async throws {
        histories.append(history)
        if throwError { throw URLError(.notConnectedToInternet) }
        onToken(reply)
    }
}
