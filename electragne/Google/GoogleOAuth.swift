import AppAuth
import AppKit
import Foundation
import os
import Security

nonisolated struct GoogleAccount: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let email: String
    let displayName: String?
}

nonisolated enum GoogleOAuthError: LocalizedError, Equatable {
    case missingClientID
    case noAccounts
    case accountNotFound
    case missingCredentials
    case authorizationFailed(String)
    case invalidIdentity
    case tokenUnavailable
    case keychain(Int32)
    case badStatus(Int)

    var errorDescription: String? {
        switch self {
        case .missingClientID: "Enter a Google OAuth desktop client ID in Electragne Settings."
        case .noAccounts: "Connect a Google account in Electragne Settings first."
        case .accountNotFound: "That Google account is no longer connected."
        case .missingCredentials: "This Google account needs to be reconnected in Settings."
        case .authorizationFailed(let message): "Google authorization failed: \(message)"
        case .invalidIdentity: "Google did not return a usable account identity."
        case .tokenUnavailable: "Google could not provide an access token. Reconnect the account."
        case .keychain: "Electragne could not access the macOS Keychain."
        case .badStatus(let status): "Google returned HTTP \(status)."
        }
    }
}

@MainActor
protocol GoogleTokenProviding {
    var accounts: [GoogleAccount] { get }
    var defaultAccountID: String? { get }
    func resolveAccount(id: String?) throws -> GoogleAccount
    func freshAccessToken(for accountID: String) async throws -> String
}

@MainActor
final class GoogleOAuthService: GoogleTokenProviding {
    static let shared = GoogleOAuthService()

    static let clientIDKey = "googleOAuthClientID"
    static let accountsKey = "googleConnectedAccounts"
    static let defaultAccountIDKey = "googleDefaultAccountID"
    private static let clientSecretCredentialID = "__oauth_client_secret__"
    static let gmailScopes = [
        OIDScopeOpenID,
        OIDScopeEmail,
        OIDScopeProfile,
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/gmail.compose",
    ]
    static let calendarScopes = [
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
        "https://www.googleapis.com/auth/calendar.events",
    ]
    static let requestedScopes = gmailScopes + calendarScopes

    private static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    private static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    private static let revocationEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!

    private let defaults: UserDefaults
    private let keychain: GoogleCredentialStoring
    private let session: URLSession
    private var redirectHandler: OIDRedirectHTTPHandler?

    init(
        defaults: UserDefaults = .standard,
        keychain: GoogleCredentialStoring? = nil,
        session: URLSession = .shared
    ) {
        self.defaults = defaults
        self.keychain = keychain ?? KeychainGoogleCredentialStore()
        self.session = session
    }

