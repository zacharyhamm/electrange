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
    let automationEngine = AutomationEngine()
    let memoryEngine = MemoryEngine()
    let chatBubbleController: ChatBubbleWindowController

    init() {
        let toolRouter = ChatToolRouter(
            memoryEngine: memoryEngine,
            calendarMonitor: calendarReminderMonitor,
            automationEngine: automationEngine
        )
        automationEngine.toolRouter = toolRouter
        chatBubbleController = ChatBubbleWindowController(
            toolRouter: toolRouter,
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

    func startAutomations(onNotify: @escaping (String, String) -> Void) {
        automationEngine.onNotify = onNotify
        automationEngine.start()
    }

    /// Starts the reminder conversation once the chat surface is ready.
    func startCalendarReminderConversation(_ event: CalendarEventDetails, attempts: Int = 10) {
        startProactiveConversation(ChatBubbleWindowController.ProactivePrompt(
            title: event.summary,
            prompt: event.reminderPrompt,
            joinURL: event.joinURL
        ), attempts: attempts)
    }

    /// Starts a machine-initiated conversation once the chat surface is ready.
    /// summonToChat's state transition (or the pet window itself, during
    /// launch) may lag; retry rather than silently dropping the prompt.
    func startProactiveConversation(
        _ prompt: ChatBubbleWindowController.ProactivePrompt,
        attempts: Int = 10
    ) {
        guard let window = petViewModel.petWindow, petViewModel.state.isChatting else {
            if attempts > 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.startProactiveConversation(prompt, attempts: attempts - 1)
                }
            } else {
                Log.calendar.error("Dropping proactive conversation ‘\(prompt.title, privacy: .public)’: chat never became available")
            }
            return
        }
        chatBubbleController.present(
            anchoredTo: window,
            onDismiss: { [petViewModel] in petViewModel.dismissChat() }
        )
        chatBubbleController.startProactiveConversation(prompt)
    }
}
