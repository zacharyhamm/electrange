//
//  SlackTool.swift
//  electragne
//
//  Slack tool calls (read-only, served by a dobbs daemon): parsing and
//  validation, plus the executor that turns archived messages into a
//  plain-text transcript the model can summarize.
//

import Foundation

nonisolated enum SlackToolRequest: Equatable, Sendable {
    case search(query: String, limit: Int)
    /// from/to are half-open bounds resolved from YYYY-MM-DD calendar days in
    /// the owner's time zone: from = start of that day, to = start of the day
    /// AFTER the given (inclusive) end date. nil leaves the bound open.
    case channelMessages(channel: String, from: Date?, to: Date?)
    case thread(channelID: String, threadTS: String)
    case users(query: String?)
    case permalink(channelID: String, ts: String)
    /// channelName is model-supplied display context for the confirmation
    /// card; the channel ID is what's actually sent.
    case post(channel: String, channelName: String?, text: String, threadTS: String?)

    init(toolCall: ChatToolCall, calendar: Calendar = .current) throws {
        let args = ToolCallArguments(toolCall)
        func required(_ key: String) throws -> String {
            try args.required(key, onMissing: SlackToolError.missingArgument)
        }

        switch toolCall.name {
        case "search_slack":
            self = .search(
                query: try required("query"),
                limit: try args.limit(default: 20, onInvalid: SlackToolError.invalidLimit)
            )
        case "get_slack_messages":
            let from = try args.string("from").map { try Self.day($0, calendar: calendar) }
            let to = try args.string("to").map {
                calendar.date(byAdding: .day, value: 1, to: try Self.day($0, calendar: calendar))!
            }
            self = .channelMessages(channel: try required("channel"), from: from, to: to)
        case "get_slack_thread":
            self = .thread(channelID: try required("channelID"), threadTS: try required("threadTS"))
        case "list_slack_users":
            self = .users(query: args.string("query"))
        case "get_slack_permalink":
            self = .permalink(channelID: try required("channelID"), ts: try required("ts"))
        case "send_slack_message":
            self = .post(
                channel: try required("channel"),
                channelName: args.string("channelName"),
                text: try required("text"),
                threadTS: args.string("threadTS")
            )
        default:
            throw SlackToolError.unsupportedTool(toolCall.name)
        }
    }

    /// Parses a YYYY-MM-DD day into its local start-of-day.
    private static func day(_ raw: String, calendar: Calendar) throws -> Date {
        guard let components = ToolDate.dayComponents(raw, calendar: calendar),
              let date = calendar.date(from: components) else {
            throw SlackToolError.invalidDate(raw)
        }
        return calendar.startOfDay(for: date)
    }
}

nonisolated enum SlackToolError: LocalizedError, Equatable {
    case unsupportedTool(String)
    case missingArgument(String)
    case invalidLimit
    case invalidDate(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedTool: "Unsupported Slack tool."
        case .missingArgument(let name): "The ‘\(name)’ argument is required."
        case .invalidLimit: "Slack result limit must be a whole number from 1 to 50."
        case .invalidDate(let raw): "‘\(raw)’ is not a valid YYYY-MM-DD date."
        }
    }
}

@MainActor
protocol SlackToolExecuting {
    func confirmationDetails(for request: SlackToolRequest) -> ToolConfirmationDetails?
    func execute(_ request: SlackToolRequest) async -> ChatToolResult
}

@MainActor
final class SlackToolService: SlackToolExecuting {
    /// Most messages one call returns to the model; conversation_range has no
    /// server-side limit, so busy channels are trimmed to the newest ones.
    static let messageCap = 500

    private let settings: () -> DobbsSettings?

    init(settings: @escaping () -> DobbsSettings? = DobbsSettings.current) {
        self.settings = settings
    }

    /// Reads run unconfirmed; sending a message is the one outbound write and
    /// always confirms.
    func confirmationDetails(for request: SlackToolRequest) -> ToolConfirmationDetails? {
        guard case .post(let channel, let channelName, let text, let threadTS) = request else {
            return nil
        }
        let channelValue = channelName.map {
            "\($0.hasPrefix("#") ? $0 : "#\($0)") (\(channel))"
        } ?? channel
        var details = [(label: "Channel", value: channelValue)]
        if let threadTS { details.append(("Thread", threadTS)) }
        return ToolConfirmationDetails(
            title: "Send this Slack message?", primaryText: text,
            details: details, actionLabel: "Send"
        )
    }

