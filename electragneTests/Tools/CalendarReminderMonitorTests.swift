import Foundation
import Testing
@testable import electragne

@MainActor
struct CalendarReminderMonitorTests {
    @Test func reconcilesReschedulesAndRevalidatesBeforeDelivery() async {
        let now = Date(timeIntervalSince1970: 1_768_000_000)
        let original = event(start: now.addingTimeInterval(3_600))
        let moved = event(start: now.addingTimeInterval(7_200))
        let provider = ReminderEventProvider(snapshot: [original], current: original)
        let scheduler = ReminderScheduler()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let monitor = CalendarReminderMonitor(
            events: provider, scheduler: scheduler, defaults: defaults,
            now: { now }, calendar: utcCalendar
        )
        var delivered: [CalendarEventDetails] = []
        monitor.onReminder = { delivered.append($0); return true }

        await monitor.refresh()
        #expect(scheduler.entries.count == 1)
        #expect(scheduler.entries[0].date == original.start?.addingTimeInterval(-180))

        provider.snapshot = [moved]
        provider.current = moved
        await monitor.refresh()
        #expect(scheduler.entries[0].token.cancelled)
        #expect(scheduler.entries.count == 2)
        #expect(scheduler.entries[1].date == moved.start?.addingTimeInterval(-180))

        scheduler.fire(1)
        await Task.yield()
        await Task.yield()
        #expect(delivered == [moved])

        provider.snapshot = [original]
        provider.current = nil
        let deletionScheduler = ReminderScheduler()
        let deletionMonitor = CalendarReminderMonitor(
            events: provider, scheduler: deletionScheduler,
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            now: { now }, calendar: utcCalendar
        )
        var deletedDelivered = false
        deletionMonitor.onReminder = { _ in deletedDelivered = true; return true }
        await deletionMonitor.refresh()
        deletionScheduler.fire(0)
        await Task.yield()
        await Task.yield()
        #expect(!deletedDelivered)
    }

    @Test func notifiesImmediatelyAndDeduplicatesAnEventInsideLeadTime() async {
        let now = Date(timeIntervalSince1970: 1_768_000_000)
        let upcoming = event(start: now.addingTimeInterval(60))
        let provider = ReminderEventProvider(snapshot: [upcoming], current: upcoming)
        let scheduler = ReminderScheduler()
        let monitor = CalendarReminderMonitor(
            events: provider, scheduler: scheduler,
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            now: { now }, calendar: utcCalendar
        )
        var delivered = 0
        monitor.onReminder = { _ in delivered += 1; return true }

        await monitor.refresh()
        await monitor.refresh()

        #expect(delivered == 1)
        #expect(scheduler.entries.isEmpty)
    }

    @Test func fetchesFarEnoughPastMidnightToScheduleTheLeadTimeReminder() async {
        let now = utcCalendar.date(from: DateComponents(
            year: 2026, month: 7, day: 15, hour: 23, minute: 55
        ))!
        let start = utcCalendar.date(from: DateComponents(
            year: 2026, month: 7, day: 16, hour: 0, minute: 5
        ))!
        let upcoming = event(start: start)
        let provider = ReminderEventProvider(snapshot: [upcoming], current: upcoming)
        let scheduler = ReminderScheduler()
        let monitor = CalendarReminderMonitor(
            events: provider, scheduler: scheduler,
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            now: { now }, calendar: utcCalendar
        )

        await monitor.refresh()

        #expect(provider.requests == [utcCalendar.startOfDay(for: now)..<start.addingTimeInterval(600)])
        #expect(scheduler.entries.map(\.date) == [start.addingTimeInterval(-180)])
    }

