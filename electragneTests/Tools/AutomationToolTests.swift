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
            instruction: "Check #ops for anything urgent.",
            schedule: nil
        ))

        #expect(try AutomationToolRequest(toolCall: call("create_automation", [
            "intervalSeconds": .number(60),
            "instruction": .string("Watch the channel."),
        ])) == .create(name: "Automation", intervalSeconds: 60, instruction: "Watch the channel.", schedule: nil))
        #expect(try AutomationToolRequest(toolCall: call("list_automations")) == .list)
        #expect(try AutomationToolRequest(toolCall: call("update_automation", [
            "automationID": .string("id-1"),
            "intervalSeconds": .number(300),
        ])) == .update(
            automationID: "id-1",
            name: nil,
            intervalSeconds: 300,
            instruction: nil,
            schedule: nil
        ))
        #expect(throws: AutomationToolError.missingArgument("automationID")) {
            try AutomationToolRequest(toolCall: call("update_automation"))
        }
        #expect(throws: AutomationToolError.invalidInterval) {
            try AutomationToolRequest(toolCall: call("update_automation", [
                "automationID": .string("id-1"),
                "intervalSeconds": .number(30),
            ]))
        }
        #expect(try AutomationToolRequest(toolCall: call("cancel_automation", [
            "automationID": .string(" id-1 "),
        ])) == .cancel(automationID: "id-1"))
    }

    @Test func parsesAndValidatesAutomationSchedules() throws {
        #expect(try AutomationToolRequest(toolCall: call("create_automation", [
            "intervalSeconds": .number(300),
            "instruction": .string("Watch."),
            "windowStart": .string("08:00"),
            "windowEnd": .string("18:00"),
            "activeDays": .string("mon, tue, wed, thu, fri"),
        ])) == .create(
            name: "Automation",
            intervalSeconds: 300,
            instruction: "Watch.",
            schedule: AutomationSchedule(
                startMinute: 480,
                endMinute: 1_080,
                weekdays: [2, 3, 4, 5, 6]
            )
        ))

        for arguments: [String: ChatToolValue] in [
            ["windowStart": .string("08:00")],
            ["windowStart": .string("8:00"), "windowEnd": .string("18:00")],
            ["windowStart": .string("08:00"), "windowEnd": .string("08:00")],
        ] {
            #expect(throws: AutomationToolError.invalidWindow) {
                try AutomationToolRequest(toolCall: call("create_automation", arguments.merging([
                    "intervalSeconds": .number(300), "instruction": .string("Watch."),
                ]) { current, _ in current }))
            }
        }
        #expect(throws: AutomationToolError.invalidDays) {
            try AutomationToolRequest(toolCall: call("create_automation", [
                "intervalSeconds": .number(300),
                "instruction": .string("Watch."),
                "activeDays": .string("weekdays"),
            ]))
        }
    }

    @Test func scheduleAllowsSameDayAndOvernightWindows() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let workday = AutomationSchedule(startMinute: 480, endMinute: 1_080, weekdays: [2, 3, 4, 5, 6])
        let overnight = AutomationSchedule(startMinute: 1_320, endMinute: 360, weekdays: [2])

        #expect(workday.allows(date(2026, 1, 5, 8, 0, calendar), calendar: calendar))
        #expect(workday.allows(date(2026, 1, 5, 17, 59, calendar), calendar: calendar))
        #expect(!workday.allows(date(2026, 1, 5, 18, 0, calendar), calendar: calendar))
        #expect(!workday.allows(date(2026, 1, 4, 9, 0, calendar), calendar: calendar))
        #expect(overnight.allows(date(2026, 1, 5, 22, 0, calendar), calendar: calendar))
        #expect(overnight.allows(date(2026, 1, 6, 5, 59, calendar), calendar: calendar))
        #expect(!overnight.allows(date(2026, 1, 6, 6, 0, calendar), calendar: calendar))
        #expect(!overnight.allows(date(2026, 1, 6, 22, 0, calendar), calendar: calendar))
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
        #expect(throws: AutomationToolError.invalidBoolean("terminalAccess")) {
            try AutomationToolRequest(toolCall: call("create_automation", [
                "intervalSeconds": .number(120),
                "instruction": .string("Watch."),
                "terminalAccess": .string("yes"),
            ]))
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

    @Test func automationStoreDecodesRecordsWithoutSchedules() throws {
        let suite = "AutomationLegacyTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"[{"id":"one","name":"Watch","intervalSeconds":60,"instruction":"Check."}]"#.utf8), forKey: AutomationStore.storageKey)

        let automation = try #require(AutomationStore(defaults: defaults).load().first)
        #expect(automation.schedule == nil)
        #expect(automation.isEnabled)
        #expect(!automation.terminalAccess)
        #expect(automation.chatID == nil)
    }

    @Test func engineRunsDueAutomationsAndNotifiesOnPrefix() async throws {
        let suite = "AutomationEngineTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var current = Date(timeIntervalSince1970: 1_000)
        let engine = AutomationEngine(defaults: defaults, now: { current })
        var notified: [(String, String)] = []
        engine.onNotify = {
            notified.append(($0.name, $0.message))
            return true
        }
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

    @Test func pausedAndDisconnectedTerminalAutomationsDoNotRun() async throws {
        let suite = "AutomationPausedTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = AutomationEngine(defaults: defaults)
        var runCount = 0
        engine.runner = { _ in runCount += 1; return "NOTHING" }
        let paused = engine.add(name: "Paused", intervalSeconds: 60, instruction: "Check.")
        _ = engine.update(id: paused.id, isEnabled: false)
        _ = engine.add(
            name: "Terminal",
            intervalSeconds: 60,
            instruction: "Check.",
            chatID: UUID(),
            terminalAccess: true
        )

        engine.tick()
        await waitUntil { false }

        #expect(runCount == 0)
        #expect(engine.list().first { $0.name == "Terminal" }?.lastRun != nil)
    }

    @Test func failedMainChatDeliveryPausesAutomation() async throws {
        let suite = "AutomationDeliveryTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = AutomationEngine(defaults: defaults)
        engine.runner = { _ in "NOTIFY: important" }
        engine.onNotify = { _ in false }
        let automation = engine.add(name: "Watch", intervalSeconds: 60, instruction: "Check.")

        engine.tick()
        await waitUntil { engine.list().first?.lastDeliveryStatus == "failed" }

        #expect(engine.list().first?.isEnabled == false)
        #expect(engine.list().first?.id == automation.id)
    }

    @Test func engineLogsRunsAndEditsWithoutOverwritingLastRun() async throws {
        let suite = "AutomationRunLogTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("automation-run-log-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = LLMLog(directory: directory)
        let start = Date(timeIntervalSince1970: 1_000)
        let engine = AutomationEngine(defaults: defaults, now: { start }, log: log)
        engine.runner = { _ in "NOTIFY: inbox changed" }
        let automation = engine.add(
            name: "Inbox watch",
            intervalSeconds: 300,
            instruction: "Check the inbox.",
            schedule: AutomationSchedule(startMinute: nil, endMinute: nil, weekdays: nil)
        )

        engine.tick()
        for _ in 0..<200 where await log.automationRuns().first?.endedAt == nil {
            await Task.yield()
        }

        let logged = try #require(await log.automationRuns().first)
        #expect(logged.name == "Inbox watch")
        #expect(logged.status == "completed")
        #expect(await log.automationEntries(automationID: automation.id, runID: logged.id).last?.text
            .contains("inbox changed") == true)

        let lastRun = try #require(engine.list().first?.lastRun)
        let edited = engine.edit(
            id: automation.id,
            name: "Inbox and calendar",
            intervalSeconds: 600,
            instruction: "Check both.",
            schedule: nil
        )
        #expect(edited?.schedule == nil)
        #expect(edited?.lastRun == lastRun)
    }

    @Test func engineRunsAnOverdueAutomationWhenItsWindowOpens() async throws {
        let suite = "AutomationWindowTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        var current = date(2026, 1, 5, 7, 59, calendar)
        let engine = AutomationEngine(defaults: defaults, now: { current }, calendar: calendar)
        var runCount = 0
        engine.runner = { _ in runCount += 1; return "NOTHING" }
        _ = engine.add(
            name: "Workday",
            intervalSeconds: 60,
            instruction: "Watch.",
            schedule: AutomationSchedule(startMinute: 480, endMinute: 1_080, weekdays: [2, 3, 4, 5, 6])
        )

        engine.tick()
        await waitUntil { false }
        #expect(runCount == 0)

        current = date(2026, 1, 5, 8, 0, calendar)
        engine.tick()
        await waitUntil { runCount == 1 }
        #expect(runCount == 1)
    }

    @Test func engineRequiresTheExactNotifyPrefix() async throws {
        let suite = "AutomationPrefixTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var current = Date(timeIntervalSince1970: 1_000)
        let engine = AutomationEngine(defaults: defaults, now: { current })
        var notified: [(String, String)] = []
        engine.onNotify = {
            notified.append(($0.name, $0.message))
            return true
        }
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
        engine.onNotify = { _ in notified += 1; return true }
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

    @Test func runNowIgnoresScheduleAndIntervalAndStampsLastRun() async throws {
        let suite = "AutomationRunNowTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let current = date(2026, 1, 4, 7, 0, calendar) // Sunday, before the window
        let engine = AutomationEngine(defaults: defaults, now: { current }, calendar: calendar)
        var runCount = 0
        engine.runner = { _ in runCount += 1; return "NOTHING" }
        let automation = engine.add(
            name: "Workday",
            intervalSeconds: 60,
            instruction: "Watch.",
            schedule: AutomationSchedule(startMinute: 480, endMinute: 1_080, weekdays: [2, 3, 4, 5, 6])
        )

        engine.tick()
        await waitUntil { false }
        #expect(runCount == 0)

        #expect(engine.runNow(id: automation.id))
        await waitUntil { runCount == 1 }
        #expect(runCount == 1)
        #expect(engine.list().first?.lastRun == current)
    }

    @Test func runNowRejectsUnknownAndInFlightAutomations() async throws {
        let suite = "AutomationRunNowBusyTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = AutomationEngine(defaults: defaults)
        var release: CheckedContinuation<Void, Never>?
        engine.runner = { _ in
            await withCheckedContinuation { release = $0 }
            return "NOTHING"
        }
        let automation = engine.add(name: "Slow", intervalSeconds: 60, instruction: "Watch.")

        #expect(!engine.runNow(id: "missing"))
        #expect(engine.runNow(id: automation.id))
        await waitUntil { release != nil }
        #expect(!engine.runNow(id: automation.id))

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
            instruction: "Check #ops.",
            schedule: AutomationSchedule(startMinute: 480, endMinute: 1_080, weekdays: [2, 3, 4, 5, 6])
        ))
        #expect(created.response["status"]?.stringValue == "created")
        #expect(created.response["schedule"]?.stringValue == "08:00–18:00 on Mon, Tue, Wed, Thu, Fri")
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

    @Test func serviceUpdatesOnlyProvidedFields() async throws {
        let suite = "AutomationUpdateTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = AutomationEngine(defaults: defaults)
        let service = AutomationToolService(engine: engine)

        let created = await service.execute(.create(
            name: "Slack watch",
            intervalSeconds: 120,
            instruction: "Check #ops.",
            schedule: AutomationSchedule(startMinute: 480, endMinute: 1_080, weekdays: nil)
        ))
        let automationID = try #require(created.response["automationID"]?.stringValue)

        let updated = await service.execute(.update(
            automationID: automationID,
            name: nil,
            intervalSeconds: 600,
            instruction: "Check #ops and #eng.",
            schedule: nil
        ))
        #expect(updated.response["status"]?.stringValue == "updated")

        let record = try #require(engine.list().first)
        #expect(record.name == "Slack watch")
        #expect(record.intervalSeconds == 600)
        #expect(record.instruction == "Check #ops and #eng.")
        #expect(record.schedule == AutomationSchedule(startMinute: 480, endMinute: 1_080, weekdays: nil))

        let missing = await service.execute(.update(
            automationID: "gone",
            name: nil,
            intervalSeconds: nil,
            instruction: nil,
            schedule: nil
        ))
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

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        _ calendar: Calendar
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }
}
