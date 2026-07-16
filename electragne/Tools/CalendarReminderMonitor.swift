import Foundation
import os

@MainActor
protocol CalendarReminderTimer: AnyObject {
    func cancel()
}

@MainActor
protocol CalendarReminderScheduling {
    func schedule(at date: Date, action: @escaping @MainActor () -> Void) -> any CalendarReminderTimer
}

@MainActor
private final class CalendarReminderTimerToken: CalendarReminderTimer {
    private var timer: Timer?

    init(date: Date, action: @escaping @MainActor () -> Void) {
        let timer = Timer(fire: date, interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }
}

@MainActor
struct CalendarReminderTimerScheduler: CalendarReminderScheduling {
    func schedule(at date: Date, action: @escaping @MainActor () -> Void) -> any CalendarReminderTimer {
        CalendarReminderTimerToken(date: date, action: action)
    }
}

@MainActor
final class CalendarReminderMonitor {
    static let pollInterval: TimeInterval = 15 * 60
    static let leadTime: TimeInterval = 3 * 60
    static let firedStorageKey = "calendarReminderFiredOccurrences"

    private struct ScheduledReminder {
        let start: Date
        let timer: any CalendarReminderTimer
    }

    private let events: any CalendarEventProviding
    private let scheduler: any CalendarReminderScheduling
    private let defaults: UserDefaults
    private let now: () -> Date
    private let calendar: Calendar
    private let poller = TimerDriver()
    private var scheduled: [String: ScheduledReminder] = [:]
    private var fired: Set<String>
    private var started = false
    var onReminder: (CalendarEventDetails) -> Void = { _ in }

    init(
        events: (any CalendarEventProviding)? = nil,
        scheduler: (any CalendarReminderScheduling)? = nil,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.events = events ?? CalendarToolService()
        self.scheduler = scheduler ?? CalendarReminderTimerScheduler()
        self.defaults = defaults
        self.now = now
        self.calendar = calendar
        self.fired = Set(defaults.stringArray(forKey: Self.firedStorageKey) ?? [])
    }

    func start() {
        guard !started else { return }
        started = true
        Task { await refresh() }
        poller.start(interval: Self.pollInterval) { [weak self] in
            Task { await self?.refresh() }
        }
    }

    func refresh() async {
        let current = now()
        let dayStart = calendar.startOfDay(for: current)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return }
        let fetchEnd = dayEnd.addingTimeInterval(Self.pollInterval)
        pruneFired(to: dayStart..<fetchEnd)

        do {
            let currentEvents = try await events.events(from: dayStart, to: fetchEnd)
            let eligible = currentEvents.filter {
                $0.isEligibleForReminder && ($0.start ?? .distantPast) > current
            }
            let byID = Dictionary(eligible.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })

            for (id, reminder) in scheduled where byID[id]?.start != reminder.start {
                reminder.timer.cancel()
                scheduled[id] = nil
            }
            for event in eligible where scheduled[event.id] == nil && !hasFired(event) {
                await enqueue(event)
            }
        } catch {
            Log.calendar.error("Calendar reminder refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func enqueue(_ event: CalendarEventDetails) async {
        guard let start = event.start, start > now(), !hasFired(event) else { return }
        let fireDate = start.addingTimeInterval(-Self.leadTime)
        if fireDate <= now() {
            await validateAndFire(eventID: event.id, expectedStart: start)
            return
        }

        let timer = scheduler.schedule(at: fireDate) { [weak self] in
            Task { await self?.validateAndFire(eventID: event.id, expectedStart: start) }
        }
        scheduled[event.id] = ScheduledReminder(start: start, timer: timer)
    }

    private func validateAndFire(eventID: String, expectedStart: Date) async {
        if scheduled[eventID]?.start == expectedStart {
            scheduled[eventID] = nil
        }

        do {
            guard let fresh = try await events.event(id: eventID),
                  fresh.isEligibleForReminder,
                  let freshStart = fresh.start,
                  freshStart > now() else { return }

            if freshStart != expectedStart {
                await enqueue(fresh)
                return
            }
            guard !hasFired(fresh) else { return }
            onReminder(fresh)
            fired.insert(occurrenceKey(fresh))
            saveFired()
        } catch {
            Log.calendar.error("Calendar reminder validation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func hasFired(_ event: CalendarEventDetails) -> Bool {
        fired.contains(occurrenceKey(event))
    }

    private func occurrenceKey(_ event: CalendarEventDetails) -> String {
        "\(event.id)|\(event.start?.timeIntervalSince1970 ?? 0)"
    }

    private func pruneFired(to interval: Range<Date>) {
        fired = fired.filter { key in
            guard let separator = key.lastIndex(of: "|"),
                  let seconds = TimeInterval(key[key.index(after: separator)...]) else { return false }
            return interval.contains(Date(timeIntervalSince1970: seconds))
        }
        saveFired()
    }

    private func saveFired() {
        defaults.set(Array(fired), forKey: Self.firedStorageKey)
    }
}

extension CalendarEventDetails {
    var reminderLinks: [URL] {
        var links = conferenceURLs
        if let hangoutURL { links.append(hangoutURL) }
        links += attachments.compactMap(\.url)
        for text in [location, description].compactMap({ $0 }) {
            guard let detector = try? NSDataDetector(
                types: NSTextCheckingResult.CheckingType.link.rawValue
            ) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            links += detector.matches(in: text, range: range).compactMap { match in
                guard let url = match.url,
                      ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
                return url
            }
        }
        if let calendarURL { links.append(calendarURL) }

        var seen = Set<String>()
        return links.filter { seen.insert($0.absoluteString).inserted }
    }

    var joinURL: URL? {
        conferenceURLs.first ?? hangoutURL ?? reminderLinks.first { url in
            guard url.scheme?.lowercased() == "https" else { return false }
            let host = url.host?.lowercased() ?? ""
            return ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com",
                    "webex.com", "whereby.com", "chime.aws"].contains { domain in
                host == domain || host.hasSuffix("." + domain)
            }
        }
    }

    var reminderPrompt: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        var lines = [
            "This calendar event starts in about three minutes. Give me a short, useful summary so I can prepare. Do not call any tools.",
            "Title: \(summary)",
        ]
        if let start { lines.append("Starts: \(formatter.string(from: start))") }
        if let end { lines.append("Ends: \(formatter.string(from: end))") }
        if let location, !location.isEmpty { lines.append("Location: \(location)") }
        if let description, !description.isEmpty { lines.append("Description: \(description)") }
        if let organizer {
            lines.append("Organizer: " + Self.identity(name: organizer.name, email: organizer.email))
        }
        if !attendees.isEmpty {
            lines.append("Attendees: " + attendees.map { attendee in
                let identity = Self.identity(name: attendee.name, email: attendee.email)
                return attendee.responseStatus.map { "\(identity) (\($0))" } ?? identity
            }.joined(separator: ", "))
        }
        if let conferenceCode, !conferenceCode.isEmpty { lines.append("Meeting code: \(conferenceCode)") }
        if !attachments.isEmpty {
            lines.append("Attachments: " + attachments.compactMap { $0.title ?? $0.url?.absoluteString }
                .joined(separator: ", "))
        }
        if !reminderLinks.isEmpty {
            lines.append("Links:\n" + reminderLinks.map { "- \($0.absoluteString)" }.joined(separator: "\n"))
        }
        return lines.joined(separator: "\n")
    }

    private static func identity(name: String?, email: String?) -> String {
        switch (name, email) {
        case let (name?, email?): return "\(name) <\(email)>"
        case let (name?, nil): return name
        case let (nil, email?): return email
        default: return "(unknown)"
        }
    }
}
