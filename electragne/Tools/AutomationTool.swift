import Foundation
import os

nonisolated struct AutomationRecord: Codable, Equatable, Sendable {
    let id: String
    var name: String
    var intervalSeconds: Int
    var instruction: String
    var schedule: AutomationSchedule? = nil
    var lastRun: Date?
    var isEnabled = true
    var chatID: UUID? = nil
    var terminalAccess = false
    var lastDeliveryStatus: String? = nil

    private enum CodingKeys: String, CodingKey {
        case id, name, intervalSeconds, instruction, schedule, lastRun
        case isEnabled, chatID, terminalAccess, lastDeliveryStatus
    }

    init(
        id: String,
        name: String,
        intervalSeconds: Int,
        instruction: String,
        schedule: AutomationSchedule? = nil,
        lastRun: Date? = nil,
        isEnabled: Bool = true,
        chatID: UUID? = nil,
        terminalAccess: Bool = false,
        lastDeliveryStatus: String? = nil
    ) {
        self.id = id
        self.name = name
        self.intervalSeconds = intervalSeconds
        self.instruction = instruction
        self.schedule = schedule
        self.lastRun = lastRun
        self.isEnabled = isEnabled
        self.chatID = chatID
        self.terminalAccess = terminalAccess
        self.lastDeliveryStatus = lastDeliveryStatus
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        intervalSeconds = try values.decode(Int.self, forKey: .intervalSeconds)
        instruction = try values.decode(String.self, forKey: .instruction)
        schedule = try values.decodeIfPresent(AutomationSchedule.self, forKey: .schedule)
        lastRun = try values.decodeIfPresent(Date.self, forKey: .lastRun)
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        chatID = try values.decodeIfPresent(UUID.self, forKey: .chatID)
        terminalAccess = try values.decodeIfPresent(Bool.self, forKey: .terminalAccess) ?? false
        lastDeliveryStatus = try values.decodeIfPresent(String.self, forKey: .lastDeliveryStatus)
    }
}

nonisolated struct AutomationSchedule: Codable, Equatable, Sendable {
    let startMinute: Int?
    let endMinute: Int?
    let weekdays: [Int]?

    func allows(_ date: Date, calendar: Calendar) -> Bool {
        let components = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = components.weekday,
              let hour = components.hour,
              let minute = components.minute else { return false }
        guard let startMinute, let endMinute else {
            return weekdays?.contains(weekday) ?? true
        }

        let currentMinute = hour * 60 + minute
        if startMinute < endMinute {
            return currentMinute >= startMinute && currentMinute < endMinute
                && (weekdays?.contains(weekday) ?? true)
        }

        guard currentMinute >= startMinute || currentMinute < endMinute else { return false }
        let owningWeekday = currentMinute >= startMinute ? weekday : (weekday == 1 ? 7 : weekday - 1)
        return weekdays?.contains(owningWeekday) ?? true
    }

    var text: String {
        var parts: [String] = []
        if let startMinute, let endMinute {
            parts.append("\(Self.timeText(startMinute))–\(Self.timeText(endMinute))")
        }
        if let weekdays {
            parts.append(weekdays.compactMap { Self.dayNames[$0] }.joined(separator: ", "))
        }
        return parts.joined(separator: " on ")
    }

    static func parseTime(_ value: String) -> Int? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    static func parseWeekdays(_ value: String) -> [Int]? {
        let names = value.lowercased().split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !names.isEmpty, names.allSatisfy({ weekdayNumbers[$0] != nil }) else { return nil }
        return Array(Set(names.compactMap { weekdayNumbers[$0] })).sorted()
    }

    private static let weekdayNumbers = [
        "sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7,
    ]
    private static let dayNames = [
        1: "Sun", 2: "Mon", 3: "Tue", 4: "Wed", 5: "Thu", 6: "Fri", 7: "Sat",
    ]

    private static func timeText(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }
}

