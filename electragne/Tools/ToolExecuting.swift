//
//  ToolExecuting.swift
//  electragne
//
//  The single execution contract every tool family exposes to the router:
//  prepare validates the call and returns an optional confirmation plus a
//  ready-to-run action. Local families prepare synchronously; Google
//  families fetch whatever the confirmation card needs first.
//

import Foundation

@MainActor
struct PreparedToolAction {
    /// Shown to the owner before execute() runs; nil executes immediately.
    let confirmation: ToolConfirmationDetails?
    let execute: @MainActor () async -> ChatToolResult
}

@MainActor
protocol ToolExecuting: AnyObject {
    /// Validates the call, throwing a LocalizedError for bad arguments.
    func prepare(_ call: ChatToolCall) async throws -> PreparedToolAction
}

/// The one adapter between the router's ToolExecuting contract and a tool
/// family's executor; the family-specific parse/confirm/execute wiring is
/// supplied as closures (see ChatToolRouter).
@MainActor
final class ToolAdapter: ToolExecuting {
    private let prepareCall: @MainActor (ChatToolCall) async throws -> PreparedToolAction

    init(_ prepare: @escaping @MainActor (ChatToolCall) async throws -> PreparedToolAction) {
        prepareCall = prepare
    }

    /// A family whose prepare is synchronous: parse the request, ask the
    /// executor for a confirmation, and run it.
    static func sync<Request>(
        parse: @escaping @MainActor (ChatToolCall) throws -> Request,
        confirm: @escaping @MainActor (Request) -> ToolConfirmationDetails?,
        execute: @escaping @MainActor (Request) async -> ChatToolResult
    ) -> ToolAdapter {
        ToolAdapter { call in
            let request = try parse(call)
            return PreparedToolAction(
                confirmation: confirm(request),
                execute: { await execute(request) }
            )
        }
    }

    func prepare(_ call: ChatToolCall) async throws -> PreparedToolAction {
        try await prepareCall(call)
    }
}

// MARK: - Web search

/// Runs the self-hosted SearXNG web search through the shared tool router.
@MainActor
final class WebSearchExecutor: ToolExecuting {
    private let webSearch: SearXNGSearch
    init(webSearch: SearXNGSearch = SearXNGSearch()) { self.webSearch = webSearch }

    func prepare(_ call: ChatToolCall) async throws -> PreparedToolAction {
        let query = call.arguments["query"]?.stringValue ?? ""
        let category: SearXNGSearch.Category = call.name == "image_search" ? .images : .general
        let webSearch = webSearch
        return PreparedToolAction(confirmation: nil, execute: {
            do {
                let output = try await webSearch.results(query: query, category: category)
                return ChatToolResult(response: [
                    "status": .string("ok"),
                    "results": .string(output.text),
                ], imageBatch: ChatImageBatch(
                    images: output.images,
                    presentation: category == .images ? .gallery : .thumbnails
                ))
            } catch ChatProviderError.invalidEndpoint {
                return .error("Web search needs a SearXNG endpoint. Set it in Electragne Settings.")
            } catch {
                // Let the model explain the failure instead of aborting.
                return .error("Web search failed: \(error.localizedDescription)")
            }
        })
    }
}
