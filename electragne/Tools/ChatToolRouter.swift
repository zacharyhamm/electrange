import Foundation

@MainActor
final class ChatToolRouter {
    private let executors: [ChatToolFamily: any ToolExecuting]

    init(
        reminderExecutor: any ReminderToolExecuting,
        notesExecutor: any NotesToolExecuting,
        desktopExecutor: any DesktopToolExecuting,
        timerExecutor: any TimerToolExecuting,
        gmailExecutor: (any GmailToolExecuting)? = nil,
        calendarExecutor: (any CalendarToolExecuting)? = nil,
        webSearchExecutor: (any ToolExecuting)? = nil
    ) {
        executors = [
            .reminders: ReminderToolAdapter(reminderExecutor),
            .notes: NotesToolAdapter(notesExecutor),
            .desktop: DesktopToolAdapter(desktopExecutor),
            .timers: TimerToolAdapter(timerExecutor),
            .gmail: GmailToolAdapter(gmailExecutor ?? GmailToolService()),
            .calendar: CalendarToolAdapter(calendarExecutor ?? CalendarToolService()),
            .webSearch: webSearchExecutor ?? WebSearchExecutor(),
        ]
    }

    func execute(
        _ call: ChatToolCall,
        confirm: (ToolConfirmationDetails) async -> Bool,
        onStatus: (String) -> Void
    ) async -> ChatToolResult {
        guard let definition = ChatToolRegistry.definition(named: call.name),
              let executor = executors[definition.family] else {
            return .error("Unknown tool ‘\(call.name)’.")
        }

        let action: PreparedToolAction
        do {
            action = try await executor.prepare(call)
        } catch {
            return .error(error.localizedDescription)
        }

        if let confirmation = action.confirmation {
            guard await confirm(confirmation) else { return Self.cancelledResult }
        }
        onStatus(definition.executionStatus)
        return await action.execute()
    }

    private static let cancelledResult = ChatToolResult(response: [
        "status": .string("cancelled"),
        "message": .string("The owner cancelled this action."),
    ])
}
