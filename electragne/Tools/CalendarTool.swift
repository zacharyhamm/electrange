import Foundation

nonisolated enum CalendarToolRequest: Equatable, Sendable {
    case listCalendars(accountID: String?)
    case listEvents(
        calendarID: String?, query: String?, timeMin: String?, timeMax: String?,
        accountID: String?, limit: Int
    )
    case createEvent(
        calendarID: String?, summary: String, start: String, end: String,
        description: String?, location: String?, accountID: String?
    )

    init(toolCall: ChatToolCall) throws {
        let args = ToolCallArguments(toolCall)
        func value(_ key: String) -> String? { args.string(key) }
        func required(_ key: String) throws -> String {
            try args.required(key, onMissing: CalendarToolError.missingArgument)
        }
        let accountID = value("accountID")
        let calendarID = value("calendarID")

        switch toolCall.name {
        case "list_google_calendars":
            self = .listCalendars(accountID: accountID)
        case "list_calendar_events":
            let limit = try args.limit(default: 20, onInvalid: CalendarToolError.invalidLimit)
            let timeMin = value("timeMin")
            let timeMax = value("timeMax")
            if let timeMin, Self.timestamp(timeMin) == nil { throw CalendarToolError.invalidDateTime("timeMin") }
            if let timeMax, Self.timestamp(timeMax) == nil { throw CalendarToolError.invalidDateTime("timeMax") }
            if let timeMin, let timeMax,
               let minimum = Self.timestamp(timeMin), let maximum = Self.timestamp(timeMax),
               minimum >= maximum {
                throw CalendarToolError.invalidRange
            }
            self = .listEvents(
                calendarID: calendarID, query: value("query"), timeMin: timeMin,
                timeMax: timeMax, accountID: accountID, limit: limit
            )
        case "create_calendar_event":
            let start = try required("start")
            let end = try required("end")
            guard let startValue = Self.eventTime(start) else {
                throw CalendarToolError.invalidDateTime("start")
            }
            guard let endValue = Self.eventTime(end) else {
                throw CalendarToolError.invalidDateTime("end")
            }
            guard startValue.isAllDay == endValue.isAllDay,
                  startValue.date < endValue.date else {
                throw CalendarToolError.invalidRange
            }
            self = .createEvent(
                calendarID: calendarID, summary: try required("summary"),
                start: start, end: end, description: value("description"),
                location: value("location"), accountID: accountID
            )
        default:
            throw CalendarToolError.unsupportedTool(toolCall.name)
        }
    }

    var accountID: String? {
        switch self {
        case .listCalendars(let id): id
        case .listEvents(_, _, _, _, let id, _): id
        case .createEvent(_, _, _, _, _, _, let id): id
        }
    }

    private static func eventTime(_ value: String) -> (date: Date, isAllDay: Bool)? {
        if let date = dateOnly(value) { return (date, true) }
        return timestamp(value).map { ($0, false) }
    }

    private static func dateOnly(_ value: String) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return ToolDate.dayComponents(value, calendar: calendar).flatMap(calendar.date(from:))
    }

    static func timestamp(_ value: String) -> Date? {
        ToolDate.timestamp(value)
    }
}

nonisolated enum CalendarToolError: LocalizedError, Equatable {
    case unsupportedTool(String)
    case missingArgument(String)
    case invalidLimit
    case invalidDateTime(String)
    case invalidRange
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unsupportedTool: "Unsupported Google Calendar tool."
        case .missingArgument(let name): "The ‘\(name)’ argument is required."
        case .invalidLimit: "Calendar result limit must be a whole number from 1 to 50."
        case .invalidDateTime(let name):
            if name == "timeMin" || name == "timeMax" {
                "The ‘\(name)’ value must be an RFC 3339 timestamp with a UTC offset."
            } else {
                "The ‘\(name)’ value must be YYYY-MM-DD or an RFC 3339 timestamp with a UTC offset."
            }
        case .invalidRange: "The Calendar end must be later than the start and use the same date format."
        case .invalidResponse: "Google Calendar returned an unreadable response."
        }
    }
}

