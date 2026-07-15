import AppKit
import Foundation

nonisolated struct ToolConfirmationDetails: Equatable, Sendable {
    let title: String
    let primaryText: String
    let details: [(label: String, value: String)]
    let actionLabel: String

    static func == (lhs: ToolConfirmationDetails, rhs: ToolConfirmationDetails) -> Bool {
        lhs.title == rhs.title
            && lhs.primaryText == rhs.primaryText
            && lhs.details.elementsEqual(rhs.details, by: ==)
            && lhs.actionLabel == rhs.actionLabel
    }
}

nonisolated enum DesktopToolRequest: Equatable, Sendable {
    case openApp(name: String)
    case openURL(URL)
    case findFiles(query: String)
    case revealInFinder(fileID: String)

    init(toolCall: ChatToolCall) throws {
        func requiredString(_ key: String) throws -> String {
            let value = toolCall.arguments[key]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty else { throw DesktopToolError.missingArgument(key) }
            return value
        }

        switch toolCall.name {
        case "open_app":
            self = .openApp(name: try requiredString("name"))
        case "open_url":
            let raw = try requiredString("url")
            guard let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  url.host != nil else {
                throw DesktopToolError.invalidWebURL(raw)
            }
            self = .openURL(url)
        case "find_files":
            self = .findFiles(query: try requiredString("query"))
        case "reveal_in_finder":
            self = .revealInFinder(fileID: try requiredString("fileID"))
        default:
            throw DesktopToolError.unsupportedTool(toolCall.name)
        }
    }

    var confirmation: ToolConfirmationDetails? {
        switch self {
        case .openApp(let name):
            return ToolConfirmationDetails(
                title: "Open this app?",
                primaryText: name,
                details: [],
                actionLabel: "Open"
            )
        case .openURL(let url):
            return ToolConfirmationDetails(
                title: "Open this website?",
                primaryText: url.absoluteString,
                details: [("Domain", url.host ?? "Unknown")],
                actionLabel: "Open"
            )
        case .revealInFinder:
            return ToolConfirmationDetails(
                title: "Show this item in Finder?",
                primaryText: "A file from the latest search",
                details: [],
                actionLabel: "Show"
            )
        case .findFiles:
            return nil
        }
    }

    var isFileSearch: Bool {
        guard case .findFiles = self else { return false }
        return true
    }
}

nonisolated enum DesktopToolError: Error, Equatable {
    case unsupportedTool(String)
    case missingArgument(String)
    case invalidWebURL(String)
}

nonisolated struct FileSearchMatch: Equatable, Sendable {
    let url: URL
    let scopeName: String
    let relativePath: String
    let isDirectory: Bool
    let modifiedAt: Date?
    let score: Int
}

nonisolated struct FileSearchOutcome: Equatable, Sendable {
    let matches: [FileSearchMatch]
    let visitedItemCount: Int
    let wasTruncated: Bool
}

