//
//  UserPreferences.swift
//  electragne
//

import Foundation

/// User-adjustable settings from the Settings window.
enum UserPreferences {
    nonisolated static let preferredNameKey = "preferredUserName"

    /// The name typed in Settings, or nil when unset/blank.
    nonisolated static func preferredName(in defaults: UserDefaults = .standard) -> String? {
        guard let raw = defaults.string(forKey: preferredNameKey) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The name the pet should use: the Settings override when present,
    /// otherwise the macOS account's full name.
    nonisolated static func resolvedUserName() -> String? {
        preferredName() ?? detectedUserName()
    }

    /// The owner's name from macOS account info, for the system prompt.
    nonisolated static func detectedUserName() -> String? {
        let fullName = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        if !fullName.isEmpty { return fullName }
        let shortName = NSUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return shortName.isEmpty ? nil : shortName
    }

    // MARK: Slack (dobbs) — endpoint + workspace; the token lives in Keychain

    nonisolated static let dobbsEndpointKey = "dobbsEndpoint"
    nonisolated static let dobbsWorkspaceKey = "dobbsWorkspace"

    /// The dobbs daemon host:port from Settings, or nil when unset/blank.
    nonisolated static func dobbsEndpoint(in defaults: UserDefaults = .standard) -> String? {
        trimmed(defaults.string(forKey: dobbsEndpointKey))
    }

    /// The expected Slack workspace name from Settings, or nil when unset/blank.
    nonisolated static func dobbsWorkspace(in defaults: UserDefaults = .standard) -> String? {
        trimmed(defaults.string(forKey: dobbsWorkspaceKey))
    }

    // MARK: SearXNG (web_search backend)

    nonisolated static let searxngEndpointKey = "searxngEndpoint"

    /// The SearXNG base URL from Settings, or nil when unset/blank (web search disabled).
    nonisolated static func searxngEndpoint(in defaults: UserDefaults = .standard) -> String? {
        trimmed(defaults.string(forKey: searxngEndpointKey))
    }

    // MARK: Gemini model (picked in Settings)

    nonisolated static let geminiModelKey = "geminiModel"

    /// The Gemini model chosen in Settings, or the ChatConfig default.
    nonisolated static func geminiModel(in defaults: UserDefaults = .standard) -> String {
        trimmed(defaults.string(forKey: geminiModelKey)) ?? ChatConfig.default.geminiModel
    }

    // MARK: Ollama model (picked in the chat bubble)

    nonisolated static let ollamaModelKey = "ollamaModel"

    /// The Ollama model chosen in the chat bubble, or the ChatConfig default.
    nonisolated static func ollamaModel(in defaults: UserDefaults = .standard) -> String {
        trimmed(defaults.string(forKey: ollamaModelKey)) ?? ChatConfig.default.ollamaModel
    }

    // MARK: OpenAI-compatible provider

    nonisolated static let openAICompatibleBaseURLKey = "openAICompatibleBaseURL"
    nonisolated static let openAICompatibleModelKey = "openAICompatibleModel"
    nonisolated static let deepSeekThinkingKey = "deepSeekThinking"

    nonisolated static func openAICompatibleBaseURL(in defaults: UserDefaults = .standard) -> String {
        trimmed(defaults.string(forKey: openAICompatibleBaseURLKey))
            ?? ChatConfig.default.openAICompatibleBaseURL
    }

    nonisolated static func openAICompatibleModel(in defaults: UserDefaults = .standard) -> String {
        trimmed(defaults.string(forKey: openAICompatibleModelKey))
            ?? ChatConfig.default.openAICompatibleModel
    }

    nonisolated static func deepSeekThinking(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: deepSeekThinkingKey) == nil
            ? ChatConfig.default.deepSeekThinking
            : defaults.bool(forKey: deepSeekThinkingKey)
    }

    // MARK: Verbose tool calls (shown inline in the chat transcript)

    nonisolated static let verboseToolCallsKey = "verboseToolCalls"

