//
//  ToolExecuting.swift
//  electragne
//
//  The single execution contract every tool family exposes to the router:
//  prepare validates the call and returns an optional confirmation plus a
//  ready-to-run action. Local families prepare synchronously; Google
//  families fetch whatever the confirmation card needs first.
//

import Foundation

@MainActor
struct PreparedToolAction {
    /// Shown to the owner before execute() runs; nil executes immediately.
    let confirmation: ToolConfirmationDetails?
    let execute: @MainActor () async -> ChatToolResult
}

@MainActor
protocol ToolExecuting: AnyObject {
    /// Validates the call, throwing a LocalizedError for bad arguments.
    func prepare(_ call: ChatToolCall) async throws -> PreparedToolAction
}

// MARK: - Local tool adapters

@MainActor
final class ReminderToolAdapter: ToolExecuting {
    private let executor: any ReminderToolExecuting
    init(_ executor: any ReminderToolExecuting) { self.executor = executor }

    func prepare(_ call: ChatToolCall) async throws -> PreparedToolAction {
        let request = try ReminderToolRequest(toolCall: call)
        let executor = executor
        return PreparedToolAction(
            confirmation: executor.confirmationDetails(for: request),
            execute: { await executor.execute(request) }
        )
    }
}

@MainActor
final class NotesToolAdapter: ToolExecuting {
    private let executor: any NotesToolExecuting
    init(_ executor: any NotesToolExecuting) { self.executor = executor }

    func prepare(_ call: ChatToolCall) async throws -> PreparedToolAction {
        let request = try NoteToolRequest(toolCall: call)
        let executor = executor
        return PreparedToolAction(
            confirmation: executor.confirmationDetails(for: request),
            execute: { await executor.execute(request) }
        )
    }
}

@MainActor
final class DesktopToolAdapter: ToolExecuting {
    private let executor: any DesktopToolExecuting
    init(_ executor: any DesktopToolExecuting) { self.executor = executor }

    func prepare(_ call: ChatToolCall) async throws -> PreparedToolAction {
        let request = try DesktopToolRequest(toolCall: call)
        let executor = executor
        return PreparedToolAction(
            confirmation: executor.confirmationDetails(for: request),
            execute: { await executor.execute(request) }
        )
    }
}

@MainActor
final class TimerToolAdapter: ToolExecuting {
    private let executor: any TimerToolExecuting
    init(_ executor: any TimerToolExecuting) { self.executor = executor }

    func prepare(_ call: ChatToolCall) async throws -> PreparedToolAction {
        let request = try TimerToolRequest(toolCall: call)
        let executor = executor
        return PreparedToolAction(
            confirmation: executor.confirmationDetails(for: request),
            execute: { await executor.execute(request) }
        )
    }
}

// MARK: - Google tool adapters (async prepare: confirmation may need a fetch)

@MainActor
final class GmailToolAdapter: ToolExecuting {
    private let executor: any GmailToolExecuting
    init(_ executor: any GmailToolExecuting) { self.executor = executor }

    func prepare(_ call: ChatToolCall) async throws -> PreparedToolAction {
        let prepared = try await executor.prepare(GmailToolRequest(toolCall: call))
        let executor = executor
        return PreparedToolAction(
            confirmation: prepared.confirmation,
            execute: { await executor.execute(prepared) }
        )
    }
}

@MainActor
final class CalendarToolAdapter: ToolExecuting {
    private let executor: any CalendarToolExecuting
    init(_ executor: any CalendarToolExecuting) { self.executor = executor }

    func prepare(_ call: ChatToolCall) async throws -> PreparedToolAction {
        let prepared = try await executor.prepare(CalendarToolRequest(toolCall: call))
        let executor = executor
        return PreparedToolAction(
            confirmation: prepared.confirmation,
            execute: { await executor.execute(prepared) }
        )
    }
}

// MARK: - Slack (dobbs)

/// Slack access through a dobbs daemon. Reads run unconfirmed; sending a
/// message is the one outbound write and always confirms.
@MainActor
final class SlackToolAdapter: ToolExecuting {
    private let executor: any SlackToolExecuting
    init(_ executor: any SlackToolExecuting) { self.executor = executor }

