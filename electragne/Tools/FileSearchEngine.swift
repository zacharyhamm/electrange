//
//  FileSearchEngine.swift
//  electragne
//
//  Bounded breadth-first filename search under user-approved roots.
//

import Foundation

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
