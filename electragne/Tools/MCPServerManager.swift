//
//  MCPServerManager.swift
//  electragne
//
//  Owns the MCP client connections: connects configured Streamable-HTTP
//  servers, publishes discovered tools to MCPToolCatalog, and executes
//  tool calls on behalf of MCPToolExecutor.
//

import Foundation
import MCP

nonisolated enum MCPServerStatus: Equatable, Sendable {
    case connecting
    case connected(toolCount: Int)
    case needsAuth
    case failed(String)

    var canSignIn: Bool {
        switch self {
        case .needsAuth, .failed: true
        case .connecting, .connected: false
        }
    }
}

/// What the OAuth browser delegate can record about a declined/failed
/// sign-in, narrower than `MCPServerError` (which also covers direct-throw
/// cases like `.notConnected`/`.signInInProgress` that the delegate never
/// produces). Shared by both places that classify a decline into a status.
nonisolated enum MCPAuthDecline: Equatable {
    case needsAuth
    case timedOut
    case failed(String)

    var status: MCPServerStatus {
        switch self {
        case .needsAuth, .timedOut: .needsAuth
        case .failed(let reason): .failed(reason)
        }
    }

    var error: MCPServerError {
        switch self {
        case .needsAuth: .signInRequired
        case .timedOut: .signInTimedOut
        case .failed(let reason): .signInFailed(reason)
        }
    }
}

nonisolated enum MCPServerError: LocalizedError, Equatable {
    case notConnected(String)
    case signInRequired
    case signInInProgress
    case signInTimedOut
    case signInFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected(let server):
            "The MCP server ‘\(server)’ is not connected. Check Electragne Settings → MCP."
        case .signInRequired:
            "Sign-in required. Open Electragne Settings → MCP and press Sign In."
        case .signInInProgress:
            "Sign-in is in progress in the browser — finish it there and try again."
        case .signInTimedOut:
            "The sign-in wasn’t completed in the browser. Press Sign In to try again."
        case .signInFailed(let reason):
            "Couldn’t start the sign-in listener: \(reason)"
        }
    }
}

@MainActor
@Observable
final class MCPServerManager {
    static let shared = MCPServerManager()

    private(set) var servers: [MCPServerConfig]
    private(set) var status: [UUID: MCPServerStatus] = [:]
    private(set) var tools: [UUID: [MCPToolDescriptor]] = [:]
    private var clients: [UUID: Client] = [:]
    private var refreshTasks: [UUID: (interactive: Bool, task: Task<Void, Never>)] = [:]
    /// Kept per server so mid-session 401s on the live transport can be
    /// classified (the transport wraps thrown errors, losing the type).
    private var oauthDelegates: [UUID: MCPOAuthBrowserDelegate] = [:]

    init(servers: [MCPServerConfig] = UserPreferences.mcpServers()) {
        self.servers = servers
    }

    func connectAll() async {
        await withTaskGroup(of: Void.self) { group in
            for server in servers {
                group.addTask { await self.refresh(server.id) }
            }
        }
    }

    func add(name: String, url: URL, token: String) async {
        let config = MCPServerConfig(id: UUID(), name: name, url: url)
        servers.append(config)
        UserPreferences.setMCPServers(servers)
        try? ChatAPIKeyStore.setMCPToken(token, forServer: config.id)
        await refresh(config.id)
    }

    func remove(_ id: UUID) {
        if let config = servers.first(where: { $0.id == id }) {
            MCPToolCatalog.removePolicies(
                namespacePrefix: MCPToolCatalog.namespacePrefix(server: config.name)
            )
        }
        servers.removeAll { $0.id == id }
        UserPreferences.setMCPServers(servers)
        try? ChatAPIKeyStore.setMCPToken("", forServer: id)
        try? ChatAPIKeyStore.setMCPOAuthState("", forServer: id)
        MCPToolCatalog.removeServer(id)
        tools[id] = nil
        status[id] = nil
        oauthDelegates[id] = nil
        if let client = clients.removeValue(forKey: id) {
            Task { await client.disconnect() }
        }
    }

