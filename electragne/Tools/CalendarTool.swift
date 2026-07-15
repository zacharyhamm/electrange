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
            let rawLimit = args.number("limit") ?? 20
            guard rawLimit.isFinite, rawLimit.rounded() == rawLimit,
                  rawLimit >= 1, rawLimit <= 50 else {
                throw CalendarToolError.invalidLimit
            }
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
                timeMax: timeMax, accountID: accountID, limit: Int(rawLimit)
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
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return date
    }

    static func timestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
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

@MainActor
protocol CalendarToolExecuting {
    func prepare(_ request: CalendarToolRequest) async throws -> CalendarPreparedRequest
    func execute(_ prepared: CalendarPreparedRequest) async -> ChatToolResult
}

@MainActor
final class CalendarToolService: CalendarToolExecuting {
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
            path: "calendar/v3/calendars/\(calendarID)/events",
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
            path: "calendar/v3/calendars/\(calendarID)/events",
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
        .object([
            "eventID": .string(event.id),
            "summary": .string(event.summary ?? "(No title)"),
            "start": .string(event.start?.value ?? ""),
            "end": .string(event.end?.value ?? ""),
            "description": .string(event.description ?? ""),
            "location": .string(event.location ?? ""),
            "status": .string(event.status ?? ""),
            "url": .string(event.htmlLink ?? ""),
        ])
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
    let start: EventTime?
    let end: EventTime?
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
