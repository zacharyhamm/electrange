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
        let router = makeRouter(reminders, notes, desktop, timers)
        var statuses: [String] = []

        _ = await router.execute(call("list_reminders"), confirm: { _ in true }, onStatus: { statuses.append($0) })
        _ = await router.execute(call("list_notes"), confirm: { _ in true }, onStatus: { statuses.append($0) })
        _ = await router.execute(call("find_files", ["query": .string("song")]), confirm: { _ in true }, onStatus: { statuses.append($0) })
        _ = await router.execute(call("list_timers"), confirm: { _ in true }, onStatus: { statuses.append($0) })

        #expect(reminders.executed.count == 1)
        #expect(notes.executed.count == 1)
        #expect(desktop.executed.count == 1)
        #expect(timers.executed.count == 1)
        #expect(statuses == [
            "Reading reminders…", "Reading Notes…",
            "Searching approved folders…", "Reading timers…",
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

    private func makeRouter(
        _ reminders: MockReminderExecutor,
        _ notes: MockNotesExecutor,
        _ desktop: MockDesktopExecutor,
        _ timers: MockTimerExecutor
    ) -> ChatToolRouter {
        ChatToolRouter(
            reminderExecutor: reminders,
            notesExecutor: notes,
            desktopExecutor: desktop,
            timerExecutor: timers
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
