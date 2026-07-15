import Foundation
import UserNotifications

nonisolated struct TimerRecord: Codable, Equatable, Sendable {
    let id: String
    let label: String
    let fireDate: Date
}

nonisolated enum TimerToolRequest: Equatable, Sendable {
    case create(label: String, durationSeconds: Int)
    case list
    case cancel(timerID: String)

    init(toolCall: ChatToolCall) throws {
        func trimmed(_ key: String) -> String? {
            guard let value = toolCall.arguments[key]?.stringValue else { return nil }
            let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return result.isEmpty ? nil : result
        }

        switch toolCall.name {
        case "create_timer":
            guard let rawDuration = toolCall.arguments["durationSeconds"]?.numberValue,
                  rawDuration.isFinite,
                  rawDuration.rounded() == rawDuration,
                  rawDuration >= 1,
                  rawDuration <= 604_800 else {
                throw TimerToolError.invalidDuration
            }
            self = .create(
                label: trimmed("label") ?? "Timer",
                durationSeconds: Int(rawDuration)
            )
        case "list_timers":
            self = .list
        case "cancel_timer":
            guard let timerID = trimmed("timerID") else {
                throw TimerToolError.missingArgument("timerID")
            }
            self = .cancel(timerID: timerID)
        default:
            throw TimerToolError.unsupportedTool(toolCall.name)
        }
    }
}

nonisolated enum TimerToolError: LocalizedError, Equatable {
    case unsupportedTool(String)
    case missingArgument(String)
    case invalidDuration

    var errorDescription: String? {
        switch self {
        case .unsupportedTool: "That timer request was invalid."
        case .missingArgument(let name): "The ‘\(name)’ argument is required."
        case .invalidDuration: "Timer duration must be a whole number from 1 second to 7 days."
        }
    }
}

nonisolated struct TimerStore {
    static let storageKey = "scheduledTimers"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [TimerRecord] {
        guard let data = defaults.data(forKey: Self.storageKey) else { return [] }
        return (try? JSONDecoder().decode([TimerRecord].self, from: data)) ?? []
    }

    func save(_ records: [TimerRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

@MainActor
protocol TimerNotificationScheduling {
    func ensureAuthorization() async -> Bool
    func schedule(identifier: String, label: String, fireDate: Date) async throws
    func cancel(identifier: String)
}

@MainActor
final class UserNotificationTimerScheduler: TimerNotificationScheduling {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func ensureAuthorization() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) == true
        default:
            return false
        }
    }

    func schedule(identifier: String, label: String, fireDate: Date) async throws {
        let content = UNMutableNotificationContent()
        content.title = "Timer finished"
        content.body = label
        content.sound = .default
        content.threadIdentifier = "electragne-timers"

        let interval = max(1, fireDate.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        try await center.add(UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        ))
    }

    func cancel(identifier: String) {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}

@MainActor
protocol TimerToolExecuting {
    func confirmationDetails(for request: TimerToolRequest) -> ToolConfirmationDetails?
    func execute(_ request: TimerToolRequest) async -> ChatToolResult
}

@MainActor
final class TimerToolService: TimerToolExecuting {
    private let store: TimerStore
    private let scheduler: any TimerNotificationScheduling
    private let now: () -> Date

    init(
        store: TimerStore = TimerStore(),
        scheduler: (any TimerNotificationScheduling)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.scheduler = scheduler ?? UserNotificationTimerScheduler()
        self.now = now
    }

    func confirmationDetails(for request: TimerToolRequest) -> ToolConfirmationDetails? {
        switch request {
        case .create(let label, let seconds):
            return ToolConfirmationDetails(
                title: "Start this timer?",
                primaryText: label,
                details: [("Duration", Self.durationText(seconds))],
                actionLabel: "Start"
            )
        case .list:
            return nil
        case .cancel(let timerID):
            let timer = activeTimers().first { $0.id == timerID }
            return ToolConfirmationDetails(
                title: "Cancel this timer?",
                primaryText: timer?.label ?? "Selected timer",
                details: [],
                actionLabel: "Cancel Timer"
            )
        }
    }

    func execute(_ request: TimerToolRequest) async -> ChatToolResult {
        switch request {
        case .create(let label, let seconds):
            guard await scheduler.ensureAuthorization() else {
                return .make(
                    status: "permission_denied",
                    message: "Notifications are disabled. Enable them in System Settings > Notifications > Electragne."
                )
            }

            let timer = TimerRecord(
                id: UUID().uuidString,
                label: label,
                fireDate: now().addingTimeInterval(TimeInterval(seconds))
            )
            do {
                try await scheduler.schedule(
                    identifier: timer.id,
                    label: timer.label,
                    fireDate: timer.fireDate
                )
                var timers = activeTimers()
                timers.append(timer)
                store.save(timers)
                return timerResult(
                    timer,
                    status: "created",
                    message: "Started ‘\(timer.label)’ for \(Self.durationText(seconds))."
                )
            } catch {
                return .make(
                    status: "error",
                    message: "The timer notification could not be scheduled: \(error.localizedDescription)"
                )
            }

        case .list:
            let timers = activeTimers()
            let values = timers.map { timer -> ChatToolValue in
                .object(timerValues(timer))
            }
            return ChatToolResult(response: [
                "status": .string(timers.isEmpty ? "not_found" : "found"),
                "count": .number(Double(timers.count)),
                "results": .array(values),
                "message": .string(timers.isEmpty
                    ? "There are no active timers."
                    : "Found \(timers.count) active timer\(timers.count == 1 ? "" : "s")."),
            ])

        case .cancel(let timerID):
            var timers = activeTimers()
            guard let index = timers.firstIndex(where: { $0.id == timerID }) else {
                return .make(
                    status: "not_found",
                    message: "That timer is no longer active. List timers again to get a current ID."
                )
            }
            let timer = timers.remove(at: index)
            scheduler.cancel(identifier: timer.id)
            store.save(timers)
            return timerResult(timer, status: "cancelled", message: "Cancelled ‘\(timer.label)’.")
        }
    }

    private func activeTimers() -> [TimerRecord] {
        let current = now()
        let stored = store.load()
        let active = stored.filter { $0.fireDate > current }.sorted { $0.fireDate < $1.fireDate }
        if active != stored { store.save(active) }
        return active
    }

    private func timerResult(
        _ timer: TimerRecord,
        status: String,
        message: String
    ) -> ChatToolResult {
        ChatToolResult(response: timerValues(timer).merging([
            "status": .string(status),
            "message": .string(message),
        ]) { _, new in new })
    }

    private func timerValues(_ timer: TimerRecord) -> [String: ChatToolValue] {
        [
            "timerID": .string(timer.id),
            "label": .string(timer.label),
            "endsAt": .string(Self.dateString(timer.fireDate)),
            "remainingSeconds": .number(Double(max(0, Int(timer.fireDate.timeIntervalSince(now()).rounded(.up))))),
        ]
    }


    nonisolated static func durationText(_ seconds: Int) -> String {
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        let parts: [String] = [
            days > 0 ? "\(days) day\(days == 1 ? "" : "s")" : nil,
            hours > 0 ? "\(hours) hour\(hours == 1 ? "" : "s")" : nil,
            minutes > 0 ? "\(minutes) minute\(minutes == 1 ? "" : "s")" : nil,
            remainingSeconds > 0 ? "\(remainingSeconds) second\(remainingSeconds == 1 ? "" : "s")" : nil,
        ].compactMap { $0 }
        return parts.joined(separator: " ")
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
