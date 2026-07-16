import Foundation
import Testing
@testable import electragne

struct LinearToolRequestTests {
    private func call(_ name: String, _ arguments: [String: ChatToolValue]) -> ChatToolCall {
        ChatToolCall(id: "1", name: name, arguments: arguments)
    }

    @Test func parsesReadTools() throws {
        #expect(try LinearToolRequest(toolCall: call("list_linear_teams", [:])) == .teams)

        #expect(try LinearToolRequest(toolCall: call("search_linear_issues", [
            "query": .string(" login bug ")
        ])) == .search(query: "login bug", limit: 20))

        #expect(try LinearToolRequest(toolCall: call("search_linear_projects", [
            "query": .string("mobile app")
        ])) == .searchProjects(query: "mobile app", limit: 20))

        #expect(try LinearToolRequest(toolCall: call("list_my_linear_issues", [
            "limit": .number(5)
        ])) == .myIssues(limit: 5))
        #expect(try LinearToolRequest(toolCall: call("list_my_linear_issues", [:]))
            == .myIssues(limit: 25))

        #expect(try LinearToolRequest(toolCall: call("get_linear_issue", [
            "issueID": .string("ENG-123")
        ])) == .issue(id: "ENG-123"))
    }

    @Test func parsesCreate() throws {
        #expect(try LinearToolRequest(toolCall: call("create_linear_issue", [
            "teamID": .string("team-uuid"), "teamName": .string("Engineering"),
            "title": .string("Fix login"), "description": .string("Steps…"),
        ])) == .create(
            teamID: "team-uuid", teamName: "Engineering",
            title: "Fix login", description: "Steps…"
        ))
        // teamName and description are optional
        #expect(try LinearToolRequest(toolCall: call("create_linear_issue", [
            "teamID": .string("t"), "title": .string("x"),
        ])) == .create(teamID: "t", teamName: nil, title: "x", description: nil))
    }

    @Test func rejectsInvalidArguments() {
        #expect(throws: LinearToolError.missingArgument("query")) {
            try LinearToolRequest(toolCall: call("search_linear_issues", [:]))
        }
        #expect(throws: LinearToolError.invalidLimit) {
            try LinearToolRequest(toolCall: call("search_linear_issues", [
                "query": .string("x"), "limit": .number(0),
            ]))
        }
        #expect(throws: LinearToolError.missingArgument("query")) {
            try LinearToolRequest(toolCall: call("search_linear_projects", [:]))
        }
        #expect(throws: LinearToolError.invalidLimit) {
            try LinearToolRequest(toolCall: call("list_my_linear_issues", [
                "limit": .number(7.5)
            ]))
        }
        #expect(throws: LinearToolError.missingArgument("issueID")) {
            try LinearToolRequest(toolCall: call("get_linear_issue", [:]))
        }
        #expect(throws: LinearToolError.missingArgument("title")) {
            try LinearToolRequest(toolCall: call("create_linear_issue", [
                "teamID": .string("t")
            ]))
        }
        #expect(throws: LinearToolError.unsupportedTool("delete_linear_issue")) {
            try LinearToolRequest(toolCall: call("delete_linear_issue", [:]))
        }
    }
}

@MainActor
struct LinearToolServiceTests {
    @Test func unconfiguredServiceReturnsSetupError() async {
        let service = LinearToolService(apiKey: { nil })
        let result = await service.execute(.teams)
        #expect(result.response["status"] == .string("error"))
        let message = result.response["message"]?.stringValue ?? ""
        #expect(message.contains("Electragne Settings"))
    }

    @Test func onlyCreatingConfirms() {
        let service = LinearToolService(apiKey: { nil })
        #expect(service.confirmationDetails(for: .teams) == nil)
        #expect(service.confirmationDetails(for: .search(query: "x", limit: 5)) == nil)
        #expect(service.confirmationDetails(for: .issue(id: "ENG-1")) == nil)

        let confirmation = service.confirmationDetails(for: .create(
            teamID: "t1", teamName: "Engineering", title: "Fix login", description: "Steps…"
        ))
        #expect(confirmation?.title == "Create this Linear issue?")
        #expect(confirmation?.primaryText == "Fix login\n\nSteps…")
        #expect(confirmation?.actionLabel == "Create")
        #expect(confirmation?.details.map(\.value) == ["Engineering (t1)"])

        // Without a model-supplied name the card falls back to the bare ID.
        let bare = service.confirmationDetails(for: .create(
            teamID: "t1", teamName: nil, title: "Fix login", description: nil
        ))
        #expect(bare?.primaryText == "Fix login")
        #expect(bare?.details.map(\.value) == ["t1"])
    }

