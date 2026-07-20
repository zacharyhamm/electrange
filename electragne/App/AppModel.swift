//
//  AppModel.swift
//  electragne
//
//  Owns the app's long-lived model objects so AppDelegate (menu bar,
//  hotkey) and the SwiftUI window talk to the same PetViewModel directly
//  instead of signalling through NotificationCenter.
//

import Foundation
import os

@MainActor
final class AppModel {
    let petViewModel = PetViewModel()
    let calendarReminderMonitor = CalendarReminderMonitor()
    let memoryEngine = MemoryEngine()
    let chatBubbleController: ChatBubbleWindowController

    init() {
        chatBubbleController = ChatBubbleWindowController(
            toolRouter: ChatToolRouter(
                memoryEngine: memoryEngine,
                calendarMonitor: calendarReminderMonitor
            ),
            memoryEngine: memoryEngine
        )
    }

    /// App bootstrap, called when the pet window content appears.
    func start() {
        petViewModel.loadAnimations()

        // Defer window positioning to after the layout pass completes
        // to avoid "layoutSubtreeIfNeeded called during layout" warning
        DispatchQueue.main.async {
            self.petViewModel.positionWindowForFall()
            self.petViewModel.startFalling()
        }
    }

    func startCalendarMonitoring(onReminder: @escaping (CalendarEventDetails) -> Void) {
        calendarReminderMonitor.onReminder = onReminder
        calendarReminderMonitor.start()
    }

    /// Starts the reminder conversation once the chat surface is ready.
    /// summonToChat's state transition (or the pet window itself, during
    /// launch) may lag; retry rather than silently dropping the reminder.
    func startCalendarReminderConversation(_ event: CalendarEventDetails, attempts: Int = 10) {
        guard let window = petViewModel.petWindow, petViewModel.state.isChatting else {
            if attempts > 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.startCalendarReminderConversation(event, attempts: attempts - 1)
                }
            } else {
                Log.calendar.error("Dropping calendar reminder for \(event.summary, privacy: .public): chat never became available")
            }
            return
        }
        chatBubbleController.present(
            anchoredTo: window,
            onDismiss: { [petViewModel] in petViewModel.dismissChat() }
        )
        chatBubbleController.startCalendarEventConversation(event)
    }
}
