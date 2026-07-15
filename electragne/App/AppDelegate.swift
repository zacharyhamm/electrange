//
//  AppDelegate.swift
//  electragne
//
//  Menu bar item, global hotkey, pet window configuration, size adjustment,
//  and the Settings window.
//

import Carbon.HIToolbox
import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem?
    weak var petWindow: NSWindow?
    private var toggleVisibilityMenuItem: NSMenuItem?
    private var geminiToggleMenuItem: NSMenuItem?
    private var isPetVisible = true
    private var summonHotkey: GlobalHotkey?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self

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
            self.configureWindow()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    private func configureWindow() {
        // Find the pet window (the main content window, not the status-bar
        // item's window or other system windows)
        guard let window = NSApplication.shared.windows.first(where: { window in
            window.contentView != nil
                && !(window is NSPanel)
                && !window.className.contains("StatusBar")
        }) else { return }
        self.petWindow = window

        // Remove ALL window decorations
        window.styleMask = [.borderless]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.isMovableByWindowBackground = false
        window.hasShadow = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        // Make sure no standard window buttons are shown
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

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

        let geminiItem = NSMenuItem(
            title: "Use Gemini (Cloud)",
            action: #selector(toggleGeminiChat),
            keyEquivalent: ""
        )
        geminiItem.state = ChatProviderPreference.useGemini ? .on : .off
        geminiToggleMenuItem = geminiItem
        menu.addItem(geminiItem)

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

    @objc func toggleGeminiChat() {
        let defaults = UserDefaults.standard
        let useGemini = !defaults.bool(forKey: ChatProviderPreference.useGeminiKey)
        defaults.set(useGemini, forKey: ChatProviderPreference.useGeminiKey)
        geminiToggleMenuItem?.state = useGemini ? .on : .off
    }

    private func summonPetToChat() {
        if !isPetVisible {
            toggleVisibility()
        }
        // The chat text field can only take keystrokes if the app is active.
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .petShouldSummonChat, object: nil)
    }

    @objc func toggleVisibility() {
        guard let window = petWindow else { return }

        isPetVisible.toggle()

        if isPetVisible {
            window.orderFront(nil)
            toggleVisibilityMenuItem?.title = "Hide Pet"
            NotificationCenter.default.post(name: .petShouldResume, object: nil)
        } else {
            window.orderOut(nil)
            toggleVisibilityMenuItem?.title = "Show Pet"
            NotificationCenter.default.post(name: .petShouldPause, object: nil)
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

    @objc func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Electragne Settings"
            window.isReleasedWhenClosed = false
            let hostingView = NSHostingView(rootView: SettingsView())
            hostingView.sizingOptions = []
            window.contentView = hostingView
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
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
        let currentSize = UserDefaults.standard.double(forKey: PetSizeConstants.storageKey)
        let size = currentSize > 0 ? currentSize : PetSizeConstants.defaultSize
        let newSize = max(PetSizeConstants.minimumSize, min(PetSizeConstants.maximumSize, size + delta))

        guard let window = petWindow else {
            UserDefaults.standard.set(newSize, forKey: PetSizeConstants.storageKey)
            return
        }

        let oldSize = window.frame.size
        let oldOrigin = window.frame.origin

        // Calculate new origin to keep pet grounded (the floor is the bottom
        // edge of whichever screen the pet is on, not necessarily y=0)
        let floorY = window.screen?.frame.minY ?? 0
        let newOrigin = NSPoint(
            x: oldOrigin.x,
            y: max(floorY, oldOrigin.y - (newSize - oldSize.height))
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
