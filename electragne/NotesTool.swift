import Foundation

nonisolated enum NoteToolRequest: Equatable, Sendable {
    case list(folderName: String?, limit: Int)
    case search(query: String, folderName: String?, limit: Int)
    case create(title: String, body: String?, folderName: String?)
    case update(noteID: String, title: String?, body: String?)
    case append(noteID: String, text: String)
    case delete(noteID: String)

    init(toolCall: ChatToolCall) throws {
        func trimmed(_ key: String) -> String? {
            guard let value = toolCall.arguments[key]?.stringValue else { return nil }
            let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return result.isEmpty ? nil : result
        }
        func required(_ key: String) throws -> String {
            guard let value = trimmed(key) else { throw NoteToolError.missingArgument(key) }
            return value
        }
        let limit = max(1, min(Int(toolCall.arguments["limit"]?.numberValue ?? 20), 50))
        switch toolCall.name {
        case "list_notes": self = .list(folderName: trimmed("folderName"), limit: limit)
        case "search_notes": self = .search(query: try required("query"), folderName: trimmed("folderName"), limit: limit)
        case "create_note": self = .create(title: try required("title"), body: trimmed("body"), folderName: trimmed("folderName"))
        case "update_note":
            let request = NoteToolRequest.update(noteID: try required("noteID"), title: trimmed("title"), body: trimmed("body"))
            guard trimmed("title") != nil || trimmed("body") != nil else { throw NoteToolError.noChanges }
            self = request
        case "append_to_note": self = .append(noteID: try required("noteID"), text: try required("text"))
        case "delete_note": self = .delete(noteID: try required("noteID"))
        default: throw NoteToolError.unsupportedTool(toolCall.name)
        }
    }
}

nonisolated enum NoteToolError: Error, Equatable {
    case unsupportedTool(String)
    case missingArgument(String)
    case noChanges
}

nonisolated enum NotesTextEncoding {
    static func appleScriptLiteral(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n") + "\""
    }

    static func html(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
            .replacingOccurrences(of: "\r", with: "<br>")
    }

    static func noteHTML(title: String, body: String?) -> String {
        let heading = "<h1>\(html(title))</h1>"
        guard let body, !body.isEmpty else { return heading }
        return heading + "<div>\(html(body))</div>"
    }
}

