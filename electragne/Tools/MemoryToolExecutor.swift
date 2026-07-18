//
//  MemoryToolExecutor.swift
//  electragne
//
//  Read-only lookup into the memory graph for the recall_memory tool;
//  never needs confirmation.
//

import Foundation

final class MemoryToolExecutor: ToolExecuting {
    private let engine: MemoryEngine
    init(engine: MemoryEngine) { self.engine = engine }

    func prepare(_ call: ChatToolCall) async throws -> PreparedToolAction {
        let query = call.arguments["query"]?.stringValue ?? ""
        let engine = engine
        return PreparedToolAction(confirmation: nil, execute: {
            let recalled = engine.retrieve(query: query)
            guard !recalled.isEmpty else {
                return .make(status: "ok", message: "No stored memories matched ‘\(query)’.")
            }
            let lines = recalled.map { node in
                var line = "- \(node.summary)"
                if !node.facts.isEmpty {
                    line += " (\(node.facts.joined(separator: "; ")))"
                }
                return line
            }
            return ChatToolResult(response: [
                "status": .string("ok"),
                "memories": .string(lines.joined(separator: "\n")),
            ])
        })
    }
}
