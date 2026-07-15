//
//  FileSearchScopeStore.swift
//  electragne
//
//  Security-scoped bookmark persistence for user-approved search folders.
//

import Foundation

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
