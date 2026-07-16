import Foundation
import Testing
@testable import electragne

struct CalendarToolRequestTests {
    @Test func parsesListSearchAndCreateRequests() throws {
        #expect(try CalendarToolRequest(toolCall: call("list_google_calendars")) == .listCalendars(accountID: nil))
        #expect(try CalendarToolRequest(toolCall: call(
            "list_calendar_events",
            ["query": .string(" lunch "), "calendarID": .string("work"), "limit": .number(5)]
        )) == .listEvents(
            calendarID: "work", query: "lunch", timeMin: nil, timeMax: nil,
            accountID: nil, limit: 5
        ))
        #expect(try CalendarToolRequest(toolCall: call(
            "create_calendar_event",
            [
                "summary": .string("Planning"),
                "start": .string("2026-07-16T09:00:00-05:00"),
                "end": .string("2026-07-16T10:00:00-05:00"),
            ]
        )) == .createEvent(
            calendarID: nil, summary: "Planning",
            start: "2026-07-16T09:00:00-05:00", end: "2026-07-16T10:00:00-05:00",
            description: nil, location: nil, accountID: nil
        ))
    }

    @Test func validatesDatesRangesAndLimits() {
        #expect(throws: CalendarToolError.invalidRange) {
            try CalendarToolRequest(toolCall: call(
                "create_calendar_event",
                [
                    "summary": .string("Bad"), "start": .string("2026-07-17"),
                    "end": .string("2026-07-16"),
                ]
            ))
        }
        #expect(throws: CalendarToolError.invalidDateTime("start")) {
            try CalendarToolRequest(toolCall: call(
                "create_calendar_event",
                ["summary": .string("Bad"), "start": .string("tomorrow"), "end": .string("2026-07-17")]
            ))
        }
        #expect(throws: CalendarToolError.invalidLimit) {
            try CalendarToolRequest(toolCall: call("list_calendar_events", ["limit": .number(51)]))
        }
        #expect(throws: CalendarToolError.invalidLimit) {
            try CalendarToolRequest(toolCall: call("list_calendar_events", ["limit": .number(1e300)]))
        }
        #expect(throws: CalendarToolError.invalidRange) {
            try CalendarToolRequest(toolCall: call(
                "create_calendar_event",
                [
                    "summary": .string("Bad"), "start": .string("2026-07-16"),
                    "end": .string("2026-07-16T10:00:00-05:00"),
                ]
            ))
        }
    }

    private func call(_ name: String, _ arguments: [String: ChatToolValue] = [:]) -> ChatToolCall {
        ChatToolCall(id: "test", name: name, arguments: arguments)
    }
}

@MainActor
struct CalendarToolServiceTests {
    @Test func listsCalendarsAndConfirmsBeforeCreatingEvent() async throws {
        let tokens = CalendarMockTokens()
        let transport = CalendarMockTransport()
        let service = CalendarToolService(accounts: tokens, transport: transport)

        let list = try await service.prepare(.listCalendars(accountID: nil))
        #expect(list.confirmation == nil)
        let listed = await service.execute(list)
        let calendars = listed.response["calendars"]?.arrayValue
        #expect(calendars?.first?.objectValue?["calendarID"]?.stringValue == "primary@example.com")
        #expect(transport.requests.first?.query["maxResults"] == "250")

        let events = CalendarToolRequest.listEvents(
            calendarID: "work@example.com", query: "planning",
            timeMin: "2026-08-01T09:00:00-05:00", timeMax: nil,
            accountID: nil, limit: 5
        )
        let listedEvents = await service.execute(try await service.prepare(events))
        #expect(listedEvents.response["events"]?.arrayValue?.count == 1)
        #expect(transport.requests.last?.path == "calendar/v3/calendars/work%40example.com/events")
        #expect(transport.requests.last?.query["q"] == "planning")
        #expect(transport.requests.last?.query["maxResults"] == "5")
        #expect(transport.requests.last?.query["timeMin"] == "2026-08-01T09:00:00-05:00")
        #expect(transport.requests.last?.query["timeMax"] == "2026-08-31T14:00:00Z")

        let create = CalendarToolRequest.createEvent(
            calendarID: nil, summary: "Lunch",
            start: "2026-07-16T12:00:00-05:00", end: "2026-07-16T13:00:00-05:00",
            description: "Tacos", location: "Cafe", accountID: nil
        )
        let prepared = try await service.prepare(create)
        #expect(prepared.confirmation?.actionLabel == "Create Event")
        #expect(prepared.confirmation?.details.contains { $0.label == "Description" && $0.value == "Tacos" } == true)
        #expect(transport.requests.count == 2)

        let created = await service.execute(prepared)
        #expect(created.response["status"]?.stringValue == "created")
        #expect(created.response["eventID"]?.stringValue == "event-1")
        #expect(transport.requests.last?.method == "POST")
        #expect(transport.requests.last?.path == "calendar/v3/calendars/primary/events")
        let body = try #require(transport.requests.last?.body)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let start = try #require(json["start"] as? [String: Any])
        #expect(start["dateTime"] as? String == "2026-07-16T12:00:00-05:00")
        #expect(start["date"] == nil)

        let reminderEvents = try await service.events(
            from: Date(timeIntervalSince1970: 1_768_000_000),
            to: Date(timeIntervalSince1970: 1_768_086_400)
        )
        let reminder = try #require(reminderEvents.first)
        #expect(reminder.attendees.first?.isSelf == true)
        #expect(reminder.attendees.first?.responseStatus == "accepted")
        #expect(reminder.conferenceURLs.first?.host == "meet.google.com")

        let revalidated = try await service.event(id: "event-3")
        #expect(revalidated?.id == "event-3")
    }
}

