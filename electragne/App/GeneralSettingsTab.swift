//
//  GeneralSettingsTab.swift
//  electragne
//
//  Settings › General: personalization, AI provider keys and models,
//  memory provider, and file search scopes.
//

import SwiftUI

struct GeneralSettingsTab: View {
    @AppStorage(UserPreferences.preferredNameKey) private var preferredName = ""
    @AppStorage(UserPreferences.verboseToolCallsKey) private var verboseToolCalls = false
    @AppStorage(UserPreferences.chatOpacityKey)
    private var chatOpacity = UserPreferences.defaultChatOpacity

    @State private var geminiAPIKey = ""
    @AppStorage(UserPreferences.geminiModelKey) private var geminiModel = ChatConfig.default.geminiModel
    @State private var availableGeminiModels: [GeminiClient.GeminiModel] = []
    @State private var geminiModelError: String?
    @AppStorage(UserPreferences.geminiUseProxyKey) private var geminiUseProxy = false

    @AppStorage(UserPreferences.ollamaBaseURLKey) private var ollamaBaseURL = ""
    @AppStorage(UserPreferences.ollamaUseProxyKey) private var ollamaUseProxy = false

    @AppStorage(UserPreferences.searxngEndpointKey) private var searxngEndpoint = ""
    @AppStorage(UserPreferences.searxngUseProxyKey) private var searxngUseProxy = false

    @State private var openAICompatibleAPIKey = ""
    @AppStorage(UserPreferences.openAICompatibleBaseURLKey)
    private var openAICompatibleBaseURL = ChatConfig.default.openAICompatibleBaseURL
    @AppStorage(UserPreferences.openAICompatibleModelKey)
    private var openAICompatibleModel = ChatConfig.default.openAICompatibleModel
    @AppStorage(UserPreferences.deepSeekThinkingKey)
    private var deepSeekThinking = ChatConfig.default.deepSeekThinking
    @AppStorage(UserPreferences.openAICompatibleUseProxyKey) private var openAICompatibleUseProxy = false
    @State private var availableOpenAICompatibleModels: [OpenAICompatibleClient.Model] = []
    @State private var openAICompatibleModelError: String?
    @State private var apiKeyStatus = SaveStatus()

    @AppStorage(MemoryProviderPreference.providerKey) private var memoryProvider = ""
    @AppStorage(MemoryProviderPreference.modelKey) private var memoryModel = ""
    @State private var availableMemoryModels: [String] = []
    @State private var memoryModelError: String?

    @State private var fileSearchScopes: [FileSearchScope] = []
    @State private var fileSearchError: String?

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
                    Toggle("Route Gemini via Tailscale proxy", isOn: $geminiUseProxy)
                        .padding(.top, 3)

                    Text("Ollama base URL")
                        .font(.subheadline.weight(.medium))
                        .padding(.top, 3)
                    TextField("http://localhost:11434", text: $ollamaBaseURL)
                        .textFieldStyle(.roundedBorder)
                    Text("Point at a local or tailnet Ollama server. Leave blank for localhost.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Route Ollama via Tailscale proxy", isOn: $ollamaUseProxy)

                    Text("SearXNG endpoint")
                        .font(.subheadline.weight(.medium))
                        .padding(.top, 3)
                    TextField("http://localhost:8888", text: $searxngEndpoint)
                        .textFieldStyle(.roundedBorder)
                    Text("Local SearXNG instance used for the web_search tool. Leave blank to disable web search.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Route SearXNG via Tailscale proxy", isOn: $searxngUseProxy)

                    Text("OpenAI-compatible API key")
                        .font(.subheadline.weight(.medium))
                        .padding(.top, 3)
                    SecureField("Paste your DeepSeek or OpenAI-compatible API key", text: $openAICompatibleAPIKey)
                        .textFieldStyle(.roundedBorder)

                    Text("Base URL")
                        .font(.subheadline.weight(.medium))
                    TextField("https://api.deepseek.com", text: $openAICompatibleBaseURL)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Route via Tailscale proxy", isOn: $openAICompatibleUseProxy)

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

                    if let message = apiKeyStatus.message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(apiKeyStatus.failed ? .red : .secondary)
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
        .onAppear {
            geminiAPIKey = ChatAPIKeyStore.key(for: .gemini) ?? ""
            openAICompatibleAPIKey = ChatAPIKeyStore.key(for: .openAICompatible) ?? ""
            refreshFileSearchScopes()
            refreshGeminiModels()
            refreshOpenAICompatibleModels()
            refreshMemoryModels()
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
        loadModels(into: $availableMemoryModels, error: $memoryModelError) {
            try await provider.listModelIDs().sorted()
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
        loadModels(into: $availableGeminiModels, error: $geminiModelError) {
            try await GeminiClient.listModels(apiKey: key)
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
        loadModels(into: $availableOpenAICompatibleModels, error: $openAICompatibleModelError) {
            try await OpenAICompatibleClient.listModels(baseURL: baseURL, apiKey: key)
        }
    }

    private func saveAPIKeys() {
        let hint = "Clear a field and save to remove its key."
        apiKeyStatus = saveKeychainKey($geminiAPIKey, for: .gemini, removalHint: hint)
        if !apiKeyStatus.failed {
            apiKeyStatus = saveKeychainKey($openAICompatibleAPIKey, for: .openAICompatible, removalHint: hint)
        }
        if !apiKeyStatus.failed {
            refreshGeminiModels()
            refreshOpenAICompatibleModels()
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
}