    nonisolated static func verboseToolCalls(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: verboseToolCallsKey)
    }

    // MARK: MCP servers (managed in Settings; tokens live in Keychain)

    nonisolated static let mcpServersKey = "mcpServers"

    nonisolated static func mcpServers(in defaults: UserDefaults = .standard) -> [MCPServerConfig] {
        guard let data = defaults.data(forKey: mcpServersKey) else { return [] }
        return (try? JSONDecoder().decode([MCPServerConfig].self, from: data)) ?? []
    }

    nonisolated static func setMCPServers(
        _ servers: [MCPServerConfig],
        in defaults: UserDefaults = .standard
    ) {
        defaults.set(try? JSONEncoder().encode(servers), forKey: mcpServersKey)
    }

    // MARK: Tailscale sidecar SOCKS5 proxy (per-endpoint opt-in)

    nonisolated static let socksProxyEndpointKey = "socksProxyEndpoint"
    nonisolated static let defaultSOCKSProxyEndpoint = "127.0.0.1:1055"

    nonisolated static let ollamaUseProxyKey = "ollamaUseProxy"
    nonisolated static let geminiUseProxyKey = "geminiUseProxy"
    nonisolated static let openAICompatibleUseProxyKey = "openAICompatibleUseProxy"
    nonisolated static let searxngUseProxyKey = "searxngUseProxy"
    nonisolated static let dobbsUseProxyKey = "dobbsUseProxy"

    /// The SOCKS5 proxy host:port, defaulting to the local tsidecar proxy.
    nonisolated static func socksProxyEndpoint(in defaults: UserDefaults = .standard) -> String {
        trimmed(defaults.string(forKey: socksProxyEndpointKey)) ?? defaultSOCKSProxyEndpoint
    }

    /// Whether requests to this chat provider route through the SOCKS5 proxy.
    nonisolated static func useProxy(
        for provider: ChatProvider,
        in defaults: UserDefaults = .standard
    ) -> Bool {
        let key = switch provider {
        case .ollama: ollamaUseProxyKey
        case .gemini: geminiUseProxyKey
        case .openAICompatible: openAICompatibleUseProxyKey
        }
        return defaults.bool(forKey: key)
    }

    nonisolated static func searxngUseProxy(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: searxngUseProxyKey)
    }

    nonisolated static func dobbsUseProxy(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: dobbsUseProxyKey)
    }

    // MARK: LED Sign (MatrixPortal M4)

    nonisolated static let ledSignEndpointKey = "ledSignEndpoint"
    nonisolated static let ledSignUseProxyKey = "ledSignUseProxy"

    /// The LED sign host or host:port from Settings, or nil when unset/blank
    /// (feature off).
    nonisolated static func ledSignEndpoint(in defaults: UserDefaults = .standard) -> String? {
        trimmed(defaults.string(forKey: ledSignEndpointKey))
    }

    nonisolated static func ledSignUseProxy(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: ledSignUseProxyKey)
    }

    // MARK: Ollama base URL (points at a local or tailnet Ollama server)

    nonisolated static let ollamaBaseURLKey = "ollamaBaseURL"

    /// The Ollama base URL from Settings, or nil when unset/blank (use the default).
    nonisolated static func ollamaBaseURL(in defaults: UserDefaults = .standard) -> String? {
        trimmed(defaults.string(forKey: ollamaBaseURLKey))
    }

    nonisolated private static func trimmed(_ raw: String?) -> String? {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    // MARK: Chat font size (adjusted with Cmd+/Cmd- in the bubble)

    nonisolated static let chatFontSizeKey = "chatFontSize"
    nonisolated static let defaultChatFontSize: CGFloat = 12
    nonisolated static let chatFontSizeRange: ClosedRange<CGFloat> = 9...28

    static func chatFontSize(in defaults: UserDefaults = .standard) -> CGFloat {
        let stored = defaults.double(forKey: chatFontSizeKey)
        guard stored > 0 else { return defaultChatFontSize }
        return CGFloat(stored).clamped(to: chatFontSizeRange)
    }

    static func setChatFontSize(_ size: CGFloat, in defaults: UserDefaults = .standard) {
        defaults.set(Double(size.clamped(to: chatFontSizeRange)), forKey: chatFontSizeKey)
    }

    // MARK: Chat bubble opacity (slider in Settings)

    nonisolated static let chatOpacityKey = "chatOpacity"
    nonisolated static let defaultChatOpacity: Double = 1.0
    nonisolated static let chatOpacityRange: ClosedRange<Double> = 0.2...1.0

    nonisolated static func chatOpacity(in defaults: UserDefaults = .standard) -> Double {
        let stored = defaults.double(forKey: chatOpacityKey)
        guard stored > 0 else { return defaultChatOpacity }
        return stored.clamped(to: chatOpacityRange)
    }
}
