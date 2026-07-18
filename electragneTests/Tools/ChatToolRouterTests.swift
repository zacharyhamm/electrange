import Foundation
import Testing
@testable import electragne

@MainActor
struct ChatToolRouterTests {
    @Test func dispatchesEveryLocalToolFamily() async {
        let reminders = MockReminderExecutor()
        let notes = MockNotesExecutor()
        let desktop = MockDesktopExecutor()
        let timers = MockTimerExecutor()
        let gmail = MockGmailExecutor()
        let calendar = MockCalendarExecutor()
        let router = makeRouter(reminders, notes, desktop, timers, gmail, calendar)
        var statuses: [String] = []

        _ = await router.execute(call("list_reminders"), confirm: { _ in true }, onStatus: { statuses.append($0) })
        _ = await router.execute(call("list_notes"), confirm: { _ in true }, onStatus: { statuses.append($0) })
        _ = await router.execute(call("find_files", ["query": .string("song")]), confirm: { _ in true }, onStatus: { statuses.append($0) })
        _ = await router.execute(call("list_timers"), confirm: { _ in true }, onStatus: { statuses.append($0) })
        _ = await router.execute(call("list_google_accounts"), confirm: { _ in true }, onStatus: { statuses.append($0) })
        _ = await router.execute(call("list_google_calendars"), confirm: { _ in true }, onStatus: { statuses.append($0) })

        #expect(reminders.executed.count == 1)
        #expect(notes.executed.count == 1)
        #expect(desktop.executed.count == 1)
        #expect(timers.executed.count == 1)
        #expect(gmail.executed.count == 1)
        #expect(calendar.executed.count == 1)
        #expect(statuses == [
            "Reading reminders…", "Reading Notes…",
            "Searching approved folders…", "Reading timers…", "Reading Google accounts…",
            "Reading Google Calendar…",
        ])
    }

    @Test func cancellationSkipsMutationExecution() async {
        let timers = MockTimerExecutor()
        timers.confirmation = ToolConfirmationDetails(
            title: "Start?", primaryText: "Tea", details: [], actionLabel: "Start"
        )
        let router = makeRouter(
            MockReminderExecutor(), MockNotesExecutor(), MockDesktopExecutor(), timers
        )

        let result = await router.execute(
            call("create_timer", ["durationSeconds": .number(60)]),
            confirm: { _ in false },
            onStatus: { _ in }
        )

        #expect(result.response["status"]?.stringValue == "cancelled")
        #expect(timers.executed.isEmpty)
    }

    @Test func everyRegistryToolResolvesToAnExecutor() async {
        // Each registered tool must dispatch to a real executor: the result
        // may be a validation error (no arguments were supplied), but never
        // the router's unknown-tool refusal.
        let router = makeRouter(
            MockReminderExecutor(), MockNotesExecutor(), MockDesktopExecutor(), MockTimerExecutor()
        )

        for definition in ChatToolRegistry.definitions {
            let result = await router.execute(
                call(definition.name), confirm: { _ in true }, onStatus: { _ in }
            )
            #expect(
                result.response["message"]?.stringValue != "Unknown tool ‘\(definition.name)’.",
                "\(definition.name) has no executor"
            )
        }
    }

    @Test func reportsUnknownToolsAndFamilyValidationErrors() async {
        let router = makeRouter(
            MockReminderExecutor(), MockNotesExecutor(), MockDesktopExecutor(), MockTimerExecutor()
        )

        let unknown = await router.execute(call("not_a_tool"), confirm: { _ in true }, onStatus: { _ in })
        let invalidTimer = await router.execute(
            call("create_timer", ["durationSeconds": .number(0)]),
            confirm: { _ in true }, onStatus: { _ in }
        )

        #expect(unknown.response["message"]?.stringValue == "Unknown tool ‘not_a_tool’.")
        #expect(invalidTimer.response["message"]?.stringValue
            == "Timer duration must be a whole number from 1 second to 7 days.")
    }

    @Test func injectedMemoryEngineIsImmediatelyVisibleToRecallTool() async {
        let engine = MemoryEngine(store: MemoryStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
        ))
        let router = ChatToolRouter(memoryEngine: engine)
        await engine.ingest(
            userText: "I like cobalt", assistantText: "Noted", chatID: UUID(),
            client: CannedChatClient(reply: #"{"ownerMemory":{"summary":"Owner likes cobalt"},"assistantOutcome":null}"#)
        )

        let result = await router.execute(
            call("recall_memory", ["query": .string("cobalt")]),
            confirm: { _ in true }, onStatus: { _ in }
        )

        #expect(result.response["memories"]?.stringValue?.contains("Owner likes cobalt") == true)
    }

    private func makeRouter(
        _ reminders: MockReminderExecutor,
        _ notes: MockNotesExecutor,
        _ desktop: MockDesktopExecutor,
        _ timers: MockTimerExecutor,
        _ gmail: MockGmailExecutor? = nil,
        _ calendar: MockCalendarExecutor? = nil
    ) -> ChatToolRouter {
        ChatToolRouter(
            reminderExecutor: reminders,
            notesExecutor: notes,
            desktopExecutor: desktop,
            timerExecutor: timers,
            gmailExecutor: gmail ?? MockGmailExecutor(),
            calendarExecutor: calendar ?? MockCalendarExecutor(),
            webSearchExecutor: MockWebSearchExecutor(),
            memoryExecutor: MemoryToolExecutor(engine: MemoryEngine(store: MemoryStore(
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
            )))
        )
    }

    private func call(
        _ name: String,
        _ arguments: [String: ChatToolValue] = [:]
    ) -> ChatToolCall {
        ChatToolCall(id: "test", name: name, arguments: arguments)
    }
}

