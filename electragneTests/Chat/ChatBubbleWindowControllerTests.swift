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

    @Test func automationUpdateReturnsToItsOriginatingChat() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChatStore(directory: directory)
        let chat = StoredChat(
            title: "Build",
            messages: [ChatMessage(role: "user", content: "Watch this build.")]
        )
        store.save(chat)
        let client = ControlledChatClient()
        let memoryEngine = MemoryEngine(store: MemoryStore(
            directory: directory.appendingPathComponent("memory")
        ))
        let controller = ChatBubbleWindowController(
            ollamaClient: client,
            geminiClient: client,
            toolRouter: ChatToolRouter(memoryEngine: memoryEngine),
            chatStore: store,
            memoryEngine: memoryEngine
        )

        let accepted = controller.startProactiveConversation(.init(
            title: "Build watch",
            prompt: "The build failed.",
            targetChatID: chat.id,
            source: .init(automationID: "automation", runID: "run", name: "Build watch")
        ))
        await waitUntil { store.load(id: chat.id)?.messages.last?.role == "assistant" }

        let saved = try #require(store.load(id: chat.id))
        #expect(accepted)
        #expect(store.listSummaries().count == 1)
        #expect(saved.messages[saved.messages.count - 2].source?.automationID == "automation")
        #expect(saved.messages.last?.content == "Summary")
    }

    @Test func shownToolCallsPersistAndStayOffTheWire() async throws {
        UserDefaults.standard.set(true, forKey: UserPreferences.verboseToolCallsKey)
        defer { UserDefaults.standard.removeObject(forKey: UserPreferences.verboseToolCallsKey) }
        let store = makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let client = ControlledChatClient(attemptToolCall: true)
        let controller = makeController(client: client, store: store)

        controller.startStream(userMessage: "poke a tool")
        await waitUntil { store.load(id: controller.currentChatID)?.messages.last?.role == "assistant" }

        let saved = try #require(store.load(id: controller.currentChatID))
        let toolMessage = try #require(saved.messages.first(where: { $0.role == "tool" }))
        #expect(toolMessage.content.contains("⚙ untrusted_tool"))
        #expect(toolMessage.content.contains("→"))

        // Memory extraction also calls the client, so find the second turn's
        // request by its user message rather than by index.
        controller.startStream(userMessage: "again")
        await waitUntil { client.histories.contains(where: { $0.last?.content == "again" }) }
        let wire = try #require(client.histories.first(where: { $0.last?.content == "again" }))
        #expect(wire.contains(where: { $0.role == "tool" }) == false)
    }

    @Test func confirmationDecisionIsRecordedInHistory() async throws {
        let store = makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let reminders = MockReminderExecutor()
        reminders.confirmation = ToolConfirmationDetails(
            title: "Create reminder “Feed sheep”",
            primaryText: "Feed sheep",
            details: [],
            actionLabel: "Create"
        )
        let client = ControlledChatClient(attemptToolCall: true)
        client.injectedCall = ChatToolCall(
            id: "r1", name: "create_reminder", arguments: ["title": .string("Feed sheep")]
        )
        let router = ChatToolRouter(
            reminderExecutor: reminders,
            notesExecutor: MockNotesExecutor(),
            desktopExecutor: MockDesktopExecutor(),
            timerExecutor: MockTimerExecutor(),
            memoryExecutor: MemoryToolExecutor(engine: makeMemoryEngine())
        )
        let controller = makeController(client: client, store: store, router: router)

        controller.startStream(userMessage: "remind me to feed the sheep")
        await waitUntil { controller.model.pendingToolConfirmation != nil }
        controller.resolveToolConfirmation(approved: true)
        await waitUntil { store.load(id: controller.currentChatID)?.messages.last?.role == "assistant" }

        let saved = try #require(store.load(id: controller.currentChatID))
        #expect(saved.messages.contains(
            where: { $0.role == "tool" && $0.content == "Create reminder “Feed sheep” — approved" }
        ))
        #expect(reminders.executed.count == 1)
    }

    private func makeTempStore() -> ChatStore {
        ChatStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
    }

    private func makeMemoryEngine() -> MemoryEngine {
        MemoryEngine(store: MemoryStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
        ))
    }

    private func makeController(
        client: ControlledChatClient,
        store: ChatStore? = nil,
        router: ChatToolRouter? = nil
    ) -> ChatBubbleWindowController {
        let memoryEngine = makeMemoryEngine()
        return ChatBubbleWindowController(
            ollamaClient: client,
            geminiClient: client,
            toolRouter: router ?? ChatToolRouter(memoryEngine: memoryEngine),
            chatStore: store ?? makeTempStore(),
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
    var injectedCall = ChatToolCall(id: "injected", name: "untrusted_tool", arguments: [:])
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
            let result = await onToolCall(injectedCall)
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