    var clientID: String {
        get { defaults.string(forKey: Self.clientIDKey) ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.clientIDKey) }
    }

    var clientSecret: String {
        get {
            guard let data = try? keychain.load(accountID: Self.clientSecretCredentialID) else {
                return ""
            }
            return String(data: data, encoding: .utf8) ?? ""
        }
        set {
            let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                try? keychain.delete(accountID: Self.clientSecretCredentialID)
            } else if let data = value.data(using: .utf8) {
                try? keychain.save(data, accountID: Self.clientSecretCredentialID)
            }
        }
    }

    var accounts: [GoogleAccount] {
        guard let data = defaults.data(forKey: Self.accountsKey) else { return [] }
        return (try? JSONDecoder().decode([GoogleAccount].self, from: data)) ?? []
    }

    var defaultAccountID: String? {
        defaults.string(forKey: Self.defaultAccountIDKey)
    }

    func setDefaultAccount(id: String) {
        guard accounts.contains(where: { $0.id == id }) else { return }
        defaults.set(id, forKey: Self.defaultAccountIDKey)
    }

    func resolveAccount(id: String?) throws -> GoogleAccount {
        let connected = accounts
        guard !connected.isEmpty else { throw GoogleOAuthError.noAccounts }
        let targetID = id ?? defaultAccountID ?? (connected.count == 1 ? connected[0].id : nil)
        guard let targetID, let account = connected.first(where: { $0.id == targetID }) else {
            throw GoogleOAuthError.accountNotFound
        }
        return account
    }

    func connect(presenting window: NSWindow, scopes: [String]? = nil) async throws -> GoogleAccount {
        let configuredClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configuredClientID.isEmpty else { throw GoogleOAuthError.missingClientID }

        let handler = OIDRedirectHTTPHandler(successURL: nil)
        var listenerError: NSError?
        let redirectURL = handler.startHTTPListener(&listenerError)
        if let listenerError {
            throw GoogleOAuthError.authorizationFailed(listenerError.localizedDescription)
        }
        redirectHandler = handler

        let configuration = OIDServiceConfiguration(
            authorizationEndpoint: Self.authorizationEndpoint,
            tokenEndpoint: Self.tokenEndpoint
        )
        let request = OIDAuthorizationRequest(
            configuration: configuration,
            clientId: configuredClientID,
            clientSecret: clientSecret.isEmpty ? nil : clientSecret,
            scopes: scopes ?? Self.requestedScopes,
            redirectURL: redirectURL,
            responseType: OIDResponseTypeCode,
            additionalParameters: [
                "access_type": "offline",
                "prompt": "select_account consent",
            ]
        )

        let state: OIDAuthState = try await withCheckedThrowingContinuation { continuation in
            handler.currentAuthorizationFlow = OIDAuthState.authState(
                byPresenting: request,
                presenting: window
            ) { state, error in
                if let state {
                    continuation.resume(returning: state)
                } else {
                    continuation.resume(throwing: GoogleOAuthError.authorizationFailed(
                        error?.localizedDescription ?? "The request was cancelled."
                    ))
                }
            }
        }
        redirectHandler = nil

        guard let rawIDToken = state.lastTokenResponse?.idToken,
              let idToken = OIDIDToken(idTokenString: rawIDToken),
              let email = idToken.claims["email"] as? String,
              !email.isEmpty else {
            throw GoogleOAuthError.invalidIdentity
        }
        let account = GoogleAccount(
            id: idToken.subject,
            email: email,
            displayName: idToken.claims["name"] as? String
        )
        try save(state: state, accountID: account.id)

        var updated = accounts.filter { $0.id != account.id }
        updated.append(account)
        updated.sort { $0.email.localizedCaseInsensitiveCompare($1.email) == .orderedAscending }
        save(accounts: updated)
        if defaultAccountID == nil { setDefaultAccount(id: account.id) }
        return account
    }

    func freshAccessToken(for accountID: String) async throws -> String {
        let state = try await loadState(accountID: accountID)
        return try await withCheckedThrowingContinuation { continuation in
            state.performAction(freshTokens: { [weak self] accessToken, _, error in
                guard let self else {
                    continuation.resume(throwing: GoogleOAuthError.tokenUnavailable)
                    return
                }
                do {
                    try self.save(state: state, accountID: accountID)
                    guard let accessToken, !accessToken.isEmpty else {
                        throw error ?? GoogleOAuthError.tokenUnavailable
                    }
                    continuation.resume(returning: accessToken)
                } catch {
                    continuation.resume(throwing: error)
                }
            })
        }
    }

    func disconnect(accountID: String) async throws {
        _ = try resolveAccount(id: accountID)

        // Best-effort revocation: an expired/already-revoked token or a
        // network failure must not leave the account stuck locally.
        do {
            let token = try await freshAccessToken(for: accountID)
            var request = URLRequest(url: Self.revocationEndpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = "token=\(Self.formEncode(token))".data(using: .utf8)
            _ = try await session.data(for: request)
        } catch {
            Log.lifecycle.error("Google token revocation failed; removing account anyway: \(error.localizedDescription, privacy: .public)")
        }

        try keychain.delete(accountID: accountID)
        let remaining = accounts.filter { $0.id != accountID }
        save(accounts: remaining)
        if defaultAccountID == accountID {
            if let first = remaining.first { setDefaultAccount(id: first.id) }
            else { defaults.removeObject(forKey: Self.defaultAccountIDKey) }
        }
    }

    private func save(accounts: [GoogleAccount]) {
        if let data = try? JSONEncoder().encode(accounts) {
            defaults.set(data, forKey: Self.accountsKey)
        }
    }

    private func save(state: OIDAuthState, accountID: String) throws {
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: state,
            requiringSecureCoding: true
        )
        try keychain.save(data, accountID: accountID)
    }

    private func loadState(accountID: String) async throws -> OIDAuthState {
        // The first keychain read after a rebuild blocks on the user
        // authorization prompt (the signature changed); off the main thread
        // so a pending prompt can't freeze the app.
        let keychain = self.keychain
        guard let data = try await Task.detached(operation: { try keychain.load(accountID: accountID) }).value,
              let state = try NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: data) else {
            throw GoogleOAuthError.missingCredentials
        }
        return state
    }

    nonisolated private static func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }
}

nonisolated protocol GoogleCredentialStoring: Sendable {
    func save(_ data: Data, accountID: String) throws
    func load(accountID: String) throws -> Data?
    func delete(accountID: String) throws
}

nonisolated struct KeychainGoogleCredentialStore: GoogleCredentialStoring {
    private let service = "org.impolexg.electragne.google-oauth"

    func save(_ data: Data, accountID: String) throws {
        let query = baseQuery(accountID: accountID)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecSuccess { return }
        if status != errSecItemNotFound { throw GoogleOAuthError.keychain(status) }
        var add = query
        add[kSecValueData as String] = data
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw GoogleOAuthError.keychain(addStatus) }
    }

    func load(accountID: String) throws -> Data? {
        var query = baseQuery(accountID: accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw GoogleOAuthError.keychain(status) }
        return item as? Data
    }

    func delete(accountID: String) throws {
        let status = SecItemDelete(baseQuery(accountID: accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GoogleOAuthError.keychain(status)
        }
    }

    private func baseQuery(accountID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
        ]
    }
}
