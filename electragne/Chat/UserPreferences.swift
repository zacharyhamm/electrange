//
//  UserPreferences.swift
//  electragne
//

import Foundation

/// User-adjustable settings from the Settings window.
enum UserPreferences {
    nonisolated static let preferredNameKey = "preferredUserName"

    /// The name typed in Settings, or nil when unset/blank.
    static func preferredName(in defaults: UserDefaults = .standard) -> String? {
        guard let raw = defaults.string(forKey: preferredNameKey) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The name the pet should use: the Settings override when present,
    /// otherwise the macOS account's full name.
    static func resolvedUserName() -> String? {
        preferredName() ?? OllamaClient.detectedUserName()
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