    @Test func retainsNextDayDeduplicationBeforeMidnight() async {
        let now = utcCalendar.date(from: DateComponents(
            year: 2026, month: 7, day: 15, hour: 23, minute: 58
        ))!
        let start = utcCalendar.date(from: DateComponents(
            year: 2026, month: 7, day: 16
        ))!
        let upcoming = event(start: start)
        let provider = ReminderEventProvider(snapshot: [upcoming], current: upcoming)
        let monitor = CalendarReminderMonitor(
            events: provider, scheduler: ReminderScheduler(),
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            now: { now }, calendar: utcCalendar
        )
        var delivered = 0
        monitor.onReminder = { _ in delivered += 1; return true }

        await monitor.refresh()
        await monitor.refresh()

        #expect(delivered == 1)
    }

    @Test func retriesAnUndeliveredReminderOnTheNextRefresh() async {
        let now = Date(timeIntervalSince1970: 1_768_000_000)
        let upcoming = event(start: now.addingTimeInterval(60))
        let provider = ReminderEventProvider(snapshot: [upcoming], current: upcoming)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let monitor = CalendarReminderMonitor(
            events: provider, scheduler: ReminderScheduler(), defaults: defaults,
            now: { now }, calendar: utcCalendar
        )
        var attempts = 0
        var deliverable = false
        monitor.onReminder = { _ in attempts += 1; return deliverable }

        await monitor.refresh()
        #expect(attempts == 1)
        #expect(defaults.stringArray(forKey: CalendarReminderMonitor.firedStorageKey) ?? [] == [])

        deliverable = true
        await monitor.refresh()
        #expect(attempts == 2)
        #expect(defaults.stringArray(forKey: CalendarReminderMonitor.firedStorageKey)?.count == 1)

        await monitor.refresh()
        #expect(attempts == 2)
    }

    @Test func retriesOnceWhenTheFireTimeFetchFails() async {
        let now = Date(timeIntervalSince1970: 1_768_000_000)
        let upcoming = event(start: now.addingTimeInterval(3_600))
        let provider = ReminderEventProvider(snapshot: [upcoming], current: upcoming)
        let scheduler = ReminderScheduler()
        let monitor = CalendarReminderMonitor(
            events: provider, scheduler: scheduler,
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            now: { now }, calendar: utcCalendar
        )
        var delivered = 0
        monitor.onReminder = { _ in delivered += 1; return true }

        await monitor.refresh()
        #expect(scheduler.entries.count == 1)

        provider.currentError = TestError.network
        scheduler.fire(0)
        await drainMainActor()
        #expect(delivered == 0)
        #expect(scheduler.entries.count == 2)
        #expect(scheduler.entries[1].date == now.addingTimeInterval(CalendarReminderMonitor.fetchRetryDelay))

        provider.currentError = nil
        scheduler.fire(1)
        await drainMainActor()
        #expect(delivered == 1)

        // The retry is single-shot: a second consecutive failure stops.
        provider.currentError = TestError.network
        scheduler.fire(1)
        await drainMainActor()
        #expect(scheduler.entries.count == 2)
    }

    private func drainMainActor() async {
        for _ in 0..<4 { await Task.yield() }
    }

    @Test func exposesScheduledRemindersAsUpcomingSnapshot() async {
        let now = Date(timeIntervalSince1970: 1_768_000_000)
        let upcoming = event(start: now.addingTimeInterval(3_600))
        let provider = ReminderEventProvider(snapshot: [upcoming], current: upcoming)
        let monitor = CalendarReminderMonitor(
            events: provider, scheduler: ReminderScheduler(),
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            now: { now }, calendar: utcCalendar
        )

        #expect(!monitor.isMonitoring)
        #expect(monitor.upcomingReminders.isEmpty)

        await monitor.refresh()

        let reminders = monitor.upcomingReminders
        #expect(reminders.count == 1)
        #expect(reminders[0].eventID == upcoming.id)
        #expect(reminders[0].summary == upcoming.summary)
        #expect(reminders[0].eventStart == upcoming.start)
        #expect(reminders[0].notifyAt == upcoming.start?.addingTimeInterval(-CalendarReminderMonitor.leadTime))
    }

