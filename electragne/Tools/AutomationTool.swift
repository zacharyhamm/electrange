import Foundation
import os

nonisolated struct AutomationRecord: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let intervalSeconds: Int
    let instruction: String
    var lastRun: Date?
}

nonisolated enum AutomationToolRequest: Equatable, Sendable {
    case create(name: String, intervalSeconds: Int, instruction: String)
    case list
    case cancel(automationID: String)

    init(toolCall: ChatToolCall) throws {
        let args = ToolCallArguments(toolCall)

        switch toolCall.name {
        case "create_automation":
            guard let rawInterval = toolCall.arguments["intervalSeconds"]?.numberValue,
                  rawInterval.isFinite,
                  rawInterval.rounded() == rawInterval,
                  rawInterval >= 60,
                  rawInterval <= 604_800 else {
                throw AutomationToolError.invalidInterval
            }
            guard let instruction = args.string("instruction") else {
                throw AutomationToolError.missingArgument("instruction")
            }
            self = .create(
                name: args.string("name") ?? "Automation",
                intervalSeconds: Int(rawInterval),
                instruction: instruction
            )
        case "list_automations":
            self = .list
        case "cancel_automation":
            guard let automationID = args.string("automationID") else {
                throw AutomationToolError.missingArgument("automationID")
            }
            self = .cancel(automationID: automationID)
        default:
            throw AutomationToolError.unsupportedTool(toolCall.name)
        }
    }
}

nonisolated enum AutomationToolError: LocalizedError, Equatable {
    case unsupportedTool(String)
    case missingArgument(String)
    case invalidInterval

    var errorDescription: String? {
        switch self {
        case .unsupportedTool: "That automation request was invalid."
        case .missingArgument(let name): "The ‘\(name)’ argument is required."
        case .invalidInterval: "Automation interval must be a whole number from 60 seconds to 7 days."
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
        case .create(let name, let seconds, let instruction):
            return ToolConfirmationDetails(
                title: "Start this automation?",
                primaryText: name,
                details: [
                    ("Every", TimerToolService.durationText(seconds)),
                    ("Task", instruction),
                ],
                actionLabel: "Start"
            )
        case .list:
            return nil
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
        case .create(let name, let seconds, let instruction):
            let automation = engine.add(
                name: name,
                intervalSeconds: seconds,
                instruction: instruction
            )
            return automationResult(
                automation,
                status: "created",
                message: "Started ‘\(automation.name)’, running every \(TimerToolService.durationText(seconds))."
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
        ]
        if let lastRun = automation.lastRun {
            values["lastRun"] = .string(TimerToolService.dateString(lastRun))
        }
        return values
    }
}