nonisolated enum NotesScriptBuilder {
    private static let cleanHandler = """
        on cleanText(theValue)
            set savedDelimiters to AppleScript's text item delimiters
            set AppleScript's text item delimiters to {tab, return, linefeed}
            set valueParts to text items of (theValue as text)
            set AppleScript's text item delimiters to " "
            set cleanValue to valueParts as text
            set AppleScript's text item delimiters to savedDelimiters
            return cleanValue
        end cleanText
        """

    static func list(query: String?, folderName: String?, limit: Int) -> String {
        let folderCondition = folderName.map {
            "(folderTitle is equal to \(NotesTextEncoding.appleScriptLiteral($0)))"
        } ?? "true"
        let queryCondition = query.map {
            let literal = NotesTextEncoding.appleScriptLiteral($0)
            return "((noteTitle contains \(literal)) or (noteText contains \(literal)))"
        } ?? "true"
        return cleanHandler + """

        tell application "Notes"
            set outputRows to {}
            repeat with currentNote in notes
                try
                    set noteTitle to name of currentNote as text
                    set noteText to plaintext of currentNote as text
                    set folderTitle to name of container of currentNote as text
                    if \(folderCondition) and \(queryCondition) then
                        set end of outputRows to ((id of currentNote as text) & tab & my cleanText(noteTitle) & tab & my cleanText(folderTitle))
                        if (count of outputRows) is greater than or equal to \(limit) then exit repeat
                    end if
                end try
            end repeat
            return outputRows
        end tell
        """
    }

    static func create(title: String, body: String?, folderName: String?) -> String {
        let folderSelection: String
        if let folderName {
            let literal = NotesTextEncoding.appleScriptLiteral(folderName)
            folderSelection = """
                set matchingFolders to every folder whose name is equal to \(literal)
                if (count of matchingFolders) is not 1 then error "No unique Notes folder has that name."
                set targetFolder to item 1 of matchingFolders
            """
        } else {
            folderSelection = "set targetFolder to default folder of default account"
        }
        let html = NotesTextEncoding.noteHTML(title: title, body: body)
        return """
        tell application "Notes"
            \(folderSelection)
            set createdNote to make new note at targetFolder with properties {body:\(NotesTextEncoding.appleScriptLiteral(html))}
            return (id of createdNote as text) & tab & (name of createdNote as text) & tab & (name of targetFolder as text)
        end tell
        """
    }

    static func update(rawID: String, title: String?, body: String?) -> String {
        var commands: [String] = []
        if let body {
            let resolvedTitle = title.map { NotesTextEncoding.appleScriptLiteral(NotesTextEncoding.html($0)) }
                ?? "(name of targetNote as text)"
            commands.append("set body of targetNote to (\"<h1>\" & \(resolvedTitle) & \"</h1><div>\" & \(NotesTextEncoding.appleScriptLiteral(NotesTextEncoding.html(body))) & \"</div>\")")
        }
        if let title { commands.append("set name of targetNote to \(NotesTextEncoding.appleScriptLiteral(title))") }
        return targetScript(rawID: rawID, commands: commands)
    }

    static func append(rawID: String, text: String) -> String {
        let html = "<div>\(NotesTextEncoding.html(text))</div>"
        return targetScript(rawID: rawID, commands: [
            "set body of targetNote to ((body of targetNote as text) & \(NotesTextEncoding.appleScriptLiteral(html)))"
        ])
    }

    static func delete(rawID: String) -> String {
        let literal = NotesTextEncoding.appleScriptLiteral(rawID)
        return """
        tell application "Notes"
            set targetNote to first note whose id is equal to \(literal)
            set deletedTitle to name of targetNote as text
            delete targetNote
            return deletedTitle
        end tell
        """
    }

    private static func targetScript(rawID: String, commands: [String]) -> String {
        """
        tell application "Notes"
            set targetNote to first note whose id is equal to \(NotesTextEncoding.appleScriptLiteral(rawID))
            \(commands.joined(separator: "\n    "))
            return (id of targetNote as text) & tab & (name of targetNote as text) & tab & (name of container of targetNote as text)
        end tell
        """
    }
}

@MainActor
protocol NotesToolExecuting {
    func confirmationDetails(for request: NoteToolRequest) -> ToolConfirmationDetails?
    func execute(_ request: NoteToolRequest) async -> ChatToolResult
}

nonisolated struct NotesScriptOutput: Sendable {
    let string: String?
    let items: [String]
}

nonisolated enum NotesAutomationResult: Sendable {
    case success(NotesScriptOutput)
    case failure(String)
}

@MainActor
final class AppleNotesService: NotesToolExecuting {
    private struct NoteReference { let rawID: String; let title: String; let folder: String }
    private var references: [String: NoteReference] = [:]

    func confirmationDetails(for request: NoteToolRequest) -> ToolConfirmationDetails? {
        switch request {
        case .list, .search: return nil
        case .create(let title, let body, let folder):
            return ToolConfirmationDetails(title: "Create this note?", primaryText: title,
                details: [("Folder", folder ?? "Default"), ("Body", body ?? "None")].filter { $0.1 != "None" }, actionLabel: "Create")
        case .update(let id, let title, let body):
            return ToolConfirmationDetails(title: "Update this note?", primaryText: reference(id)?.title ?? "Selected note",
                details: [("Title", title ?? "Unchanged"), ("Body", body ?? "Unchanged")].filter { $0.1 != "Unchanged" }, actionLabel: "Update")
        case .append(let id, let text):
            return ToolConfirmationDetails(title: "Append to this note?", primaryText: reference(id)?.title ?? "Selected note",
                details: [("Append", text)], actionLabel: "Append")
        case .delete(let id):
            let item = reference(id)
            return ToolConfirmationDetails(title: "Delete this note?", primaryText: item?.title ?? "Selected note",
                details: item.map { [("Folder", $0.folder)] } ?? [], actionLabel: "Delete")
        }
    }