nonisolated struct CalendarPreparedRequest: Sendable {
    let request: CalendarToolRequest
    let account: GoogleAccount
    let confirmation: ToolConfirmationDetails?
}

nonisolated struct CalendarEventDetails: Equatable, Sendable {
    nonisolated struct Attendee: Equatable, Sendable {
        let name: String?
        let email: String?
        let responseStatus: String?
        let isSelf: Bool
    }

    nonisolated struct Attachment: Equatable, Sendable {
        let title: String?
        let url: URL?
    }

    let id: String
    let summary: String
    let start: Date?
    let end: Date?
    let isAllDay: Bool
    let description: String?
    let location: String?
    let status: String?
    let attendees: [Attendee]
    let calendarURL: URL?
    let hangoutURL: URL?
    let conferenceURLs: [URL]
    var organizer: Attendee? = nil
    var attachments: [Attachment] = []
    var conferenceCode: String? = nil

    var isEligibleForReminder: Bool {
        !isAllDay
            && start != nil
            && status != "cancelled"
            && !attendees.contains { $0.isSelf && $0.responseStatus == "declined" }
    }
}

@MainActor
protocol CalendarEventProviding {
    func events(from start: Date, to end: Date) async throws -> [CalendarEventDetails]
    func event(id: String) async throws -> CalendarEventDetails?
}

@MainActor
protocol CalendarToolExecuting {
    func prepare(_ request: CalendarToolRequest) async throws -> CalendarPreparedRequest
    func execute(_ prepared: CalendarPreparedRequest) async -> ChatToolResult
}

@MainActor
final class CalendarToolService: CalendarToolExecuting, CalendarEventProviding {
    private let accounts: any GoogleTokenProviding
    private let transport: any GoogleAPITransporting

    init(
        accounts: (any GoogleTokenProviding)? = nil,
        transport: (any GoogleAPITransporting)? = nil
    ) {
        let resolvedAccounts = accounts ?? GoogleOAuthService.shared
        self.accounts = resolvedAccounts
        self.transport = transport ?? GoogleAPITransport(
            tokens: resolvedAccounts,
            baseURL: URL(string: "https://www.googleapis.com")!
        )
    }

    func prepare(_ request: CalendarToolRequest) async throws -> CalendarPreparedRequest {
        let account = try accounts.resolveAccount(id: request.accountID)
        let confirmation: ToolConfirmationDetails?
        switch request {
        case .createEvent(let calendarID, let summary, let start, let end, let description, let location, _):
            var details = [
                (label: "Account", value: account.email),
                (label: "Calendar", value: calendarID ?? "Primary"),
                (label: "Starts", value: start),
                (label: "Ends", value: end),
            ]
            if let location { details.append(("Location", location)) }
            if let description { details.append(("Description", GoogleToolSupport.preview(description))) }
            confirmation = ToolConfirmationDetails(
                title: "Create this Google Calendar event?",
                primaryText: summary,
                details: details,
                actionLabel: "Create Event"
            )
        default:
            confirmation = nil
        }
        return CalendarPreparedRequest(request: request, account: account, confirmation: confirmation)
    }

    func execute(_ prepared: CalendarPreparedRequest) async -> ChatToolResult {
        do {
            switch prepared.request {
            case .listCalendars:
                return try await listCalendars(account: prepared.account)
            case .listEvents(let calendarID, let query, let timeMin, let timeMax, _, let limit):
                return try await listEvents(
                    calendarID: calendarID ?? "primary", query: query,
                    timeMin: timeMin, timeMax: timeMax,
                    account: prepared.account, limit: limit
                )
            case .createEvent(let calendarID, let summary, let start, let end, let description, let location, _):
                return try await createEvent(
                    calendarID: calendarID ?? "primary", summary: summary,
                    start: start, end: end, description: description,
                    location: location, account: prepared.account
                )
            }
        } catch {
            return .error(error.localizedDescription)
        }
    }

