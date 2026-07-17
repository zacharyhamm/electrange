//
//  MCPToolCatalog.swift
//  electragne
//
//  Runtime-discovered MCP tools: server configs, per-tool permission
//  policies, and the live tool snapshot the chat client reads when building
//  each request's function declarations.
//

import Foundation
import MCP

/// One remote Streamable-HTTP MCP server from Settings. The bearer token
/// lives in the Keychain (ChatAPIKeyStore) keyed by this server's id.
nonisolated struct MCPServerConfig: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var url: URL
}

/// What happens when the model calls an MCP tool.
nonisolated enum MCPToolPolicy: String, CaseIterable, Sendable {
    case allowed
    case ask
    case forbidden

    var label: String {
        switch self {
        case .allowed: "Allowed"
        case .ask: "Ask"
        case .forbidden: "Forbidden"
        }
    }
}

/// One discovered MCP tool, namespaced so Gemini function calls round-trip
/// back to the right server without re-parsing the name.
nonisolated struct MCPToolDescriptor: Equatable, Sendable {
    let serverID: UUID
    let serverName: String
    let toolName: String
    let namespacedName: String
    let description: String
    let inputSchema: ChatToolValue

    init(
        serverID: UUID,
        serverName: String,
        toolName: String,
        description: String,
        inputSchema: ChatToolValue
    ) {
        self.serverID = serverID
        self.serverName = serverName
        self.toolName = toolName
        self.namespacedName = MCPToolCatalog.namespacedName(server: serverName, tool: toolName)
        self.description = description
        self.inputSchema = MCPToolCatalog.sanitizeSchema(inputSchema)
    }
}

