import Foundation
import Security

nonisolated enum ChatAPIProvider: String, CaseIterable, Sendable {
    case gemini
    case openAICompatible
    case dobbs
    case linear

    var environmentKey: String {
        switch self {
        case .gemini: "GEMINI_API_KEY"
        case .openAICompatible: "OPENAI_API_KEY"
        case .dobbs: "DOBBS_TOKEN"
        case .linear: "LINEAR_API_KEY"
        }
    }

    var keyFile: String {
        switch self {
        case .gemini: ".gemini.api.key"
        case .openAICompatible: ".openai_api_key"
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
    /// Every access is already inside a critical section guarded by `lock`
    /// (see `allKeysLocked()`/`setValue()`), so this needs no lock of its own.
    nonisolated(unsafe) private static var cached: [String: String]?
    private static let lock = NSLock()

    static func key(for provider: ChatAPIProvider) -> String? {
        value(forKey: provider.rawValue)
    }

    /// Populates the cache off the main thread. The first keychain read after
    /// a rebuild blocks on the user authorization prompt (the signature
    /// changed); calling this before any main-thread read keeps a pending
    /// prompt from freezing the app.
    static func warm() async {
        await Task.detached { _ = allKeys() }.value
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
        try setValue(rawValue, forKey: provider.rawValue)
    }

    // MARK: - MCP server tokens (same combined item, keyed by server id)

    static func mcpToken(forServer id: UUID) -> String? {
        value(forKey: "mcp:\(id.uuidString)")
    }

    static func setMCPToken(_ rawValue: String, forServer id: UUID) throws {
        try setValue(rawValue, forKey: "mcp:\(id.uuidString)")
    }

    /// JSON-encoded OAuth token state (access + refresh token, clientID)
    /// written by MCPOAuthTokenStorage.
    static func mcpOAuthState(forServer id: UUID) -> String? {
        value(forKey: "mcp-oauth:\(id.uuidString)")
    }

    static func setMCPOAuthState(_ rawValue: String, forServer id: UUID) throws {
        try setValue(rawValue, forKey: "mcp-oauth:\(id.uuidString)")
    }

    // MARK: - Google OAuth credentials (same combined item, keyed by account id)

    static func googleCredential(forAccount id: String) -> Data? {
        value(forKey: "google:\(id)").flatMap { Data(base64Encoded: $0) }
    }

    /// `nil` deletes the credential.
    static func setGoogleCredential(_ data: Data?, forAccount id: String) throws {
        try setValue(data?.base64EncodedString() ?? "", forKey: "google:\(id)")
    }

    // MARK: - Shared accessors

    private static func value(forKey key: String) -> String? {
        let value = allKeys()[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    /// Empty (after trimming) deletes the key. The lock makes the
    /// read-modify-write atomic: MCPOAuthTokenStorage saves tokens from the
    /// SDK's background tasks while Settings writes on the main thread.
    private static func setValue(_ rawValue: String, forKey key: String) throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        defer { lock.unlock() }
        var keys = allKeysLocked()
        keys[key] = value.isEmpty ? nil : value
        try writeCombined(keys)
        cached = keys
    }

    // MARK: - The combined keychain item

    /// Reads also take the lock: a cache-miss read racing a write could
    /// otherwise repopulate the cache with a pre-write keychain snapshot,
    /// which the next setValue would persist — deleting the racing write's key.
    private static func allKeys() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return allKeysLocked()
    }

    private static func allKeysLocked() -> [String: String] {
        if let keys = cached { return keys }
        let keys = readCombined() ?? migrateLegacyItems()
        cached = keys
        return keys
    }

    private static func readCombined() -> [String: String]? {
        #if DEBUG
        if let backing = inMemoryBacking { return backing }
        #endif
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
        #if DEBUG
        if inMemoryBacking != nil {
            inMemoryBacking = keys
            return
        }
        #endif
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

    #if DEBUG
    /// True when XCTest is loaded into the process, i.e. we're the test host.
    /// The unsigned test build can never match the keychain item's ACL, so any
    /// real keychain access under test triggers a password prompt.
    private static let isTestRun = NSClassFromString("XCTestCase") != nil
    /// Test-only: when non-nil, readCombined/writeCombined use this dictionary
    /// instead of the Keychain. Defaults to in-memory for the whole test run
    /// (covers AppDelegate's warm() in the test host and tests that don't set
    /// the flag). Only touched under `lock` (the public accessor takes it; the
    /// boundary functions are already inside it).
    nonisolated(unsafe) private static var inMemoryBacking: [String: String]? =
        isTestRun ? [:] : nil
    /// Test-only: toggling in either direction resets both the backing store
    /// and the cache, so a test can't poison state for later real writes.
    /// During a test run, `false` still keeps an (empty) in-memory store so a
    /// toggle-off can never fall through to the real keychain.
    static var useInMemoryStoreForTesting: Bool {
        get { lock.withLock { inMemoryBacking != nil } }
        set {
            lock.withLock {
                inMemoryBacking = newValue || isTestRun ? [:] : nil
                cached = nil
            }
        }
    }
    #endif
}
