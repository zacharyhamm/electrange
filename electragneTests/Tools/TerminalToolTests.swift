import Foundation
import Testing
@testable import electragne

struct TerminalToolRequestTests {
    @Test func parsesOpenReadTextAndKeyRequests() throws {
        #expect(try request("open_terminal") == .open)
        #expect(try request("read_terminal") == .read(maxLines: 100))
        #expect(try request("read_terminal", ["maxLines": .number(200)]) == .read(maxLines: 200))
        #expect(try request("write_terminal", ["text": .string("top")])
            == .write(.text("top", pressEnter: true)))
        #expect(try request("write_terminal", [
            "text": .string("q"), "pressEnter": .bool(false),
        ]) == .write(.text("q", pressEnter: false)))

        let key = try request("write_terminal", [
            "key": .string("F12"),
            "modifiers": .string("ctrl+meta super shift"),
        ])
        #expect(key == .write(.key(try TerminalKeyPress(
            key: "F12",
            modifiers: "control+option+command+shift"
        ))))
    }

    @Test func acceptsUnicodeNamedRawAndHyperKeys() throws {
        #expect(try TerminalKeyPress(key: "é", modifiers: nil).key == "é")
        #expect(try TerminalKeyPress(key: "print screen", modifiers: nil).key == "print screen")
        #expect(try TerminalKeyPress(key: "keycode:65535", modifiers: nil).key == "keycode:65535")
        #expect(try TerminalKeyPress(key: "x", modifiers: "hyper").modifiers
            == Set(TerminalModifier.allCases.prefix(4)))
    }

    @Test func rejectsInvalidArguments() {
        #expect(throws: TerminalToolError.invalidWrite) {
            try request("write_terminal")
        }
        #expect(throws: TerminalToolError.invalidWrite) {
            try request("write_terminal", ["text": .string("x"), "key": .string("x")])
        }
        #expect(throws: TerminalToolError.invalidWrite) {
            try request("write_terminal", ["text": .string("x"), "modifiers": .string("shift")])
        }
        #expect(throws: TerminalToolError.invalidKey) {
            try request("write_terminal", ["key": .string("not-a-key")])
        }
        #expect(throws: TerminalToolError.invalidKey) {
            try request("write_terminal", ["key": .string("keycode:65536")])
        }
        #expect(throws: TerminalToolError.invalidModifier("banana")) {
            try request("write_terminal", [
                "key": .string("x"), "modifiers": .string("banana"),
            ])
        }
        for value in [0.0, 1.5, 201.0] {
            #expect(throws: TerminalToolError.invalidMaxLines) {
                try request("read_terminal", ["maxLines": .number(value)])
            }
        }
    }

    private func request(
        _ name: String,
        _ arguments: [String: ChatToolValue] = [:]
    ) throws -> TerminalToolRequest {
        try TerminalToolRequest(toolCall: ChatToolCall(
            id: "test", name: name, arguments: arguments
        ))
    }
}

@MainActor
struct TerminalToolServiceTests {
    @Test func confirmsWritesAndExecutesInjectedTerminal() async throws {
        let service = TerminalToolService()
        var written: TerminalWriteInput?
        service.write = { input, _ in written = input; return true }
        let request = TerminalToolRequest.write(.key(try TerminalKeyPress(
            key: "c", modifiers: "control"
        )))

        let confirmation = try #require(service.confirmationDetails(for: request))
        #expect(confirmation.primaryText == "Control+c")
        #expect(confirmation.actionLabel == "Press")
        let result = await service.execute(request)
        #expect(result.response["status"]?.stringValue == "ok")
        #expect(written == .key(try TerminalKeyPress(key: "c", modifiers: "ctrl")))
    }

    @Test func returnsTerminalSnapshot() async {
        let service = TerminalToolService()
        service.read = { _, _ in
            TerminalReadResult(content: "one\ntwo", lineCount: 2, truncated: true)
        }

        let result = await service.execute(.read(maxLines: 2))

        #expect(result.response["content"]?.stringValue == "one\ntwo")
        #expect(result.response["lineCount"]?.numberValue == 2)
        #expect(result.response["truncated"]?.boolValue == true)
    }

    @Test func automationContextTargetsItsChatAndRequiresTheGrant() async {
        let service = TerminalToolService()
        let chatID = UUID()
        var target: UUID?
        service.read = { _, chatID in
            target = chatID
            return TerminalReadResult(content: "ok", lineCount: 1, truncated: false)
        }

        let denied = await AutomationRunScope.$current.withValue(.init(
            automationID: "one",
            runID: "run",
            chatID: chatID,
            terminalAccess: false
        )) {
            await service.execute(.read(maxLines: 1))
        }
        #expect(denied.response["status"]?.stringValue == "error")
        #expect(target == nil)

        let allowed = await AutomationRunScope.$current.withValue(.init(
            automationID: "one",
            runID: "run",
            chatID: chatID,
            terminalAccess: true
        )) {
            await service.execute(.read(maxLines: 1))
        }
        #expect(allowed.response["content"]?.stringValue == "ok")
        #expect(target == chatID)
    }

    @Test func snapshotTrimsBlankRowsAndKeepsNewestLines() {
        let result = TerminalPanelController.snapshot(
            buffer: "old\nkept one\n\nkept two\n   \n\n",
            maxLines: 3
        )

        #expect(result.content == "kept one\n\nkept two")
        #expect(result.lineCount == 3)
        #expect(result.truncated)
    }
}
