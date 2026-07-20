//
//  LinearTool.swift
//  electragne
//
//  Linear tool calls (linear.app GraphQL API): parsing and validation, plus
//  the executor that turns issues into plain text the model can summarize.
//  Reads run unconfirmed; creating an issue is the one write and confirms.
//

import Foundation

nonisolated enum LinearToolRequest: Equatable, Sendable {
    case teams
    case search(query: String, limit: Int)
    case searchProjects(query: String, limit: Int)
    case myIssues(limit: Int)
    case issue(id: String)
    /// teamName is model-supplied display context for the confirmation card;
    /// the team ID is what's actually sent.
    case create(teamID: String, teamName: String?, title: String, description: String?)

    init(toolCall: ChatToolCall) throws {
        let args = ToolCallArguments(toolCall)
        func required(_ key: String) throws -> String {
            try args.required(key, onMissing: LinearToolError.missingArgument)
        }
        func limit(default defaultLimit: Int) throws -> Int {
            try args.limit(default: defaultLimit, onInvalid: LinearToolError.invalidLimit)
        }

        switch toolCall.name {
        case "list_linear_teams":
            self = .teams
        case "search_linear_issues":
            self = .search(query: try required("query"), limit: try limit(default: 20))
        case "search_linear_projects":
            self = .searchProjects(query: try required("query"), limit: try limit(default: 20))
        case "list_my_linear_issues":
            self = .myIssues(limit: try limit(default: 25))
        case "get_linear_issue":
            self = .issue(id: try required("issueID"))
        case "create_linear_issue":
            self = .create(
                teamID: try required("teamID"),
                teamName: args.string("teamName"),
                title: try required("title"),
                description: args.string("description")
            )
        default:
            throw LinearToolError.unsupportedTool(toolCall.name)
        }
    }
}

nonisolated enum LinearToolError: LocalizedError, Equatable {
    case unsupportedTool(String)
    case missingArgument(String)
    case invalidLimit
    case notConfigured
    case api(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedTool: "Unsupported Linear tool."
        case .missingArgument(let name): "The ‘\(name)’ argument is required."
        case .invalidLimit: "Linear result limit must be a whole number from 1 to 50."
        case .notConfigured: "Linear is not configured. Add a Linear API key in Electragne Settings."
        case .api(let message): "The Linear API reported an error: \(message)"
        }
    }
}

// MARK: - Wire models

nonisolated struct LinearIssue: Decodable, Equatable, Sendable {
    struct Named: Decodable, Equatable, Sendable { var name: String? }
    struct User: Decodable, Equatable, Sendable { var displayName: String? }
    struct Team: Decodable, Equatable, Sendable { var key: String?; var name: String? }
    struct Comment: Decodable, Equatable, Sendable {
        var body: String?
        var user: User?
        var createdAt: String?
    }
    struct Comments: Decodable, Equatable, Sendable { var nodes: [Comment]? }

    var identifier: String
    var title: String? = nil
    var url: String? = nil
    var description: String? = nil
    var priorityLabel: String? = nil
    var state: Named? = nil
    var assignee: User? = nil
    var team: Team? = nil
    var createdAt: String? = nil
    var updatedAt: String? = nil
    var comments: Comments? = nil
}

nonisolated struct LinearProject: Decodable, Equatable, Sendable {
    var id: String
    var name: String? = nil
    var url: String? = nil
    var state: String? = nil
    var lead: LinearIssue.User? = nil
    var targetDate: String? = nil
    var updatedAt: String? = nil
}

nonisolated struct LinearTeam: Decodable, Equatable, Sendable {
    var id: String
    var key: String? = nil
    var name: String? = nil
}

// MARK: - GraphQL client

