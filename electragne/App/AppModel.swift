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

    func startCalendarMonitoring(onReminder: @escaping (CalendarEventDetails) async -> Bool) {
        calendarReminderMonitor.onReminder = onReminder
        calendarReminderMonitor.start()
    }

    func startAutomations(onNotify: @escaping (String, String) -> Void) {
        automationEngine.onNotify = onNotify
        automationEngine.start()
    }

    /// Delivers a calendar reminder to every configured surface: the LED sign
    /// (independent of chat state) and the proactive chat bubble. True when at
    /// least one surface got it, so the monitor only marks delivered
    /// occurrences as fired.
    func deliverCalendarReminder(_ event: CalendarEventDetails) async -> Bool {
        async let sign = sendCalendarReminderToLEDSign(event)
        let bubbled = await startProactiveConversation(ChatBubbleWindowController.ProactivePrompt(
            title: event.summary,
            prompt: event.reminderPrompt,
            joinURL: event.joinURL
        ))
        return await sign || bubbled
    }

    private func sendCalendarReminderToLEDSign(_ event: CalendarEventDetails) async -> Bool {
        guard UserPreferences.ledSignEndpoint() != nil else { return false }
        do {
            try await LEDSignClient.send(try LEDSignMessage(
                text: "\(event.summary) in 3 min",
                duration: 30,
                icon: "clock",
                priority: true
            ))
            return true
        } catch {
            Log.calendar.error("LED sign reminder failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Starts a machine-initiated conversation once the chat surface is ready.
    /// summonToChat's state transition (or the pet window itself, during
    /// launch) may lag; retry rather than silently dropping the prompt.
    /// Returns whether the bubble was actually presented.
    @discardableResult
    func startProactiveConversation(
        _ prompt: ChatBubbleWindowController.ProactivePrompt,
        attempts: Int = 10
    ) async -> Bool {
        for attempt in 1...attempts {
            if let window = petViewModel.petWindow, petViewModel.state.isChatting {
                chatBubbleController.present(
                    anchoredTo: window,
                    onDismiss: { [petViewModel] in petViewModel.dismissChat() }
                )
                chatBubbleController.startProactiveConversation(prompt)
                return true
            }
            if attempt < attempts {
                try? await Task.sleep(for: .seconds(0.5))
            }
        }
        Log.calendar.error("Dropping proactive conversation ‘\(prompt.title, privacy: .public)’: chat never became available")
        return false
    }
}
