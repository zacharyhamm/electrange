import Foundation
import Testing
@testable import electragne

@MainActor
struct AppStatusExecutorTests {
    @Test func reportsActiveTimersAndArmedCalendarReminders() async throws {
        let now = Date(timeIntervalSince1970: 1_768_000_000)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = TimerStore(defaults: defaults)
        store.save([
            TimerRecord(id: "expired", label: "Old", fireDate: now.addingTimeInterval(-10)),
            TimerRecord(id: "tea", label: "Tea", fireDate: now.addingTimeInterval(120)),
        ])

        let event = CalendarEventDetails(
            id: "event-1", summary: "Planning", start: now.addingTimeInterval(3_600),
            end: now.addingTimeInterval(7_200), isAllDay: false,
            description: nil, location: nil, status: "confirmed",
            attendees: [], calendarURL: nil, hangoutURL: nil, conferenceURLs: []
        )
        let monitor = CalendarReminderMonitor(
            events: StatusEventProvider(event: event),
            scheduler: StatusScheduler(),
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            now: { now }
        )
        await monitor.refresh()

        let executor = AppStatusExecutor(monitor: monitor, timerStore: store, now: { now })
        let call = ChatToolCall(id: "test", name: "report_app_status", arguments: [:])
        let action = try await executor.prepare(call)
        #expect(action.confirmation == nil)
        let result = await action.execute()

        #expect(result.response["status"]?.stringValue == "ok")
        let timers = result.response["timers"]?.arrayValue ?? []
        #expect(timers.count == 1)
        #expect(timers[0].objectValue?["label"]?.stringValue == "Tea")
        #expect(timers[0].objectValue?["remainingSeconds"]?.numberValue == 120)

        let reminders = result.response["calendarReminders"]?.objectValue
        let upcoming = reminders?["upcoming"]?.arrayValue ?? []
        #expect(upcoming.count == 1)
        #expect(upcoming[0].objectValue?["event"]?.stringValue == "Planning")
        #expect(reminders?["leadTimeSeconds"]?.numberValue == CalendarReminderMonitor.leadTime)

        // Read-only: the expired record must not be pruned from the store.
        #expect(store.load().count == 2)
    }

    @Test func reportsMonitoringOffWithoutAMonitor() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let executor = AppStatusExecutor(monitor: nil, timerStore: TimerStore(defaults: defaults))
        let action = try await executor.prepare(
            ChatToolCall(id: "test", name: "report_app_status", arguments: [:])
        )
        let result = await action.execute()

        #expect(result.response["status"]?.stringValue == "ok")
        let reminders = result.response["calendarReminders"]?.objectValue
        #expect(reminders?["monitoring"]?.boolValue == false)
        #expect(result.response["timers"]?.arrayValue?.isEmpty == true)
    }
}

@MainActor
private final class StatusEventProvider: CalendarEventProviding {
    let event: CalendarEventDetails
    init(event: CalendarEventDetails) { self.event = event }
    func events(from start: Date, to end: Date) async throws -> [CalendarEventDetails] { [event] }
    func event(id: String) async throws -> CalendarEventDetails? { event }
}

@MainActor
private final class StatusScheduler: CalendarReminderScheduling {
    final class Token: CalendarReminderTimer {
        func cancel() {}
    }
    func schedule(at date: Date, action: @escaping @MainActor () -> Void) -> any CalendarReminderTimer {
        Token()
    }
}