    /// Sign In only helps when no bearer token is pasted: a token suppresses
    /// the OAuth authorizer in performRefresh, so the browser can never open.
    func canSignIn(_ id: UUID) -> Bool {
        status[id]?.canSignIn == true && ChatAPIKeyStore.mcpToken(forServer: id) == nil
    }

    func refresh(_ id: UUID, interactive: Bool = false) async {
        while let inflight = refreshTasks[id] {
            // A background reconnect must not block behind a browser flow.
            if !interactive, inflight.interactive { return }
            await inflight.task.value
            // Piggyback on the refresh that just finished; only an
            // interactive request (Sign In button) racing a *background*
            // refresh re-runs, so the click still opens the browser — a
            // click racing another browser flow piggybacks instead of
            // opening a second one.
            if !interactive || inflight.interactive { return }
            // If the completed task's entry is still in place, stop waiting
            // and re-run; if a different task replaced it, loop and await
            // that one. Re-awaiting the same completed task would spin
            // without ever suspending, starving the creator's own cleanup.
            if refreshTasks[id]?.task == inflight.task { break }
        }
        guard servers.contains(where: { $0.id == id }) else { return }
        let task = Task { await performRefresh(id, interactive: interactive) }
        refreshTasks[id] = (interactive, task)
        await task.value
        // Only clear our own entry — a piggybacking interactive refresh may
        // have already replaced it with a still-running task.
        if refreshTasks[id]?.task == task { refreshTasks[id] = nil }
    }

    private func performRefresh(_ id: UUID, interactive: Bool) async {
        guard let config = servers.first(where: { $0.id == id }) else { return }
        // Read before overwriting with .connecting: the needs-auth gate below
        // is about what the *previous* refresh learned.
        let previousStatus = status[id]
        status[id] = .connecting
        if let old = clients.removeValue(forKey: id) { await old.disconnect() }
        // A pasted bearer token wins; otherwise attach the SDK's OAuth
        // authorizer, which stays inert until the server sends a 401.
        // Interactive (Sign In button) may open the browser; launch-time and
        // mid-chat reconnects instead surface .needsAuth via the delegate.
        let token = ChatAPIKeyStore.mcpToken(forServer: id)
        var authorizer: OAuthAuthorizer?
        var oauthDelegate: MCPOAuthBrowserDelegate?
        // Once a non-interactive refresh has already learned the server
        // needs auth, attaching another authorizer just triggers another
        // dynamic client registration (with no reachable redirect URI) that
        // the delegate can only decline again — only Sign In should retry.
        if token == nil, interactive || previousStatus != .needsAuth {
            (authorizer, oauthDelegate) = MCPOAuth.authorizer(server: config, interactive: interactive)
        }
        oauthDelegates[id] = oauthDelegate
        var client: Client?
        do {
            let connected = try await connect(config, token: token, authorizer: authorizer)
            client = connected
            let descriptors = try await discoverTools(from: connected, config: config)
            guard isConfigured(id) else {
                cleanUpAfterRemoval(id, client: connected)
                return
            }
            clients[id] = connected
            tools[id] = descriptors
            MCPToolCatalog.setTools(descriptors, forServer: id)
            status[id] = .connected(toolCount: descriptors.count)
        } catch {
            await client?.disconnect()
            guard isConfigured(id) else {
                cleanUpAfterRemoval(id, client: nil)
                return
            }
            tools[id] = nil
            MCPToolCatalog.removeServer(id)
            // token == nil && authorizer == nil means the needs-auth gate
            // above deliberately connected without credentials; the resulting
            // 401 is still "needs sign-in", not a new failure.
            status[id] =
                oauthDelegate?.takeAuthError()?.status
                ?? (token == nil && authorizer == nil
                    ? .needsAuth : .failed(error.localizedDescription))
        }
    }

