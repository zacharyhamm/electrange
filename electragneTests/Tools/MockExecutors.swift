//
//  MockExecutors.swift
//  electragneTests
//
//  Shared executor fakes for router/registry tests. Each records what it
//  executed and returns a canned ok result; set `confirmation` to make a
//  family confirm first.
//

import Foundation
@testable import electragne

@MainActor
final class MockReminderExecutor: ReminderToolExecuting {
    var executed: [ReminderToolRequest] = []
    var confirmation: ToolConfirmationDetails?
    func confirmationDetails(for request: ReminderToolRequest) -> ToolConfirmationDetails? { confirmation }
    func execute(_ request: ReminderToolRequest) async -> ChatToolResult {
        executed.append(request)
        return ChatToolResult(response: ["status": .string("ok")])
    }
}

@MainActor
final class MockNotesExecutor: NotesToolExecuting {
    var executed: [NoteToolRequest] = []
    var confirmation: ToolConfirmationDetails?
    func confirmationDetails(for request: NoteToolRequest) -> ToolConfirmationDetails? { confirmation }
    func execute(_ request: NoteToolRequest) async -> ChatToolResult {
        executed.append(request)
        return ChatToolResult(response: ["status": .string("ok")])
    }
}

@MainActor
final class MockDesktopExecutor: DesktopToolExecuting {
    var executed: [DesktopToolRequest] = []
    var confirmation: ToolConfirmationDetails?
    func confirmationDetails(for request: DesktopToolRequest) -> ToolConfirmationDetails? { confirmation }
    func execute(_ request: DesktopToolRequest) async -> ChatToolResult {
        executed.append(request)
        return ChatToolResult(response: ["status": .string("ok")])
    }
}

@MainActor
final class MockTimerExecutor: TimerToolExecuting {
    var executed: [TimerToolRequest] = []
    var confirmation: ToolConfirmationDetails?
    func confirmationDetails(for request: TimerToolRequest) -> ToolConfirmationDetails? { confirmation }
    func execute(_ request: TimerToolRequest) async -> ChatToolResult {
        executed.append(request)
        return ChatToolResult(response: ["status": .string("ok")])
    }
}

@MainActor
final class MockWebSearchExecutor: ToolExecuting {
    var executed: [ChatToolCall] = []
    func prepare(_ call: ChatToolCall) async throws -> PreparedToolAction {
        PreparedToolAction(confirmation: nil, execute: { [weak self] in
            self?.executed.append(call)
            return ChatToolResult(response: ["status": .string("ok")])
        })
    }
}

@MainActor
final class MockGmailExecutor: GmailToolExecuting {
    var executed: [GmailPreparedRequest] = []
    var confirmation: ToolConfirmationDetails?
    func prepare(_ request: GmailToolRequest) async throws -> GmailPreparedRequest {
        GmailPreparedRequest(request: request, account: nil, confirmation: confirmation)
    }
    func execute(_ prepared: GmailPreparedRequest) async -> ChatToolResult {
        executed.append(prepared)
        return ChatToolResult(response: ["status": .string("ok")])
    }
}

@MainActor
final class MockCalendarExecutor: CalendarToolExecuting {
    var executed: [CalendarPreparedRequest] = []
    var confirmation: ToolConfirmationDetails?
    func prepare(_ request: CalendarToolRequest) async throws -> CalendarPreparedRequest {
        CalendarPreparedRequest(
            request: request,
            account: GoogleAccount(id: "a1", email: "one@example.com", displayName: nil),
            confirmation: confirmation
        )
    }
    func execute(_ prepared: CalendarPreparedRequest) async -> ChatToolResult {
        executed.append(prepared)
        return ChatToolResult(response: ["status": .string("ok")])
    }
}

@MainActor
final class MockMCPExecutor: ToolExecuting {
    var prepared: [String] = []
    func prepare(_ call: ChatToolCall) async throws -> PreparedToolAction {
        prepared.append(call.name)
        return PreparedToolAction(confirmation: nil) {
            .make(status: "ok", message: "mcp ran")
        }
    }
}
