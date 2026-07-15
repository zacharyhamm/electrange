import Foundation

@MainActor
final class ChatToolRouter {
    private let reminderExecutor: any ReminderToolExecuting
    private let notesExecutor: any NotesToolExecuting
    private let desktopExecutor: any DesktopToolExecuting
    private let timerExecutor: any TimerToolExecuting
    private let gmailExecutor: any GmailToolExecuting
    private let calendarExecutor: any CalendarToolExecuting

    init(
        reminderExecutor: any ReminderToolExecuting,
        notesExecutor: any NotesToolExecuting,
        desktopExecutor: any DesktopToolExecuting,
        timerExecutor: any TimerToolExecuting,
        gmailExecutor: (any GmailToolExecuting)? = nil,
        calendarExecutor: (any CalendarToolExecuting)? = nil
    ) {
        self.reminderExecutor = reminderExecutor
        self.notesExecutor = notesExecutor
        self.desktopExecutor = desktopExecutor
        self.timerExecutor = timerExecutor
        self.gmailExecutor = gmailExecutor ?? GmailToolService()
        self.calendarExecutor = calendarExecutor ?? CalendarToolService()
    }

    func execute(
        _ call: ChatToolCall,
        confirm: (ToolConfirmationDetails) async -> Bool,
        onStatus: (String) -> Void
    ) async -> ChatToolResult {
        guard let definition = ChatToolRegistry.definition(named: call.name),
              definition.family != .webSearch else {
            return .error("Unknown tool ‘\(call.name)’.")
        }

        switch definition.family {
        case .reminders:
            return await executeReminder(call, definition: definition, confirm: confirm, onStatus: onStatus)
        case .notes:
            return await executeNote(call, definition: definition, confirm: confirm, onStatus: onStatus)
        case .desktop:
            return await executeDesktop(call, definition: definition, confirm: confirm, onStatus: onStatus)
        case .timers:
            return await executeTimer(call, definition: definition, confirm: confirm, onStatus: onStatus)
        case .gmail:
            return await executeGmail(call, definition: definition, confirm: confirm, onStatus: onStatus)
        case .calendar:
            return await executeCalendar(call, definition: definition, confirm: confirm, onStatus: onStatus)
        case .webSearch:
            return .error("Unknown tool ‘\(call.name)’.")
        }
    }

    private func executeReminder(
        _ call: ChatToolCall,
        definition: ChatToolDefinition,
        confirm: (ToolConfirmationDetails) async -> Bool,
        onStatus: (String) -> Void
    ) async -> ChatToolResult {
        let request: ReminderToolRequest
        do {
            request = try ReminderToolRequest(toolCall: call)
        } catch ReminderRequestError.missingArgument(let name) {
            return .error("The ‘\(name)’ argument is required.")
        } catch ReminderRequestError.invalidCompletion {
            return .error("Reminder completion must be incomplete, completed, or all.")
        } catch ReminderRequestError.noChanges {
            return .error("At least one reminder change is required.")
        } catch {
            return .error("That reminder request was invalid.")
        }
        guard await approve(reminderExecutor.confirmationDetails(for: request), using: confirm) else {
            return Self.cancelledResult
        }
        onStatus(definition.executionStatus)
        return await reminderExecutor.execute(request)
    }

    private func executeNote(
        _ call: ChatToolCall,
        definition: ChatToolDefinition,
        confirm: (ToolConfirmationDetails) async -> Bool,
        onStatus: (String) -> Void
    ) async -> ChatToolResult {
        let request: NoteToolRequest
        do {
            request = try NoteToolRequest(toolCall: call)
        } catch NoteToolError.missingArgument(let name) {
            return .error("The ‘\(name)’ argument is required.")
        } catch NoteToolError.noChanges {
            return .error("At least one note change is required.")
        } catch {
            return .error("That Notes request was invalid.")
        }
        guard await approve(notesExecutor.confirmationDetails(for: request), using: confirm) else {
            return Self.cancelledResult
        }
        onStatus(definition.executionStatus)
        return await notesExecutor.execute(request)
    }

