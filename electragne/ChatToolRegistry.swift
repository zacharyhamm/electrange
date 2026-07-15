import Foundation

nonisolated enum ChatToolProvider: Hashable, Sendable {
    case gemini
    case ollama
}

nonisolated enum ChatToolFamily: Equatable, Sendable {
    case webSearch
    case reminders
    case notes
    case desktop
    case timers
}

nonisolated enum ChatToolParameterType: String, Equatable, Sendable {
    case string
    case number
    case boolean
}

nonisolated struct ChatToolParameter: Equatable, Sendable {
    let type: ChatToolParameterType
    let description: String
}

nonisolated struct ChatToolDefinition: Equatable, Sendable {
    let name: String
    let family: ChatToolFamily
    let description: String
    let properties: [String: ChatToolParameter]
    let required: [String]
    let providers: Set<ChatToolProvider>
    let initialStatus: String
    let executionStatus: String
}

nonisolated enum ChatToolRegistry {
    static let definitions: [ChatToolDefinition] = [
        definition(
            "web_search", family: .webSearch,
            description: "Search the web and return the top results.",
            properties: ["query": property(.string, "The search query")],
            required: ["query"], providers: [.ollama],
            initialStatus: "Searching the web…", executionStatus: "Searching the web…"
        ),
        definition(
            "create_reminder", family: .reminders,
            description: "Create one reminder in Apple Reminders after the owner confirms it.",
            properties: [
                "title": property(.string, "Required reminder title."),
                "notes": property(.string, "Optional reminder notes."),
                "listName": property(.string, "Optional existing Apple Reminders list name. Omit for the default list."),
                "due": property(.string, "Optional due date as YYYY-MM-DD, or an RFC 3339 timestamp with UTC offset."),
            ], required: ["title"], initialStatus: "Confirm reminder…",
            executionStatus: "Updating reminders…"
        ),
        definition(
            "list_reminders", family: .reminders,
            description: "List or search Apple Reminders. Use this first to obtain an identifier before updating or deleting a reminder.",
            properties: [
                "query": property(.string, "Optional words to match in title or notes."),
                "listName": property(.string, "Optional exact Reminders list name."),
                "completion": property(.string, "incomplete (default), completed, or all."),
                "limit": property(.number, "Optional result limit from 1 to 50."),
            ], initialStatus: "Reading reminders…", executionStatus: "Reading reminders…"
        ),
        definition(
            "update_reminder", family: .reminders,
            description: "Modify one reminder identified by list_reminders. The owner must confirm.",
            properties: [
                "identifier": property(.string, "Identifier returned by list_reminders or create_reminder."),
                "title": property(.string, "Optional replacement title."),
                "notes": property(.string, "Optional replacement notes."),
                "clearNotes": property(.boolean, "Set true to remove existing notes."),
                "listName": property(.string, "Optional exact destination list name."),
                "due": property(.string, "Optional replacement due date as YYYY-MM-DD or RFC 3339 timestamp."),
                "clearDue": property(.boolean, "Set true to remove the due date and alarms."),
                "completed": property(.boolean, "Optional completion state."),
            ], required: ["identifier"], initialStatus: "Confirm reminder…",
            executionStatus: "Updating reminders…"
        ),
        definition(
            "delete_reminder", family: .reminders,
            description: "Permanently delete one reminder identified by list_reminders after confirmation.",
            properties: [
                "identifier": property(.string, "Identifier returned by list_reminders.")
            ], required: ["identifier"], initialStatus: "Confirm reminder…",
            executionStatus: "Updating reminders…"
        ),
        definition(
            "list_notes", family: .notes,
            description: "List recent Apple Notes titles and opaque IDs, optionally within one folder.",
            properties: [
                "folderName": property(.string, "Optional exact Notes folder name."),
                "limit": property(.number, "Optional result limit from 1 to 50."),
            ], initialStatus: "Reading Notes…", executionStatus: "Reading Notes…"
        ),
        definition(
            "search_notes", family: .notes,
            description: "Search Apple Notes titles and plaintext. Use before modifying or deleting a note to obtain its opaque ID.",
            properties: [
                "query": property(.string, "Required text to find."),
                "folderName": property(.string, "Optional exact Notes folder name."),
                "limit": property(.number, "Optional result limit from 1 to 50."),
            ], required: ["query"], initialStatus: "Reading Notes…",
            executionStatus: "Reading Notes…"
        ),
        definition(
            "create_note", family: .notes,
            description: "Create an Apple Note after confirmation.",
            properties: [
                "title": property(.string, "Required note title."),
                "body": property(.string, "Optional plaintext body."),
                "folderName": property(.string, "Optional exact existing Notes folder name; omit for default."),
            ], required: ["title"], initialStatus: "Confirm Notes action…",
            executionStatus: "Updating Notes…"
        ),
        definition(
            "update_note", family: .notes,
            description: "Replace an Apple Note title and/or body after confirmation. Requires an opaque ID from list_notes or search_notes.",
            properties: [
                "noteID": property(.string, "Opaque note ID returned by a Notes read tool."),
                "title": property(.string, "Optional replacement title."),
                "body": property(.string, "Optional replacement plaintext body."),
            ], required: ["noteID"], initialStatus: "Confirm Notes action…",
            executionStatus: "Updating Notes…"
        ),
        definition(
            "append_to_note", family: .notes,
            description: "Append plaintext to an Apple Note after confirmation.",
            properties: [
                "noteID": property(.string, "Opaque note ID returned by a Notes read tool."),
                "text": property(.string, "Text to append."),
            ], required: ["noteID", "text"], initialStatus: "Confirm Notes action…",
            executionStatus: "Updating Notes…"
        ),
        definition(
            "delete_note", family: .notes,
            description: "Permanently delete an Apple Note after confirmation.",
            properties: [
                "noteID": property(.string, "Opaque note ID returned by a Notes read tool.")
            ], required: ["noteID"], initialStatus: "Confirm Notes action…",
            executionStatus: "Updating Notes…"
        ),
        definition(
            "open_app", family: .desktop,
            description: "Open an installed macOS application after the owner confirms.",
            properties: [
                "name": property(.string, "Application name or bundle identifier.")
            ], required: ["name"], initialStatus: "Confirm action…", executionStatus: "Opening…"
        ),
        definition(
            "open_url", family: .desktop,
            description: "Open an HTTP or HTTPS website in the default browser after confirmation.",
            properties: [
                "url": property(.string, "Complete http:// or https:// URL.")
            ], required: ["url"], initialStatus: "Confirm action…", executionStatus: "Opening…"
        ),
        definition(
            "find_files", family: .desktop,
            description: "Search file and folder names within folders the owner approved in Electragne Settings.",
            properties: [
                "query": property(.string, "Words that must occur in the item name or relative path.")
            ], required: ["query"], initialStatus: "Searching approved folders…",
            executionStatus: "Searching approved folders…"
        ),
        definition(
            "reveal_in_finder", family: .desktop,
            description: "Reveal one result from the latest find_files call in Finder after confirmation.",
            properties: [
                "fileID": property(.string, "Opaque result ID returned by find_files.")
            ], required: ["fileID"], initialStatus: "Confirm action…", executionStatus: "Opening…"
        ),
        definition(
            "create_timer", family: .timers,
            description: "Start a countdown timer after the owner confirms. Convert the requested duration to a whole number of seconds.",
            properties: [
                "label": property(.string, "Optional short description of what the timer is for."),
                "durationSeconds": property(.number, "Required whole-number duration from 1 to 604800 seconds."),
            ], required: ["durationSeconds"], initialStatus: "Confirm timer…",
            executionStatus: "Updating timers…"
        ),
        definition(
            "list_timers", family: .timers,
            description: "List active countdown timers and obtain their opaque IDs.",
            initialStatus: "Reading timers…", executionStatus: "Reading timers…"
        ),
        definition(
            "cancel_timer", family: .timers,
            description: "Cancel an active countdown timer after confirmation. Use list_timers first to obtain its ID.",
            properties: [
                "timerID": property(.string, "Opaque timer ID returned by create_timer or list_timers.")
            ], required: ["timerID"], initialStatus: "Confirm timer…",
            executionStatus: "Updating timers…"
        ),
    ]

    static func definitions(for provider: ChatToolProvider) -> [ChatToolDefinition] {
        definitions.filter { $0.providers.contains(provider) }
    }

    static func definition(named name: String) -> ChatToolDefinition? {
        definitions.first { $0.name == name }
    }

    private static func property(
        _ type: ChatToolParameterType,
        _ description: String
    ) -> ChatToolParameter {
        ChatToolParameter(type: type, description: description)
    }

    private static func definition(
        _ name: String,
        family: ChatToolFamily,
        description: String,
        properties: [String: ChatToolParameter] = [:],
        required: [String] = [],
        providers: Set<ChatToolProvider> = [.gemini, .ollama],
        initialStatus: String,
        executionStatus: String
    ) -> ChatToolDefinition {
        ChatToolDefinition(
            name: name,
            family: family,
            description: description,
            properties: properties,
            required: required,
            providers: providers,
            initialStatus: initialStatus,
            executionStatus: executionStatus
        )
    }
}
