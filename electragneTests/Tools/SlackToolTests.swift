import Foundation
import Testing
@testable import electragne

struct SlackToolRequestTests {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func call(_ name: String, _ arguments: [String: ChatToolValue]) -> ChatToolCall {
        ChatToolCall(id: "1", name: name, arguments: arguments)
    }

    @Test func parsesSearchWithDefaultLimit() throws {
        let request = try SlackToolRequest(toolCall: call("search_slack", [
            "query": .string(" deploy failed ")
        ]))
        #expect(request == .search(query: "deploy failed", limit: 20))
    }

    @Test func rejectsInvalidSearchArguments() {
        #expect(throws: SlackToolError.missingArgument("query")) {
            try SlackToolRequest(toolCall: call("search_slack", [:]))
        }
        #expect(throws: SlackToolError.invalidLimit) {
            try SlackToolRequest(toolCall: call("search_slack", [
                "query": .string("x"), "limit": .number(0),
            ]))
        }
        #expect(throws: SlackToolError.invalidLimit) {
            try SlackToolRequest(toolCall: call("search_slack", [
                "query": .string("x"), "limit": .number(12.5),
            ]))
        }
        #expect(throws: SlackToolError.unsupportedTool("post_slack_message")) {
            try SlackToolRequest(toolCall: call("post_slack_message", [:]))
        }
    }

    @Test func parsesChannelMessagesDateRange() throws {
        let calendar = utcCalendar
        let request = try SlackToolRequest(
            toolCall: call("get_slack_messages", [
                "channel": .string("#general"),
                "from": .string("2026-07-01"),
                "to": .string("2026-07-01"),
            ]),
            calendar: calendar
        )
        let dayStart = calendar.date(from: DateComponents(year: 2026, month: 7, day: 1))!
        // `to` is inclusive, so the upper bound is the start of the next day.
        #expect(request == .channelMessages(
            channel: "#general",
            from: dayStart,
            to: calendar.date(byAdding: .day, value: 1, to: dayStart)!
        ))
    }

    @Test func channelMessagesBoundsAreOptional() throws {
        let request = try SlackToolRequest(toolCall: call("get_slack_messages", [
            "channel": .string("ops")
        ]))
        #expect(request == .channelMessages(channel: "ops", from: nil, to: nil))
    }

    @Test func rejectsInvalidChannelMessagesArguments() {
        #expect(throws: SlackToolError.missingArgument("channel")) {
            try SlackToolRequest(toolCall: call("get_slack_messages", [:]))
        }
        #expect(throws: SlackToolError.invalidDate("last tuesday")) {
            try SlackToolRequest(toolCall: call("get_slack_messages", [
                "channel": .string("ops"), "from": .string("last tuesday"),
            ]))
        }
        #expect(throws: SlackToolError.invalidDate("2026-13-01")) {
            try SlackToolRequest(toolCall: call("get_slack_messages", [
                "channel": .string("ops"), "to": .string("2026-13-01"),
            ]))
        }
    }
}

@MainActor
struct SlackToolServiceTests {
    @Test func unconfiguredServiceReturnsSetupError() async {
        let service = SlackToolService(settings: { nil })
        let result = await service.execute(.search(query: "x", limit: 5))
        #expect(result.response["status"] == .string("error"))
        let message = result.response["message"]?.stringValue ?? ""
        #expect(message.contains("Electragne Settings"))
    }

    @Test func transcriptRendersOneLinePerMessage() {
        let messages = [
            DobbsMessage(
                channelName: "general", userName: "alice", text: "ship it",
                ts: "1.0", timeUnixNano: 1_752_600_000_000_000_000
            ),
            DobbsMessage(
                channelName: "general", userID: "U123", text: "done",
                ts: "3.0", threadTS: "1.0"
            ),
        ]
        let transcript = SlackToolService.transcript(messages)
        let lines = transcript.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].contains("#general alice: ship it"))
        #expect(lines[0].hasPrefix("["))
        #expect(lines[1] == "#general U123: (thread reply) done")
    }
}