    /// The server may have been removed while refresh was awaiting the network
    /// or an interactive sign-in; completing anyway would resurrect its tools
    /// and re-persist OAuth tokens the removal just wiped.
    private func isConfigured(_ id: UUID) -> Bool {
        servers.contains(where: { $0.id == id })
    }

    private func cleanUpAfterRemoval(_ id: UUID, client: Client?) {
        if let client { Task { await client.disconnect() } }
        try? ChatAPIKeyStore.setMCPOAuthState("", forServer: id)
        oauthDelegates[id] = nil
    }

    func callTool(
        descriptor: MCPToolDescriptor,
        arguments: [String: ChatToolValue]
    ) async -> ChatToolResult {
        do {
            let client = try await connectedClient(for: descriptor.serverID)
            let (content, isError) = try await client.callTool(
                name: descriptor.toolName,
                arguments: arguments.mapValues(MCPToolCatalog.mcpValue)
            )
            return MCPToolCatalog.result(from: content, isError: isError)
        } catch {
            // A mid-session 401 on the live transport declines auth inside the
            // delegate; reflect it so Settings doesn't keep showing .connected.
            let serverID = descriptor.serverID
            // A concurrent performRefresh may still need this delegate's
            // one-shot auth error to classify its own outcome; don't race it.
            if refreshTasks[serverID] == nil, let decline = oauthDelegates[serverID]?.takeAuthError() {
                status[serverID] = decline.status
                if let client = clients.removeValue(forKey: serverID) {
                    Task { await client.disconnect() }
                }
                return .error(decline.error.localizedDescription)
            }
            return .error("MCP tool ‘\(descriptor.toolName)’ failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Connection plumbing

    private func connectedClient(for serverID: UUID) async throws -> Client {
        if let client = clients[serverID] { return client }
        guard let config = servers.first(where: { $0.id == serverID }) else {
            throw MCPServerError.notConnected(serverID.uuidString)
        }
        // Already known to need auth and nothing is retrying it right now:
        // don't spam another reconnect (transport + tool + OAuth discovery)
        // that can only fail the same way; only Sign In should retry.
        if refreshTasks[serverID] == nil, status[serverID] == .needsAuth {
            throw MCPServerError.signInRequired
        }
        // The launch-time connect may have failed (offline, wrong token);
        // retry once now that the model actually wants the tool.
        await refresh(serverID)
        guard let client = clients[serverID] else {
            if refreshTasks[serverID]?.interactive == true {
                throw MCPServerError.signInInProgress
            }
            if status[serverID] == .needsAuth {
                throw MCPServerError.signInRequired
            }
            throw MCPServerError.notConnected(config.name)
        }
        return client
    }

    private func connect(
        _ config: MCPServerConfig,
        token: String?,
        authorizer: OAuthAuthorizer?
    ) async throws -> Client {
        let transport = HTTPClientTransport(
            endpoint: config.url,
            streaming: false,
            authorizer: authorizer,
            requestModifier: { request in
                guard let token else { return request }
                var request = request
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                return request
            }
        )
        let client = Client(name: "Electragne", version: "1.0")
        try await client.connect(transport: transport)
        return client
    }

    private func discoverTools(
        from client: Client,
        config: MCPServerConfig
    ) async throws -> [MCPToolDescriptor] {
        var descriptors: [MCPToolDescriptor] = []
        var cursor: String?
        repeat {
            let page = try await client.listTools(cursor: cursor)
            descriptors += page.tools.map { tool in
                MCPToolDescriptor(
                    serverID: config.id,
                    serverName: config.name,
                    toolName: tool.name,
                    description: tool.description ?? tool.title ?? tool.name,
                    inputSchema: MCPToolCatalog.chatToolValue(tool.inputSchema)
                )
            }
            cursor = page.nextCursor
        } while cursor != nil
        return descriptors
    }
}
