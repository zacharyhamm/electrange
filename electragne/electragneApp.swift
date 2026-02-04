//
//  electragneApp.swift
//  electragne
//
//  Created by zacharyhamm on 2/3/26.
//

import SwiftUI

@main
struct electragneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    weak var petWindow: NSWindow?
    private var toggleVisibilityMenuItem: NSMenuItem?
    private var isPetVisible = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create menu bar item
        setupMenuBar()

        // Delay window configuration to ensure SwiftUI has finished its initial layout pass
        // Using asyncAfter to give SwiftUI time to complete layout
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.configureWindow()
        }
    }

    private func configureWindow() {
        // Find the pet window (the main content window, not alerts or other system windows)
        guard let window = NSApplication.shared.windows.first(where: { $0.contentView != nil }) else { return }
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

        toggleVisibilityMenuItem = NSMenuItem(title: "Hide Pet", action: #selector(toggleVisibility), keyEquivalent: "h")
        menu.addItem(toggleVisibilityMenuItem!)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Increase Size", action: #selector(increaseSize), keyEquivalent: "+"))
        menu.addItem(NSMenuItem(title: "Decrease Size", action: #selector(decreaseSize), keyEquivalent: "-"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem?.menu = menu
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

        let linkURL = URL(string: "https://adrianotiger.github.io/desktopPet/")!
        let fullText = "An electric sheep for macOS based on desktopPet. It's a little guy. He's your friend."
        let attributedString = NSMutableAttributedString(string: fullText)

        // Style the entire text
        let fullRange = NSRange(location: 0, length: fullText.count)
        attributedString.addAttribute(.font, value: NSFont.systemFont(ofSize: 11), range: fullRange)
        attributedString.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)

        // Make "desktopPet" a clickable link
        if let linkRange = fullText.range(of: "desktopPet") {
            let nsRange = NSRange(linkRange, in: fullText)
            attributedString.addAttribute(.link, value: linkURL, range: nsRange)
        }

        textView.textStorage?.setAttributedString(attributedString)
        textView.alignment = .center

        alert.accessoryView = textView

        alert.runModal()
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
        let currentSize = UserDefaults.standard.double(forKey: "petSize")
        let size = currentSize > 0 ? currentSize : PetSizeConstants.defaultSize
        let newSize = max(PetSizeConstants.minimumSize, min(PetSizeConstants.maximumSize, size + delta))

        guard let window = petWindow else {
            UserDefaults.standard.set(newSize, forKey: "petSize")
            return
        }

        let oldSize = window.frame.size
        let oldOrigin = window.frame.origin

        // Calculate new origin to keep pet grounded
        let newOrigin = NSPoint(
            x: oldOrigin.x,
            y: max(0, oldOrigin.y - (newSize - oldSize.height))
        )

        // Update UserDefaults - this triggers SwiftUI to re-render with new size
        // SwiftUI's .windowResizability(.contentSize) will handle the window resize
        UserDefaults.standard.set(newSize, forKey: "petSize")

        // Adjust window position to keep pet grounded (after a brief delay to let SwiftUI resize)
        DispatchQueue.main.async {
            window.setFrameOrigin(newOrigin)
        }
    }
}

