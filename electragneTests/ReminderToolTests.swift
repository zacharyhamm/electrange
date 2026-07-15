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
}