    func events(from start: Date, to end: Date) async throws -> [CalendarEventDetails] {
        let account = try accounts.resolveAccount(id: nil)
        let formatter = ISO8601DateFormatter()
        let data = try await transport.data(
            accountID: account.id, method: "GET",
            path: "calendar/v3/calendars/primary/events",
            query: [
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "orderBy", value: "startTime"),
                URLQueryItem(name: "maxResults", value: "250"),
                URLQueryItem(name: "timeMin", value: formatter.string(from: start)),
                URLQueryItem(name: "timeMax", value: formatter.string(from: end)),
            ],
            body: nil
        )
        let response = try GoogleToolSupport.decode(
            CalendarEventsResponse.self, from: data, orThrow: CalendarToolError.invalidResponse
        )
        return (response.items ?? []).map(Self.eventDetails)
    }

    func event(id: String) async throws -> CalendarEventDetails? {
        let account = try accounts.resolveAccount(id: nil)
        do {
            let data = try await transport.data(
                accountID: account.id, method: "GET",
                path: "calendar/v3/calendars/primary/events/\(GoogleAPITransport.pathSegment(id))",
                query: [], body: nil
            )
            return Self.eventDetails(try GoogleToolSupport.decode(
                CalendarEvent.self, from: data, orThrow: CalendarToolError.invalidResponse
            ))
        } catch GoogleAPIError.api(let status, _) where status == 404 || status == 410 {
            return nil
        }
    }

    private func listCalendars(account: GoogleAccount) async throws -> ChatToolResult {
        let data = try await transport.data(
            accountID: account.id, method: "GET",
            path: "calendar/v3/users/me/calendarList",
            query: [URLQueryItem(name: "maxResults", value: "250")], body: nil
        )
        let response = try GoogleToolSupport.decode(
            CalendarListResponse.self, from: data, orThrow: CalendarToolError.invalidResponse
        )
        return ChatToolResult(response: [
            "status": .string("ok"),
            "account": .string(account.email),
            "calendars": .array((response.items ?? []).map { calendar in
                .object([
                    "calendarID": .string(calendar.id),
                    "name": .string(calendar.summary),
                    "primary": .bool(calendar.primary ?? false),
                    "accessRole": .string(calendar.accessRole ?? ""),
                ])
            }),
        ])
    }

    private func listEvents(
        calendarID: String, query: String?, timeMin: String?, timeMax: String?,
        account: GoogleAccount, limit: Int
    ) async throws -> ChatToolResult {
        let formatter = ISO8601DateFormatter()
        let now = Date()
        let thirtyDays: TimeInterval = 30 * 24 * 60 * 60
        let resolvedMin: String
        let resolvedMax: String
        switch (timeMin.flatMap(CalendarToolRequest.timestamp), timeMax.flatMap(CalendarToolRequest.timestamp)) {
        case (let minimum?, let maximum?):
            resolvedMin = timeMin ?? formatter.string(from: minimum)
            resolvedMax = timeMax ?? formatter.string(from: maximum)
        case (let minimum?, nil):
            resolvedMin = timeMin ?? formatter.string(from: minimum)
            resolvedMax = formatter.string(from: minimum.addingTimeInterval(thirtyDays))
        case (nil, let maximum?):
            resolvedMin = formatter.string(from: maximum.addingTimeInterval(-thirtyDays))
            resolvedMax = timeMax ?? formatter.string(from: maximum)
        case (nil, nil):
            resolvedMin = formatter.string(from: now)
            resolvedMax = formatter.string(from: now.addingTimeInterval(thirtyDays))
        }
        var queryItems = [
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: String(limit)),
            URLQueryItem(name: "timeMin", value: resolvedMin),
            URLQueryItem(name: "timeMax", value: resolvedMax),
        ]
        if let query { queryItems.append(URLQueryItem(name: "q", value: query)) }
        let data = try await transport.data(
            accountID: account.id, method: "GET",
            path: "calendar/v3/calendars/\(GoogleAPITransport.pathSegment(calendarID))/events",
            query: queryItems, body: nil
        )
        let response = try GoogleToolSupport.decode(
            CalendarEventsResponse.self, from: data, orThrow: CalendarToolError.invalidResponse
        )
        return ChatToolResult(response: [
            "status": .string("ok"), "account": .string(account.email),
            "calendarID": .string(calendarID),
            "events": .array((response.items ?? []).map(Self.eventValue)),
        ])
    }

    private func createEvent(
        calendarID: String, summary: String, start: String, end: String,
        description: String?, location: String?, account: GoogleAccount
    ) async throws -> ChatToolResult {
        let body = CalendarEventCreate(
            summary: summary, description: description, location: location,
            start: .init(value: start), end: .init(value: end)
        )
        let data = try await transport.data(
            accountID: account.id, method: "POST",
            path: "calendar/v3/calendars/\(GoogleAPITransport.pathSegment(calendarID))/events",
            query: [], body: try GoogleToolSupport.encoder.encode(body)
        )
        let event = try GoogleToolSupport.decode(
            CalendarEvent.self, from: data, orThrow: CalendarToolError.invalidResponse
        )
        var response = Self.eventValue(event).objectValue ?? [:]
        response["status"] = .string("created")
        response["account"] = .string(account.email)
        response["calendarID"] = .string(calendarID)
        response["message"] = .string("Google Calendar event created.")
        return ChatToolResult(response: response)
    }

    nonisolated private static func eventValue(_ event: CalendarEvent) -> ChatToolValue {
        var value: [String: ChatToolValue] = [
            "eventID": .string(event.id),
            "summary": .string(event.summary ?? "(No title)"),
            "start": .string(event.start?.value ?? ""),
            "end": .string(event.end?.value ?? ""),
            "description": .string(event.description ?? ""),
            "location": .string(event.location ?? ""),
            "status": .string(event.status ?? ""),
            "url": .string(event.htmlLink ?? ""),
            "hangoutLink": .string(event.hangoutLink ?? ""),
        ]
        if let conferenceData = event.conferenceData {
            let entryPoints: [ChatToolValue] = (conferenceData.entryPoints ?? []).map { entryPoint in
                .object([
                    "type": .string(entryPoint.entryPointType ?? ""),
                    "uri": .string(entryPoint.uri ?? ""),
                    "label": .string(entryPoint.label ?? ""),
                    "meetingCode": .string(entryPoint.meetingCode ?? ""),
                    "accessCode": .string(entryPoint.accessCode ?? ""),
                    "passcode": .string(entryPoint.passcode ?? ""),
                    "password": .string(entryPoint.password ?? ""),
                    "pin": .string(entryPoint.pin ?? ""),
                ])
            }
            value["conference"] = .object([
                "solutionName": .string(conferenceData.conferenceSolution?.name ?? ""),
                "solutionType": .string(conferenceData.conferenceSolution?.key?.type ?? ""),
                "notes": .string(conferenceData.notes ?? ""),
                "entryPoints": .array(entryPoints),
            ])
        }
        if let attachments = event.attachments, !attachments.isEmpty {
            value["attachments"] = .array(attachments.map { attachment in
                .object([
                    "title": .string(attachment.title ?? ""),
                    "fileURL": .string(attachment.fileUrl ?? ""),
                    "mimeType": .string(attachment.mimeType ?? ""),
                ])
            })
        }
        if let organizer = event.organizer {
            value["organizer"] = .object([
                "name": .string(organizer.displayName ?? ""),
                "email": .string(organizer.email ?? ""),
            ])
        }
        if let attendees = event.attendees, !attendees.isEmpty {
            // ponytail: hard cap keeps huge rosters out of the model prompt; split a
            // detail-level serializer if full rosters are ever needed.
            let cap = 25
            value["attendees"] = .array(attendees.prefix(cap).map { attendee in
                .object([
                    "name": .string(attendee.displayName ?? ""),
                    "email": .string(attendee.email ?? ""),
                    "responseStatus": .string(attendee.responseStatus ?? ""),
                    "self": .bool(attendee.selfAttendee ?? false),
                ])
            })
            if attendees.count > cap {
                value["attendeesOmitted"] = .number(Double(attendees.count - cap))
            }
        }
        return .object(value)
    }

    nonisolated private static func eventDetails(_ event: CalendarEvent) -> CalendarEventDetails {
        CalendarEventDetails(
            id: event.id,
            summary: event.summary ?? "(No title)",
            start: event.start?.dateTime.flatMap(CalendarToolRequest.timestamp),
            end: event.end?.dateTime.flatMap(CalendarToolRequest.timestamp),
            isAllDay: event.start?.date != nil,
            description: event.description,
            location: event.location,
            status: event.status,
            attendees: (event.attendees ?? []).map {
                .init(
                    name: $0.displayName,
                    email: $0.email,
                    responseStatus: $0.responseStatus,
                    isSelf: $0.selfAttendee ?? false
                )
            },
            calendarURL: event.htmlLink.flatMap(URL.init(string:)),
            hangoutURL: event.hangoutLink.flatMap(URL.init(string:)),
            conferenceURLs: (event.conferenceData?.entryPoints ?? [])
                .filter { $0.entryPointType == "video" }
                .compactMap { $0.uri.flatMap(URL.init(string:)) },
            organizer: event.organizer.map {
                .init(name: $0.displayName, email: $0.email, responseStatus: nil, isSelf: false)
            },
            attachments: (event.attachments ?? []).map {
                .init(title: $0.title, url: $0.fileUrl.flatMap(URL.init(string:)))
            },
            conferenceCode: (event.conferenceData?.entryPoints ?? [])
                .compactMap { $0.meetingCode ?? $0.passcode ?? $0.password ?? $0.pin }
                .first
        )
    }

}