nonisolated enum LinearClient {
    static let endpoint = URL(string: "https://api.linear.app/graphql")!

    /// Fields every issue list shows; detail queries extend them.
    private static let issueFields =
        "identifier title url priorityLabel state { name } assignee { displayName } updatedAt"

    static func teams(_ apiKey: String) async throws -> [LinearTeam] {
        struct Result: Decodable { struct Nodes: Decodable { let nodes: [LinearTeam]? }; let teams: Nodes? }
        let result: Result = try await call(
            apiKey, query: "query { teams { nodes { id key name } } }", variables: Empty()
        )
        return result.teams?.nodes ?? []
    }

    static func search(_ apiKey: String, term: String, limit: Int) async throws -> [LinearIssue] {
        struct Variables: Encodable { let term: String; let first: Int }
        struct Result: Decodable {
            struct Nodes: Decodable { let nodes: [LinearIssue]? }
            let searchIssues: Nodes?
        }
        let result: Result = try await call(
            apiKey,
            query: "query($term: String!, $first: Int!) { searchIssues(term: $term, first: $first) { nodes { \(issueFields) } } }",
            variables: Variables(term: term, first: limit)
        )
        return result.searchIssues?.nodes ?? []
    }

    static func searchProjects(_ apiKey: String, term: String, limit: Int) async throws -> [LinearProject] {
        struct Variables: Encodable { let term: String; let first: Int }
        struct Result: Decodable {
            struct Nodes: Decodable { let nodes: [LinearProject]? }
            let searchProjects: Nodes?
        }
        let result: Result = try await call(
            apiKey,
            query: "query($term: String!, $first: Int!) { searchProjects(term: $term, first: $first) { nodes { id name url state lead { displayName } targetDate updatedAt } } }",
            variables: Variables(term: term, first: limit)
        )
        return result.searchProjects?.nodes ?? []
    }

    /// The key owner's open assigned issues, most recently updated first.
    static func myIssues(_ apiKey: String, limit: Int) async throws -> [LinearIssue] {
        struct Variables: Encodable { let first: Int }
        struct Result: Decodable {
            struct Nodes: Decodable { let nodes: [LinearIssue]? }
            struct Viewer: Decodable { let assignedIssues: Nodes? }
            let viewer: Viewer?
        }
        let result: Result = try await call(
            apiKey,
            query: """
            query($first: Int!) { viewer { assignedIssues(first: $first, orderBy: updatedAt, \
            filter: { state: { type: { nin: ["completed", "canceled"] } } }) { nodes { \(issueFields) } } } }
            """,
            variables: Variables(first: limit)
        )
        return result.viewer?.assignedIssues?.nodes ?? []
    }

    static func issue(_ apiKey: String, id: String) async throws -> LinearIssue {
        struct Variables: Encodable { let id: String }
        struct Result: Decodable { let issue: LinearIssue? }
        let result: Result = try await call(
            apiKey,
            query: """
            query($id: String!) { issue(id: $id) { \(issueFields) description team { key name } createdAt \
            comments(first: 50) { nodes { body createdAt user { displayName } } } } }
            """,
            variables: Variables(id: id)
        )
        guard let issue = result.issue else { throw LinearToolError.api("issue not found") }
        return issue
    }

    /// Creates an issue and returns it (identifier + url).
    static func createIssue(
        _ apiKey: String, teamID: String, title: String, description: String?
    ) async throws -> LinearIssue {
        struct Input: Encodable { let teamId: String; let title: String; let description: String? }
        struct Variables: Encodable { let input: Input }
        struct Result: Decodable {
            struct Payload: Decodable { let success: Bool?; let issue: LinearIssue? }
            let issueCreate: Payload?
        }
        let result: Result = try await call(
            apiKey,
            query: "mutation($input: IssueCreateInput!) { issueCreate(input: $input) { success issue { identifier url title } } }",
            variables: Variables(input: Input(teamId: teamID, title: title, description: description))
        )
        guard result.issueCreate?.success == true, let issue = result.issueCreate?.issue else {
            throw LinearToolError.api("issue creation did not succeed")
        }
        return issue
    }

    private struct Empty: Encodable {}
    private struct Payload<V: Encodable>: Encodable { let query: String; let variables: V }
    private struct GraphQLError: Decodable { let message: String? }
    private struct Body<D: Decodable>: Decodable { let data: D?; let errors: [GraphQLError]? }

    private static func call<V: Encodable & Sendable, R: Decodable & Sendable>(
        _ apiKey: String, query: String, variables: V
    ) async throws -> R {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(Payload(query: query, variables: variables))

        let (data, response) = try await URLSession.shared.data(for: request)
        let body = try? JSONDecoder().decode(Body<R>.self, from: data)
        if let message = body?.errors?.first?.message {
            throw LinearToolError.api(message)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw LinearToolError.api("HTTP \(http.statusCode)")
        }
        guard let result = body?.data else {
            throw LinearToolError.api("unexpected response from Linear")
        }
        return result
    }
}

// MARK: - Executor

@MainActor
protocol LinearToolExecuting {
    func confirmationDetails(for request: LinearToolRequest) -> ToolConfirmationDetails?
    func execute(_ request: LinearToolRequest) async -> ChatToolResult
}

@MainActor
final class LinearToolService: LinearToolExecuting {
    private let apiKey: () -> String?

    init(apiKey: @escaping () -> String? = { ChatAPIKeyStore.load(for: .linear) }) {
        self.apiKey = apiKey
    }

    /// Reads run unconfirmed; creating an issue always confirms.
    func confirmationDetails(for request: LinearToolRequest) -> ToolConfirmationDetails? {
        guard case .create(let teamID, let teamName, let title, let description) = request else {
            return nil
        }
        return ToolConfirmationDetails(
            title: "Create this Linear issue?",
            primaryText: description.map { "\(title)\n\n\($0)" } ?? title,
            details: [("Team", teamName.map { "\($0) (\(teamID))" } ?? teamID)],
            actionLabel: "Create"
        )
    }

