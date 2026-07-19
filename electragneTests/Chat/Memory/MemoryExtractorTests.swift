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

    @Test func parseSurvivesLeakedProseWithBraces() {
        let text = """
        Thinking: the shape is {"summary": ...} but incomplete, so {oops.
        {"ownerMemory": {"summary": "Owner likes tea"}, "assistantOutcome": null}
        And a stray } afterwards.
        """
        #expect(MemoryExtractor.parse(text)?.ownerMemory?.summary == "Owner likes tea")
    }

    @Test func parsePicksTheDecodableObjectAmongSeveral() {
        let text = """
        {"not": ["an extraction", 1]}
        {"ownerMemory": null, "assistantOutcome": {"summary": "Booked flights"}}
        """
        #expect(MemoryExtractor.parse(text)?.assistantOutcome?.summary == "Booked flights")
    }

    @Test func parseIgnoresBracesInsideStringLiterals() {
        let text = #"{"ownerMemory": {"summary": "Owner said {hi}"}, "assistantOutcome": null} trailing {"#
        #expect(MemoryExtractor.parse(text)?.ownerMemory?.summary == "Owner said {hi}")
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

    @Test func extractRetriesOnceAfterUnparseableOutput() async {
        let client = CannedChatClient(replies: [
            "definitely not json",
            #"{"ownerMemory": null, "assistantOutcome": {"summary": "Named the fix"}}"#,
        ])
        let extraction = await MemoryExtractor.extract(
            userText: "hi",
            assistantText: "hello!",
            client: client
        )
        #expect(client.histories.count == 2)
        #expect(extraction?.assistantOutcome?.summary == "Named the fix")
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

    @Test func extractionReceivesPriorTurnsAsReferenceOnlyContext() async {
        let client = CannedChatClient(
            reply: #"{"ownerMemory": null, "assistantOutcome": null}"#
        )
        _ = await MemoryExtractor.extract(
            userText: "She lives there now",
            assistantText: "Understood",
            context: [
                ChatMessage(role: "user", content: "My sister is Mara"),
                ChatMessage(role: "assistant", content: "Mara moved to Portland"),
            ],
            client: client
        )

        let prompt = client.histories[0][0].content
        #expect(prompt.contains("user: My sister is Mara"))
        #expect(prompt.contains("assistant: Mara moved to Portland"))
        #expect(prompt.contains("it is not new evidence"))
        #expect(prompt.contains("newest Owner text"))
    }
}

/// Replays canned replies, one per call (the last repeats), for extraction tests.
final class CannedChatClient: ChatClient {
    private let replies: [String]
    private let throwError: Bool
    var histories: [[ChatMessage]] = []

    convenience init(reply: String, throwError: Bool = false) {
        self.init(replies: [reply], throwError: throwError)
    }

    init(replies: [String], throwError: Bool = false) {
        self.replies = replies
        self.throwError = throwError
    }

    func streamChat(
        history: [ChatMessage],
        onStatus: (String) -> Void,
        onToolCall: (ChatToolCall) async -> ChatToolResult,
        onImages: (ChatImageBatch) -> Void,
        onToken: (String) -> Void
    ) async throws {
        histories.append(history)
        if throwError { throw URLError(.notConnectedToInternet) }
        onToken(replies[min(histories.count - 1, replies.count - 1)])
    }
}
