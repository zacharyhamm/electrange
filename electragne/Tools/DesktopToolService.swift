//
//  DesktopToolService.swift
//  electragne
//
//  Desktop tool executor: open apps/URLs, file search over approved
//  scopes, reveal in Finder.
//

import AppKit
import Foundation

@MainActor
protocol DesktopToolExecuting {
    func confirmationDetails(for request: DesktopToolRequest) -> ToolConfirmationDetails?
    func execute(_ request: DesktopToolRequest) async -> ChatToolResult
}

@MainActor
final class DesktopToolService: DesktopToolExecuting {
    private let scopeStore: FileSearchScopeStore
    private var latestSearchResults: [String: URL] = [:]

    init(scopeStore: FileSearchScopeStore? = nil) {
        self.scopeStore = scopeStore ?? .shared
    }

    func confirmationDetails(for request: DesktopToolRequest) -> ToolConfirmationDetails? {
        guard case .revealInFinder(let fileID) = request else { return request.confirmation }
        guard let url = latestSearchResults[fileID] else { return request.confirmation }
        return ToolConfirmationDetails(
            title: "Show this item in Finder?",
            primaryText: url.lastPathComponent,
            details: [("Folder", url.deletingLastPathComponent().path)],
            actionLabel: "Show"
        )
    }

    func execute(_ request: DesktopToolRequest) async -> ChatToolResult {
        switch request {
        case .openApp(let name):
            return await openApp(named: name)
        case .openURL(let url):
            guard NSWorkspace.shared.open(url) else {
                return .error("macOS could not open \(url.absoluteString).")
            }
            return .make(status: "opened", message: "Opened \(url.absoluteString).")
        case .findFiles(let query):
            return await findFiles(query: query)
        case .revealInFinder(let fileID):
            guard let url = latestSearchResults[fileID] else {
                return .error("That file result is no longer available. Search for it again first.")
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return .make(status: "revealed", message: "Revealed \(url.lastPathComponent) in Finder.")
        }
    }

    private func openApp(named name: String) async -> ChatToolResult {
        let workspace = NSWorkspace.shared
        var appURL: URL?
        if let bundleIdentifier = ApplicationLocator.bundleIdentifier(for: name) {
            appURL = workspace.urlsForApplications(withBundleIdentifier: bundleIdentifier).first
        }
        if appURL == nil {
            appURL = ApplicationLocator.candidateURLs(
                for: name,
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser
            ).first { FileManager.default.fileExists(atPath: $0.path) }
        }
        guard let appURL else { return .error("No installed app named ‘\(name)’ was found.") }

        do {
            _ = try await workspace.openApplication(
                at: appURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
            return .make(status: "opened", message: "Opened \(appURL.deletingPathExtension().lastPathComponent).")
        } catch {
            return .error("The app could not be opened: \(error.localizedDescription)")
        }
    }

    private func findFiles(query: String) async -> ChatToolResult {
        let scopes = scopeStore.scopes()
        guard !scopes.isEmpty else {
            return .make(
                status: "needs_setup",
                message: "No file-search folders are configured. Add one in Electragne Settings."
            )
        }

        let access = scopes.map { scope in
            (scope: scope, didStart: scope.url.startAccessingSecurityScopedResource())
        }
        let accessible = access.filter {
            $0.didStart || FileManager.default.isReadableFile(atPath: $0.scope.url.path)
        }
        defer { access.filter(\.didStart).forEach { $0.scope.url.stopAccessingSecurityScopedResource() } }
        guard !accessible.isEmpty else {
            return .error("Electragne no longer has access to its configured search folders.")
        }

        let roots = accessible.map(\.scope.url)
        let outcome = await Task.detached {
            FileSearchEngine.searchWithDiagnostics(query: query, roots: roots)
        }.value
        latestSearchResults = [:]

        let values: [ChatToolValue] = outcome.matches.map { match in
            let id = UUID().uuidString
            latestSearchResults[id] = match.url
            return .object([
                "id": .string(id),
                "name": .string(match.url.lastPathComponent),
                "scope": .string(match.scopeName),
                "location": .string(match.relativePath),
                "kind": .string(match.isDirectory ? "folder" : "file"),
            ])
        }
        let message: String
        if values.isEmpty, outcome.wasTruncated {
            message = "No matches were found in the first \(outcome.visitedItemCount) items. The approved folder is very large, so narrower search folders may improve coverage."
        } else if values.isEmpty {
            message = "No matching files or folders were found."
        } else {
            message = "Found \(values.count) matching items."
        }
        return ChatToolResult(response: [
            "status": .string(values.isEmpty ? "not_found" : "found"),
            "query": .string(query),
            "count": .number(Double(values.count)),
            "searchedItemCount": .number(Double(outcome.visitedItemCount)),
            "truncated": .bool(outcome.wasTruncated),
            "results": .array(values),
            "message": .string(message),
        ])
    }

}
