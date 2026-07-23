import Foundation
import Testing
@testable import electragne

@MainActor
struct ChatBubbleWindowControllerTests {
    @Test func terminalWidthsAreRememberedPerChat() {
        let controller = makeController(client: ControlledChatClient())
        let first = UUID()
        let second = UUID()

        #expect(controller.terminalWidth(for: first, initialHeight: 200) == 300)
        controller.rememberTerminalWidth(425, for: first)

        #expect(controller.terminalWidth(for: first, initialHeight: 200) == 425)
        #expect(controller.terminalWidth(for: second, initialHeight: 200) == 300)
    }

    @Test func calendarSummaryDisablesToolsWithoutAJoinURL() async {
        let client = ControlledChatClient(attemptToolCall: true)
        let controller = makeController(client: client)

        controller.startProactiveConversation(prompt(id: "one", summary: "Planning"))
        await waitUntil { client.toolResultMessages.count == 1 }

        #expect(client.toolResultMessages == [
            "Tools are disabled in this proactive conversation."
        ])
    }

    @Test func overlappingCalendarSummariesRunInFIFOOrder() async {
        let client = ControlledChatClient(suspendFirstRequest: true)
        let controller = makeController(client: client)

        controller.startProactiveConversation(prompt(id: "one", summary: "First"))
        await waitUntil { client.canResumeFirstRequest }
        controller.startProactiveConversation(prompt(id: "two", summary: "Second"))
        await Task.yield()

        #expect(client.histories.count == 1)

        client.resumeFirstRequest()
        await waitUntil { client.histories.count == 2 }

        #expect(client.histories[0].last?.content.contains("Title: First") == true)
        #expect(client.histories[1].last?.content.contains("Title: Second") == true)
        #expect(!client.firstRequestWasCancelled)
    }

    private func makeController(client: ControlledChatClient) -> ChatBubbleWindowController {
        let memoryEngine = MemoryEngine(store: MemoryStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
        ))
        return ChatBubbleWindowController(
            ollamaClient: client,
            geminiClient: client,
            toolRouter: ChatToolRouter(memoryEngine: memoryEngine),
            chatStore: ChatStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)),
            memoryEngine: memoryEngine
        )
    }

    private func prompt(id: String, summary: String) -> ChatBubbleWindowController.ProactivePrompt {
        let event = event(id: id, summary: summary)
        return .init(title: event.summary, prompt: event.reminderPrompt, joinURL: event.joinURL)
    }

    private func event(id: String, summary: String) -> CalendarEventDetails {
        let start = Date().addingTimeInterval(180)
        return CalendarEventDetails(
            id: id, summary: summary, start: start,
            end: start.addingTimeInterval(3600), isAllDay: false,
            description: nil, location: nil, status: "confirmed",
            attendees: [], calendarURL: nil, hangoutURL: nil,
            conferenceURLs: []
        )
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() {
            await Task.yield()
        }
        #expect(condition())
    }
}

@MainActor
private final class ControlledChatClient: ChatClient {
    private let attemptToolCall: Bool
    private let suspendFirstRequest: Bool
    private var firstContinuation: CheckedContinuation<Void, Never>?

    var histories: [[ChatMessage]] = []
    var toolResultMessages: [String] = []
    var firstRequestWasCancelled = false
    var canResumeFirstRequest: Bool { firstContinuation != nil }

    init(attemptToolCall: Bool = false, suspendFirstRequest: Bool = false) {
        self.attemptToolCall = attemptToolCall
        self.suspendFirstRequest = suspendFirstRequest
    }

    func streamChat(
        history: [ChatMessage],
        onStatus: (String) -> Void,
        onToolCall: (ChatToolCall) async -> ChatToolResult,
        onImages: (ChatImageBatch) -> Void,
        onToken: (String) -> Void
    ) async throws {
        histories.append(history)
        if attemptToolCall {
            let result = await onToolCall(ChatToolCall(
                id: "injected", name: "untrusted_tool", arguments: [:]
            ))
            toolResultMessages.append(result.response["message"]?.stringValue ?? "")
        }
        if suspendFirstRequest && histories.count == 1 {
            await withCheckedContinuation { firstContinuation = $0 }
            firstRequestWasCancelled = Task.isCancelled
        }
        onToken("Summary")
    }

    func resumeFirstRequest() {
        firstContinuation?.resume()
        firstContinuation = nil
    }
}
