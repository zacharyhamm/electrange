import Foundation
import Testing
@testable import electragne

struct ReminderToolTests {
    @Test func parsesReminderToolArgumentsAndTrimsOptionals() throws {
        let request = try ReminderRequest(toolCall: ChatToolCall(
            id: "1",
            name: "create_reminder",
            arguments: [
                "title": .string("  Buy oats  "),
                "notes": .string("  organic  "),
                "listName": .string(" Groceries "),
                "due": .string(" 2026-07-15 "),
            ]
        ))

        #expect(request == ReminderRequest(
            title: "Buy oats",
            notes: "organic",
            listName: "Groceries",
            due: "2026-07-15"
        ))
    }

    @Test func rejectsMissingTitleAndUnknownTool() {
        #expect(throws: ReminderRequestError.missingTitle) {
            try ReminderRequest(toolCall: ChatToolCall(
                id: "1",
                name: "create_reminder",
                arguments: ["title": .string("   ")]
            ))
        }
        #expect(throws: ReminderRequestError.unsupportedTool("delete_reminder")) {
            try ReminderRequest(toolCall: ChatToolCall(
                id: "2",
                name: "delete_reminder",
                arguments: [:]
            ))
        }
    }

    @Test func parsesAllDayDateAndRejectsImpossibleDate() {
        let utc = TimeZone(secondsFromGMT: 0)!
        #expect(
            ReminderDateParser.parse("2026-07-15", timeZone: utc)
                == .allDay(DateComponents(year: 2026, month: 7, day: 15))
        )
        #expect(ReminderDateParser.parse("2026-02-30", timeZone: utc) == nil)
        #expect(ReminderDateParser.parse("tomorrow morning", timeZone: utc) == nil)
    }

    @Test func parsesRFC3339TimestampIntoLocalComponents() {
        let utc = TimeZone(secondsFromGMT: 0)!
        let parsed = ReminderDateParser.parse("2026-07-14T09:30:00-05:00", timeZone: utc)

        var expected = DateComponents(
            timeZone: utc,
            year: 2026,
            month: 7,
            day: 14,
            hour: 14,
            minute: 30
        )
        expected.calendar = nil
        #expect(parsed == .timed(expected))
    }

    @Test func parsesListUpdateAndDeleteRequests() throws {
        let list = try ReminderToolRequest(toolCall: call("list_reminders", [
            "query": .string(" bills "), "completion": .string("all"), "limit": .number(50),
        ]))
        #expect(list == .list(ReminderListRequest(query: "bills", listName: nil, completion: .all, limit: 50)))

        // Out-of-range limits throw instead of silently clamping.
        #expect(throws: ReminderRequestError.invalidLimit) {
            try ReminderToolRequest(toolCall: call("list_reminders", ["limit": .number(500)]))
        }

        let update = try ReminderToolRequest(toolCall: call("update_reminder", [
            "identifier": .string(" reminder-1 "), "clearDue": .bool(true), "completed": .bool(true),
        ]))
        #expect(update == .update(ReminderUpdateRequest(
            identifier: "reminder-1", title: nil, notes: nil, clearNotes: false,
            listName: nil, due: nil, clearDue: true, completed: true
        )))
        #expect(try ReminderToolRequest(toolCall: call("delete_reminder", ["identifier": .string("r2")])) == .delete(identifier: "r2"))
    }

    @Test func rejectsInvalidReminderMutations() {
        #expect(throws: ReminderRequestError.noChanges) {
            try ReminderToolRequest(toolCall: call("update_reminder", ["identifier": .string("r1")]))
        }
        #expect(throws: ReminderRequestError.invalidCompletion("later")) {
            try ReminderToolRequest(toolCall: call("list_reminders", ["completion": .string("later")]))
        }
    }

    private func call(_ name: String, _ arguments: [String: ChatToolValue]) -> ChatToolCall {
        ChatToolCall(id: "test", name: name, arguments: arguments)
    }
}