    @Test func extractsMeetingLinksAndFormatsAttendees() {
        let zoom = URL(string: "https://acme.zoom.us/j/123")!
        let details = event(
            start: Date(timeIntervalSince1970: 1_768_003_600),
            description: "Agenda: https://example.com/doc",
            location: zoom.absoluteString,
            attendees: [.init(name: "Ada", email: "ada@example.com", responseStatus: "accepted", isSelf: false)]
        )

        #expect(details.joinURL == zoom)
        #expect(details.reminderLinks.contains(zoom))
        #expect(details.reminderPrompt.contains("Ada <ada@example.com> (accepted)"))
        #expect(details.reminderPrompt.contains("https://example.com/doc"))
    }

    @Test func joinURLRejectsLookalikeAndInsecureHosts() {
        func details(location: String) -> CalendarEventDetails {
            event(start: Date(timeIntervalSince1970: 1_768_003_600), location: location)
        }
        #expect(details(location: "https://zoom.evil.com/x").joinURL == nil)
        #expect(details(location: "https://notzoom.us/x").joinURL == nil)
        #expect(details(location: "http://acme.zoom.us/j/123").joinURL == nil)
        #expect(details(location: "https://us02web.zoom.us/j/123").joinURL != nil)
        #expect(details(location: "https://meet.google.com/abc-defg-hij").joinURL != nil)
    }

    @Test func eligibilityRejectsDeclinedCancelledAndAllDayEvents() {
        let start = Date(timeIntervalSince1970: 1_768_003_600)
        let declined = CalendarEventDetails.Attendee(
            name: nil, email: "me@example.com", responseStatus: "declined", isSelf: true
        )
        let base = event(start: start)
        #expect(base.isEligibleForReminder)
        #expect(!event(start: start, attendees: [declined]).isEligibleForReminder)
        #expect(!CalendarEventDetails(
            id: base.id, summary: base.summary, start: start, end: base.end,
            isAllDay: false, description: nil, location: nil, status: "cancelled",
            attendees: [], calendarURL: nil, hangoutURL: nil, conferenceURLs: []
        ).isEligibleForReminder)
        #expect(!CalendarEventDetails(
            id: base.id, summary: base.summary, start: nil, end: nil,
            isAllDay: true, description: nil, location: nil, status: "confirmed",
            attendees: [], calendarURL: nil, hangoutURL: nil, conferenceURLs: []
        ).isEligibleForReminder)
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func event(
        start: Date,
        description: String? = nil,
        location: String? = nil,
        attendees: [CalendarEventDetails.Attendee] = []
    ) -> CalendarEventDetails {
        CalendarEventDetails(
            id: "event-1", summary: "Planning", start: start,
            end: start.addingTimeInterval(3_600), isAllDay: false,
            description: description, location: location, status: "confirmed",
            attendees: attendees, calendarURL: nil, hangoutURL: nil,
            conferenceURLs: []
        )
    }
}

private enum TestError: Error {
    case network
}

@MainActor
private final class ReminderEventProvider: CalendarEventProviding {
    var snapshot: [CalendarEventDetails]
    var current: CalendarEventDetails?
    var currentError: Error?
    var requests: [Range<Date>] = []

    init(snapshot: [CalendarEventDetails], current: CalendarEventDetails?) {
        self.snapshot = snapshot
        self.current = current
    }

    func events(from start: Date, to end: Date) async throws -> [CalendarEventDetails] {
        requests.append(start..<end)
        return snapshot
    }
    func event(id: String) async throws -> CalendarEventDetails? {
        if let currentError { throw currentError }
        return current
    }
}

@MainActor
private final class ReminderScheduler: CalendarReminderScheduling {
    struct Entry {
        let date: Date
        let token: Token
        let action: @MainActor () -> Void
    }

    final class Token: CalendarReminderTimer {
        var cancelled = false
        func cancel() { cancelled = true }
    }

    var entries: [Entry] = []

    func schedule(at date: Date, action: @escaping @MainActor () -> Void) -> any CalendarReminderTimer {
        let token = Token()
        entries.append(Entry(date: date, token: token, action: action))
        return token
    }

    func fire(_ index: Int) {
        let entry = entries[index]
        if !entry.token.cancelled { entry.action() }
    }
}