@MainActor
private final class CalendarMockTokens: GoogleTokenProviding {
    let accounts = [GoogleAccount(id: "a1", email: "one@example.com", displayName: "One")]
    let defaultAccountID: String? = "a1"
    func resolveAccount(id: String?) throws -> GoogleAccount { accounts[0] }
    func freshAccessToken(for accountID: String) async throws -> String { "token" }
}

@MainActor
private final class CalendarMockTransport: GoogleAPITransporting {
    struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let body: Data?
    }
    var requests: [Request] = []

    func data(
        accountID: String, method: String, path: String,
        query: [URLQueryItem], body: Data?
    ) async throws -> Data {
        requests.append(Request(
            method: method, path: path,
            query: Dictionary(uniqueKeysWithValues: query.compactMap { item in
                item.value.map { (item.name, $0) }
            }),
            body: body
        ))
        switch (method, path) {
        case ("GET", "calendar/v3/users/me/calendarList"):
            return Data(#"{"items":[{"id":"primary@example.com","summary":"My Calendar","primary":true,"accessRole":"owner"}]}"#.utf8)
        case ("POST", "calendar/v3/calendars/primary/events"):
            return Data(#"{"id":"event-1","summary":"Lunch","status":"confirmed","htmlLink":"https://calendar.google.com/event","start":{"dateTime":"2026-07-16T12:00:00-05:00"},"end":{"dateTime":"2026-07-16T13:00:00-05:00"}}"#.utf8)
        case ("GET", "calendar/v3/calendars/work%40example.com/events"):
            return Data(#"{"items":[{"id":"event-2","summary":"Planning","status":"confirmed","start":{"dateTime":"2026-08-01T09:00:00-05:00"},"end":{"dateTime":"2026-08-01T10:00:00-05:00"}}]}"#.utf8)
        case ("GET", "calendar/v3/calendars/primary/events"):
            return Data(#"{"items":[{"id":"event-3","summary":"Standup","status":"confirmed","attendees":[{"email":"me@example.com","self":true,"responseStatus":"accepted"}],"conferenceData":{"entryPoints":[{"entryPointType":"video","uri":"https://meet.google.com/abc-defg-hij"}]},"start":{"dateTime":"2026-01-09T09:00:00Z"},"end":{"dateTime":"2026-01-09T09:30:00Z"}}]}"#.utf8)
        case ("GET", "calendar/v3/calendars/primary/events/event-3"):
            return Data(#"{"id":"event-3","summary":"Standup","status":"confirmed","start":{"dateTime":"2026-01-09T09:00:00Z"},"end":{"dateTime":"2026-01-09T09:30:00Z"}}"#.utf8)
        default:
            throw CalendarToolError.invalidResponse
        }
    }
}