    func execute(_ request: NoteToolRequest) async -> ChatToolResult {
        switch request {
        case .list(let folder, let limit): return await executeList(query: nil, folder: folder, limit: limit)
        case .search(let query, let folder, let limit): return await executeList(query: query, folder: folder, limit: limit)
        case .create(let title, let body, let folder):
            return await executeMutation(script: NotesScriptBuilder.create(title: title, body: body, folderName: folder), status: "created", verb: "Created")
        case .update(let id, let title, let body):
            guard let item = reference(id) else { return staleResult() }
            return await executeMutation(script: NotesScriptBuilder.update(rawID: item.rawID, title: title, body: body), status: "updated", verb: "Updated", existingID: id)
        case .append(let id, let text):
            guard let item = reference(id) else { return staleResult() }
            return await executeMutation(script: NotesScriptBuilder.append(rawID: item.rawID, text: text), status: "updated", verb: "Updated", existingID: id)
        case .delete(let id):
            guard let item = reference(id) else { return staleResult() }
            switch await Self.run(NotesScriptBuilder.delete(rawID: item.rawID)) {
            case .success(let output):
                references[id] = nil
                return result(status: "deleted", message: "Deleted ‘\(output.string ?? item.title)’.")
            case .failure(let message): return automationError(message)
            }
        }
    }

    private func executeList(query: String?, folder: String?, limit: Int) async -> ChatToolResult {
        switch await Self.run(NotesScriptBuilder.list(query: query, folderName: folder, limit: limit)) {
        case .success(let output):
            references = [:]
            var values: [ChatToolValue] = []
            for row in output.items {
                let parts = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 3 else { continue }
                let id = UUID().uuidString
                references[id] = NoteReference(rawID: parts[0], title: parts[1], folder: parts[2])
                values.append(.object(["noteID": .string(id), "title": .string(parts[1]), "folderName": .string(parts[2])]))
            }
            return ChatToolResult(response: ["status": .string(values.isEmpty ? "not_found" : "found"),
                "count": .number(Double(values.count)), "results": .array(values),
                "message": .string(values.isEmpty ? "No matching notes were found." : "Found \(values.count) notes.")])
        case .failure(let message): return automationError(message)
        }
    }

    private func executeMutation(script: String, status: String, verb: String, existingID: String? = nil) async -> ChatToolResult {
        switch await Self.run(script) {
        case .success(let output):
            let parts = (output.string ?? "").split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { return result(status: "error", message: "Notes returned an unexpected response.") }
            let id = existingID ?? UUID().uuidString
            references[id] = NoteReference(rawID: parts[0], title: parts[1], folder: parts[2])
            return ChatToolResult(response: ["status": .string(status), "noteID": .string(id),
                "title": .string(parts[1]), "folderName": .string(parts[2]), "message": .string("\(verb) ‘\(parts[1])’.")])
        case .failure(let message): return automationError(message)
        }
    }

    nonisolated private static func run(_ source: String) async -> NotesAutomationResult {
        await Task.detached {
            guard let script = NSAppleScript(source: source) else {
                return .failure("The Notes command could not be prepared.")
            }
            var error: NSDictionary?
            let value = script.executeAndReturnError(&error)
            if let error {
                return .failure(error[NSAppleScript.errorMessage] as? String ?? "Unknown automation error")
            }
            let items = value.numberOfItems > 0
                ? (1...value.numberOfItems).compactMap { value.atIndex($0)?.stringValue }
                : []
            return .success(NotesScriptOutput(string: value.stringValue, items: items))
        }.value
    }

    private func reference(_ id: String) -> NoteReference? { references[id] }
    private func staleResult() -> ChatToolResult { result(status: "not_found", message: "That note result is no longer available. Search Notes again first.") }
    private func automationError(_ message: String) -> ChatToolResult {
        result(status: "automation_error", message: "Apple Notes could not complete the request: \(message). If prompted, allow Electragne to control Notes in System Settings > Privacy & Security > Automation.")
    }
    private func result(status: String, message: String) -> ChatToolResult {
        ChatToolResult(response: ["status": .string(status), "message": .string(message)])
    }
}