nonisolated enum AutomationToolRequest: Equatable, Sendable {
    case create(
        name: String,
        intervalSeconds: Int,
        instruction: String,
        schedule: AutomationSchedule? = nil,
        terminalAccess: Bool = false
    )
    case list
    case update(
        automationID: String,
        name: String?,
        intervalSeconds: Int?,
        instruction: String?,
        schedule: AutomationSchedule?,
        enabled: Bool? = nil,
        terminalAccess: Bool? = nil
    )
    case cancel(automationID: String)

    init(toolCall: ChatToolCall) throws {
        let args = ToolCallArguments(toolCall)

        switch toolCall.name {
        case "create_automation":
            guard let intervalSeconds = try Self.parseInterval(toolCall) else {
                throw AutomationToolError.invalidInterval
            }
            guard let instruction = args.string("instruction") else {
                throw AutomationToolError.missingArgument("instruction")
            }
            self = .create(
                name: args.string("name") ?? "Automation",
                intervalSeconds: intervalSeconds,
                instruction: instruction,
                schedule: try Self.parseSchedule(toolCall, args),
                terminalAccess: try Self.parseBoolean(toolCall, "terminalAccess") ?? false
            )
        case "list_automations":
            self = .list
        case "update_automation":
            guard let automationID = args.string("automationID") else {
                throw AutomationToolError.missingArgument("automationID")
            }
            self = .update(
                automationID: automationID,
                name: args.string("name"),
                intervalSeconds: try Self.parseInterval(toolCall),
                instruction: args.string("instruction"),
                schedule: try Self.parseSchedule(toolCall, args),
                enabled: try Self.parseBoolean(toolCall, "enabled"),
                terminalAccess: try Self.parseBoolean(toolCall, "terminalAccess")
            )
        case "cancel_automation":
            guard let automationID = args.string("automationID") else {
                throw AutomationToolError.missingArgument("automationID")
            }
            self = .cancel(automationID: automationID)
        default:
            throw AutomationToolError.unsupportedTool(toolCall.name)
        }
    }

    /// Nil when the argument is absent; throws when present but invalid.
    private static func parseInterval(_ toolCall: ChatToolCall) throws -> Int? {
        guard let raw = toolCall.arguments["intervalSeconds"]?.numberValue else { return nil }
        guard raw.isFinite,
              raw.rounded() == raw,
              raw >= 60,
              raw <= 604_800 else {
            throw AutomationToolError.invalidInterval
        }
        return Int(raw)
    }

    private static func parseBoolean(_ toolCall: ChatToolCall, _ name: String) throws -> Bool? {
        guard let value = toolCall.arguments[name] else { return nil }
        guard let result = value.boolValue else {
            throw AutomationToolError.invalidBoolean(name)
        }
        return result
    }

    /// Nil when no window or day arguments are present.
    private static func parseSchedule(
        _ toolCall: ChatToolCall,
        _ args: ToolCallArguments
    ) throws -> AutomationSchedule? {
        let hasStart = toolCall.arguments["windowStart"] != nil
        let hasEnd = toolCall.arguments["windowEnd"] != nil
        guard hasStart == hasEnd else { throw AutomationToolError.invalidWindow }
        var startMinute: Int?
        var endMinute: Int?
        if hasStart {
            guard let start = args.string("windowStart"),
                  let end = args.string("windowEnd"),
                  let parsedStart = AutomationSchedule.parseTime(start),
                  let parsedEnd = AutomationSchedule.parseTime(end),
                  parsedStart != parsedEnd else { throw AutomationToolError.invalidWindow }
            startMinute = parsedStart
            endMinute = parsedEnd
        }
        var weekdays: [Int]?
        if toolCall.arguments["activeDays"] != nil {
            guard let days = args.string("activeDays"),
                  let parsed = AutomationSchedule.parseWeekdays(days) else {
                throw AutomationToolError.invalidDays
            }
            weekdays = parsed
        }
        return startMinute != nil || weekdays != nil
            ? AutomationSchedule(startMinute: startMinute, endMinute: endMinute, weekdays: weekdays)
            : nil
    }
}

nonisolated enum AutomationToolError: LocalizedError, Equatable {
    case unsupportedTool(String)
    case missingArgument(String)
    case invalidInterval
    case invalidWindow
    case invalidDays
    case invalidBoolean(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedTool: "That automation request was invalid."
        case .missingArgument(let name): "The ‘\(name)’ argument is required."
        case .invalidInterval: "Automation interval must be a whole number from 60 seconds to 7 days."
        case .invalidWindow: "Automation window must have different start and end times in HH:mm format."
        case .invalidDays: "Automation days must be a comma-separated list using mon, tue, wed, thu, fri, sat, or sun."
        case .invalidBoolean(let name): "Automation ‘\(name)’ must be true or false."
        }
    }
}

