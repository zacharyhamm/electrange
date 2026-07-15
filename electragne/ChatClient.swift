import Foundation

/// JSON-compatible values used at the boundary between model tool calls and
/// local executors. Keeping this type provider-neutral makes subsequent tools
/// reusable without introducing an arguments struct into ChatClient itself.
nonisolated enum ChatToolValue: Equatable, Codable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: ChatToolValue])
    case array([ChatToolValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: ChatToolValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([ChatToolValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported tool JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var objectValue: [String: ChatToolValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var numberValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }
}

nonisolated struct ChatToolCall: Equatable, Sendable {
    let id: String
    let name: String
    let arguments: [String: ChatToolValue]
}

nonisolated struct ChatToolResult: Equatable, Sendable {
    let response: [String: ChatToolValue]

    static func error(_ message: String) -> ChatToolResult {
        ChatToolResult(response: [
            "status": .string("error"),
            "message": .string(message),
        ])
    }
}

/// A chat backend the bubble can stream a reply from.
protocol ChatClient {
    func streamChat(
        history: [OllamaMessage],
        onStatus: (String) -> Void,
        onToolCall: (ChatToolCall) async -> ChatToolResult,
        onToken: (String) -> Void
    ) async throws
}

/// Which backend the menu-bar toggle has selected.
enum ChatProviderPreference {
    nonisolated static let useGeminiKey = "useGeminiChat"

    static var useGemini: Bool {
        UserDefaults.standard.bool(forKey: useGeminiKey)
    }
}

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

extension CGFloat {
    nonisolated func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