    func execute(_ request: LinearToolRequest) async -> ChatToolResult {
        guard let apiKey = apiKey() else {
            return .error(LinearToolError.notConfigured.localizedDescription)
        }
        do {
            switch request {
            case .teams:
                return Self.teamsResult(try await LinearClient.teams(apiKey))
            case .search(let query, let limit):
                return Self.issuesResult(
                    try await LinearClient.search(apiKey, term: query, limit: limit),
                    emptyNote: "No Linear issues matched."
                )
            case .searchProjects(let query, let limit):
                return Self.projectsResult(
                    try await LinearClient.searchProjects(apiKey, term: query, limit: limit),
                    emptyNote: "No Linear projects matched."
                )
            case .myIssues(let limit):
                return Self.issuesResult(
                    try await LinearClient.myIssues(apiKey, limit: limit),
                    emptyNote: "No open Linear issues are assigned to you."
                )
            case .issue(let id):
                return Self.issueDetailResult(try await LinearClient.issue(apiKey, id: id))
            case .create(let teamID, _, let title, let description):
                let issue = try await LinearClient.createIssue(
                    apiKey, teamID: teamID, title: title, description: description
                )
                var response: [String: ChatToolValue] = [
                    "status": .string("ok"),
                    "message": .string("Created \(issue.identifier)."),
                    "issueID": .string(issue.identifier),
                ]
                if let url = issue.url { response["url"] = .string(url) }
                return ChatToolResult(response: response)
            }
        } catch {
            return .error(error.localizedDescription)
        }
    }

    static func teamsResult(_ teams: [LinearTeam]) -> ChatToolResult {
        guard !teams.isEmpty else {
            return .make(status: "ok", message: "No Linear teams are visible to this API key.")
        }
        return ChatToolResult(response: [
            "status": .string("ok"),
            "teams": .array(teams.map { team in
                var entry: [String: ChatToolValue] = ["teamID": .string(team.id)]
                if let key = team.key { entry["key"] = .string(key) }
                if let name = team.name { entry["name"] = .string(name) }
                return .object(entry)
            }),
        ])
    }

    static func issuesResult(_ issues: [LinearIssue], emptyNote: String) -> ChatToolResult {
        guard !issues.isEmpty else { return .make(status: "ok", message: emptyNote) }
        return ChatToolResult(response: [
            "status": .string("ok"),
            "issueCount": .number(Double(issues.count)),
            "issues": .string(issues.map(issueLine).joined(separator: "\n")),
        ])
    }

    /// One "ID [State] Title — assignee (updated day) url" line per issue. The
    /// leading identifier is what get_linear_issue takes.
    static func issueLine(_ issue: LinearIssue) -> String {
        var line = issue.identifier
        if let state = issue.state?.name, !state.isEmpty { line += " [\(state)]" }
        line += " \(issue.title ?? "")"
        if let assignee = issue.assignee?.displayName, !assignee.isEmpty {
            line += " — \(assignee)"
        }
        if let day = day(issue.updatedAt) { line += " (updated \(day))" }
        if let url = issue.url { line += " \(url)" }
        return line
    }

    static func projectsResult(_ projects: [LinearProject], emptyNote: String) -> ChatToolResult {
        guard !projects.isEmpty else { return .make(status: "ok", message: emptyNote) }
        return ChatToolResult(response: [
            "status": .string("ok"),
            "projectCount": .number(Double(projects.count)),
            "projects": .string(projects.map(projectLine).joined(separator: "\n")),
        ])
    }

    /// One "Name [state] — lead (target day, updated day) url" line per project.
    static func projectLine(_ project: LinearProject) -> String {
        var line = project.name ?? project.id
        if let state = project.state, !state.isEmpty { line += " [\(state)]" }
        if let lead = project.lead?.displayName, !lead.isEmpty { line += " — \(lead)" }
        let dates = [
            day(project.targetDate).map { "target \($0)" },
            day(project.updatedAt).map { "updated \($0)" },
        ].compactMap { $0 }
        if !dates.isEmpty { line += " (\(dates.joined(separator: ", ")))" }
        if let url = project.url { line += " \(url)" }
        return line
    }

    static func issueDetailResult(_ issue: LinearIssue) -> ChatToolResult {
        var lines = [issueLine(issue)]
        if let team = issue.team, let label = team.name ?? team.key {
            lines.append("Team: \(label)")
        }
        if let priority = issue.priorityLabel, !priority.isEmpty {
            lines.append("Priority: \(priority)")
        }
        if let day = day(issue.createdAt) { lines.append("Created: \(day)") }
        if let description = issue.description, !description.isEmpty {
            lines.append("")
            lines.append(description)
        }
        let comments = issue.comments?.nodes ?? []
        if !comments.isEmpty {
            lines.append("")
            lines.append("Comments:")
            lines.append(contentsOf: comments.map { comment in
                let who = comment.user?.displayName ?? "unknown"
                let prefix = day(comment.createdAt).map { "[\($0)] " } ?? ""
                return "\(prefix)\(who): \(comment.body ?? "")"
            })
        }
        return ChatToolResult(response: [
            "status": .string("ok"),
            "issue": .string(lines.joined(separator: "\n")),
        ])
    }

    /// The YYYY-MM-DD prefix of a Linear ISO 8601 timestamp.
    private static func day(_ timestamp: String?) -> String? {
        guard let timestamp, timestamp.count >= 10 else { return nil }
        return String(timestamp.prefix(10))
    }
}
