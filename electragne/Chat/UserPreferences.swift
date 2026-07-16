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
        preferredName() ?? OllamaClient.detectedUserName()
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

    // MARK: Gemini model (picked in Settings)

    nonisolated static let geminiModelKey = "geminiModel"

    /// The Gemini model chosen in Settings, or the ChatConfig default.
    nonisolated static func geminiModel(in defaults: UserDefaults = .standard) -> String {
        trimmed(defaults.string(forKey: geminiModelKey)) ?? ChatConfig.default.geminiModel
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
}
