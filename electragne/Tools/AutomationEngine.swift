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
    private var running: Set<String> = []
    private var started = false
    var onNotify: (String, String) -> Void = { _, _ in }
    /// Set after construction by AppModel; breaks the engine ↔ router cycle.
    weak var toolRouter: ChatToolRouter?
    /// Injectable for tests; nil runs a real headless LLM turn.
    var runner: ((AutomationRecord) async -> String)?

    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.store = AutomationStore(defaults: defaults)
        self.now = now
        self.calendar = calendar
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
        schedule: AutomationSchedule? = nil
    ) -> AutomationRecord {
        let automation = AutomationRecord(
            id: UUID().uuidString,
            name: name,
            intervalSeconds: intervalSeconds,
            instruction: instruction,
            schedule: schedule,
            lastRun: nil
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
        schedule: AutomationSchedule? = nil
    ) -> AutomationRecord? {
        var automations = store.load()
        guard let index = automations.firstIndex(where: { $0.id == id }) else { return nil }
        if let name { automations[index].name = name }
        if let intervalSeconds { automations[index].intervalSeconds = intervalSeconds }
        if let instruction { automations[index].instruction = instruction }
        if let schedule { automations[index].schedule = schedule }
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

    func tick() {
        let current = now()
        for automation in store.load() where !running.contains(automation.id) {
            guard automation.schedule?.allows(current, calendar: calendar) ?? true else { continue }
            let due = (automation.lastRun ?? .distantPast)
                .addingTimeInterval(TimeInterval(automation.intervalSeconds))
            if current >= due { run(automation) }
        }
    }

    private func run(_ automation: AutomationRecord) {
        running.insert(automation.id)
        // Stamp at run start so a slow run can't double-fire next tick.
        markLastRun(automation.id, at: now())
        Task { [weak self] in
            guard let self else { return }
            let output: String = if let runner = self.runner {
                await runner(automation)
            } else {
                await self.headlessTurn(automation)
            }
            self.running.remove(automation.id)
            // Cancelled while the run was in flight — drop the result.
            guard self.store.load().contains(where: { $0.id == automation.id }) else { return }
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("NOTIFY:") else { return }
            let payload = trimmed.dropFirst("NOTIFY:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty else {
                Log.automation.warning("Automation ‘\(automation.name, privacy: .public)’ replied NOTIFY: with no message; skipping notice.")
                return
            }
            self.onNotify(automation.name, payload)
        }
    }

    private func markLastRun(_ id: String, at date: Date) {
        var automations = store.load()
        guard let index = automations.firstIndex(where: { $0.id == id }) else { return }
        automations[index].lastRun = date
        store.save(automations)
    }

    private static let systemPrompt = """
        You are running as a background automation with no visible chat. \
        Perform the task below using read-only tools as needed; write actions \
        will be denied. When you are done, decide whether the result warrants \
        proactively interrupting the owner. If — and only if — it does, your \
        final reply MUST start with "NOTIFY:" followed by a short message for \
        the owner. Otherwise reply exactly "NOTHING".
        """

    private func headlessTurn(_ automation: AutomationRecord) async -> String {
        guard let toolRouter else { return "" }
        let client = ChatProviderPreference.selected.makeClient()
        let history = [
            ChatMessage(role: "system", content: Self.systemPrompt),
            ChatMessage(role: "user", content: automation.instruction),
        ]
        var buffer = ""
        do {
            try await client.streamChat(
                history: history,
                onStatus: { _ in },
                onToolCall: { call in
                    await toolRouter.execute(call, confirm: { _ in false }, onStatus: { _ in })
                },
                onImages: { _ in },
                onToken: { buffer += $0 }
            )
        } catch {
            Log.automation.error("Automation ‘\(automation.name, privacy: .public)’ failed: \(error.localizedDescription, privacy: .public)")
            return ""
        }
        return buffer
    }
}