nonisolated private struct CalendarListResponse: Decodable {
    let items: [CalendarListEntry]?
}

nonisolated private struct CalendarListEntry: Decodable {
    let id: String
    let summary: String
    let primary: Bool?
    let accessRole: String?
}

nonisolated private struct CalendarEventsResponse: Decodable {
    let items: [CalendarEvent]?
}

nonisolated private struct CalendarEvent: Decodable {
    struct EventTime: Decodable {
        let date: String?
        let dateTime: String?
        var value: String { dateTime ?? date ?? "" }
    }

    let id: String
    let summary: String?
    let description: String?
    let location: String?
    let status: String?
    let htmlLink: String?
    let hangoutLink: String?
    let start: EventTime?
    let end: EventTime?
    let attendees: [Attendee]?
    let organizer: Organizer?
    let attachments: [Attachment]?
    let conferenceData: ConferenceData?

    struct Attendee: Decodable {
        let displayName: String?
        let email: String?
        let responseStatus: String?
        let selfAttendee: Bool?

        private enum CodingKeys: String, CodingKey {
            case displayName, email, responseStatus
            case selfAttendee = "self"
        }
    }

    struct ConferenceData: Decodable {
        let entryPoints: [EntryPoint]?
        let conferenceSolution: ConferenceSolution?
        let notes: String?

        struct ConferenceSolution: Decodable {
            let key: Key?
            let name: String?

            struct Key: Decodable {
                let type: String?
            }
        }
    }

    struct EntryPoint: Decodable {
        let entryPointType: String?
        let uri: String?
        let label: String?
        let meetingCode: String?
        let accessCode: String?
        let passcode: String?
        let password: String?
        let pin: String?
    }

    struct Organizer: Decodable {
        let displayName: String?
        let email: String?
    }

    struct Attachment: Decodable {
        let title: String?
        let fileUrl: String?
        let mimeType: String?
    }
}

nonisolated private struct CalendarEventCreate: Encodable {
    struct EventTime: Encodable {
        let date: String?
        let dateTime: String?

        init(value: String) {
            if value.count == 10 && !value.contains("T") {
                date = value
                dateTime = nil
            } else {
                date = nil
                dateTime = value
            }
        }
    }

    let summary: String
    let description: String?
    let location: String?
    let start: EventTime
    let end: EventTime
}
