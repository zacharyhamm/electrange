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

    func refresh(_ id: UUID, interactive: Bool = false) async {
        while let inflight = refreshTasks[id] {
            // A background reconnect must not block behind a browser flow.
            if !interactive, inflight.interactive { return }
            await inflight.task.value
            // Piggyback on the refresh that just finished; only an
            // interactive request (Sign In button) re-runs so a click racing
            // a background refresh still opens the browser.
            if !interactive { return }
        }
        guard servers.contains(where: { $0.id == id }) else { return }
        let task = Task { await performRefresh(id, interactive: interactive) }
        refreshTasks[id] = (interactive, task)
        await task.value
        refreshTasks[id] = nil
    }

    private func performRefresh(_ id: UUID, interactive: Bool) async {
        guard let config = servers.first(where: { $0.id == id }) else { return }
        status[id] = .connecting
        if let old = clients.removeValue(forKey: id) { await old.disconnect() }
        // A pasted bearer token wins; otherwise attach the SDK's OAuth
        // authorizer, which stays inert until the server sends a 401.
        // Interactive (Sign In button) may open the browser; launch-time and
        // mid-chat reconnects instead surface .needsAuth via the delegate.
        let token = ChatAPIKeyStore.mcpToken(forServer: id)
        var authorizer: OAuthAuthorizer?
        var oauthDelegate: MCPOAuthBrowserDelegate?
        if token == nil {
            (authorizer, oauthDelegate) = MCPOAuth.authorizer(serverID: id, interactive: interactive)
        }
        oauthDelegates[id] = oauthDelegate
        var client: Client?
        do {
            let connected = try await connect(config, token: token, authorizer: authorizer)
            client = connected
            let descriptors = try await discoverTools(from: connected, config: config)
            guard stillConfigured(id, client: connected) else { return }
            clients[id] = connected
            tools[id] = descriptors
            MCPToolCatalog.setTools(descriptors, forServer: id)
            status[id] = .connected(toolCount: descriptors.count)
        } catch {
            await client?.disconnect()
            guard stillConfigured(id, client: nil) else { return }
            tools[id] = nil
            MCPToolCatalog.removeServer(id)
            status[id] =
                switch oauthDelegate?.takeAuthError() {
                case .signInRequired, .signInInProgress, .signInTimedOut: .needsAuth
                case .signInFailed(let reason): .failed(reason)
                case nil, .notConnected: .failed(error.localizedDescription)
                }
        }
    }

    /// The server may have been removed while refresh was awaiting the network
    /// or an interactive sign-in; completing anyway would resurrect its tools
    /// and re-persist OAuth tokens the removal just wiped.
    private func stillConfigured(_ id: UUID, client: Client?) -> Bool {
        guard !servers.contains(where: { $0.id == id }) else { return true }
        if let client { Task { await client.disconnect() } }
        try? ChatAPIKeyStore.setMCPOAuthState("", forServer: id)
        oauthDelegates[id] = nil
        return false
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
            if oauthDelegates[serverID]?.takeAuthError() != nil {
                status[serverID] = .needsAuth
                if let client = clients.removeValue(forKey: serverID) {
                    Task { await client.disconnect() }
                }
                return .error(MCPServerError.signInRequired.localizedDescription)
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
