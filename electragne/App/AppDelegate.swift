//
//  AppDelegate.swift
//  electragne
//
//  Menu bar item, global hotkey, pet window configuration, size adjustment,
//  and the Settings window.
//

import Carbon.HIToolbox
import os
import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem?
    /// Set by ElectragneApp when the pet window appears.
    var appModel: AppModel?
    /// The pet window, as reported by ContentView's WindowAccessor — the
    /// single mechanism that identifies it.
    private var petWindow: NSWindow? { appModel?.petViewModel.petWindow }
    private var toggleVisibilityMenuItem: NSMenuItem?
    private var chatProviderMenuItems: [ChatProvider: NSMenuItem] = [:]
    private var isPetVisible = true
    private var summonHotkey: GlobalHotkey?
    private var settingsWindow: NSWindow?
    private var memoryBrowserWindow: NSWindow?
    private var automationBrowserWindow: NSWindow?
    private var collectionBehaviorObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosted unit tests: skip launch work. warm() would hit the real
        // keychain (unsigned test build → password prompt every run), and
        // connectAll() would spawn real MCP servers.
        if NSClassFromString("XCTestCase") != nil { return }

        UNUserNotificationCenter.current().delegate = self

        // Connect configured MCP servers so their tools are available to chat.
        // Warm the key store first: its initial keychain read can block on the
        // authorization prompt and must not happen on the main actor.
        Task {
            await ChatAPIKeyStore.warm()
            await MCPServerManager.shared.connectAll()
        }

        // Create menu bar item
        setupMenuBar()

        // Cmd-Shift-E anywhere summons the pet for a chat
        summonHotkey = GlobalHotkey(
            keyCode: kVK_ANSI_E,
            modifiers: cmdKey | shiftKey
        ) { [weak self] in
            self?.summonPetToChat()
        }

        // Delay window configuration to ensure SwiftUI has finished its initial layout pass
        // Using asyncAfter to give SwiftUI time to complete layout
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.configureWindowWhenAvailable()
        }
    }

    /// The pet window is reported by ContentView's WindowAccessor during the
    /// first layout pass; retry briefly in case that hasn't happened yet.
    private func configureWindowWhenAvailable(attempts: Int = 20) {
        if petWindow != nil {
            configureWindow()
        } else if attempts > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.configureWindowWhenAvailable(attempts: attempts - 1)
            }
        }
    }

    /// Hiding the pet orders its window out, leaving the app with no visible
    /// windows (status-bar items don't count). SwiftUI's app lifecycle would
    /// then quit the app; this is a menu-bar app, so it must stay alive.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    private func configureWindow() {
        guard let window = petWindow else { return }

        // Remove ALL window decorations
        window.styleMask = [.borderless]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        PetWindowPresentation.enforce(on: window)
        window.isMovableByWindowBackground = false
        window.hasShadow = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        // Make sure no standard window buttons are shown
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        // SwiftUI's Window scene rewrites collectionBehavior after launch.
        // Observe that property directly and restore the overlay policy.
        if collectionBehaviorObservation == nil {
            collectionBehaviorObservation = PetWindowPresentation.observe(window)
        }

        // Note: Window size is managed by SwiftUI via .windowResizability(.contentSize)
        // and the @AppStorage("petSize") binding in ContentView.
        // Window position is set by PetViewModel.positionWindowForFall()
    }

    func setupMenuBar() {
        // Create status item in menu bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            button.image = NSImage(named: "MenuBarIcon")
            button.image?.isTemplate = true
        }

        // Create menu
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "About Electragne", action: #selector(aboutApp), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        let toggleItem = NSMenuItem(title: "Hide Pet", action: #selector(toggleVisibility), keyEquivalent: "h")
        toggleVisibilityMenuItem = toggleItem
        menu.addItem(toggleItem)

        let chatItem = NSMenuItem(
            title: "Chat with Pet",
            action: #selector(summonPetToChatFromMenu),
            keyEquivalent: "E"
        )
        chatItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(chatItem)

        let providerItem = NSMenuItem(title: "Chat Provider", action: nil, keyEquivalent: "")
        let providerMenu = NSMenu(title: "Chat Provider")
        for provider in ChatProvider.allCases {
            let item = NSMenuItem(
                title: provider.displayName,
                action: #selector(selectChatProvider(_:)),
                keyEquivalent: ""
            )
            item.representedObject = provider.rawValue
            item.state = ChatProviderPreference.selected == provider ? .on : .off
            chatProviderMenuItems[provider] = item
            providerMenu.addItem(item)
        }
        providerItem.submenu = providerMenu
        menu.addItem(providerItem)

        menu.addItem(NSMenuItem(
            title: "Browse Memories…",
            action: #selector(openMemoryBrowser),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Manage Automations…",
            action: #selector(openAutomationBrowser),
            keyEquivalent: ""
        ))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Increase Size", action: #selector(increaseSize), keyEquivalent: "+"))
        menu.addItem(NSMenuItem(title: "Decrease Size", action: #selector(decreaseSize), keyEquivalent: "-"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    @objc func summonPetToChatFromMenu() {
        summonPetToChat()
    }

    @objc func selectChatProvider(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let provider = ChatProvider(rawValue: raw) else { return }
        ChatProviderPreference.set(provider)
        for (candidate, item) in chatProviderMenuItems {
            item.state = candidate == provider ? .on : .off
        }
    }

    private func summonPetToChat() {
        if !isPetVisible {
            toggleVisibility()
        }
        // The chat text field can only take keystrokes if the app is active.
        NSApp.activate(ignoringOtherApps: true)
        appModel?.petViewModel.summonToChat()
    }

    func presentCalendarReminder(_ event: CalendarEventDetails) async -> Bool {
        summonPetToChat()
        return await appModel?.deliverCalendarReminder(event) ?? false
    }

    func presentAutomationNotice(name: String, payload: String) {
        summonPetToChat()
        Task { [weak self] in
            await self?.appModel?.startProactiveConversation(ChatBubbleWindowController.ProactivePrompt(
                title: name,
                prompt: """
                My background automation ‘\(name)’ flagged something. Its finding:
                \(payload)
                Relay this to me concisely and note anything I should do. Do not call any tools.
                """
            ))
        }
    }

    @objc func toggleVisibility() {
        guard let window = petWindow else { return }

        isPetVisible.toggle()

        if isPetVisible {
            window.orderFront(nil)
            toggleVisibilityMenuItem?.title = "Hide Pet"
            appModel?.petViewModel.resume()
        } else {
            window.orderOut(nil)
            toggleVisibilityMenuItem?.title = "Show Pet"
            appModel?.petViewModel.pause()
        }
    }

    @objc func aboutApp() {
        let alert = NSAlert()
        alert.messageText = "Electric Sheep"
        alert.informativeText = ""
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")

        // Set custom icon
        if let iconImage = NSImage(named: "esheep") {
            alert.icon = iconImage
        }

        // Create accessory view with clickable link
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 50))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false

        let fullText = "An electric sheep for macOS based on desktopPet. It's a little guy. He's your friend."
        let attributedString = NSMutableAttributedString(string: fullText)

        // Style the entire text
        let fullRange = NSRange(location: 0, length: fullText.count)
        attributedString.addAttribute(.font, value: NSFont.systemFont(ofSize: 11), range: fullRange)
        attributedString.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)

        // Make "desktopPet" a clickable link
        if let linkRange = fullText.range(of: "desktopPet"),
           let linkURL = URL(string: "https://adrianotiger.github.io/desktopPet/") {
            let nsRange = NSRange(linkRange, in: fullText)
            attributedString.addAttribute(.link, value: linkURL, range: nsRange)
        }

        textView.textStorage?.setAttributedString(attributedString)
        textView.alignment = .center

        alert.accessoryView = textView

        alert.runModal()
    }

    /// A lazily created auxiliary window (Settings, Memories) that survives
    /// close and is re-shown on demand.
    private func makeAuxiliaryWindow(
        title: String,
        size: NSSize,
        minSize: NSSize,
        styleMask: NSWindow.StyleMask,
        contentView: NSView
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = title
        // With sizingOptions = [] the hosting view never constrains the window,
        // so the window must enforce the SwiftUI content's minimum itself or
        // the content overflows the frame when the user shrinks it.
        window.contentMinSize = minSize
        window.isReleasedWhenClosed = false
        window.contentView = contentView
        window.center()
        return window
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let hostingView = NSHostingView(rootView: SettingsView())
            hostingView.sizingOptions = []
            settingsWindow = makeAuxiliaryWindow(
                title: "Electragne Settings",
                size: NSSize(width: 560, height: 520),
                minSize: NSSize(width: 560, height: 520),
                styleMask: [.titled, .closable],
                contentView: hostingView
            )
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func openMemoryBrowser() {
        guard let memoryEngine = appModel?.memoryEngine else { return }
        if memoryBrowserWindow == nil {
            // sizingOptions = []: the hosting view must never feed intrinsic
            // size back into the window, or window ↔ layout feedback can spin
            // the main thread at 100%.
            let hostingView = NSHostingView(rootView: MemoryBrowserView(engine: memoryEngine))
            hostingView.sizingOptions = []
            memoryBrowserWindow = makeAuxiliaryWindow(
                title: "Electragne Memories",
                size: NSSize(width: 760, height: 520),
                minSize: NSSize(width: 620, height: 400),
                styleMask: [.titled, .closable, .resizable],
                contentView: hostingView
            )
        }
        NSApp.activate(ignoringOtherApps: true)
        memoryBrowserWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func openAutomationBrowser() {
        guard let automationEngine = appModel?.automationEngine else { return }
        if automationBrowserWindow == nil {
            let hostingView = NSHostingView(rootView: AutomationBrowserView(engine: automationEngine))
            hostingView.sizingOptions = []
            automationBrowserWindow = makeAuxiliaryWindow(
                title: "Electragne Automations",
                size: NSSize(width: 900, height: 640),
                minSize: NSSize(width: 800, height: 500),
                styleMask: [.titled, .closable, .resizable],
                contentView: hostingView
            )
        }
        NSApp.activate(ignoringOtherApps: true)
        automationBrowserWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc func increaseSize() {
        adjustPetSize(by: PetSizeConstants.sizeStep)
    }

    @objc func decreaseSize() {
        adjustPetSize(by: -PetSizeConstants.sizeStep)
    }

    private func adjustPetSize(by delta: Double) {
        let newSize = PetSizeAdjustment.newSize(
            current: UserDefaults.standard.double(forKey: PetSizeConstants.storageKey),
            delta: delta
        )

        guard let window = petWindow else {
            UserDefaults.standard.set(newSize, forKey: PetSizeConstants.storageKey)
            return
        }

        let newOrigin = PetSizeAdjustment.groundedOrigin(
            frame: window.frame,
            newSize: newSize,
            floorY: window.screen?.frame.minY ?? 0
        )

        // Update UserDefaults - this triggers SwiftUI to re-render with new size
        // SwiftUI's .windowResizability(.contentSize) will handle the window resize
        UserDefaults.standard.set(newSize, forKey: PetSizeConstants.storageKey)

        // Adjust window position to keep pet grounded (after a brief delay to let SwiftUI resize)
        DispatchQueue.main.async {
            window.setFrameOrigin(newOrigin)
        }
    }
}
