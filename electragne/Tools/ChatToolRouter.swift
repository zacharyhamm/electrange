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
        let gmail = gmailExecutor ?? GmailToolService()
        let calendar = calendarExecutor ?? CalendarToolService()
        let slack = slackExecutor ?? SlackToolService()
        let linear = linearExecutor ?? LinearToolService()
        executors = [
            .reminders: ToolAdapter.sync(
                parse: ReminderToolRequest.init(toolCall:),
                confirm: reminderExecutor.confirmationDetails(for:),
                execute: reminderExecutor.execute(_:)
            ),
            .notes: ToolAdapter.sync(
                parse: NoteToolRequest.init(toolCall:),
                confirm: notesExecutor.confirmationDetails(for:),
                execute: notesExecutor.execute(_:)
            ),
            .desktop: ToolAdapter.sync(
                parse: DesktopToolRequest.init(toolCall:),
                confirm: desktopExecutor.confirmationDetails(for:),
                execute: desktopExecutor.execute(_:)
            ),
            .timers: ToolAdapter.sync(
                parse: TimerToolRequest.init(toolCall:),
                confirm: timerExecutor.confirmationDetails(for:),
                execute: timerExecutor.execute(_:)
            ),
            .slack: ToolAdapter.sync(
                parse: { try SlackToolRequest(toolCall: $0) },
                confirm: slack.confirmationDetails(for:),
                execute: slack.execute(_:)
            ),
            .linear: ToolAdapter.sync(
                parse: LinearToolRequest.init(toolCall:),
                confirm: linear.confirmationDetails(for:),
                execute: linear.execute(_:)
            ),
            // Google families prepare asynchronously: the confirmation card
            // may need a fetch first.
            .gmail: ToolAdapter { call in
                let prepared = try await gmail.prepare(GmailToolRequest(toolCall: call))
                return PreparedToolAction(
                    confirmation: prepared.confirmation,
                    execute: { await gmail.execute(prepared) }
                )
            },
            .calendar: ToolAdapter { call in
                let prepared = try await calendar.prepare(CalendarToolRequest(toolCall: call))
                return PreparedToolAction(
                    confirmation: prepared.confirmation,
                    execute: { await calendar.execute(prepared) }
                )
            },
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
