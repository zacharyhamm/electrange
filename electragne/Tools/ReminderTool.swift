import EventKit
import Foundation

nonisolated struct ReminderRequest: Equatable, Sendable {
    let title: String
    let notes: String?
    let listName: String?
    let due: String?

    init(title: String, notes: String? = nil, listName: String? = nil, due: String? = nil) {
        self.title = title
        self.notes = notes
        self.listName = listName
        self.due = due
    }

    init(toolCall: ChatToolCall) throws {
        guard toolCall.name == "create_reminder" else {
            throw ReminderRequestError.unsupportedTool(toolCall.name)
        }
        let title = toolCall.arguments["title"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { throw ReminderRequestError.missingTitle }
        self.title = title
        self.notes = Self.trimmed(toolCall.arguments["notes"]?.stringValue)
        self.listName = Self.trimmed(toolCall.arguments["listName"]?.stringValue)
        self.due = Self.trimmed(toolCall.arguments["due"]?.stringValue)
    }

    static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

nonisolated struct ReminderListRequest: Equatable, Sendable {
    enum Completion: String, Equatable, Sendable { case incomplete, completed, all }
    let query: String?
    let listName: String?
    let completion: Completion
    let limit: Int
}

nonisolated struct ReminderUpdateRequest: Equatable, Sendable {
    let identifier: String
    let title: String?
    let notes: String?
    let clearNotes: Bool
    let listName: String?
    let due: String?
    let clearDue: Bool
    let completed: Bool?
}

nonisolated enum ReminderToolRequest: Equatable, Sendable {
    case create(ReminderRequest)
    case list(ReminderListRequest)
    case update(ReminderUpdateRequest)
    case delete(identifier: String)

    init(toolCall: ChatToolCall) throws {
        func required(_ key: String) throws -> String {
            guard let value = ReminderRequest.trimmed(toolCall.arguments[key]?.stringValue) else {
                throw ReminderRequestError.missingArgument(key)
            }
            return value
        }
        switch toolCall.name {
        case "create_reminder":
            self = .create(try ReminderRequest(toolCall: toolCall))
        case "list_reminders":
            let rawCompletion = ReminderRequest.trimmed(toolCall.arguments["completion"]?.stringValue)?
                .lowercased() ?? "incomplete"
            guard let completion = ReminderListRequest.Completion(rawValue: rawCompletion) else {
                throw ReminderRequestError.invalidCompletion(rawCompletion)
            }
            let limit = max(1, min(Int(toolCall.arguments["limit"]?.numberValue ?? 20), 50))
            self = .list(ReminderListRequest(
                query: ReminderRequest.trimmed(toolCall.arguments["query"]?.stringValue),
                listName: ReminderRequest.trimmed(toolCall.arguments["listName"]?.stringValue),
                completion: completion,
                limit: limit
            ))
        case "update_reminder":
            let identifier = try required("identifier")
            let request = ReminderUpdateRequest(
                identifier: identifier,
                title: ReminderRequest.trimmed(toolCall.arguments["title"]?.stringValue),
                notes: ReminderRequest.trimmed(toolCall.arguments["notes"]?.stringValue),
                clearNotes: toolCall.arguments["clearNotes"]?.boolValue ?? false,
                listName: ReminderRequest.trimmed(toolCall.arguments["listName"]?.stringValue),
                due: ReminderRequest.trimmed(toolCall.arguments["due"]?.stringValue),
                clearDue: toolCall.arguments["clearDue"]?.boolValue ?? false,
                completed: toolCall.arguments["completed"]?.boolValue
            )
            guard request.title != nil || request.notes != nil || request.clearNotes
                    || request.listName != nil || request.due != nil || request.clearDue
                    || request.completed != nil else {
                throw ReminderRequestError.noChanges
            }
            self = .update(request)
        case "delete_reminder":
            self = .delete(identifier: try required("identifier"))
        default:
            throw ReminderRequestError.unsupportedTool(toolCall.name)
        }
    }
}

nonisolated enum ReminderRequestError: LocalizedError, Equatable {
    case unsupportedTool(String)
    case missingTitle
    case missingArgument(String)
    case invalidCompletion(String)
    case noChanges

    var errorDescription: String? {
        switch self {
        // missingTitle and unsupportedTool keep the wording the router's
        // former generic catch produced for them.
        case .unsupportedTool, .missingTitle: "That reminder request was invalid."
        case .missingArgument(let name): "The ‘\(name)’ argument is required."
        case .invalidCompletion: "Reminder completion must be incomplete, completed, or all."
        case .noChanges: "At least one reminder change is required."
        }
    }
}

nonisolated enum ParsedReminderDue: Equatable, Sendable {
    case allDay(DateComponents)
    case timed(DateComponents)
}

nonisolated enum ReminderDateParser {
    static func parse(_ value: String, timeZone: TimeZone = .current) -> ParsedReminderDue? {
        let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
        if pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2,
           pieces[2].count == 2, let year = Int(pieces[0]), let month = Int(pieces[1]),
           let day = Int(pieces[2]) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let components = DateComponents(year: year, month: month, day: day)
            guard let date = calendar.date(from: components) else { return nil }
            let checked = calendar.dateComponents([.year, .month, .day], from: date)
            guard checked.year == year, checked.month == month, checked.day == day else { return nil }
            return .allDay(components)
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        guard let date = fractional.date(from: value) ?? standard.date(from: value) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        components.timeZone = timeZone
        return .timed(components)
    }
}

@MainActor
protocol ReminderToolExecuting {
    func confirmationDetails(for request: ReminderToolRequest) -> ToolConfirmationDetails?
    func execute(_ request: ReminderToolRequest) async -> ChatToolResult
}

@MainActor
final class AppleReminderService: ReminderToolExecuting {
    private let store: EKEventStore
    private let timeZone: TimeZone

    init(store: EKEventStore = EKEventStore(), timeZone: TimeZone = .current) {
        self.store = store
        self.timeZone = timeZone
    }

    func confirmationDetails(for request: ReminderToolRequest) -> ToolConfirmationDetails? {
        switch request {
        case .list:
            return nil
        case .create(let value):
            return ToolConfirmationDetails(
                title: "Create this reminder?", primaryText: value.title,
                details: [("List", value.listName ?? "Default"), ("Due", value.due ?? "None"),
                          ("Notes", value.notes ?? "None")].filter { $0.1 != "None" },
                actionLabel: "Create"
            )
        case .update(let value):
            let reminder = store.calendarItem(withIdentifier: value.identifier) as? EKReminder
            return ToolConfirmationDetails(
                title: "Update this reminder?",
                primaryText: reminder?.title ?? "Selected reminder",
                details: updateSummary(value), actionLabel: "Update"
            )
        case .delete(let identifier):
            let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder
            return ToolConfirmationDetails(
                title: "Delete this reminder?",
                primaryText: reminder?.title ?? "Selected reminder",
                details: reminder.map { [("List", $0.calendar.title)] } ?? [],
                actionLabel: "Delete"
            )
        }
    }

    func execute(_ request: ReminderToolRequest) async -> ChatToolResult {
        guard await ensureAccess() else {
            return .make(status: "permission_denied", message: "Reminders access was denied. Enable it in System Settings > Privacy & Security > Reminders.")
        }
        switch request {
        case .create(let value): return create(value)
        case .list(let value): return await list(value)
        case .update(let value): return update(value)
        case .delete(let identifier): return delete(identifier)
        }
    }

    private func ensureAccess() async -> Bool {
        do {
            switch EKEventStore.authorizationStatus(for: .reminder) {
            case .notDetermined: return try await store.requestFullAccessToReminders()
            case .fullAccess, .authorized: return true
            default: return false
            }
        } catch { return false }
    }

    private func create(_ request: ReminderRequest) -> ChatToolResult {
        guard let calendar = calendar(named: request.listName) else {
            return .make(status: "validation_error", message: request.listName == nil
                ? "Apple Reminders has no default list available."
                : "No unique Reminders list named ‘\(request.listName!)’ exists.")
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = request.title
        reminder.notes = request.notes
        reminder.calendar = calendar
        if let due = request.due {
            guard applyDue(due, to: reminder) else {
                return .make(status: "validation_error", message: "The due date ‘\(due)’ is invalid.")
            }
        }
        do {
            try store.save(reminder, commit: true)
            return reminderResult(reminder, status: "created", message: "Created ‘\(request.title)’ in ‘\(calendar.title)’.")
        } catch {
            return .make(status: "error", message: "The reminder could not be saved: \(error.localizedDescription)")
        }
    }

    private func list(_ request: ReminderListRequest) async -> ChatToolResult {
        let calendars: [EKCalendar]?
        if let listName = request.listName {
            guard let selected = calendar(named: listName) else {
                return .make(status: "validation_error", message: "No unique Reminders list named ‘\(listName)’ exists.")
            }
            calendars = [selected]
        } else { calendars = nil }
        let predicate = store.predicateForReminders(in: calendars)
        let reminders: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
        }
        let query = request.query?.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let filtered = reminders.filter { reminder in
            let completionMatches = request.completion == .all
                || (request.completion == .completed) == reminder.isCompleted
            guard completionMatches, let query else { return completionMatches }
            let text = [reminder.title, reminder.notes ?? ""].joined(separator: " ")
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return text.contains(query)
        }.sorted { lhs, rhs in
            let lhsDate = date(from: lhs.dueDateComponents) ?? .distantFuture
            let rhsDate = date(from: rhs.dueDateComponents) ?? .distantFuture
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        let results = filtered.prefix(request.limit).map { reminder -> ChatToolValue in
            .object(reminderFields(reminder))
        }
        return ChatToolResult(response: [
            "status": .string(results.isEmpty ? "not_found" : "found"),
            "count": .number(Double(results.count)), "results": .array(Array(results)),
            "message": .string(results.isEmpty ? "No matching reminders were found." : "Found \(results.count) reminders."),
        ])
    }

    private func update(_ request: ReminderUpdateRequest) -> ChatToolResult {
        guard let reminder = store.calendarItem(withIdentifier: request.identifier) as? EKReminder else {
            return .make(status: "not_found", message: "That reminder no longer exists. List reminders again.")
        }
        if let title = request.title { reminder.title = title }
        if request.clearNotes { reminder.notes = nil } else if let notes = request.notes { reminder.notes = notes }
        if let listName = request.listName {
            guard let calendar = calendar(named: listName) else {
                return .make(status: "validation_error", message: "No unique Reminders list named ‘\(listName)’ exists.")
            }
            reminder.calendar = calendar
        }
        if request.clearDue {
            reminder.dueDateComponents = nil
            reminder.alarms?.forEach(reminder.removeAlarm)
        } else if let due = request.due, !applyDue(due, to: reminder) {
            return .make(status: "validation_error", message: "The due date ‘\(due)’ is invalid.")
        }
        if let completed = request.completed { reminder.isCompleted = completed }
        do {
            try store.save(reminder, commit: true)
            return reminderResult(reminder, status: "updated", message: "Updated ‘\(reminder.title ?? "Untitled")’.")
        } catch {
            return .make(status: "error", message: "The reminder could not be updated: \(error.localizedDescription)")
        }
    }

    private func delete(_ identifier: String) -> ChatToolResult {
        guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
            return .make(status: "not_found", message: "That reminder no longer exists. List reminders again.")
        }
        let title = reminder.title ?? "Untitled"
        do {
            try store.remove(reminder, commit: true)
            return .make(status: "deleted", message: "Deleted ‘\(title)’.")
        } catch {
            return .make(status: "error", message: "The reminder could not be deleted: \(error.localizedDescription)")
        }
    }

    private func calendar(named name: String?) -> EKCalendar? {
        guard let name else { return store.defaultCalendarForNewReminders() }
        let matches = store.calendars(for: .reminder).filter {
            $0.title.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func applyDue(_ due: String, to reminder: EKReminder) -> Bool {
        guard let parsed = ReminderDateParser.parse(due, timeZone: timeZone) else { return false }
        reminder.alarms?.forEach(reminder.removeAlarm)
        switch parsed {
        case .allDay(let components):
            reminder.dueDateComponents = components
            reminder.timeZone = nil
        case .timed(let components):
            reminder.dueDateComponents = components
            reminder.timeZone = timeZone
            if let alarmDate = date(from: components) { reminder.addAlarm(EKAlarm(absoluteDate: alarmDate)) }
        }
        return true
    }

    private func date(from components: DateComponents?) -> Date? {
        guard let components else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = components.timeZone ?? timeZone
        return calendar.date(from: components)
    }

    private func reminderFields(_ reminder: EKReminder) -> [String: ChatToolValue] {
        var fields: [String: ChatToolValue] = [
            "identifier": .string(reminder.calendarItemIdentifier), "title": .string(reminder.title),
            "listName": .string(reminder.calendar.title), "completed": .bool(reminder.isCompleted),
        ]
        if let notes = reminder.notes, !notes.isEmpty { fields["notes"] = .string(notes) }
        if let due = reminder.dueDateComponents {
            fields["due"] = .string(Self.format(components: due, allDay: reminder.timeZone == nil))
        }
        return fields
    }

    private func reminderResult(_ reminder: EKReminder, status: String, message: String) -> ChatToolResult {
        var response = reminderFields(reminder)
        response["status"] = .string(status)
        response["message"] = .string(message)
        return ChatToolResult(response: response)
    }

    private func updateSummary(_ request: ReminderUpdateRequest) -> [(label: String, value: String)] {
        var details: [(String, String)] = []
        if let title = request.title { details.append(("Title", title)) }
        if let notes = request.notes { details.append(("Notes", notes)) }
        if request.clearNotes { details.append(("Notes", "Remove")) }
        if let list = request.listName { details.append(("List", list)) }
        if let due = request.due { details.append(("Due", due)) }
        if request.clearDue { details.append(("Due", "Remove")) }
        if let completed = request.completed { details.append(("Completed", completed ? "Yes" : "No")) }
        return details
    }

    nonisolated private static func format(components: DateComponents, allDay: Bool) -> String {
        guard let year = components.year, let month = components.month, let day = components.day else { return "Unknown" }
        let date = String(format: "%04d-%02d-%02d", year, month, day)
        guard !allDay, let hour = components.hour, let minute = components.minute else { return date }
        return date + String(format: "T%02d:%02d", hour, minute)
    }

}
