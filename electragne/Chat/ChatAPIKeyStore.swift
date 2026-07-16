import Foundation
import Security

nonisolated enum ChatAPIProvider: String, CaseIterable, Sendable {
    case gemini
    case ollama
    case dobbs
    case linear

    var environmentKey: String {
        switch self {
        case .gemini: "GEMINI_API_KEY"
        case .ollama: "OLLAMA_API_KEY"
        case .dobbs: "DOBBS_TOKEN"
        case .linear: "LINEAR_API_KEY"
        }
    }

    var keyFile: String {
        switch self {
        case .gemini: ".gemini.api.key"
        case .ollama: ".ollama/api_key"
        case .dobbs: ".dobbs/token"
        case .linear: ".linear.api.key"
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
///
/// All provider keys live in ONE keychain item (a JSON dictionary keyed by
/// provider), read at most once per launch, so the Keychain authorization
/// prompt appears once instead of once per provider per access.
nonisolated enum ChatAPIKeyStore {
    private static let service = "org.impolexg.electragne.chat-api-keys"
    private static let combinedAccount = "api-keys"
    private static let cached = CachedKeys()

    static func key(for provider: ChatAPIProvider) -> String? {
        let value = allKeys()[provider.rawValue]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
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
        var keys = allKeys()
        keys[provider.rawValue] = value.isEmpty ? nil : value
        try writeCombined(keys)
        cached.set(keys)
    }

    // MARK: - The combined keychain item

    private static func allKeys() -> [String: String] {
        if let keys = cached.get() { return keys }
        let keys = readCombined() ?? migrateLegacyItems()
        cached.set(keys)
        return keys
    }

    private static func readCombined() -> [String: String]? {
        guard let data = readData(account: combinedAccount) else { return nil }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    /// One-time migration from the old one-item-per-provider layout: reads
    /// each legacy item (the last multi-prompt launch), rewrites them as the
    /// combined item, and deletes the legacy items.
    private static func migrateLegacyItems() -> [String: String] {
        var keys: [String: String] = [:]
        for provider in ChatAPIProvider.allCases {
            guard let data = readData(account: provider.rawValue) else { continue }
            if let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                keys[provider.rawValue] = value
            }
            SecItemDelete(baseQuery(account: provider.rawValue) as CFDictionary)
        }
        try? writeCombined(keys)
        return keys
    }

    private static func readData(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else {
            return nil
        }
        return item as? Data
    }

    private static func writeCombined(_ keys: [String: String]) throws {
        let data = try! JSONEncoder().encode(keys)
        let query = baseQuery(account: combinedAccount)
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

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// The in-memory copy of the combined item, so repeated key lookups never
/// touch the Keychain (each access can prompt on unsigned dev builds).
nonisolated private final class CachedKeys: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: String]?

    func get() -> [String: String]? {
        lock.lock()
        defer { lock.unlock() }
        return keys
    }

    func set(_ new: [String: String]) {
        lock.lock()
        keys = new
        lock.unlock()
    }
}
