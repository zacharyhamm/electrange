import Foundation
import os

/// Runs user-created recurring automations: each is a stored instruction
/// executed as a headless LLM turn on its interval. A run that concludes the
/// owner should be told replies starting with "NOTIFY:", which surfaces via
/// onNotify (the same proactive bubble path calendar reminders use).
final class AutomationEngine {
    static let tickInterval: TimeInterval = 30

    private let store: AutomationStore
    private let poller = TimerDriver()
    private let now: () -> Date
    private let calendar: Calendar
    private let log: LLMLog?
    private var running: Set<String> = []
    private var started = false
    var onNotify: (AutomationNotice) async -> Bool = { _ in false }
    var currentToolChatID: () -> UUID? = { nil }
    var hasTerminalSession: (UUID) -> Bool = { _ in false }
    /// Set after construction by AppModel; breaks the engine ↔ router cycle.
    weak var toolRouter: ChatToolRouter?
    /// Injectable for tests; nil runs a real headless LLM turn.
    var runner: ((AutomationRecord) async throws -> String)?

    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent,
        log: LLMLog? = nil
    ) {
        self.store = AutomationStore(defaults: defaults)
        self.now = now
        self.calendar = calendar
        self.log = log
    }

    func start() {
        guard !started else { return }
        started = true
        poller.start(interval: Self.tickInterval) { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func add(
        name: String,
        intervalSeconds: Int,
        instruction: String,
        schedule: AutomationSchedule? = nil,
        chatID: UUID? = nil,
        terminalAccess: Bool = false
    ) -> AutomationRecord {
        let targetChatID = chatID ?? currentToolChatID()
        let automation = AutomationRecord(
            id: UUID().uuidString,
            name: name,
            intervalSeconds: intervalSeconds,
            instruction: instruction,
            schedule: schedule,
            lastRun: nil,
            chatID: targetChatID,
            terminalAccess: terminalAccess
        )
        store.save(store.load() + [automation])
        return automation
    }

    func list() -> [AutomationRecord] {
        store.load()
    }

    /// Nil arguments leave the corresponding field unchanged; a provided
    /// schedule replaces the old one wholesale. Returns nil for unknown IDs.
    func update(
        id: String,
        name: String? = nil,
        intervalSeconds: Int? = nil,
        instruction: String? = nil,
        schedule: AutomationSchedule? = nil,
        isEnabled: Bool? = nil,
        terminalAccess: Bool? = nil,
        chatID: UUID? = nil
    ) -> AutomationRecord? {
        var automations = store.load()
        guard let index = automations.firstIndex(where: { $0.id == id }) else { return nil }
        if let name { automations[index].name = name }
        if let intervalSeconds { automations[index].intervalSeconds = intervalSeconds }
        if let instruction { automations[index].instruction = instruction }
        if let schedule { automations[index].schedule = schedule }
        if let isEnabled { automations[index].isEnabled = isEnabled }
        if let terminalAccess {
            automations[index].terminalAccess = terminalAccess
            if terminalAccess, let chatID { automations[index].chatID = chatID }
        }
        store.save(automations)
        return automations[index]
    }

    /// Replaces every owner-editable field while preserving engine-owned
    /// state such as lastRun. Unlike update(...), nil clears the schedule.
    func edit(
        id: String,
        name: String,
        intervalSeconds: Int,
        instruction: String,
        schedule: AutomationSchedule?,
        isEnabled: Bool? = nil
    ) -> AutomationRecord? {
        var automations = store.load()
        guard let index = automations.firstIndex(where: { $0.id == id }) else { return nil }
        automations[index].name = name
        automations[index].intervalSeconds = intervalSeconds
        automations[index].instruction = instruction
        automations[index].schedule = schedule
        if let isEnabled { automations[index].isEnabled = isEnabled }
        store.save(automations)
        return automations[index]
    }

    func remove(id: String) -> AutomationRecord? {
        var automations = store.load()
        guard let index = automations.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = automations.remove(at: index)
        store.save(automations)
        return removed
    }

    /// Runs an automation immediately, ignoring its interval and schedule
    /// window. Returns false for unknown IDs or when a run is in flight.
    func runNow(id: String) -> Bool {
        guard !running.contains(id),
              let automation = store.load().first(where: { $0.id == id }) else { return false }
        guard terminalAvailable(for: automation) else { return false }
        run(automation)
        return true
    }

    func tick() {
        let current = now()
        for automation in store.load()
            where automation.isEnabled && !running.contains(automation.id) {
            guard automation.schedule?.allows(current, calendar: calendar) ?? true else { continue }
            let due = (automation.lastRun ?? .distantPast)
                .addingTimeInterval(TimeInterval(automation.intervalSeconds))
            if current >= due {
                if terminalAvailable(for: automation) {
                    run(automation)
                } else {
                    skipUnavailableTerminal(automation)
                }
            }
        }
    }

    private func run(_ automation: AutomationRecord) {
        running.insert(automation.id)
        // Stamp at run start so a slow run can't double-fire next tick.
        markLastRun(automation.id, at: now())
        Task { [weak self] in
            guard let self else { return }
            let context = AutomationRunContext(
                automationID: automation.id,
                runID: UUID().uuidString,
                chatID: automation.chatID,
                terminalAccess: automation.terminalAccess
            )
            await AutomationRunScope.$current.withValue(context) {
                await self.performRun(automation)
            }
        }
    }

    private func performRun(_ automation: AutomationRecord) async {
        await log?.append(kind: "automation_run_start", [
            "name": .string(automation.name),
            "instruction": .string(automation.instruction),
            "intervalSeconds": .number(Double(automation.intervalSeconds)),
            "schedule": automation.schedule.map { .string($0.text) } ?? .null,
        ])
        do {
            let output: String = if let runner {
                try await runner(automation)
            } else {
                try await headlessTurn(automation)
            }
            running.remove(automation.id)
            guard store.load().contains(where: { $0.id == automation.id }) else {
                await log?.append(kind: "automation_run_end", [
                    "status": .string("discarded"),
                    "output": .string(output),
                    "notified": .bool(false),
                ])
                return
            }

            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            var notified = false
            if trimmed.hasPrefix("NOTIFY:") {
                let payload = trimmed.dropFirst("NOTIFY:".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if payload.isEmpty {
                    Log.automation.warning("Automation ‘\(automation.name, privacy: .public)’ replied NOTIFY: with no message; skipping notice.")
                } else {
                    notified = true
                    let delivered = await onNotify(AutomationNotice(
                        automationID: automation.id,
                        runID: AutomationRunScope.current?.runID ?? UUID().uuidString,
                        name: automation.name,
                        chatID: automation.chatID,
                        message: payload
                    ))
                    setDeliveryStatus(
                        automation.id,
                        status: delivered ? "queued" : "failed",
                        pause: !delivered
                    )
                }
            }
            await log?.append(kind: "automation_run_end", [
                "status": .string("completed"),
                "output": .string(output),
                "notified": .bool(notified),
            ])
        } catch {
            running.remove(automation.id)
            Log.automation.error("Automation ‘\(automation.name, privacy: .public)’ failed: \(error.localizedDescription, privacy: .public)")
            await log?.append(kind: "automation_run_end", [
                "status": .string("failed"),
                "error": .string(error.localizedDescription),
                "notified": .bool(false),
            ])
        }
    }

    private func markLastRun(_ id: String, at date: Date) {
        var automations = store.load()
        guard let index = automations.firstIndex(where: { $0.id == id }) else { return }
        automations[index].lastRun = date
        store.save(automations)
    }

    func nextRun(for automation: AutomationRecord) -> Date {
        automation.lastRun?
            .addingTimeInterval(TimeInterval(automation.intervalSeconds))
            ?? now()
    }

    func terminalStatus(for automation: AutomationRecord) -> String {
        guard automation.terminalAccess else { return "not_requested" }
        guard let chatID = automation.chatID else { return "unbound" }
        return hasTerminalSession(chatID) ? "connected" : "waiting"
    }

    private func terminalAvailable(for automation: AutomationRecord) -> Bool {
        !automation.terminalAccess
            || automation.chatID.map(hasTerminalSession) == true
    }

    private func skipUnavailableTerminal(_ automation: AutomationRecord) {
        let date = now()
        markLastRun(automation.id, at: date)
        let context = AutomationRunContext(
            automationID: automation.id,
            runID: UUID().uuidString,
            chatID: automation.chatID,
            terminalAccess: true
        )
        Task { [log] in
            await AutomationRunScope.$current.withValue(context) {
                await log?.append(kind: "automation_run_start", [
                    "name": .string(automation.name),
                    "instruction": .string(automation.instruction),
                    "intervalSeconds": .number(Double(automation.intervalSeconds)),
                    "schedule": automation.schedule.map { .string($0.text) } ?? .null,
                ])
                await log?.append(kind: "automation_run_end", [
                    "status": .string("waiting_for_terminal"),
                    "notified": .bool(false),
                ])
            }
        }
    }

    private func setDeliveryStatus(_ id: String, status: String, pause: Bool) {
        var automations = store.load()
        guard let index = automations.firstIndex(where: { $0.id == id }) else { return }
        automations[index].lastDeliveryStatus = status
        if pause { automations[index].isEnabled = false }
        store.save(automations)
    }

    private static let systemPrompt = """
        You are running as a background automation with no visible chat. \
        Perform the task below using tools as needed. Terminal writes are allowed \
        only when this automation was explicitly granted terminal access; every \
        other write action will be denied. When you are done, decide whether the result warrants \
        proactively interrupting the owner. If — and only if — it does, your \
        final reply MUST start with "NOTIFY:" followed by a short message for \
        the owner. Otherwise reply exactly "NOTHING".
        """

    private func headlessTurn(_ automation: AutomationRecord) async throws -> String {
        guard let toolRouter else { throw AutomationRunError.missingToolRouter }
        let client = ChatProviderPreference.selected.makeClient()
        let history = [
            ChatMessage(role: "system", content: Self.systemPrompt),
            ChatMessage(role: "user", content: automation.instruction),
        ]
        var buffer = ""
        try await client.streamChat(
            history: history,
            onStatus: { _ in },
            onToolCall: { call in
                await toolRouter.execute(
                    call,
                    confirm: { _ in
                        call.name == "write_terminal" && automation.terminalAccess
                    },
                    onStatus: { _ in }
                )
            },
            onImages: { _ in },
            onToken: { buffer += $0 }
        )
        return buffer
    }
}

nonisolated struct AutomationNotice: Equatable, Sendable {
    let automationID: String
    let runID: String
    let name: String
    let chatID: UUID?
    let message: String
}

nonisolated private enum AutomationRunError: LocalizedError {
    case missingToolRouter

    var errorDescription: String? { "Automation tools are unavailable." }
}