    @Test func issueLineRendersIdentifierStateAndAssignee() {
        let issue = LinearIssue(
            identifier: "ENG-42", title: "Fix login", url: "https://linear.app/x/issue/ENG-42",
            state: .init(name: "In Progress"), assignee: .init(displayName: "alice"),
            updatedAt: "2026-07-14T09:30:00.000Z"
        )
        #expect(LinearToolService.issueLine(issue)
            == "ENG-42 [In Progress] Fix login — alice (updated 2026-07-14) https://linear.app/x/issue/ENG-42")

        // Sparse issues degrade to just the identifier and title.
        #expect(LinearToolService.issueLine(LinearIssue(identifier: "ENG-1", title: "x")) == "ENG-1 x")
    }

    @Test func issuesResultListsOneLinePerIssueAndNotesEmpty() {
        let empty = LinearToolService.issuesResult([], emptyNote: "None.")
        #expect(empty.response["message"] == .string("None."))

        let result = LinearToolService.issuesResult([
            LinearIssue(identifier: "ENG-1", title: "a"),
            LinearIssue(identifier: "ENG-2", title: "b"),
        ], emptyNote: "None.")
        #expect(result.response["issueCount"] == .number(2))
        #expect(result.response["issues"] == .string("ENG-1 a\nENG-2 b"))
    }

    @Test func projectLineRendersNameStateLeadAndDates() {
        let project = LinearProject(
            id: "p1", name: "Mobile App", url: "https://linear.app/x/project/mobile",
            state: "started", lead: .init(displayName: "alice"),
            targetDate: "2026-09-01", updatedAt: "2026-07-14T09:30:00.000Z"
        )
        #expect(LinearToolService.projectLine(project)
            == "Mobile App [started] — alice (target 2026-09-01, updated 2026-07-14) https://linear.app/x/project/mobile")

        // Sparse projects degrade to the name, or the ID when unnamed.
        #expect(LinearToolService.projectLine(LinearProject(id: "p2", name: "Bare")) == "Bare")
        #expect(LinearToolService.projectLine(LinearProject(id: "p3")) == "p3")
    }

    @Test func projectsResultListsOneLinePerProjectAndNotesEmpty() {
        let empty = LinearToolService.projectsResult([], emptyNote: "None.")
        #expect(empty.response["message"] == .string("None."))

        let result = LinearToolService.projectsResult([
            LinearProject(id: "p1", name: "a"),
            LinearProject(id: "p2", name: "b"),
        ], emptyNote: "None.")
        #expect(result.response["projectCount"] == .number(2))
        #expect(result.response["projects"] == .string("a\nb"))
    }

    @Test func issueDetailIncludesDescriptionAndComments() {
        let issue = LinearIssue(
            identifier: "ENG-42", title: "Fix login",
            description: "Users are logged out.",
            priorityLabel: "High",
            state: .init(name: "Todo"),
            team: .init(key: "ENG", name: "Engineering"),
            createdAt: "2026-07-01T00:00:00.000Z",
            comments: .init(nodes: [
                .init(body: "on it", user: .init(displayName: "alice"), createdAt: "2026-07-02T00:00:00.000Z")
            ])
        )
        let text = LinearToolService.issueDetailResult(issue).response["issue"]?.stringValue ?? ""
        #expect(text.contains("ENG-42 [Todo] Fix login"))
        #expect(text.contains("Team: Engineering"))
        #expect(text.contains("Priority: High"))
        #expect(text.contains("Created: 2026-07-01"))
        #expect(text.contains("Users are logged out."))
        #expect(text.contains("[2026-07-02] alice: on it"))
    }

    @Test func teamsResultListsEntries() {
        let result = LinearToolService.teamsResult([
            LinearTeam(id: "t1", key: "ENG", name: "Engineering")
        ])
        #expect(result.response["teams"]?.arrayValue?.first == .object([
            "teamID": .string("t1"), "key": .string("ENG"), "name": .string("Engineering"),
        ]))

        let none = LinearToolService.teamsResult([])
        #expect(none.response["message"] == .string("No Linear teams are visible to this API key."))
    }
}
