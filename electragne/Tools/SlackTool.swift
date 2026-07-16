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

    init(toolCall: ChatToolCall, calendar: Calendar = .current) throws {
        let args = ToolCallArguments(toolCall)
        func required(_ key: String) throws -> String {
            try args.required(key, onMissing: SlackToolError.missingArgument)
        }

        switch toolCall.name {
        case "search_slack":
            let rawLimit = args.number("limit") ?? 20
            guard rawLimit.isFinite, rawLimit.rounded() == rawLimit,
                  rawLimit >= 1, rawLimit <= 50 else {
                throw SlackToolError.invalidLimit
            }
            self = .search(query: try required("query"), limit: Int(rawLimit))
        case "get_slack_messages":
            let from = try args.string("from").map { try Self.day($0, calendar: calendar) }
            let to = try args.string("to").map {
                calendar.date(byAdding: .day, value: 1, to: try Self.day($0, calendar: calendar))!
            }
            self = .channelMessages(channel: try required("channel"), from: from, to: to)
        default:
            throw SlackToolError.unsupportedTool(toolCall.name)
        }
    }

    /// Parses a YYYY-MM-DD day into its local start-of-day.
    private static func day(_ raw: String, calendar: Calendar) throws -> Date {
        let parts = raw.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
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
        let shown = messages.suffix(messageCap)
        var response: [String: ChatToolValue] = [
            "status": .string("ok"),
            "messageCount": .number(Double(shown.count)),
            "messages": .string(transcript(Array(shown))),
        ]
        if shown.count < messages.count {
            response["note"] = .string(
                "Showing only the newest \(shown.count) of \(messages.count) messages. Narrow the date range for the rest."
            )
        }
        return ChatToolResult(response: response)
    }

    /// One "[timestamp] #channel user: text" line per message.
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
            var line = "\(parts.joined(separator: " ")) \(sender):"
            if let threadTS = message.threadTS, !threadTS.isEmpty, threadTS != message.ts {
                line += " (thread reply)"
            }
            return "\(line) \(message.text ?? "")"
                .trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }

    nonisolated private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
