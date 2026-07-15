import Foundation
import Security

nonisolated enum ChatAPIProvider: String, CaseIterable, Sendable {
    case gemini
    case ollama

    var environmentKey: String {
        switch self {
        case .gemini: "GEMINI_API_KEY"
        case .ollama: "OLLAMA_API_KEY"
        }
    }

    var keyFile: String {
        switch self {
        case .gemini: ".gemini.api.key"
        case .ollama: ".ollama/api_key"
        }
    }
}

nonisolated enum ChatAPIKeyStoreError: LocalizedError, Equatable {
    case keychain(Int32)

    var errorDescription: String? {
        "Electragne could not update the macOS Keychain."
    }
}

/// Keychain storage shared by Settings and the chat clients.
nonisolated enum ChatAPIKeyStore {
    private static let service = "org.impolexg.electragne.chat-api-keys"

    static func key(for provider: ChatAPIProvider) -> String? {
        var query = baseQuery(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Keychain first, then environment for terminal launches, then the
    /// provider CLI's key file for Finder launches.
    static func load(for provider: ChatAPIProvider) -> String? {
        load(for: provider, keychainKey: key(for: provider))
    }

    static func load(
        for provider: ChatAPIProvider,
        keychainKey: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = HomeDirectory.realPath
    ) -> String? {
        for rawValue in [keychainKey, environment[provider.environmentKey]] {
            if let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        let url = URL(fileURLWithPath: homeDirectory).appendingPathComponent(provider.keyFile)
        guard let value = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    static func setKey(_ rawValue: String, for provider: ChatAPIProvider) throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = baseQuery(for: provider)

        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw ChatAPIKeyStoreError.keychain(status)
            }
            return
        }

        let data = Data(value.utf8)
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw ChatAPIKeyStoreError.keychain(status)
        }

        var item = query
        item[kSecValueData as String] = data
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw ChatAPIKeyStoreError.keychain(addStatus)
        }
    }

    private static func baseQuery(for provider: ChatAPIProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
    }
}