    private func executeDesktop(
        _ call: ChatToolCall,
        definition: ChatToolDefinition,
        confirm: (ToolConfirmationDetails) async -> Bool,
        onStatus: (String) -> Void
    ) async -> ChatToolResult {
        let request: DesktopToolRequest
        do {
            request = try DesktopToolRequest(toolCall: call)
        } catch DesktopToolError.missingArgument(let name) {
            return .error("The ‘\(name)’ argument is required.")
        } catch DesktopToolError.invalidWebURL {
            return .error("Only complete HTTP and HTTPS web addresses can be opened.")
        } catch {
            return .error("That tool request was invalid.")
        }
        guard await approve(desktopExecutor.confirmationDetails(for: request), using: confirm) else {
            return Self.cancelledResult
        }
        onStatus(definition.executionStatus)
        return await desktopExecutor.execute(request)
    }

    private func executeTimer(
        _ call: ChatToolCall,
        definition: ChatToolDefinition,
        confirm: (ToolConfirmationDetails) async -> Bool,
        onStatus: (String) -> Void
    ) async -> ChatToolResult {
        let request: TimerToolRequest
        do {
            request = try TimerToolRequest(toolCall: call)
        } catch TimerToolError.missingArgument(let name) {
            return .error("The ‘\(name)’ argument is required.")
        } catch TimerToolError.invalidDuration {
            return .error("Timer duration must be a whole number from 1 second to 7 days.")
        } catch {
            return .error("That timer request was invalid.")
        }
        guard await approve(timerExecutor.confirmationDetails(for: request), using: confirm) else {
            return Self.cancelledResult
        }
        onStatus(definition.executionStatus)
        return await timerExecutor.execute(request)
    }

    private func executeGmail(
        _ call: ChatToolCall,
        definition: ChatToolDefinition,
        confirm: (ToolConfirmationDetails) async -> Bool,
        onStatus: (String) -> Void
    ) async -> ChatToolResult {
        let request: GmailToolRequest
        do {
            request = try GmailToolRequest(toolCall: call)
        } catch let error as GmailToolError {
            return .error(error.localizedDescription)
        } catch {
            return .error("That Gmail request was invalid.")
        }

        let prepared: GmailPreparedRequest
        do {
            prepared = try await gmailExecutor.prepare(request)
        } catch {
            return .error(error.localizedDescription)
        }
        guard await approve(prepared.confirmation, using: confirm) else {
            return Self.cancelledResult
        }
        onStatus(definition.executionStatus)
        return await gmailExecutor.execute(prepared)
    }

    private func executeCalendar(
        _ call: ChatToolCall,
        definition: ChatToolDefinition,
        confirm: (ToolConfirmationDetails) async -> Bool,
        onStatus: (String) -> Void
    ) async -> ChatToolResult {
        let request: CalendarToolRequest
        do {
            request = try CalendarToolRequest(toolCall: call)
        } catch let error as CalendarToolError {
            return .error(error.localizedDescription)
        } catch {
            return .error("That Google Calendar request was invalid.")
        }

        let prepared: CalendarPreparedRequest
        do {
            prepared = try await calendarExecutor.prepare(request)
        } catch {
            return .error(error.localizedDescription)
        }
        guard await approve(prepared.confirmation, using: confirm) else {
            return Self.cancelledResult
        }
        onStatus(definition.executionStatus)
        return await calendarExecutor.execute(prepared)
    }

    private func approve(
        _ details: ToolConfirmationDetails?,
        using confirm: (ToolConfirmationDetails) async -> Bool
    ) async -> Bool {
        guard let details else { return true }
        return await confirm(details)
    }

    private static let cancelledResult = ChatToolResult(response: [
        "status": .string("cancelled"),
        "message": .string("The owner cancelled this action."),
    ])
}
