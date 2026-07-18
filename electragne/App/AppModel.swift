//
//  AppModel.swift
//  electragne
//
//  Owns the app's long-lived model objects so AppDelegate (menu bar,
//  hotkey) and the SwiftUI window talk to the same PetViewModel directly
//  instead of signalling through NotificationCenter.
//

import Foundation

@MainActor
final class AppModel {
    let petViewModel = PetViewModel()
    let calendarReminderMonitor = CalendarReminderMonitor()
    let memoryEngine = MemoryEngine()
    let chatBubbleController: ChatBubbleWindowController

    init() {
        chatBubbleController = ChatBubbleWindowController(
            toolRouter: ChatToolRouter(
                calendarMonitor: calendarReminderMonitor,
                memoryEngine: memoryEngine
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
}
