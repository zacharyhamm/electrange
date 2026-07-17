//
//  MCPOAuth.swift
//  electragne
//
//  Generic OAuth for remote MCP servers. The MCP SDK's OAuthAuthorizer does
//  the whole spec (discovery, dynamic client registration, PKCE, refresh);
//  this file supplies the two host-app pieces it can't: persisting tokens in
//  the Keychain, and opening the user's browser for the consent step via
//  AppAuth's loopback redirect listener.
//

import AppAuth
import AppKit
import Foundation
import MCP
import os

nonisolated enum MCPOAuth {
    /// One authorizer per transport (SDK rule); shared state lives in the
    /// Keychain-backed storage. Seeding the stored token's clientID lets the
    /// refresh grant work across app restarts without re-registering.
    static func authorizer(
        serverID: UUID,
        interactive: Bool
    ) -> (OAuthAuthorizer, MCPOAuthBrowserDelegate) {
        let storage = MCPOAuthTokenStorage(serverID: serverID)
        let delegate = MCPOAuthBrowserDelegate(interactive: interactive)
        // ponytail: the DCR registration response is not persisted (only the
        // token's clientID). If a server registers us as a confidential
        // client, or expires the registration so a refresh-grant 4xx makes
        // the SDK re-register under a new clientID (orphaning the stored
        // refresh token), refresh fails after relaunch and we fall back to
        // browser sign-in. Persist the registration response if that ever
        // matters.
        let configuration = OAuthConfiguration(
            grantType: .authorizationCode,
            authentication: .none(clientID: storage.load()?.clientID ?? ""),
            authorizationRedirectURI: delegate.redirectURL,
            clientName: "Electragne",
            authorizationDelegate: delegate
        )
        return (OAuthAuthorizer(configuration: configuration, tokenStorage: storage), delegate)
    }
}

/// Persists the SDK's access/refresh token in the shared Keychain item,
/// keyed "mcp-oauth:<server-uuid>".
nonisolated final class MCPOAuthTokenStorage: TokenStorage, @unchecked Sendable {
    private let serverID: UUID

    init(serverID: UUID) {
        self.serverID = serverID
    }

    func save(_ token: OAuthAccessToken) {
        do {
            let data = try JSONEncoder().encode(token)
            try ChatAPIKeyStore.setMCPOAuthState(
                String(decoding: data, as: UTF8.self), forServer: serverID)
        } catch {
            // The SDK has no error path here; at least leave a trace so a
            // "signed in but forgotten after relaunch" report is diagnosable.
            Log.mcp.error("Failed to persist OAuth token: \(error.localizedDescription)")
        }
    }

    func load() -> OAuthAccessToken? {
        guard let raw = ChatAPIKeyStore.mcpOAuthState(forServer: serverID) else { return nil }
        return try? JSONDecoder().decode(OAuthAccessToken.self, from: Data(raw.utf8))
    }

    /// The SDK clears storage *before* attempting the refresh grant
    /// (OAuthAuthorizer.handleChallenge), so a hard delete here would destroy
    /// the refresh token whenever that grant fails transiently (DNS, 500).
    /// Keep the refresh credentials and drop only the access token; remove()
    /// hard-deletes via ChatAPIKeyStore directly.
    func clear() {
        guard let token = load(), let refreshToken = token.refreshToken else {
            try? ChatAPIKeyStore.setMCPOAuthState("", forServer: serverID)
            return
        }
        save(
            OAuthAccessToken(
                value: "",
                tokenType: token.tokenType,
                // distantPast, not nil: the SDK treats nil expiresAt as
                // never-expired and would send "Bearer " (empty credential)
                // on every request instead of entering the refresh path.
                expiresAt: .distantPast,
                scopes: token.scopes,
                authorizationServer: token.authorizationServer,
                refreshToken: refreshToken,
                clientID: token.clientID
            ))
    }
}