nonisolated struct AutomationStore {
    static let storageKey = "automations"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [AutomationRecord] {
        guard let data = defaults.data(forKey: Self.storageKey) else { return [] }
        do {
            return try JSONDecoder().decode([AutomationRecord].self, from: data)
        } catch {
            // A decode failure must never be silently overwritten by the next
            // load-modify-save: park the blob under a backup key instead.
            Log.automation.error("Automation store undecodable, preserving blob under ‘\(Self.storageKey).corrupt’: \(error.localizedDescription, privacy: .public)")
            defaults.set(data, forKey: Self.storageKey + ".corrupt")
            defaults.removeObject(forKey: Self.storageKey)
            return []
        }
    }

    func save(_ records: [AutomationRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

protocol AutomationToolExecuting {
    func confirmationDetails(for request: AutomationToolRequest) -> ToolConfirmationDetails?
    func execute(_ request: AutomationToolRequest) async -> ChatToolResult
}

final class AutomationToolService: AutomationToolExecuting {
    private let engine: AutomationEngine

    init(engine: AutomationEngine) {
        self.engine = engine
    }

    func confirmationDetails(for request: AutomationToolRequest) -> ToolConfirmationDetails? {
        switch request {
        case .create(let name, let seconds, let instruction, let schedule, let terminalAccess):
            var details = [
                ("Every", TimerToolService.durationText(seconds)),
                ("Task", instruction),
            ]
            if let schedule { details.insert(("When", schedule.text), at: 1) }
            if terminalAccess {
                details.append(("Terminal", "Unattended read and write access to this chat"))
            }
            return ToolConfirmationDetails(
                title: "Start this automation?",
                primaryText: name,
                details: details,
                actionLabel: "Start"
            )
        case .list:
            return nil
        case .update(
            let automationID, let name, let seconds, let instruction,
            let schedule, let enabled, let terminalAccess
        ):
            let existing = engine.list().first { $0.id == automationID }
            var details: [(String, String)] = []
            if let seconds { details.append(("Every", TimerToolService.durationText(seconds))) }
            if let schedule { details.append(("When", schedule.text)) }
            if let instruction { details.append(("Task", instruction)) }
            if let enabled { details.append(("Status", enabled ? "Enabled" : "Paused")) }
            if let terminalAccess {
                details.append(("Terminal", terminalAccess
                    ? "Unattended read and write access to this chat"
                    : "No access"))
            }
            return ToolConfirmationDetails(
                title: "Update this automation?",
                primaryText: name ?? existing?.name ?? "Selected automation",
                details: details,
                actionLabel: "Update"
            )
        case .cancel(let automationID):
            let automation = engine.list().first { $0.id == automationID }
            return ToolConfirmationDetails(
                title: "Cancel this automation?",
                primaryText: automation?.name ?? "Selected automation",
                details: [],
                actionLabel: "Cancel Automation"
            )
        }
    }

    func execute(_ request: AutomationToolRequest) async -> ChatToolResult {
        switch request {
        case .create(let name, let seconds, let instruction, let schedule, let terminalAccess):
            let chatID = engine.currentToolChatID()
            if terminalAccess,
               (chatID == nil || chatID.map(engine.hasTerminalSession) != true) {
                return .make(
                    status: "terminal_unavailable",
                    message: "Open this chat’s terminal before granting unattended terminal access."
                )
            }
            let automation = engine.add(
                name: name,
                intervalSeconds: seconds,
                instruction: instruction,
                schedule: schedule,
                chatID: chatID,
                terminalAccess: terminalAccess
            )
            return automationResult(
                automation,
                status: "created",
                message: "Started ‘\(automation.name)’, running every \(TimerToolService.durationText(seconds))\(schedule.map { " during \($0.text)" } ?? "")."
            )

        case .list:
            let automations = engine.list()
            return ChatToolResult(response: [
                "status": .string(automations.isEmpty ? "not_found" : "found"),
                "count": .number(Double(automations.count)),
                "results": .array(automations.map { .object(automationValues($0)) }),
                "message": .string(automations.isEmpty
                    ? "There are no active automations."
                    : "Found \(automations.count) active automation\(automations.count == 1 ? "" : "s")."),
            ])

        case .update(
            let automationID, let name, let seconds, let instruction,
            let schedule, let enabled, let terminalAccess
        ):
            let chatID = terminalAccess == true ? engine.currentToolChatID() : nil
            if terminalAccess == true,
               (chatID == nil || chatID.map(engine.hasTerminalSession) != true) {
                return .make(
                    status: "terminal_unavailable",
                    message: "Open this chat’s terminal before granting unattended terminal access."
                )
            }
            guard let automation = engine.update(
                id: automationID,
                name: name,
                intervalSeconds: seconds,
                instruction: instruction,
                schedule: schedule,
                isEnabled: enabled,
                terminalAccess: terminalAccess,
                chatID: chatID
            ) else {
                return .make(
                    status: "not_found",
                    message: "That automation no longer exists. List automations again to get a current ID."
                )
            }
            return automationResult(automation, status: "updated", message: "Updated ‘\(automation.name)’.")

        case .cancel(let automationID):
            guard let automation = engine.remove(id: automationID) else {
                return .make(
                    status: "not_found",
                    message: "That automation no longer exists. List automations again to get a current ID."
                )
            }
            return automationResult(automation, status: "cancelled", message: "Cancelled ‘\(automation.name)’.")
        }
    }

    private func automationResult(
        _ automation: AutomationRecord,
        status: String,
        message: String
    ) -> ChatToolResult {
        ChatToolResult(response: automationValues(automation).merging([
            "status": .string(status),
            "message": .string(message),
        ]) { _, new in new })
    }

    private func automationValues(_ automation: AutomationRecord) -> [String: ChatToolValue] {
        var values: [String: ChatToolValue] = [
            "automationID": .string(automation.id),
            "name": .string(automation.name),
            "intervalSeconds": .number(Double(automation.intervalSeconds)),
            "instruction": .string(automation.instruction),
            "enabled": .bool(automation.isEnabled),
            "terminalAccess": .bool(automation.terminalAccess),
            "terminalStatus": .string(engine.terminalStatus(for: automation)),
            "nextRun": automation.isEnabled
                ? .string(TimerToolService.dateString(engine.nextRun(for: automation)))
                : .null,
        ]
        if let lastRun = automation.lastRun {
            values["lastRun"] = .string(TimerToolService.dateString(lastRun))
        }
        if let schedule = automation.schedule {
            values["schedule"] = .string(schedule.text)
        }
        if let status = automation.lastDeliveryStatus {
            values["lastDeliveryStatus"] = .string(status)
        }
        return values
    }
}
