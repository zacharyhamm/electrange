import Foundation

nonisolated enum ChatToolProvider: Hashable, Sendable {
    case gemini
    case ollama
    case openAICompatible
}

nonisolated enum ChatToolFamily: Equatable, Sendable {
    case webSearch
    case reminders
    case notes
    case desktop
    case timers
    case gmail
    case calendar
    case slack
    case linear
    case status
    case memory
    case automations
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
            required: ["query"], providers: [.ollama, .openAICompatible],
            initialStatus: "Searching the web…", executionStatus: "Searching the web…"
        ),
        definition(
            "image_search", family: .webSearch,
            description: "Search the web for images to display in the chat response.",
            properties: ["query": property(.string, "The image search query")],
            required: ["query"], providers: [.gemini, .ollama, .openAICompatible],
            initialStatus: "Searching for images…", executionStatus: "Searching for images…"
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
        definition(
            "create_automation", family: .automations,
            description: "Create a recurring background automation after the owner confirms. It runs the given instruction headlessly with read-only tools every interval and proactively messages the owner only when its result warrants it.",
            properties: [
                "name": property(.string, "Short human-readable name for the automation."),
                "intervalSeconds": property(.number, "Required whole-number run interval from 60 to 604800 seconds."),
                "instruction": property(.string, "The task to perform each run, phrased as an instruction, including what makes a result worth notifying the owner about. Example: ‘Fetch today's messages in Slack channel #ops and notify me only if something looks urgent or blocking.’"),
            ], required: ["intervalSeconds", "instruction"], initialStatus: "Confirm automation…",
            executionStatus: "Saving automation…"
        ),
        definition(
            "list_automations", family: .automations,
            description: "List active background automations and obtain their opaque IDs.",
            initialStatus: "Reading automations…", executionStatus: "Reading automations…"
        ),
        definition(
            "cancel_automation", family: .automations,
            description: "Cancel a background automation after confirmation. Use list_automations first to obtain its ID.",
            properties: [
                "automationID": property(.string, "Opaque automation ID returned by create_automation or list_automations.")
            ], required: ["automationID"], initialStatus: "Confirm automation…",
            executionStatus: "Updating automations…"
        ),
        definition(
            "report_app_status", family: .status,
            description: "Report Electragne's own internal scheduling state: active countdown timers and which calendar events it will proactively notify the owner about.",
            initialStatus: "Checking internal state…", executionStatus: "Checking internal state…"
        ),
        definition(
            "list_google_accounts", family: .gmail,
            description: "List Google accounts connected to Electragne and obtain their opaque account IDs.",
            initialStatus: "Reading Google accounts…", executionStatus: "Reading Google accounts…"
        ),
        definition(
            "search_gmail", family: .gmail,
            description: "Search Gmail using Gmail search syntax. Returns message IDs for read_gmail_message.",
            properties: [
                "query": property(.string, "Gmail search query, such as from:alex newer_than:7d."),
                "accountID": property(.string, "Optional opaque Google account ID. Omit to use the default account."),
                "limit": property(.number, "Optional result limit from 1 to 25."),
            ], required: ["query"], initialStatus: "Searching Gmail…",
            executionStatus: "Searching Gmail…"
        ),
        definition(
            "read_gmail_message", family: .gmail,
            description: "Read one Gmail message identified by search_gmail.",
            properties: [
                "messageID": property(.string, "Opaque Gmail message ID returned by search_gmail."),
                "accountID": property(.string, "Optional opaque Google account ID. Omit to use the default account."),
            ], required: ["messageID"], initialStatus: "Reading Gmail…",
            executionStatus: "Reading Gmail…"
        ),
        definition(
            "create_gmail_draft", family: .gmail,
            description: "Create a Gmail draft after confirmation. Use comma-separated addresses for multiple recipients.",
            properties: [
                "to": property(.string, "Required recipient email address or comma-separated addresses."),
                "cc": property(.string, "Optional CC email address or comma-separated addresses."),
                "bcc": property(.string, "Optional BCC email address or comma-separated addresses."),
                "subject": property(.string, "Required email subject."),
                "body": property(.string, "Required plaintext email body."),
                "accountID": property(.string, "Optional opaque Google account ID. Omit to use the default account."),
            ], required: ["to", "subject", "body"], initialStatus: "Confirm Gmail draft…",
            executionStatus: "Creating Gmail draft…"
        ),
        definition(
            "send_gmail_draft", family: .gmail,
            description: "Send an existing Gmail draft after a separate confirmation.",
            properties: [
                "draftID": property(.string, "Opaque draft ID returned by create_gmail_draft."),
                "accountID": property(.string, "Optional opaque Google account ID. Omit to use the default account."),
            ], required: ["draftID"], initialStatus: "Confirm Gmail send…",
            executionStatus: "Sending Gmail draft…"
        ),
        definition(
            "list_google_calendars", family: .calendar,
            description: "List calendars for a connected Google account and obtain calendar IDs.",
            properties: [
                "accountID": property(.string, "Optional opaque Google account ID. Omit to use the default account."),
            ], initialStatus: "Reading Google Calendar…",
            executionStatus: "Reading Google Calendar…"
        ),
        definition(
            "list_calendar_events", family: .calendar,
            description: "List or search Google Calendar events. Defaults to the primary calendar and the next 30 days.",
            properties: [
                "calendarID": property(.string, "Optional calendar ID from list_google_calendars. Omit for primary."),
                "query": property(.string, "Optional free-text event search query."),
                "timeMin": property(.string, "Optional inclusive lower bound as an RFC 3339 timestamp with UTC offset."),
                "timeMax": property(.string, "Optional exclusive upper bound as an RFC 3339 timestamp with UTC offset."),
                "accountID": property(.string, "Optional opaque Google account ID. Omit to use the default account."),
                "limit": property(.number, "Optional result limit from 1 to 50."),
            ], initialStatus: "Reading Google Calendar…",
            executionStatus: "Reading Google Calendar…"
        ),
        definition(
            "create_calendar_event", family: .calendar,
            description: "Create a Google Calendar event after confirmation. Use RFC 3339 timestamps for timed events or YYYY-MM-DD dates for all-day events.",
            properties: [
                "summary": property(.string, "Required event title."),
                "start": property(.string, "Start as RFC 3339 with UTC offset, or YYYY-MM-DD for an all-day event."),
                "end": property(.string, "Exclusive end using the same format as start. For a one-day all-day event, use the following date."),
                "description": property(.string, "Optional event description."),
                "location": property(.string, "Optional event location."),
                "calendarID": property(.string, "Optional calendar ID from list_google_calendars. Omit for primary."),
                "accountID": property(.string, "Optional opaque Google account ID. Omit to use the default account."),
            ], required: ["summary", "start", "end"], initialStatus: "Confirm Calendar event…",
            executionStatus: "Creating Calendar event…"
        ),
        definition(
            "search_slack", family: .slack,
            description: "Full-text search the owner's archived Slack messages across all channels. Supports SQLite FTS5 syntax: words, \"quoted phrases\", and OR.",
            properties: [
                "query": property(.string, "Required search query."),
                "limit": property(.number, "Optional result limit from 1 to 50."),
            ], required: ["query"], initialStatus: "Searching Slack…",
            executionStatus: "Searching Slack…"
        ),
        definition(
            "get_slack_messages", family: .slack,
            description: "Read archived Slack messages from one channel, optionally within a date range. Use this to summarize what is going on in a Slack channel.",
            properties: [
                "channel": property(.string, "Required channel name (with or without #) or channel ID."),
                "from": property(.string, "Optional inclusive start date as YYYY-MM-DD in the owner's time zone."),
                "to": property(.string, "Optional inclusive end date as YYYY-MM-DD in the owner's time zone."),
            ], required: ["channel"], initialStatus: "Reading Slack…",
            executionStatus: "Reading Slack…"
        ),
        definition(
            "get_slack_thread", family: .slack,
            description: "Read one archived Slack thread (root message and replies). Use the channel ID and thread ts from a Slack read tool's message ids.",
            properties: [
                "channelID": property(.string, "Required channel ID from a message id."),
                "threadTS": property(.string, "Required thread ts from a message id."),
            ], required: ["channelID", "threadTS"], initialStatus: "Reading Slack…",
            executionStatus: "Reading Slack…"
        ),
        definition(
            "list_slack_users", family: .slack,
            description: "List Slack workspace members with their user IDs and names. Use to resolve who a user ID is or find someone's ID.",
            properties: [
                "query": property(.string, "Optional case-insensitive match on username, real name, or display name."),
            ], initialStatus: "Reading Slack users…",
            executionStatus: "Reading Slack users…"
        ),
        definition(
            "get_slack_permalink", family: .slack,
            description: "Get the browser permalink for one Slack message, identified by the channel ID and ts from a Slack read tool's message ids.",
            properties: [
                "channelID": property(.string, "Required channel ID from a message id."),
                "ts": property(.string, "Required message ts from a message id."),
            ], required: ["channelID", "ts"], initialStatus: "Reading Slack…",
            executionStatus: "Reading Slack…"
        ),
        definition(
            "send_slack_message", family: .slack,
            description: "Send a Slack message after the owner confirms it. Use a channel ID from a Slack read tool; set threadTS to reply in a thread.",
            properties: [
                "channel": property(.string, "Required channel ID from a Slack read tool's message ids."),
                "channelName": property(.string, "Optional human-readable channel name from the transcript, shown to the owner in the confirmation."),
                "text": property(.string, "Required message text."),
                "threadTS": property(.string, "Optional thread ts from a message id to reply in that thread."),
            ], required: ["channel", "text"], initialStatus: "Confirm Slack message…",
            executionStatus: "Sending Slack message…"
        ),
        definition(
            "recall_memory", family: .memory,
            description: "Search your long-term memory of past conversations with the owner. Use when asked what you remember, or when past context about the owner would help.",
            properties: [
                "query": property(.string, "Topic, name, or question to look up."),
            ], required: ["query"], initialStatus: "Remembering…",
            executionStatus: "Remembering…"
        ),
        definition(
            "list_linear_teams", family: .linear,
            description: "List Linear teams with their IDs, keys, and names. Use this first to obtain a teamID before creating an issue.",
            initialStatus: "Reading Linear…", executionStatus: "Reading Linear…"
        ),
        definition(
            "search_linear_issues", family: .linear,
            description: "Full-text search Linear issues by title and description. Returns issue identifiers for get_linear_issue.",
            properties: [
                "query": property(.string, "Required search query."),
                "limit": property(.number, "Optional result limit from 1 to 50."),
            ], required: ["query"], initialStatus: "Searching Linear…",
            executionStatus: "Searching Linear…"
        ),
        definition(
            "search_linear_projects", family: .linear,
            description: "Full-text search Linear projects by name and content. Returns project names, states, leads, and URLs.",
            properties: [
                "query": property(.string, "Required search query."),
                "limit": property(.number, "Optional result limit from 1 to 50."),
            ], required: ["query"], initialStatus: "Searching Linear…",
            executionStatus: "Searching Linear…"
        ),
        definition(
            "list_my_linear_issues", family: .linear,
            description: "List the owner's open Linear issues (assigned to them, not completed or canceled), most recently updated first.",
            properties: [
                "limit": property(.number, "Optional result limit from 1 to 50."),
            ], initialStatus: "Reading Linear…", executionStatus: "Reading Linear…"
        ),
        definition(
            "get_linear_issue", family: .linear,
            description: "Read one Linear issue in full — description and comments — by its identifier such as ENG-123.",
            properties: [
                "issueID": property(.string, "Required issue identifier such as ENG-123, from a Linear read tool."),
            ], required: ["issueID"], initialStatus: "Reading Linear…",
            executionStatus: "Reading Linear…"
        ),
        definition(
            "create_linear_issue", family: .linear,
            description: "Create a Linear issue after the owner confirms it. Use a teamID from list_linear_teams.",
            properties: [
                "teamID": property(.string, "Required team ID from list_linear_teams."),
                "teamName": property(.string, "Optional human-readable team name, shown to the owner in the confirmation."),
                "title": property(.string, "Required issue title."),
                "description": property(.string, "Optional issue description in Markdown."),
            ], required: ["teamID", "title"], initialStatus: "Confirm Linear issue…",
            executionStatus: "Creating Linear issue…"
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
        providers: Set<ChatToolProvider> = [.gemini, .ollama, .openAICompatible],
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
