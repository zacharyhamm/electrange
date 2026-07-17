//
//  MCPToolExecutor.swift
//  electragne
//
//  Routes mcp__server__tool calls to the right MCP server, gated by the
//  per-tool policy from Settings: allowed runs silently, ask shows the
//  shared confirmation card, forbidden never runs.
//

import Foundation

nonisolated enum MCPToolError: LocalizedError {
    case unknownTool(String)
    case forbidden(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            "‘\(name)’ is not a connected MCP tool."
        case .forbidden(let name):
            "The owner has forbidden the MCP tool ‘\(name)’ in Electragne Settings."
        }
    }
}

@MainActor
final class MCPToolExecutor: ToolExecuting {
    private let callTool: (MCPToolDescriptor, [String: ChatToolValue]) async -> ChatToolResult
    private let defaults: UserDefaults

    init(
        defaults: UserDefaults = .standard,
        callTool: @escaping @MainActor (MCPToolDescriptor, [String: ChatToolValue])
            async -> ChatToolResult = { await MCPServerManager.shared.callTool(descriptor: $0, arguments: $1) }
    ) {
        self.defaults = defaults
        self.callTool = callTool
    }

    func prepare(_ call: ChatToolCall) async throws -> PreparedToolAction {
        guard let descriptor = MCPToolCatalog.descriptor(named: call.name) else {
            throw MCPToolError.unknownTool(call.name)
        }
        let policy = MCPToolCatalog.policy(for: descriptor.namespacedName, in: defaults)
        guard policy != .forbidden else {
            throw MCPToolError.forbidden(descriptor.toolName)
        }
        let callTool = callTool
        return PreparedToolAction(
            confirmation: policy == .ask
                ? Self.confirmationDetails(for: descriptor, arguments: call.arguments)
                : nil,
            execute: { await callTool(descriptor, call.arguments) }
        )
    }

    static func confirmationDetails(
        for descriptor: MCPToolDescriptor,
        arguments: [String: ChatToolValue]
    ) -> ToolConfirmationDetails {
        let details = arguments.sorted { $0.key < $1.key }.map { key, value in
            (label: key, value: Self.displayValue(value))
        }
        return ToolConfirmationDetails(
            title: "Run MCP tool?",
            primaryText: "\(descriptor.serverName): \(descriptor.toolName)",
            details: details,
            actionLabel: "Run"
        )
    }

    private static func displayValue(_ value: ChatToolValue) -> String {
        switch value {
        case .string(let string): string
        case .number(let number):
            // Int(exactly:) is nil for non-integral or out-of-range values,
            // so a model-supplied 1e30 cannot trap.
            Int(exactly: number).map(String.init) ?? String(number)
        case .bool(let bool): String(bool)
        case .null: "null"
        case .object, .array:
            (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
    }
}
