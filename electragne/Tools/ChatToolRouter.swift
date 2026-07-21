import Foundation

@MainActor
final class ChatToolRouter {
    private let executors: [ChatToolFamily: any ToolExecuting]
    private let mcpExecutor: any ToolExecuting

    convenience init(
        memoryEngine: MemoryEngine,
        calendarMonitor: CalendarReminderMonitor? = nil,
        automationEngine: AutomationEngine? = nil
    ) {
        self.init(
            reminderExecutor: AppleReminderService(),
            notesExecutor: AppleNotesService(),
            desktopExecutor: DesktopToolService(),
            timerExecutor: TimerToolService(),
            calendarMonitor: calendarMonitor,
            memoryExecutor: MemoryToolExecutor(engine: memoryEngine),
            automationEngine: automationEngine
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
        memoryExecutor: any ToolExecuting,
        automationEngine: AutomationEngine? = nil
    ) {
        self.mcpExecutor = mcpExecutor ?? MCPToolExecutor()
        let gmail = gmailExecutor ?? GmailToolService()
        let calendar = calendarExecutor ?? CalendarToolService()
        let slack = slackExecutor ?? SlackToolService()
        let linear = linearExecutor ?? LinearToolService()
        // The fallback engine is never started, but it must not share the live
        // store: a create through it would persist a record the real engine
        // picks up next tick. Give it a throwaway suite, wiped on construction.
        let automations = AutomationToolService(engine: automationEngine ?? {
            let suiteName = "org.impolexg.electragne.inert-automations"
            let inertDefaults = UserDefaults(suiteName: suiteName)!
            inertDefaults.removePersistentDomain(forName: suiteName)
            return AutomationEngine(defaults: inertDefaults)
        }())
        executors = [
            .automations: ToolAdapter.sync(
                parse: AutomationToolRequest.init(toolCall:),
                confirm: automations.confirmationDetails(for:),
                execute: automations.execute(_:)
            ),
            // Closure literals rather than method references: an unapplied
            // method on an existential is a non-Sendable function value, which
            // warns when converted to the adapter's @MainActor parameters.
            .reminders: ToolAdapter.sync(
                parse: ReminderToolRequest.init(toolCall:),
                confirm: { reminderExecutor.confirmationDetails(for: $0) },
                execute: { await reminderExecutor.execute($0) }
            ),
            .notes: ToolAdapter.sync(
                parse: NoteToolRequest.init(toolCall:),
                confirm: { notesExecutor.confirmationDetails(for: $0) },
                execute: { await notesExecutor.execute($0) }
            ),
            .desktop: ToolAdapter.sync(
                parse: DesktopToolRequest.init(toolCall:),
                confirm: { desktopExecutor.confirmationDetails(for: $0) },
                execute: { await desktopExecutor.execute($0) }
            ),
            .timers: ToolAdapter.sync(
                parse: TimerToolRequest.init(toolCall:),
                confirm: { timerExecutor.confirmationDetails(for: $0) },
                execute: { await timerExecutor.execute($0) }
            ),
            .slack: ToolAdapter.sync(
                parse: { try SlackToolRequest(toolCall: $0) },
                confirm: { slack.confirmationDetails(for: $0) },
                execute: { await slack.execute($0) }
            ),
            .linear: ToolAdapter.sync(
                parse: LinearToolRequest.init(toolCall:),
                confirm: { linear.confirmationDetails(for: $0) },
                execute: { await linear.execute($0) }
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
