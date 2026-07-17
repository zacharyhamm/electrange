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
    case failed(String)
}

nonisolated enum MCPServerError: LocalizedError {
    case notConnected(String)

    var errorDescription: String? {
        switch self {
        case .notConnected(let server):
            "The MCP server ‘\(server)’ is not connected. Check Electragne Settings → MCP."
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
    private var refreshing: Set<UUID> = []

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
        MCPToolCatalog.removeServer(id)
        tools[id] = nil
        status[id] = nil
        if let client = clients.removeValue(forKey: id) {
            Task { await client.disconnect() }
        }
    }

    func refresh(_ id: UUID) async {
        guard let config = servers.first(where: { $0.id == id }),
              !refreshing.contains(id) else { return }
        refreshing.insert(id)
        defer { refreshing.remove(id) }
        status[id] = .connecting
        if let old = clients.removeValue(forKey: id) { await old.disconnect() }
        var client: Client?
        do {
            let connected = try await connect(config)
            client = connected
            let descriptors = try await discoverTools(from: connected, config: config)
            clients[id] = connected
            tools[id] = descriptors
            MCPToolCatalog.setTools(descriptors, forServer: id)
            status[id] = .connected(toolCount: descriptors.count)
        } catch {
            await client?.disconnect()
            tools[id] = nil
            MCPToolCatalog.removeServer(id)
            status[id] = .failed(error.localizedDescription)
        }
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
            throw MCPServerError.notConnected(config.name)
        }
        return client
    }

    private func connect(_ config: MCPServerConfig) async throws -> Client {
        let token = ChatAPIKeyStore.mcpToken(forServer: config.id)
        let transport = HTTPClientTransport(
            endpoint: config.url,
            streaming: false,
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
