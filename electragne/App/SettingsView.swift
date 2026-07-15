//
//  SettingsView.swift
//  electragne
//
//  The Settings window content: personalization, AI provider keys, file
//  search scopes, and Google account management.
//

import SwiftUI

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