@MainActor
private final class MockReminderExecutor: ReminderToolExecuting {
    var executed: [ReminderToolRequest] = []
    var confirmation: ToolConfirmationDetails?
    func confirmationDetails(for request: ReminderToolRequest) -> ToolConfirmationDetails? { confirmation }
    func execute(_ request: ReminderToolRequest) async -> ChatToolResult {
        executed.append(request)
        return ChatToolResult(response: ["status": .string("ok")])
    }
}

@MainActor
private final class MockNotesExecutor: NotesToolExecuting {
    var executed: [NoteToolRequest] = []
    var confirmation: ToolConfirmationDetails?
    func confirmationDetails(for request: NoteToolRequest) -> ToolConfirmationDetails? { confirmation }
    func execute(_ request: NoteToolRequest) async -> ChatToolResult {
        executed.append(request)
        return ChatToolResult(response: ["status": .string("ok")])
    }
}

@MainActor
private final class MockDesktopExecutor: DesktopToolExecuting {
    var executed: [DesktopToolRequest] = []
    var confirmation: ToolConfirmationDetails?
    func confirmationDetails(for request: DesktopToolRequest) -> ToolConfirmationDetails? { confirmation }
    func execute(_ request: DesktopToolRequest) async -> ChatToolResult {
        executed.append(request)
        return ChatToolResult(response: ["status": .string("ok")])
    }
}

@MainActor
private final class MockTimerExecutor: TimerToolExecuting {
    var executed: [TimerToolRequest] = []
    var confirmation: ToolConfirmationDetails?
    func confirmationDetails(for request: TimerToolRequest) -> ToolConfirmationDetails? { confirmation }
    func execute(_ request: TimerToolRequest) async -> ChatToolResult {
        executed.append(request)
        return ChatToolResult(response: ["status": .string("ok")])
    }
}

@MainActor
private final class MockWebSearchExecutor: ToolExecuting {
    var executed: [ChatToolCall] = []
    func prepare(_ call: ChatToolCall) async throws -> PreparedToolAction {
        PreparedToolAction(confirmation: nil, execute: { [weak self] in
            self?.executed.append(call)
            return ChatToolResult(response: ["status": .string("ok")])
        })
    }
}

@MainActor
private final class MockGmailExecutor: GmailToolExecuting {
    var executed: [GmailPreparedRequest] = []
    var confirmation: ToolConfirmationDetails?
    func prepare(_ request: GmailToolRequest) async throws -> GmailPreparedRequest {
        GmailPreparedRequest(request: request, account: nil, confirmation: confirmation)
    }
    func execute(_ prepared: GmailPreparedRequest) async -> ChatToolResult {
        executed.append(prepared)
        return ChatToolResult(response: ["status": .string("ok")])
    }
}

@MainActor
private final class MockCalendarExecutor: CalendarToolExecuting {
    var executed: [CalendarPreparedRequest] = []
    var confirmation: ToolConfirmationDetails?
    func prepare(_ request: CalendarToolRequest) async throws -> CalendarPreparedRequest {
        CalendarPreparedRequest(
            request: request,
            account: GoogleAccount(id: "a1", email: "one@example.com", displayName: nil),
            confirmation: confirmation
        )
    }
    func execute(_ prepared: CalendarPreparedRequest) async -> ChatToolResult {
        executed.append(prepared)
        return ChatToolResult(response: ["status": .string("ok")])
    }
}