    func prepare(_ call: ChatToolCall) async throws -> PreparedToolAction {
        let request = try SlackToolRequest(toolCall: call)
        let executor = executor
        return PreparedToolAction(
            confirmation: executor.confirmationDetails(for: request),
            execute: { await executor.execute(request) }
        )
    }
}

// MARK: - Linear

/// Linear access through the linear.app GraphQL API. Reads run unconfirmed;
/// creating an issue is the one write and always confirms.
@MainActor
final class LinearToolAdapter: ToolExecuting {
    private let executor: any LinearToolExecuting
    init(_ executor: any LinearToolExecuting) { self.executor = executor }

    func prepare(_ call: ChatToolCall) async throws -> PreparedToolAction {
        let request = try LinearToolRequest(toolCall: call)
        let executor = executor
        return PreparedToolAction(
            confirmation: executor.confirmationDetails(for: request),
            execute: { await executor.execute(request) }
        )
    }
}

// MARK: - App status

/// Reports Electragne's own scheduling state: active countdown timers and
/// upcoming calendar reminder notifications. Read-only, no confirmation.
@MainActor
final class AppStatusExecutor: ToolExecuting {
    private let monitor: CalendarReminderMonitor?
    private let timerStore: TimerStore
    private let now: () -> Date

    init(
        monitor: CalendarReminderMonitor?,
        timerStore: TimerStore = TimerStore(),
        now: @escaping () -> Date = Date.init
    ) {
        self.monitor = monitor
        self.timerStore = timerStore
        self.now = now
    }

    func prepare(_ call: ChatToolCall) async throws -> PreparedToolAction {
        PreparedToolAction(confirmation: nil, execute: { [self] in
            let current = now()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]

            // Read-only view: unlike TimerToolService.activeTimers(), expired
            // records are filtered but never pruned from the store.
            let timers = timerStore.load()
                .filter { $0.fireDate > current }
                .sorted { $0.fireDate < $1.fireDate }
                .map { ChatToolValue.object(TimerToolService.timerValues($0, now: current)) }

            let upcoming = (monitor?.upcomingReminders ?? []).map { reminder -> ChatToolValue in
                .object([
                    "event": .string(reminder.summary),
                    "eventStart": .string(formatter.string(from: reminder.eventStart)),
                    "notifyAt": .string(formatter.string(from: reminder.notifyAt)),
                ])
            }
            let monitoring = monitor?.isMonitoring ?? false

            return ChatToolResult(response: [
                "status": .string("ok"),
                "timers": .array(timers),
                "calendarReminders": .object([
                    "monitoring": .bool(monitoring),
                    "leadTimeSeconds": .number(CalendarReminderMonitor.leadTime),
                    "pollIntervalSeconds": .number(CalendarReminderMonitor.pollInterval),
                    "upcoming": .array(upcoming),
                ]),
                "message": .string(monitoring
                    ? "\(timers.count) active timer(s); \(upcoming.count) calendar reminder(s) armed."
                    : "\(timers.count) active timer(s); calendar reminder monitoring is not running."),
            ])
        })
    }
}

// MARK: - Web search

/// Runs the hosted ollama.com web search through the shared tool router.
@MainActor
final class WebSearchExecutor: ToolExecuting {
    private let webSearch: OllamaWebSearch
    init(webSearch: OllamaWebSearch = OllamaWebSearch()) { self.webSearch = webSearch }

    func prepare(_ call: ChatToolCall) async throws -> PreparedToolAction {
        let query = call.arguments["query"]?.stringValue ?? ""
        let webSearch = webSearch
        return PreparedToolAction(confirmation: nil, execute: {
            do {
                let text = try await webSearch.resultsText(query: query)
                return ChatToolResult(response: [
                    "status": .string("ok"),
                    "results": .string(text),
                ])
            } catch ChatProviderError.missingAPIKey(.ollama) {
                return .error("Web search needs an ollama.com API key. Add it in Electragne Settings.")
            } catch {
                // Let the model explain the failure instead of aborting.
                return .error("Web search failed: \(error.localizedDescription)")
            }
        })
    }
}
