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
    @AppStorage(UserPreferences.geminiModelKey) private var geminiModel = ChatConfig.default.geminiModel
    @State private var geminiAPIKey = ""
    @State private var availableGeminiModels: [GeminiClient.GeminiModel] = []
    @State private var geminiModelError: String?
    @State private var ollamaAPIKey = ""
    @State private var openAICompatibleAPIKey = ""
    @AppStorage(UserPreferences.openAICompatibleBaseURLKey)
    private var openAICompatibleBaseURL = ChatConfig.default.openAICompatibleBaseURL
    @AppStorage(UserPreferences.openAICompatibleModelKey)
    private var openAICompatibleModel = ChatConfig.default.openAICompatibleModel
    @AppStorage(UserPreferences.deepSeekThinkingKey)
    private var deepSeekThinking = ChatConfig.default.deepSeekThinking
    @AppStorage(UserPreferences.verboseToolCallsKey)
    private var verboseToolCalls = false
    @AppStorage(UserPreferences.chatOpacityKey)
    private var chatOpacity = UserPreferences.defaultChatOpacity
    @State private var availableOpenAICompatibleModels: [OpenAICompatibleClient.Model] = []
    @State private var openAICompatibleModelError: String?
    @State private var apiKeyMessage: String?
    @State private var apiKeySaveFailed = false
    @AppStorage(MemoryProviderPreference.providerKey) private var memoryProvider = ""
    @AppStorage(MemoryProviderPreference.modelKey) private var memoryModel = ""
    @State private var availableMemoryModels: [String] = []
    @State private var memoryModelError: String?
    @State private var googleClientSecret = ""
    @State private var fileSearchScopes: [FileSearchScope] = []
    @State private var fileSearchError: String?
    @AppStorage(UserPreferences.dobbsEndpointKey) private var dobbsEndpoint = ""
    @AppStorage(UserPreferences.dobbsWorkspaceKey) private var dobbsWorkspace = ""
    @State private var dobbsToken = ""
    @State private var dobbsMessage: String?
    @State private var dobbsSaveFailed = false
    @State private var linearAPIKey = ""
    @State private var linearMessage: String?
    @State private var linearSaveFailed = false
    @State private var googleAccounts: [GoogleAccount] = []
    @State private var defaultGoogleAccountID: String?
    @State private var googleError: String?
    @State private var googleBusy = false

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            integrationsTab
                .tabItem { Label("Integrations", systemImage: "link") }
            MCPSettingsTab()
                .tabItem { Label("MCP", systemImage: "wrench.and.screwdriver") }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // This view is hosted in a manually managed NSWindow. Keep its viewport
        // stable so account updates cannot trigger an AppKit layout recursion.
        .frame(width: 560, height: 520)
        .onAppear {
            geminiAPIKey = ChatAPIKeyStore.key(for: .gemini) ?? ""
            ollamaAPIKey = ChatAPIKeyStore.key(for: .ollama) ?? ""
            openAICompatibleAPIKey = ChatAPIKeyStore.key(for: .openAICompatible) ?? ""
            dobbsToken = ChatAPIKeyStore.key(for: .dobbs) ?? ""
            linearAPIKey = ChatAPIKeyStore.key(for: .linear) ?? ""
            refreshFileSearchScopes()
            refreshGoogleAccounts()
            googleClientSecret = GoogleOAuthService.shared.clientSecret
            refreshGeminiModels()
            refreshOpenAICompatibleModels()
            refreshMemoryModels()
        }
    }

    private var generalTab: some View {
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
                    Toggle("Show tool calls in chat", isOn: $verboseToolCalls)
                        .padding(.top, 3)
                    Text("Verbose mode: each tool call's name, arguments, and result appear inline in the transcript.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Chat window opacity")
                        .font(.subheadline.weight(.medium))
                        .padding(.top, 3)
                    Slider(value: $chatOpacity, in: UserPreferences.chatOpacityRange) {
                        Text("Chat window opacity")
                    } minimumValueLabel: {
                        Image(systemName: "circle.dotted")
                    } maximumValueLabel: {
                        Image(systemName: "circle.fill")
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320)
                    Text("How see-through the chat bubble's background is. Text stays fully visible.")
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

                    Text("Gemini model")
                        .font(.subheadline.weight(.medium))
                        .padding(.top, 3)
                    Picker("Gemini model", selection: $geminiModel) {
                        ForEach(geminiModelChoices, id: \.id) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320)
                    if let geminiModelError {
                        Text(geminiModelError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Text("Ollama API key")
                        .font(.subheadline.weight(.medium))
                        .padding(.top, 3)
                    SecureField("Paste your ollama.com API key", text: $ollamaAPIKey)
                        .textFieldStyle(.roundedBorder)
                    Text("The Ollama key is used only for hosted web search; local Ollama chat remains keyless.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("OpenAI-compatible API key")
                        .font(.subheadline.weight(.medium))
                        .padding(.top, 3)
                    SecureField("Paste your DeepSeek or OpenAI-compatible API key", text: $openAICompatibleAPIKey)
                        .textFieldStyle(.roundedBorder)

                    Text("Base URL")
                        .font(.subheadline.weight(.medium))
                    TextField("https://api.deepseek.com", text: $openAICompatibleBaseURL)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Text("Model")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Button("Reload Models", action: refreshOpenAICompatibleModels)
                    }
                    Picker("OpenAI-compatible model", selection: $openAICompatibleModel) {
                        ForEach(openAICompatibleModelChoices, id: \.id) { model in
                            Text(model.id).tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320)
                    if isOfficialDeepSeekEndpoint {
                        Toggle("DeepSeek thinking mode", isOn: $deepSeekThinking)
                    }
                    if let openAICompatibleModelError {
                        Text(openAICompatibleModelError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if let apiKeyMessage {
                        Text(apiKeyMessage)
                            .font(.caption)
                            .foregroundStyle(apiKeySaveFailed ? .red : .secondary)
                    }
                }

                if ChatProvider.configured().count > 1 {
                    Divider()
                    memorySection
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
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
    }

    private var integrationsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("Slack (dobbs)")
                            .font(.headline)
                        Spacer()
                        Button("Save Token", action: saveDobbsToken)
                    }
                    Text("Lets the pet search and summarize Slack through a running dobbs daemon. The token is stored in macOS Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Endpoint")
                        .font(.subheadline.weight(.medium))
                    TextField("host:port, e.g. 127.0.0.1:7355", text: $dobbsEndpoint)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)

                    Text("Workspace")
                        .font(.subheadline.weight(.medium))
                        .padding(.top, 3)
                    TextField("Optional expected workspace name", text: $dobbsWorkspace)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                    Text("When set, tool calls fail unless the daemon serves this workspace.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Token")
                        .font(.subheadline.weight(.medium))
                        .padding(.top, 3)
                    SecureField("Paste the dobbs daemon token", text: $dobbsToken)
                        .textFieldStyle(.roundedBorder)

                    if let dobbsMessage {
                        Text(dobbsMessage)
                            .font(.caption)
                            .foregroundStyle(dobbsSaveFailed ? .red : .secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("Linear")
                            .font(.headline)
                        Spacer()
                        Button("Save Key", action: saveLinearAPIKey)
                    }
                    Text("Lets the pet search, read, and create Linear issues. The API key is stored in macOS Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(alignment: .firstTextBaseline) {
                        Text("API key")
                            .font(.subheadline.weight(.medium))
                        Spacer(minLength: 12)
                        Link("Create one in Linear", destination: URL(string: "https://linear.app/settings/account/security")!)
                            .font(.caption)
                    }
                    SecureField("Paste your Linear personal API key", text: $linearAPIKey)
                        .textFieldStyle(.roundedBorder)

                    if let linearMessage {
                        Text(linearMessage)
                            .font(.caption)
                            .foregroundStyle(linearSaveFailed ? .red : .secondary)
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
    }

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Memory")
                .font(.headline)
            Text("Memories are extracted after each chat exchange. Pick a dedicated provider — for example a cheap local model — or leave it matching the chat.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Provider")
                .font(.subheadline.weight(.medium))
            Picker("Memory provider", selection: $memoryProvider) {
                Text("Same as chat").tag("")
                ForEach(ChatProvider.configured(), id: \.rawValue) { provider in
                    Text(provider.displayName).tag(provider.rawValue)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 320)
            .onChange(of: memoryProvider) { _, _ in
                // A model id from one provider is meaningless on another.
                memoryModel = ""
                availableMemoryModels = []
                refreshMemoryModels()
            }

            if !memoryProvider.isEmpty {
                HStack {
                    Text("Model")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Button("Reload Models", action: refreshMemoryModels)
                }
                Picker("Memory model", selection: $memoryModel) {
                    Text("Provider default").tag("")
                    ForEach(memoryModelChoices, id: \.self) { id in
                        Text(id).tag(id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 320)
                if let memoryModelError {
                    Text(memoryModelError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    /// Fetched models, with the stored selection always present so the picker
    /// never shows an empty selection before (or without) a successful fetch.
    private var memoryModelChoices: [String] {
        if memoryModel.isEmpty || availableMemoryModels.contains(memoryModel) {
            return availableMemoryModels
        }
        return [memoryModel] + availableMemoryModels
    }

    private func refreshMemoryModels() {
        guard let provider = ChatProvider(rawValue: memoryProvider) else { return }
        Task {
            do {
                availableMemoryModels = try await provider.listModelIDs().sorted()
                memoryModelError = nil
            } catch {
                memoryModelError = "Could not load the model list: \(error.localizedDescription)"
            }
        }
    }

    /// Fetched models, with the stored selection always present so the picker
    /// never shows an empty selection before (or without) a successful fetch.
    private var geminiModelChoices: [GeminiClient.GeminiModel] {
        if availableGeminiModels.contains(where: { $0.id == geminiModel }) {
            return availableGeminiModels
        }
        return [GeminiClient.GeminiModel(id: geminiModel, displayName: geminiModel)]
            + availableGeminiModels
    }

    private func refreshGeminiModels() {
        guard let key = ChatAPIKeyStore.load(for: .gemini) else { return }
        Task {
            do {
                availableGeminiModels = try await GeminiClient.listModels(apiKey: key)
                geminiModelError = nil
            } catch {
                geminiModelError = "Could not load the model list: \(error.localizedDescription)"
            }
        }
    }

    private var isOfficialDeepSeekEndpoint: Bool {
        URL(string: openAICompatibleBaseURL).map(OpenAICompatibleClient.isOfficialDeepSeek) == true
    }

    private var openAICompatibleModelChoices: [OpenAICompatibleClient.Model] {
        var ids = OpenAICompatibleClient.defaultModels
        ids.append(contentsOf: availableOpenAICompatibleModels.map(\.id))
        ids.append(openAICompatibleModel)
        return Array(Set(ids)).sorted().map(OpenAICompatibleClient.Model.init(id:))
    }

    private func refreshOpenAICompatibleModels() {
        guard let baseURL = URL(string: openAICompatibleBaseURL),
              let key = OpenAICompatibleClient.resolveAPIKey(
                baseURL: baseURL,
                keychainKey: ChatAPIKeyStore.key(for: .openAICompatible)
              ) else { return }
        Task {
            do {
                availableOpenAICompatibleModels = try await OpenAICompatibleClient.listModels(
                    baseURL: baseURL,
                    apiKey: key
                )
                openAICompatibleModelError = nil
            } catch {
                openAICompatibleModelError = "Could not load the model list: \(error.localizedDescription)"
            }
        }
    }

    private func saveAPIKeys() {
        do {
            try ChatAPIKeyStore.setKey(geminiAPIKey, for: .gemini)
            try ChatAPIKeyStore.setKey(ollamaAPIKey, for: .ollama)
            try ChatAPIKeyStore.setKey(openAICompatibleAPIKey, for: .openAICompatible)
            geminiAPIKey = ChatAPIKeyStore.key(for: .gemini) ?? ""
            ollamaAPIKey = ChatAPIKeyStore.key(for: .ollama) ?? ""
            openAICompatibleAPIKey = ChatAPIKeyStore.key(for: .openAICompatible) ?? ""
            apiKeySaveFailed = false
            apiKeyMessage = "Saved in macOS Keychain. Clear a field and save to remove its key."
            refreshGeminiModels()
            refreshOpenAICompatibleModels()
        } catch {
            apiKeySaveFailed = true
            apiKeyMessage = error.localizedDescription
        }
    }

    private func saveDobbsToken() {
        do {
            try ChatAPIKeyStore.setKey(dobbsToken, for: .dobbs)
            dobbsToken = ChatAPIKeyStore.key(for: .dobbs) ?? ""
            dobbsSaveFailed = false
            dobbsMessage = "Saved in macOS Keychain. Clear the field and save to remove the token."
        } catch {
            dobbsSaveFailed = true
            dobbsMessage = error.localizedDescription
        }
    }

    private func saveLinearAPIKey() {
        do {
            try ChatAPIKeyStore.setKey(linearAPIKey, for: .linear)
            linearAPIKey = ChatAPIKeyStore.key(for: .linear) ?? ""
            linearSaveFailed = false
            linearMessage = "Saved in macOS Keychain. Clear the field and save to remove the key."
        } catch {
            linearSaveFailed = true
            linearMessage = error.localizedDescription
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
