import Foundation
import Testing
@testable import electragne

struct AutomationToolTests {
    @Test func parsesAutomationRequestsAndDefaultsTheName() throws {
        #expect(try AutomationToolRequest(toolCall: call("create_automation", [
            "name": .string("  Slack watch  "),
            "intervalSeconds": .number(120),
            "instruction": .string("Check #ops for anything urgent."),
        ])) == .create(
            name: "Slack watch",
            intervalSeconds: 120,
            instruction: "Check #ops for anything urgent."
        ))

        #expect(try AutomationToolRequest(toolCall: call("create_automation", [
            "intervalSeconds": .number(60),
            "instruction": .string("Watch the channel."),
        ])) == .create(name: "Automation", intervalSeconds: 60, instruction: "Watch the channel."))
        #expect(try AutomationToolRequest(toolCall: call("list_automations")) == .list)
        #expect(try AutomationToolRequest(toolCall: call("cancel_automation", [
            "automationID": .string(" id-1 "),
        ])) == .cancel(automationID: "id-1"))
    }

    @Test func rejectsInvalidIntervalsAndMissingArguments() {
        for value in [0.0, 59, 90.5, 604_801, .infinity] {
            #expect(throws: AutomationToolError.invalidInterval) {
                try AutomationToolRequest(toolCall: call("create_automation", [
                    "intervalSeconds": .number(value),
                    "instruction": .string("Watch."),
                ]))
            }
        }
        #expect(throws: AutomationToolError.missingArgument("instruction")) {
            try AutomationToolRequest(toolCall: call("create_automation", [
                "intervalSeconds": .number(120),
            ]))
        }
        #expect(throws: AutomationToolError.missingArgument("automationID")) {
            try AutomationToolRequest(toolCall: call("cancel_automation"))
        }
    }

    @Test func automationStoreRoundTripsRecords() throws {
        let suite = "AutomationToolTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AutomationStore(defaults: defaults)
        let automations = [AutomationRecord(
            id: "one",
            name: "Slack watch",
            intervalSeconds: 120,
            instruction: "Check #ops.",
            lastRun: Date(timeIntervalSince1970: 100)
        )]

        store.save(automations)

        #expect(store.load() == automations)
    }

    @Test func engineRunsDueAutomationsAndNotifiesOnPrefix() async throws {
        let suite = "AutomationEngineTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var current = Date(timeIntervalSince1970: 1_000)
        let engine = AutomationEngine(defaults: defaults, now: { current })
        var notified: [(String, String)] = []
        engine.onNotify = { notified.append(($0, $1)) }
        var runCount = 0
        var output = "NOTIFY: server down"
        engine.runner = { _ in
            runCount += 1
            return output
        }
        _ = engine.add(name: "Slack watch", intervalSeconds: 120, instruction: "Check #ops.")

        engine.tick()
        await waitUntil { runCount == 1 }
        #expect(notified.count == 1)
        #expect(notified.first?.0 == "Slack watch")
        #expect(notified.first?.1 == "server down")

        // Not due again until the interval elapses.
        engine.tick()
        await waitUntil { false }
        #expect(runCount == 1)

        // Due again; a NOTHING result stays silent.
        output = "NOTHING"
        current += 121
        engine.tick()
        await waitUntil { runCount == 2 }
        #expect(runCount == 2)
        #expect(notified.count == 1)
    }

    @Test func engineRequiresTheExactNotifyPrefix() async throws {
        let suite = "AutomationPrefixTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var current = Date(timeIntervalSince1970: 1_000)
        let engine = AutomationEngine(defaults: defaults, now: { current })
        var notified: [(String, String)] = []
        engine.onNotify = { notified.append(($0, $1)) }
        var runCount = 0
        var output = ""
        engine.runner = { _ in
            runCount += 1
            return output
        }
        _ = engine.add(name: "Watch", intervalSeconds: 60, instruction: "Watch.")

        // Prose that merely starts with the word must stay silent.
        for reply in ["Notifying the owner is unnecessary here.", "notify: lowercase", "NOTIFY without colon", "NOTIFY:", "NOTIFY:   "] {
            output = reply
            let expected = runCount + 1
            engine.tick()
            await waitUntil { runCount == expected }
            current += 61
        }
        #expect(notified.isEmpty)

        output = "NOTIFY:  server down  "
        let expected = runCount + 1
        engine.tick()
        await waitUntil { runCount == expected }
        #expect(notified.count == 1)
        #expect(notified.first?.1 == "server down")
    }

    @Test func engineDropsResultOfAutomationCancelledMidRun() async throws {
        let suite = "AutomationCancelTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = AutomationEngine(defaults: defaults)
        var notified = 0
        engine.onNotify = { _, _ in notified += 1 }
        var release: CheckedContinuation<Void, Never>?
        engine.runner = { _ in
            await withCheckedContinuation { release = $0 }
            return "NOTIFY: too late"
        }
        let automation = engine.add(name: "Doomed", intervalSeconds: 60, instruction: "Watch.")

        engine.tick()
        await waitUntil { release != nil }
        _ = engine.remove(id: automation.id)
        release?.resume()
        await waitUntil { false }
        #expect(notified == 0)
    }

    @Test func automationStorePreservesUndecodableBlobInsteadOfOverwriting() throws {
        let suite = "AutomationCorruptTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AutomationStore(defaults: defaults)
        let corrupt = Data("not json".utf8)
        defaults.set(corrupt, forKey: AutomationStore.storageKey)

        #expect(store.load() == [])
        #expect(defaults.data(forKey: AutomationStore.storageKey + ".corrupt") == corrupt)

        // The next load-modify-save starts fresh without touching the backup.
        store.save([])
        #expect(defaults.data(forKey: AutomationStore.storageKey + ".corrupt") == corrupt)
    }

    @Test func engineSkipsTicksWhileARunIsInFlight() async throws {
        let suite = "AutomationEngineBusyTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var current = Date(timeIntervalSince1970: 1_000)
        let engine = AutomationEngine(defaults: defaults, now: { current })
        var runCount = 0
        var release: CheckedContinuation<Void, Never>?
        engine.runner = { _ in
            runCount += 1
            await withCheckedContinuation { release = $0 }
            return "NOTHING"
        }
        _ = engine.add(name: "Slow", intervalSeconds: 60, instruction: "Watch.")

        engine.tick()
        await waitUntil { release != nil }
        current += 61
        engine.tick()
        await waitUntil { false }
        #expect(runCount == 1)

        release?.resume()
        await waitUntil { false }
    }

    @Test func serviceCreatesListsAndCancelsAutomations() async throws {
        let suite = "AutomationServiceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = AutomationEngine(defaults: defaults)
        let service = AutomationToolService(engine: engine)

        let created = await service.execute(.create(
            name: "Slack watch",
            intervalSeconds: 120,
            instruction: "Check #ops."
        ))
        #expect(created.response["status"]?.stringValue == "created")
        let automationID = try #require(created.response["automationID"]?.stringValue)

        let listed = await service.execute(.list)
        #expect(listed.response["count"]?.numberValue == 1)
        #expect(listed.response["results"]?.arrayValue?.count == 1)

        let cancelled = await service.execute(.cancel(automationID: automationID))
        #expect(cancelled.response["status"]?.stringValue == "cancelled")
        #expect((await service.execute(.list)).response["count"]?.numberValue == 0)

        let missing = await service.execute(.cancel(automationID: automationID))
        #expect(missing.response["status"]?.stringValue == "not_found")
    }

    /// Yields the main actor until the condition holds (or a bounded number
    /// of yields pass, which doubles as "let pending tasks settle").
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { await Task.yield() }
    }

    private func call(
        _ name: String,
        _ arguments: [String: ChatToolValue] = [:]
    ) -> ChatToolCall {
        ChatToolCall(id: "test", name: name, arguments: arguments)
    }
}