nonisolated enum ApplicationLocator {
    private static let bundleIdentifiers: [String: String] = [
        "app store": "com.apple.AppStore",
        "calculator": "com.apple.calculator",
        "calendar": "com.apple.iCal",
        "contacts": "com.apple.AddressBook",
        "facetime": "com.apple.FaceTime",
        "finder": "com.apple.finder",
        "firefox": "org.mozilla.firefox",
        "google chrome": "com.google.Chrome",
        "mail": "com.apple.mail",
        "maps": "com.apple.Maps",
        "messages": "com.apple.MobileSMS",
        "music": "com.apple.Music",
        "notes": "com.apple.Notes",
        "photos": "com.apple.Photos",
        "preview": "com.apple.Preview",
        "reminders": "com.apple.reminders",
        "safari": "com.apple.Safari",
        "system preferences": "com.apple.systempreferences",
        "system settings": "com.apple.systempreferences",
        "terminal": "com.apple.Terminal",
        "tv": "com.apple.TV",
        "visual studio code": "com.microsoft.VSCode",
        "vs code": "com.microsoft.VSCode",
        "xcode": "com.apple.dt.Xcode",
    ]

    static func bundleIdentifier(for name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(".") && !trimmed.lowercased().hasSuffix(".app") {
            return trimmed
        }
        return bundleIdentifiers[normalizedName(trimmed)?.lowercased() ?? ""]
    }

    static func candidateURLs(for name: String, homeDirectory: URL) -> [URL] {
        guard let appName = normalizedName(name) else { return [] }
        let directories = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            homeDirectory.appendingPathComponent("Applications", isDirectory: true),
        ]
        return directories.map {
            $0.appendingPathComponent(appName, isDirectory: true).appendingPathExtension("app")
        }
    }

    private static func normalizedName(_ name: String) -> String? {
        var result = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.lowercased().hasSuffix(".app") { result.removeLast(4) }
        guard !result.isEmpty,
              result != ".",
              result != "..",
              !result.contains("/"),
              !result.contains(":"),
              !result.contains("\\") else { return nil }
        return result
    }
}

