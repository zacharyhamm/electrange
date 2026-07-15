import Foundation
import Testing
@testable import electragne

struct TimerToolTests {
    @Test func parsesTimerRequestsAndDefaultsTheLabel() throws {
        #expect(try TimerToolRequest(toolCall: call("create_timer", [
            "label": .string("  Tea  "),
            "durationSeconds": .number(300),
        ])) == .create(label: "Tea", durationSeconds: 300))

        #expect(try TimerToolRequest(toolCall: call("create_timer", [
            "durationSeconds": .number(25),
        ])) == .create(label: "Timer", durationSeconds: 25))
        #expect(try TimerToolRequest(toolCall: call("list_timers")) == .list)
        #expect(try TimerToolRequest(toolCall: call("cancel_timer", [
            "timerID": .string(" id-1 "),
        ])) == .cancel(timerID: "id-1"))
    }

    @Test func rejectsInvalidDurationsAndMissingIDs() {
        for value in [0.0, -1, 1.5, 604_801, .infinity] {
            #expect(throws: TimerToolError.invalidDuration) {
                try TimerToolRequest(toolCall: call("create_timer", [
                    "durationSeconds": .number(value),
                ]))
            }
        }
        #expect(throws: TimerToolError.missingArgument("timerID")) {
            try TimerToolRequest(toolCall: call("cancel_timer"))
        }
    }

    @Test func formatsDurationsForConfirmationAndReplies() {
        #expect(TimerToolService.durationText(1) == "1 second")
        #expect(TimerToolService.durationText(65) == "1 minute 5 seconds")
        #expect(TimerToolService.durationText(90_061) == "1 day 1 hour 1 minute 1 second")
    }

    @Test func timerStoreRoundTripsRecords() throws {
        let suite = "TimerToolTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TimerStore(defaults: defaults)
        let timers = [TimerRecord(id: "one", label: "Tea", fireDate: Date(timeIntervalSince1970: 100))]

        store.save(timers)

        #expect(store.load() == timers)
    }

    @MainActor
    @Test func serviceCreatesListsAndCancelsTimers() async throws {
        let suite = "TimerToolServiceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let scheduler = MockTimerScheduler()
        let now = Date(timeIntervalSince1970: 1_000)
        let service = TimerToolService(
            store: TimerStore(defaults: defaults),
            scheduler: scheduler,
            now: { now }
        )

        let created = await service.execute(.create(label: "Tea", durationSeconds: 300))
        #expect(created.response["status"]?.stringValue == "created")
        let timerID = try #require(created.response["timerID"]?.stringValue)
        #expect(scheduler.scheduled == [MockTimerScheduler.Scheduled(
            id: timerID,
            label: "Tea",
            fireDate: now.addingTimeInterval(300)
        )])

        let listed = await service.execute(.list)
        #expect(listed.response["count"]?.numberValue == 1)
        #expect(listed.response["results"]?.arrayValue?.count == 1)

        let cancelled = await service.execute(.cancel(timerID: timerID))
        #expect(cancelled.response["status"]?.stringValue == "cancelled")
        #expect(scheduler.cancelled == [timerID])
        #expect((await service.execute(.list)).response["count"]?.numberValue == 0)
    }

    @MainActor
    @Test func serviceDoesNotStoreTimerWhenNotificationsAreDenied() async throws {
        let suite = "TimerToolDeniedTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let scheduler = MockTimerScheduler()
        scheduler.isAuthorized = false
        let store = TimerStore(defaults: defaults)
        let service = TimerToolService(store: store, scheduler: scheduler)

        let result = await service.execute(.create(label: "Tea", durationSeconds: 60))

        #expect(result.response["status"]?.stringValue == "permission_denied")
        #expect(store.load().isEmpty)
        #expect(scheduler.scheduled.isEmpty)
    }

    private func call(
        _ name: String,
        _ arguments: [String: ChatToolValue] = [:]
    ) -> ChatToolCall {
        ChatToolCall(id: "test", name: name, arguments: arguments)
    }
}

@MainActor
private final class MockTimerScheduler: TimerNotificationScheduling {
    struct Scheduled: Equatable {
        let id: String
        let label: String
        let fireDate: Date
    }

    var isAuthorized = true
    var scheduled: [Scheduled] = []
    var cancelled: [String] = []

    func ensureAuthorization() async -> Bool { isAuthorized }

    func schedule(identifier: String, label: String, fireDate: Date) async throws {
        scheduled.append(Scheduled(id: identifier, label: label, fireDate: fireDate))
    }

    func cancel(identifier: String) {
        cancelled.append(identifier)
    }
}
