import Foundation
import Testing
@testable import electragne

struct NotesToolTests {
    @Test func parsesReadAndMutationRequests() throws {
        #expect(try NoteToolRequest(toolCall: call("list_notes", ["limit": .number(80)])) == .list(folderName: nil, limit: 50))
        #expect(try NoteToolRequest(toolCall: call("search_notes", ["query": .string(" sheep ")])) == .search(query: "sheep", folderName: nil, limit: 20))
        #expect(try NoteToolRequest(toolCall: call("create_note", ["title": .string(" Ideas "), "body": .string("One")])) == .create(title: "Ideas", body: "One", folderName: nil))
        #expect(try NoteToolRequest(toolCall: call("append_to_note", ["noteID": .string("n1"), "text": .string("More")])) == .append(noteID: "n1", text: "More"))
        #expect(try NoteToolRequest(toolCall: call("delete_note", ["noteID": .string("n1")])) == .delete(noteID: "n1"))
    }

    @Test func rejectsMissingArgumentsAndEmptyUpdates() {
        #expect(throws: NoteToolError.missingArgument("query")) {
            try NoteToolRequest(toolCall: call("search_notes", [:]))
        }
        #expect(throws: NoteToolError.noChanges) {
            try NoteToolRequest(toolCall: call("update_note", ["noteID": .string("n1")]))
        }
    }

    @Test func escapesAppleScriptAndHTMLContent() {
        #expect(NotesTextEncoding.appleScriptLiteral("a\\b\"c\nd") == "\"a\\\\b\\\"c\\nd\"")
        #expect(NotesTextEncoding.noteHTML(title: "A < B", body: "x & y\nz") == "<h1>A &lt; B</h1><div>x &amp; y<br>z</div>")
    }

    @Test func generatedAppleScriptsCompile() throws {
        let scripts = [
            NotesScriptBuilder.list(query: "sheep", folderName: "Work", limit: 10),
            NotesScriptBuilder.create(title: "A \"title\"", body: "body", folderName: nil),
            NotesScriptBuilder.update(rawID: "x-coredata://1", title: "New", body: "Body"),
            NotesScriptBuilder.append(rawID: "x-coredata://1", text: "More"),
            NotesScriptBuilder.delete(rawID: "x-coredata://1"),
        ]
        for source in scripts {
            let script = try #require(NSAppleScript(source: source))
            var error: NSDictionary?
            let compiled = script.compileAndReturnError(&error)
            let message = String(describing: error)
            #expect(compiled, Comment(rawValue: message))
        }
    }

    private func call(_ name: String, _ arguments: [String: ChatToolValue]) -> ChatToolCall {
        ChatToolCall(id: "test", name: name, arguments: arguments)
    }
}