nonisolated enum FileSearchEngine {
    static let defaultMaxResults = 12
    static let maxVisitedItemsPerRoot = 50_000

    static func search(
        query: String,
        roots: [URL],
        maxResults: Int = defaultMaxResults,
        visitLimitPerRoot: Int = maxVisitedItemsPerRoot
    ) -> [FileSearchMatch] {
        searchWithDiagnostics(
            query: query,
            roots: roots,
            maxResults: maxResults,
            visitLimitPerRoot: visitLimitPerRoot
        ).matches
    }

    static func searchWithDiagnostics(
        query: String,
        roots: [URL],
        maxResults: Int = defaultMaxResults,
        visitLimitPerRoot: Int = maxVisitedItemsPerRoot
    ) -> FileSearchOutcome {
        let terms = query
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \Character.isWhitespace)
            .map(String.init)
        guard !terms.isEmpty, maxResults > 0, visitLimitPerRoot > 0 else {
            return FileSearchOutcome(matches: [], visitedItemCount: 0, wasTruncated: false)
        }

        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isPackageKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
        ]
        let keySet = Set(keys)
        var matches: [FileSearchMatch] = []
        var totalVisited = 0
        var wasTruncated = false

        for root in roots {
            var pendingDirectories = [root]
            var directoryIndex = 0
            var visited = 0
            while directoryIndex < pendingDirectories.count, visited < visitLimitPerRoot {
                let directory = pendingDirectories[directoryIndex]
                directoryIndex += 1
                guard let children = try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for url in children.sorted(by: traversalOrder) {
                    guard visited < visitLimitPerRoot else {
                        wasTruncated = true
                        break
                    }
                    visited += 1
                    totalVisited += 1
                    guard let values = try? url.resourceValues(forKeys: keySet),
                          values.isRegularFile == true || values.isDirectory == true else { continue }

                    if values.isDirectory == true,
                       values.isPackage != true,
                       values.isSymbolicLink != true {
                        pendingDirectories.append(url)
                    }

                    let relative = relativePath(for: url, under: root)
                    let foldedPath = relative.folding(
                        options: [.caseInsensitive, .diacriticInsensitive], locale: .current
                    )
                    guard terms.allSatisfy({ foldedPath.contains($0) }) else { continue }

                    let searchableName = values.isRegularFile == true
                        ? url.deletingPathExtension().lastPathComponent
                        : url.lastPathComponent
                    let foldedName = searchableName.folding(
                        options: [.caseInsensitive, .diacriticInsensitive], locale: .current
                    )
                    let joined = terms.joined(separator: " ")
                    let score: Int
                    if foldedName == joined { score = 300 }
                    else if foldedName.hasPrefix(joined) { score = 200 }
                    else if terms.allSatisfy({ foldedName.contains($0) }) { score = 100 }
                    else { score = 10 }

                    matches.append(FileSearchMatch(
                        url: url, scopeName: root.lastPathComponent, relativePath: relative,
                        isDirectory: values.isDirectory == true,
                        modifiedAt: values.contentModificationDate, score: score
                    ))
                }
            }
            if directoryIndex < pendingDirectories.count { wasTruncated = true }
        }

        let ranked = Array(matches.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.modifiedAt != rhs.modifiedAt {
                return (lhs.modifiedAt ?? .distantPast) > (rhs.modifiedAt ?? .distantPast)
            }
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }.prefix(maxResults))
        return FileSearchOutcome(
            matches: ranked,
            visitedItemCount: totalVisited,
            wasTruncated: wasTruncated
        )
    }

    private static func traversalOrder(_ lhs: URL, _ rhs: URL) -> Bool {
        let priority: [String: Int] = [
            "desktop": 0, "documents": 0, "downloads": 0, "movies": 0,
            "music": 0, "pictures": 0, "public": 0, "library": 2,
        ]
        let lhsPriority = priority[lhs.lastPathComponent.lowercased()] ?? 1
        let rhsPriority = priority[rhs.lastPathComponent.lowercased()] ?? 1
        if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
        return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
    }

    private static func relativePath(for url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

nonisolated struct FileSearchScope: Equatable, Identifiable, Sendable {
    let id: UUID
    let url: URL
}

@MainActor
final class FileSearchScopeStore {
    static let shared = FileSearchScopeStore()
    nonisolated static let storageKey = "fileSearchSecurityScopedBookmarks"

    private struct Bookmark: Codable {
        let id: UUID
        let data: Data
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func scopes() -> [FileSearchScope] {
        bookmarks().compactMap { bookmark in
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmark.data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) else { return nil }
            if stale { try? replaceBookmark(id: bookmark.id, url: url) }
            return FileSearchScope(id: bookmark.id, url: url)
        }
    }

    func addFolder(_ url: URL) throws {
        var current = bookmarks()
        let existingPaths = Set(scopes().map { $0.url.standardizedFileURL.path })
        guard !existingPaths.contains(url.standardizedFileURL.path) else { return }
        let data = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        current.append(Bookmark(id: UUID(), data: data))
        save(current)
    }

    func removeScope(id: UUID) {
        save(bookmarks().filter { $0.id != id })
    }

    private func replaceBookmark(id: UUID, url: URL) throws {
        let data = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        save(bookmarks().map { $0.id == id ? Bookmark(id: id, data: data) : $0 })
    }

    private func bookmarks() -> [Bookmark] {
        guard let data = defaults.data(forKey: Self.storageKey) else { return [] }
        return (try? JSONDecoder().decode([Bookmark].self, from: data)) ?? []
    }

    private func save(_ bookmarks: [Bookmark]) {
        defaults.set(try? JSONEncoder().encode(bookmarks), forKey: Self.storageKey)
    }
}

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
            return Self.result(status: "opened", message: "Opened \(url.absoluteString).")
        case .findFiles(let query):
            return await findFiles(query: query)
        case .revealInFinder(let fileID):
            guard let url = latestSearchResults[fileID] else {
                return .error("That file result is no longer available. Search for it again first.")
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return Self.result(status: "revealed", message: "Revealed \(url.lastPathComponent) in Finder.")
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
            return Self.result(status: "opened", message: "Opened \(appURL.deletingPathExtension().lastPathComponent).")
        } catch {
            return .error("The app could not be opened: \(error.localizedDescription)")
        }
    }

    private func findFiles(query: String) async -> ChatToolResult {
        let scopes = scopeStore.scopes()
        guard !scopes.isEmpty else {
            return Self.result(
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

    private static func result(status: String, message: String) -> ChatToolResult {
        ChatToolResult(response: [
            "status": .string(status),
            "message": .string(message),
        ])
    }
}
