//
//  AppStatusTool.swift
//  electragne
//
//  The report_app_status tool: reports Electragne's own scheduling state.
//

import Foundation

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

            // Read-only view: unlike TimerToolService.activeTimers(), expired
            // records are filtered but never pruned from the store.
            let timers = timerStore.load()
                .filter { $0.fireDate > current }
                .sorted { $0.fireDate < $1.fireDate }
                .map { ChatToolValue.object(TimerToolService.timerValues($0, now: current)) }

            let upcoming = (monitor?.upcomingReminders ?? []).map { reminder -> ChatToolValue in
                .object([
                    "event": .string(reminder.summary),
                    "eventStart": .string(TimerToolService.dateString(reminder.eventStart)),
                    "notifyAt": .string(TimerToolService.dateString(reminder.notifyAt)),
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