    func execute(_ request: SlackToolRequest) async -> ChatToolResult {
        guard let settings = settings() else {
            return .error(DobbsError.notConfigured.localizedDescription)
        }
        do {
            switch request {
            case .search(let query, let limit):
                let hits = try await DobbsClient.search(settings, query: query, limit: limit)
                return Self.result(messages: hits, emptyNote: "No archived Slack messages matched.")
            case .channelMessages(let channel, let from, let to):
                let messages = try await DobbsClient.conversationRange(
                    settings, channel: channel,
                    from: from.map(Self.unixNanos) ?? 0,
                    to: to.map { Self.unixNanos($0) - 1 } ?? 0
                )
                return Self.result(
                    messages: messages,
                    emptyNote: "No archived Slack messages in that channel and range."
                )
            case .thread(let channelID, let threadTS):
                let messages = try await DobbsClient.conversation(
                    settings, channelID: channelID, threadTS: threadTS, limit: Self.messageCap
                )
                return Self.threadResult(messages)
            case .users(let query):
                return Self.usersResult(try await DobbsClient.usersList(settings), query: query)
            case .permalink(let channelID, let ts):
                let url = try await DobbsClient.getPermalink(settings, channel: channelID, ts: ts)
                return ChatToolResult(response: [
                    "status": .string("ok"),
                    "url": .string(url),
                ])
            case .post(let channel, _, let text, let threadTS):
                let ts = try await DobbsClient.postMessage(
                    settings, channel: channel, text: text, threadTS: threadTS
                )
                return ChatToolResult(response: [
                    "status": .string("ok"),
                    "message": .string("Sent."),
                    "ts": .string(ts),
                ])
            }
        } catch {
            return .error(error.localizedDescription)
        }
    }

    private static func unixNanos(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000_000_000)
    }

    private static func result(messages: [DobbsMessage], emptyNote: String) -> ChatToolResult {
        guard !messages.isEmpty else { return .make(status: "ok", message: emptyNote) }
        let shown = Array(messages.suffix(messageCap))
        let note = shown.count < messages.count
            ? "Showing only the newest \(shown.count) of \(messages.count) messages. Narrow the date range for the rest."
            : nil
        return transcriptResult(shown, note: note)
    }

    /// A whole thread; the daemon ignores limit for thread queries, so trim
    /// here — keeping the root, which suffix-trimming would drop first.
    static func threadResult(_ messages: [DobbsMessage]) -> ChatToolResult {
        guard !messages.isEmpty else {
            return .make(status: "ok", message: "No archived messages in that thread.")
        }
        guard messages.count > messageCap else { return transcriptResult(messages, note: nil) }
        let shown = [messages[0]] + messages.suffix(messageCap - 1)
        return transcriptResult(
            shown,
            note: "Showing the thread root and the newest \(messageCap - 1) of \(messages.count - 1) replies."
        )
    }

    private static func transcriptResult(_ shown: [DobbsMessage], note: String?) -> ChatToolResult {
        var response: [String: ChatToolValue] = [
            "status": .string("ok"),
            "messageCount": .number(Double(shown.count)),
            "messages": .string(transcript(shown)),
        ]
        if let note { response["note"] = .string(note) }
        return ChatToolResult(response: response)
    }

    /// One "[timestamp] #channel user: text (id …)" line per message. The id
    /// suffix carries what the thread/permalink/reply tools need: channel ID,
    /// message ts, and the thread root ts when the message is threaded.
    static func transcript(_ messages: [DobbsMessage]) -> String {
        messages.map { message in
            var parts: [String] = []
            if let time = message.time {
                parts.append("[\(Self.timestampFormatter.string(from: time))]")
            }
            if let channel = message.channelName, !channel.isEmpty {
                parts.append("#\(channel)")
            }
            let sender = message.userName ?? message.userID ?? "unknown"
            var line = "\(parts.joined(separator: " ")) \(sender): \(message.text ?? "")"
                .trimmingCharacters(in: .whitespaces)
            var ids = "id \(message.channelID ?? "?")/\(message.ts)"
            if let threadTS = message.threadTS, !threadTS.isEmpty {
                ids += ", thread \(threadTS)"
            }
            line += " (\(ids))"
            return line
        }.joined(separator: "\n")
    }

    /// The workspace directory as structured entries, active humans and bots
    /// only, optionally filtered by a case-insensitive name query.
    static func usersResult(_ users: [DobbsUser], query: String?) -> ChatToolResult {
        var matched = users.filter { $0.deleted != true }
        let query = query?.trimmingCharacters(in: .whitespaces)
        if let query, !query.isEmpty {
            matched = matched.filter { user in
                [user.id, user.name, user.realName, user.displayName].contains {
                    $0?.localizedCaseInsensitiveContains(query) == true
                }
            }
        }
        guard !matched.isEmpty else {
            return .make(status: "ok", message: "No Slack users matched.")
        }
        // ponytail: flat cap; add paging if a workspace ever outgrows it
        let shown = matched.prefix(100)
        var response: [String: ChatToolValue] = [
            "status": .string("ok"),
            "users": .array(shown.map { user in
                var entry: [String: ChatToolValue] = [
                    "userID": .string(user.id),
                    "name": .string([user.displayName, user.name, user.realName]
                        .compactMap { $0 }.first { !$0.isEmpty } ?? ""),
                ]
                if let realName = user.realName, !realName.isEmpty {
                    entry["realName"] = .string(realName)
                }
                if user.isBot == true { entry["isBot"] = .bool(true) }
                return .object(entry)
            }),
        ]
        if shown.count < matched.count {
            response["note"] = .string(
                "Showing only \(shown.count) of \(matched.count) users. Pass a query to narrow the list."
            )
        }
        return ChatToolResult(response: response)
    }

    nonisolated private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
