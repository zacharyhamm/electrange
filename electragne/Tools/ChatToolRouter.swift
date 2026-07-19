import Foundation

@MainActor
final class ChatToolRouter {
    private let executors: [ChatToolFamily: any ToolExecuting]
    private let mcpExecutor: any ToolExecuting

    convenience init(
        memoryEngine: MemoryEngine,
        calendarMonitor: CalendarReminderMonitor? = nil
    ) {
        self.init(
            reminderExecutor: AppleReminderService(),
            notesExecutor: AppleNotesService(),
            desktopExecutor: DesktopToolService(),
            timerExecutor: TimerToolService(),
            calendarMonitor: calendarMonitor,
            memoryExecutor: MemoryToolExecutor(engine: memoryEngine)
        )
    }

    init(
        reminderExecutor: any ReminderToolExecuting,
        notesExecutor: any NotesToolExecuting,
        desktopExecutor: any DesktopToolExecuting,
        timerExecutor: any TimerToolExecuting,
        gmailExecutor: (any GmailToolExecuting)? = nil,
        calendarExecutor: (any CalendarToolExecuting)? = nil,
        slackExecutor: (any SlackToolExecuting)? = nil,
        linearExecutor: (any LinearToolExecuting)? = nil,
        webSearchExecutor: (any ToolExecuting)? = nil,
        mcpExecutor: (any ToolExecuting)? = nil,
        calendarMonitor: CalendarReminderMonitor? = nil,
        statusExecutor: (any ToolExecuting)? = nil,
        memoryExecutor: any ToolExecuting
    ) {
        self.mcpExecutor = mcpExecutor ?? MCPToolExecutor()
        executors = [
            .reminders: ReminderToolAdapter(reminderExecutor),
            .notes: NotesToolAdapter(notesExecutor),
            .desktop: DesktopToolAdapter(desktopExecutor),
            .timers: TimerToolAdapter(timerExecutor),
            .gmail: GmailToolAdapter(gmailExecutor ?? GmailToolService()),
            .calendar: CalendarToolAdapter(calendarExecutor ?? CalendarToolService()),
            .slack: SlackToolAdapter(slackExecutor ?? SlackToolService()),
            .linear: LinearToolAdapter(linearExecutor ?? LinearToolService()),
            .webSearch: webSearchExecutor ?? WebSearchExecutor(),
            .status: statusExecutor ?? AppStatusExecutor(monitor: calendarMonitor),
            .memory: memoryExecutor,
        ]
    }

    func execute(
        _ call: ChatToolCall,
        confirm: (ToolConfirmationDetails) async -> Bool,
        onStatus: (String) -> Void
    ) async -> ChatToolResult {
        let result = await perform(call, confirm: confirm, onStatus: onStatus)
        await LLMLog.shared.append(kind: "tool", [
            "name": .string(call.name),
            "arguments": .object(call.arguments),
            "response": .object(result.response),
        ])
        return result
    }

    private func perform(
        _ call: ChatToolCall,
        confirm: (ToolConfirmationDetails) async -> Bool,
        onStatus: (String) -> Void
    ) async -> ChatToolResult {
        let executor: any ToolExecuting
        let executionStatus: String
        if call.name.hasPrefix("mcp__") {
            executor = mcpExecutor
            executionStatus = "Running \(MCPToolCatalog.descriptor(named: call.name)?.toolName ?? call.name)…"
        } else if let definition = ChatToolRegistry.definition(named: call.name),
                  let familyExecutor = executors[definition.family] {
            executor = familyExecutor
            executionStatus = definition.executionStatus
        } else {
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
        onStatus(executionStatus)
        return await action.execute()
    }

    private static let cancelledResult = ChatToolResult(response: [
        "status": .string("cancelled"),
        "message": .string("The owner cancelled this action."),
    ])
}
