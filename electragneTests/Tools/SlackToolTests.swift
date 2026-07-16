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

    @Test func parsesThreadUsersPermalinkAndPost() throws {
        #expect(try SlackToolRequest(toolCall: call("get_slack_thread", [
            "channelID": .string("C01"), "threadTS": .string("1.5"),
        ])) == .thread(channelID: "C01", threadTS: "1.5"))

        #expect(try SlackToolRequest(toolCall: call("list_slack_users", [:]))
            == .users(query: nil))
        #expect(try SlackToolRequest(toolCall: call("list_slack_users", [
            "query": .string("alice")
        ])) == .users(query: "alice"))

        #expect(try SlackToolRequest(toolCall: call("get_slack_permalink", [
            "channelID": .string("C01"), "ts": .string("1.5"),
        ])) == .permalink(channelID: "C01", ts: "1.5"))

        #expect(try SlackToolRequest(toolCall: call("send_slack_message", [
            "channel": .string("C01"), "channelName": .string("ops"),
            "text": .string("on it"), "threadTS": .string("1.5"),
        ])) == .post(channel: "C01", channelName: "ops", text: "on it", threadTS: "1.5"))
    }

    @Test func rejectsMissingArgumentsOnNewTools() {
        #expect(throws: SlackToolError.missingArgument("threadTS")) {
            try SlackToolRequest(toolCall: call("get_slack_thread", [
                "channelID": .string("C01")
            ]))
        }
        #expect(throws: SlackToolError.missingArgument("ts")) {
            try SlackToolRequest(toolCall: call("get_slack_permalink", [
                "channelID": .string("C01")
            ]))
        }
        #expect(throws: SlackToolError.missingArgument("text")) {
            try SlackToolRequest(toolCall: call("send_slack_message", [
                "channel": .string("C01")
            ]))
        }
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

    @Test func transcriptRendersOneLinePerMessageWithIDs() {
        let messages = [
            DobbsMessage(
                channelID: "C01", channelName: "general", userName: "alice",
                text: "ship it", ts: "1.0", timeUnixNano: 1_752_600_000_000_000_000
            ),
            DobbsMessage(
                channelID: "C01", channelName: "general", userID: "U123",
                text: "done", ts: "3.0", threadTS: "1.0"
            ),
        ]
        let transcript = SlackToolService.transcript(messages)
        let lines = transcript.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].contains("#general alice: ship it (id C01/1.0)"))
        #expect(lines[0].hasPrefix("["))
        #expect(lines[1] == "#general U123: done (id C01/3.0, thread 1.0)")
    }

    @Test func usersResultFiltersAndResolvesNames() {
        let users = [
            DobbsUser(id: "U1", name: "alice", realName: "Alice Ames", displayName: "ali"),
            DobbsUser(id: "U2", name: "bob", deleted: true),
            DobbsUser(id: "U3", name: "deploybot", isBot: true),
        ]
        let all = SlackToolService.usersResult(users, query: nil)
        let entries = all.response["users"]?.arrayValue ?? []
        // deleted users are dropped; display name wins over username
        #expect(entries.count == 2)
        #expect(entries[0] == .object([
            "userID": .string("U1"), "name": .string("ali"), "realName": .string("Alice Ames"),
        ]))
        #expect(entries[1] == .object([
            "userID": .string("U3"), "name": .string("deploybot"), "isBot": .bool(true),
        ]))

        let queried = SlackToolService.usersResult(users, query: "ames")
        #expect(queried.response["users"]?.arrayValue?.count == 1)
        let none = SlackToolService.usersResult(users, query: "zed")
        #expect(none.response["message"] == .string("No Slack users matched."))
    }

    @Test func onlySendingConfirms() {
        let service = SlackToolService(settings: { nil })
        #expect(service.confirmationDetails(for: .search(query: "x", limit: 5)) == nil)
        #expect(service.confirmationDetails(for: .thread(channelID: "C01", threadTS: "1.0")) == nil)

        let confirmation = service.confirmationDetails(
            for: .post(channel: "C01", channelName: "ops", text: "on it", threadTS: "1.0")
        )
        #expect(confirmation?.title == "Send this Slack message?")
        #expect(confirmation?.primaryText == "on it")
        #expect(confirmation?.actionLabel == "Send")
        #expect(confirmation?.details.map(\.value) == ["#ops (C01)", "1.0"])

        // Without a model-supplied name the card falls back to the bare ID.
        let bare = service.confirmationDetails(
            for: .post(channel: "C01", channelName: nil, text: "on it", threadTS: nil)
        )
        #expect(bare?.details.map(\.value) == ["C01"])
    }

    @Test func threadResultKeepsRootWhenTrimming() {
        let cap = SlackToolService.messageCap
        let messages = (0...cap).map { i in
            DobbsMessage(
                channelID: "C01", channelName: "general", userName: "alice",
                text: "m\(i)", ts: "\(i).0", threadTS: "0.0"
            )
        }
        let result = SlackToolService.threadResult(messages)
        let transcript = result.response["messages"]?.stringValue ?? ""
        #expect(result.response["messageCount"] == .number(Double(cap)))
        #expect(transcript.hasPrefix("#general alice: m0 "))   // root survives
        #expect(!transcript.contains(" m1 "))                  // oldest reply trimmed
        #expect(transcript.contains("m\(cap)"))                // newest reply kept
        #expect(result.response["note"] == .string(
            "Showing the thread root and the newest \(cap - 1) of \(cap) replies."
        ))

        let short = SlackToolService.threadResult(Array(messages.prefix(2)))
        #expect(short.response["note"] == nil)
        #expect(short.response["messageCount"] == .number(2))
    }

    @Test func usersQueryMatchesIDsAndIgnoresEmpty() {
        let users = [
            DobbsUser(id: "U1", name: "alice", realName: "Alice Ames", displayName: "ali"),
            DobbsUser(id: "U3", name: "deploybot", isBot: true),
        ]
        let byID = SlackToolService.usersResult(users, query: "u1")
        #expect(byID.response["users"]?.arrayValue?.count == 1)

        let empty = SlackToolService.usersResult(users, query: "  ")
        #expect(empty.response["users"]?.arrayValue?.count == 2)

        // Empty display name and missing username fall back to the real name.
        let sparse = SlackToolService.usersResult(
            [DobbsUser(id: "U9", realName: "Zed Zee", displayName: "")], query: nil
        )
        #expect(sparse.response["users"]?.arrayValue?.first == .object([
            "userID": .string("U9"), "name": .string("Zed Zee"), "realName": .string("Zed Zee"),
        ]))
    }
}
