//
//  electragneApp.swift
//  electragne
//
//  Created by zacharyhamm on 2/3/26.
//

import Carbon.HIToolbox
import SwiftUI
import UserNotifications

@main
struct ElectragneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        // Window (not WindowGroup) so File > New Window can't spawn a second
        // pet view fighting over the same NSWindow
        Window("Electragne", id: "pet") {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
struct SettingsView: View {
    @AppStorage(UserPreferences.preferredNameKey) private var preferredName = ""
    @AppStorage(GoogleOAuthService.clientIDKey) private var googleClientID = ""
    @State private var geminiAPIKey = ""
    @State private var ollamaAPIKey = ""
    @State private var apiKeyMessage: String?
    @State private var apiKeySaveFailed = false
    @State private var googleClientSecret = ""
    @State private var fileSearchScopes: [FileSearchScope] = []
    @State private var fileSearchError: String?
    @State private var googleAccounts: [GoogleAccount] = []
    @State private var defaultGoogleAccountID: String?
    @State private var googleError: String?
    @State private var googleBusy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Personalization")
                        .font(.headline)
                    Text("Your name")
                        .font(.subheadline.weight(.medium))
                    TextField("Use my macOS account name", text: $preferredName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                    Text("The pet uses this name when chatting. Leave it blank to use your macOS account name.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("AI provider keys")
                            .font(.headline)
                        Spacer()
                        Button("Save Keys", action: saveAPIKeys)
                    }
                    Text("Keys entered here are stored in macOS Keychain and used immediately.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Gemini API key")
                        .font(.subheadline.weight(.medium))
                    SecureField("Paste your Gemini API key", text: $geminiAPIKey)
                        .textFieldStyle(.roundedBorder)

                    Text("Ollama API key")
                        .font(.subheadline.weight(.medium))
                        .padding(.top, 3)
                    SecureField("Paste your ollama.com API key", text: $ollamaAPIKey)
                        .textFieldStyle(.roundedBorder)
                    Text("The Ollama key is used only for hosted web search; local Ollama chat remains keyless.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let apiKeyMessage {
                        Text(apiKeyMessage)
                            .font(.caption)
                            .foregroundStyle(apiKeySaveFailed ? .red : .secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("File search")
                            .font(.headline)
                        Spacer()
                        Button("Add Folder…", action: addFileSearchFolder)
                    }
                    Text("Gemini can search file names only inside folders you add here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if fileSearchScopes.isEmpty {
                        Text("No folders added")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(fileSearchScopes) { scope in
                            HStack(spacing: 8) {
                                Image(systemName: "folder")
                                    .foregroundStyle(.secondary)
                                Text(scope.url.path)
                                    .font(.callout)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button {
                                    FileSearchScopeStore.shared.removeScope(id: scope.id)
                                    refreshFileSearchScopes()
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove \(scope.url.lastPathComponent)")
                            }
                        }
                    }

                    if let fileSearchError {
                        Text(fileSearchError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("Google accounts")
                            .font(.headline)
                        Spacer()
                        if googleBusy {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Button("Connect Account…", action: connectGoogleAccount)
                            .disabled(googleBusy || googleClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Text("Connect Gmail and Google Calendar with one Google account authorization.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !googleAccounts.isEmpty {
                        Text("Already connected? Reconnect once to approve the new Calendar permissions.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Client ID")
                            .font(.subheadline.weight(.medium))
                        TextField("…apps.googleusercontent.com", text: $googleClientID)
                            .textFieldStyle(.roundedBorder)

                        Text("Client secret")
                            .font(.subheadline.weight(.medium))
                            .padding(.top, 3)
                        SecureField("Paste the desktop client secret", text: $googleClientSecret)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack(alignment: .firstTextBaseline) {
                        Text("Use credentials from a Desktop OAuth client. The secret is saved in Keychain.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 12)
                        Link("Open Google Cloud Console", destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
                            .font(.caption)
                    }

                    if googleAccounts.isEmpty {
                        Text("No Google accounts connected")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    } else {
                        ForEach(googleAccounts) { account in
                            HStack(spacing: 9) {
                                Button {
                                    GoogleOAuthService.shared.setDefaultAccount(id: account.id)
                                    refreshGoogleAccounts()
                                } label: {
                                    Image(systemName: account.id == defaultGoogleAccountID ? "largecircle.fill.circle" : "circle")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Use \(account.email) by default")

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(account.email)
                                        .lineLimit(1)
                                    if let name = account.displayName, !name.isEmpty {
                                        Text(name)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Menu {
                                    Button("Reconnect…", action: connectGoogleAccount)
                                    Button("Disconnect", role: .destructive) {
                                        disconnectGoogleAccount(account)
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .disabled(googleBusy)
                                .accessibilityLabel("Actions for \(account.email)")
                            }
                        }
                    }

                    if let googleError {
                        Text(googleError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // This view is hosted in a manually managed NSWindow. Keep its viewport
        // stable so account updates cannot trigger an AppKit layout recursion.
        .frame(width: 560, height: 520)
        .onAppear {
            geminiAPIKey = ChatAPIKeyStore.key(for: .gemini) ?? ""
            ollamaAPIKey = ChatAPIKeyStore.key(for: .ollama) ?? ""
            refreshFileSearchScopes()
            refreshGoogleAccounts()
            googleClientSecret = GoogleOAuthService.shared.clientSecret
        }
    }

    private func saveAPIKeys() {
        do {
            try ChatAPIKeyStore.setKey(geminiAPIKey, for: .gemini)
            try ChatAPIKeyStore.setKey(ollamaAPIKey, for: .ollama)
            geminiAPIKey = ChatAPIKeyStore.key(for: .gemini) ?? ""
            ollamaAPIKey = ChatAPIKeyStore.key(for: .ollama) ?? ""
            apiKeySaveFailed = false
            apiKeyMessage = "Saved in macOS Keychain. Clear a field and save to remove its key."
        } catch {
            apiKeySaveFailed = true
            apiKeyMessage = error.localizedDescription
        }
    }

    private func addFileSearchFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Folder Electragne Can Search"
        panel.prompt = "Allow Search"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FileSearchScopeStore.shared.addFolder(url)
            fileSearchError = nil
            refreshFileSearchScopes()
        } catch {
            fileSearchError = "Could not remember that folder: \(error.localizedDescription)"
        }
    }

    private func refreshFileSearchScopes() {
        fileSearchScopes = FileSearchScopeStore.shared.scopes()
    }

    private func refreshGoogleAccounts() {
        googleAccounts = GoogleOAuthService.shared.accounts
        defaultGoogleAccountID = GoogleOAuthService.shared.defaultAccountID
    }

    private func connectGoogleAccount() {
        guard let window = NSApp.keyWindow else {
            googleError = "The Settings window is not available for Google sign-in."
            return
        }
        GoogleOAuthService.shared.clientID = googleClientID
        GoogleOAuthService.shared.clientSecret = googleClientSecret
        googleBusy = true
        googleError = nil
        Task {
            defer { googleBusy = false }
            do {
                _ = try await GoogleOAuthService.shared.connect(presenting: window)
                refreshGoogleAccounts()
            } catch {
                googleError = error.localizedDescription
            }
        }
    }

    private func disconnectGoogleAccount(_ account: GoogleAccount) {
        googleBusy = true
        googleError = nil
        Task {
            defer { googleBusy = false }
            do {
                try await GoogleOAuthService.shared.disconnect(accountID: account.id)
                refreshGoogleAccounts()
            } catch {
                googleError = error.localizedDescription
            }
        }
    }
}

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