/// Presents the authorization URL in the default browser and catches the
/// loopback redirect with AppAuth's OIDRedirectHTTPHandler (the pattern
/// GoogleOAuth already uses; the sandbox network.server entitlement covers
/// the listener). Non-interactive instances decline instead, so a launch-time
/// reconnect never pops a browser — the manager maps the decline to a
/// "needs sign-in" status.
nonisolated final class MCPOAuthBrowserDelegate: NSObject, OAuthAuthorizationDelegate,
    OIDExternalUserAgentSession, @unchecked Sendable
{
    /// The loopback listener's URL; nil when non-interactive. Must exist
    /// before OAuthConfiguration is built so the authorization request's
    /// redirect_uri matches the listener.
    let redirectURL: URL?

    /// Why sign-in couldn't proceed. The transport wraps thrown errors in
    /// MCPError.internalError (type lost), so MCPServerManager reads this
    /// instead to classify the failure. nil once taken.
    private var authError: MCPServerError?
    /// One-shot: nilled after the first presentation, since the loopback
    /// listener can't be restarted on the same port.
    private var handler: OIDRedirectHTTPHandler?
    private let listenerError: String?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?

    init(interactive: Bool) {
        if interactive {
            let handler = OIDRedirectHTTPHandler(successURL: nil)
            var error: NSError?
            let url = handler.startHTTPListener(&error)
            self.handler = error == nil ? handler : nil
            self.redirectURL = error == nil ? url : nil
            self.listenerError = error?.localizedDescription
        } else {
            handler = nil
            redirectURL = nil
            listenerError = nil
        }
        super.init()
    }

    /// Read-and-clear the recorded auth failure.
    func takeAuthError() -> MCPServerError? {
        lock.lock()
        defer { lock.unlock() }
        let error = authError
        authError = nil
        return error
    }

    deinit {
        handler?.cancelHTTPListener()
    }

    // MARK: - OAuthAuthorizationDelegate

    func presentAuthorizationURL(_ url: URL) async throws -> URL {
        guard let handler = takeHandler(), redirectURL != nil else {
            let error: MCPServerError =
                if let listenerError {
                    .signInFailed(listenerError)
                } else {
                    .signInRequired
                }
            record(error)
            throw error
        }
        handler.currentAuthorizationFlow = self
        defer {
            handler.currentAuthorizationFlow = nil
            handler.cancelHTTPListener()
        }
        let timeout = Task { [weak self] in
            try await Task.sleep(for: .seconds(300))
            self?.record(.signInTimedOut)
            self?.finish(with: .failure(MCPServerError.signInTimedOut))
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            install(continuation)
            Task { @MainActor in
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - OIDExternalUserAgentSession (the loopback listener's callback)

    func resumeExternalUserAgentFlow(with url: URL) -> Bool {
        resume(url)
    }

    // The preferred (non-deprecated) requirement, which OIDRedirectHTTPHandler
    // invokes directly with error:nil — a missing selector is an
    // unrecognized-selector crash mid sign-in. Swift imports it in a
    // `(with:error:()) throws` shape that cannot be marked @objc, so it can't
    // be witnessed normally; instead the raw selector is provided directly
    // with the BOOL + NSError** signature the handler expects (it only checks
    // the BOOL).
    @objc(resumeExternalUserAgentFlowWithURL:error:)
    func resumeExternalUserAgentFlow(withURL url: URL, error: NSErrorPointer) -> Bool {
        resume(url)
    }

    func failExternalUserAgentFlowWithError(_ error: any Error) {
        finish(with: .failure(error))
    }

    func cancel() {
        finish(with: .failure(CancellationError()))
    }

    func cancel(completion: (() -> Void)? = nil) {
        cancel()
        completion?()
    }

    // MARK: - Redirect plumbing

    /// The listener hands us every request it receives (including favicon
    /// fetches), as a URL that may lack scheme/host. Consume only the OAuth
    /// redirect, rebuilt onto the listener's absolute base so the SDK's
    /// redirect-URI check passes.
    private func resume(_ incoming: URL) -> Bool {
        guard let redirectURL,
              let components = URLComponents(url: incoming, resolvingAgainstBaseURL: false),
              components.queryItems?.contains(where: { $0.name == "code" || $0.name == "error" })
                  == true,
              var absolute = URLComponents(url: redirectURL, resolvingAgainstBaseURL: false)
        else { return false }
        absolute.percentEncodedQuery = components.percentEncodedQuery
        guard let url = absolute.url else { return false }
        // Consumed only if a continuation was actually waiting: a code/error
        // request arriving before presentAuthorizationURL installs one (stale
        // tab, local probe) must not make the handler kill the listener.
        return finish(with: .success(url))
    }

    private func record(_ error: MCPServerError) {
        lock.lock()
        authError = error
        lock.unlock()
    }

    /// Take the handler for its single presentation (SDK retries and later
    /// 401s must not reuse the dead listener).
    private func takeHandler() -> OIDRedirectHTTPHandler? {
        lock.lock()
        defer { lock.unlock() }
        let handler = handler
        self.handler = nil
        return handler
    }

    private func install(_ continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    /// Returns whether a continuation was waiting and got resumed.
    @discardableResult
    private func finish(with result: Result<URL, Error>) -> Bool {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
        return continuation != nil
    }
}