/// The process-wide snapshot of discovered MCP tools plus their policies.
/// Written by MCPServerManager, read per request by GeminiClient and per
/// call by MCPToolExecutor.
nonisolated enum MCPToolCatalog {
    static let toolPoliciesKey = "mcpToolPolicies"

    private static let snapshot = Snapshot()

    /// Gemini function names allow [a-zA-Z0-9_.-], max 64 characters.
    static func namespacedName(server: String, tool: String) -> String {
        let sanitizedTool = tool.map { character in
            character.isASCII && (character.isLetter || character.isNumber
                || character == "_" || character == "." || character == "-")
                ? character : "_"
        }
        // ponytail: 64-char truncation can collide; add a numeric suffix if a real server ever does.
        return String("\(namespacePrefix(server: server))\(String(sanitizedTool))".prefix(64))
    }

    /// The shared per-server prefix of every namespacedName; also the unit of
    /// add-time collision checks and policy cleanup.
    static func namespacePrefix(server: String) -> String {
        let sanitized = server.lowercased().map { character in
            character.isASCII && (character.isLetter || character.isNumber) ? character : "_"
        }
        return "mcp__\(String(sanitized))__"
    }

    static func setTools(_ tools: [MCPToolDescriptor], forServer id: UUID) {
        snapshot.set(tools, forServer: id)
    }

    static func removeServer(_ id: UUID) {
        snapshot.set(nil, forServer: id)
    }

    static func descriptor(named name: String) -> MCPToolDescriptor? {
        snapshot.all().first { $0.namespacedName == name }
    }

    /// Everything the model may see: forbidden tools are filtered out so it
    /// cannot plan around them.
    static func offeredTools(in defaults: UserDefaults = .standard) -> [MCPToolDescriptor] {
        snapshot.all().filter { policy(for: $0.namespacedName, in: defaults) != .forbidden }
    }

    static func policy(
        for namespacedName: String,
        in defaults: UserDefaults = .standard
    ) -> MCPToolPolicy {
        let stored = defaults.dictionary(forKey: toolPoliciesKey) as? [String: String]
        return stored?[namespacedName].flatMap(MCPToolPolicy.init(rawValue:)) ?? .ask
    }

    static func setPolicy(
        _ policy: MCPToolPolicy,
        for namespacedName: String,
        in defaults: UserDefaults = .standard
    ) {
        var stored = (defaults.dictionary(forKey: toolPoliciesKey) as? [String: String]) ?? [:]
        stored[namespacedName] = policy == .ask ? nil : policy.rawValue
        defaults.set(stored, forKey: toolPoliciesKey)
    }

    /// Prefix-scoped so removal works even when the server never connected
    /// this session and no descriptors exist.
    static func removePolicies(namespacePrefix: String, in defaults: UserDefaults = .standard) {
        var stored = (defaults.dictionary(forKey: toolPoliciesKey) as? [String: String]) ?? [:]
        for key in stored.keys where key.hasPrefix(namespacePrefix) { stored[key] = nil }
        defaults.set(stored, forKey: toolPoliciesKey)
    }

    /// Schema keys Gemini's function declarations accept; anything else
    /// (e.g. $ref, oneOf) fails the entire generate request.
    private static let geminiSchemaKeys: Set<String> = [
        "type", "format", "title", "description", "nullable", "enum",
        "items", "properties", "required", "minimum", "maximum",
        "minItems", "maxItems", "minLength", "maxLength",
        "minProperties", "maxProperties", "pattern", "example",
        "anyOf", "default", "propertyOrdering",
    ]

    /// Keeps only the Gemini-supported subset of JSON Schema, recursing into
    /// the positions that hold nested schemas.
    static func sanitizeSchema(_ raw: ChatToolValue) -> ChatToolValue {
        guard case .object(let object) = raw else { return raw }
        var cleaned: [String: ChatToolValue] = [:]
        for (key, value) in object where geminiSchemaKeys.contains(key) {
            switch key {
            case "items":
                cleaned[key] = sanitizeSchema(value)
            case "anyOf":
                guard case .array(let schemas) = value else { continue }
                cleaned[key] = .array(schemas.map(sanitizeSchema))
            case "properties":
                // Keys here are property names, not schema keywords.
                guard case .object(let properties) = value else { continue }
                cleaned[key] = .object(properties.mapValues(sanitizeSchema))
            default:
                cleaned[key] = value
            }
        }
        return .object(cleaned)
    }

    private final class Snapshot: @unchecked Sendable {
        private let lock = NSLock()
        private var tools: [UUID: [MCPToolDescriptor]] = [:]

        func set(_ new: [MCPToolDescriptor]?, forServer id: UUID) {
            lock.lock()
            tools[id] = new
            lock.unlock()
        }

        func all() -> [MCPToolDescriptor] {
            lock.lock()
            defer { lock.unlock() }
            return tools.sorted { $0.key.uuidString < $1.key.uuidString }.flatMap(\.value)
        }
    }
}

// MARK: - MCP SDK bridging

extension MCPToolCatalog {
    /// MCP.Value and ChatToolValue encode to identical JSON, so a round-trip
    /// is the whole conversion.
    static func chatToolValue(_ value: Value) -> ChatToolValue {
        (try? JSONDecoder().decode(ChatToolValue.self, from: JSONEncoder().encode(value)))
            ?? .null
    }

    static func mcpValue(_ value: ChatToolValue) -> Value {
        (try? JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))) ?? .null
    }

    /// Flattens an MCP tool-result content array into the status+message
    /// shape every other tool feeds back to the model. Non-text content
    /// becomes a placeholder; Gemini functionResponse is JSON-only.
    static func result(from content: [Tool.Content], isError: Bool?) -> ChatToolResult {
        let text = content.map { item -> String in
            switch item {
            case .text(let text, _, _): text
            case .image(_, let mimeType, _, _): "[image: \(mimeType)]"
            case .audio(_, let mimeType, _, _): "[audio: \(mimeType)]"
            case .resource(let resource, _, _): resource.text ?? "[resource: \(resource.uri)]"
            case .resourceLink(let uri, let name, _, _, _, _): "[resource link: \(name) \(uri)]"
            }
        }.joined(separator: "\n")
        return .make(status: isError == true ? "error" : "ok", message: text)
    }
}
