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

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

nonisolated enum ReminderRequestError: Error, Equatable {
    case unsupportedTool(String)
    case missingTitle
}

nonisolated enum ParsedReminderDue: Equatable, Sendable {
    case allDay(DateComponents)
    case timed(DateComponents)
}

nonisolated enum ReminderDateParser {
    static func parse(_ value: String, timeZone: TimeZone = .current) -> ParsedReminderDue? {
        let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
        if pieces.count == 3,
           pieces[0].count == 4,
           pieces[1].count == 2,
           pieces[2].count == 2,
           let year = Int(pieces[0]),
           let month = Int(pieces[1]),
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
        guard let date = fractional.date(from: value) ?? standard.date(from: value) else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        components.timeZone = timeZone
        return .timed(components)
    }
}

@MainActor
protocol ReminderCreating {
    func createReminder(_ request: ReminderRequest) async -> ChatToolResult
}

/// EventKit implementation for the Apple Reminders database. One store is
/// retained for the service lifetime, as recommended by EventKit.
@MainActor
final class AppleReminderService: ReminderCreating {
    private let store: EKEventStore
    private let timeZone: TimeZone

    init(store: EKEventStore = EKEventStore(), timeZone: TimeZone = .current) {
        self.store = store
        self.timeZone = timeZone
    }

    func createReminder(_ request: ReminderRequest) async -> ChatToolResult {
        let granted: Bool
        do {
            switch EKEventStore.authorizationStatus(for: .reminder) {
            case .notDetermined:
                granted = try await store.requestFullAccessToReminders()
            case .fullAccess, .authorized:
                granted = true
            default:
                granted = false
            }
        } catch {
            return Self.result(
                status: "error",
                message: "Reminders access failed: \(error.localizedDescription)"
            )
        }

        guard granted else {
            return Self.result(
                status: "permission_denied",
                message: "Reminders access was denied. It can be enabled in System Settings > Privacy & Security > Reminders."
            )
        }

        let calendar: EKCalendar
        if let requestedList = request.listName {
            let matches = store.calendars(for: .reminder).filter {
                $0.title.compare(requestedList, options: [.caseInsensitive, .diacriticInsensitive])
                    == .orderedSame
            }
            guard matches.count == 1, let match = matches.first else {
                let message = matches.isEmpty
                    ? "No Reminders list named ‘\(requestedList)’ exists."
                    : "More than one Reminders list is named ‘\(requestedList)’; choose a unique list."
                return Self.result(status: "validation_error", message: message)
            }
            calendar = match
        } else if let defaultCalendar = store.defaultCalendarForNewReminders() {
            calendar = defaultCalendar
        } else {
            return Self.result(
                status: "error",
                message: "Apple Reminders has no default list available."
            )
        }

        let parsedDue: ParsedReminderDue?
        if let due = request.due {
            guard let parsed = ReminderDateParser.parse(due, timeZone: timeZone) else {
                return Self.result(
                    status: "validation_error",
                    message: "The due date ‘\(due)’ is invalid."
                )
            }
            parsedDue = parsed
        } else {
            parsedDue = nil
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = request.title
        reminder.notes = request.notes
        reminder.calendar = calendar
        switch parsedDue {
        case .allDay(let components):
            reminder.dueDateComponents = components
            reminder.timeZone = nil
        case .timed(let components):
            reminder.dueDateComponents = components
            reminder.timeZone = timeZone
            if let alarmDate = Calendar.current.date(from: components) {
                reminder.addAlarm(EKAlarm(absoluteDate: alarmDate))
            }
        case nil:
            break
        }

        do {
            try store.save(reminder, commit: true)
            var response: [String: ChatToolValue] = [
                "status": .string("created"),
                "message": .string("Created ‘\(request.title)’ in ‘\(calendar.title)’.")
            ]
            let identifier = reminder.calendarItemIdentifier
            if !identifier.isEmpty {
                response["identifier"] = .string(identifier)
            }
            return ChatToolResult(response: response)
        } catch {
            return Self.result(
                status: "error",
                message: "The reminder could not be saved: \(error.localizedDescription)"
            )
        }
    }

    private static func result(status: String, message: String) -> ChatToolResult {
        ChatToolResult(response: [
            "status": .string(status),
            "message": .string(message),
        ])
    }
}
