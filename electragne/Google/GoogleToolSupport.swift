//
//  GoogleToolSupport.swift
//  electragne
//
//  Helpers shared by the Gmail and Calendar tool services.
//

import Foundation

enum GoogleToolSupport {
    // Shared coders for Google API payloads. MainActor-isolated (project
    // default), matching the @MainActor services that use them.
    static let decoder = JSONDecoder()
    static let encoder = JSONEncoder()

    /// Single-line preview used in confirmation cards.
    nonisolated static func preview(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\n", with: " ")
        return normalized.count > 180 ? String(normalized.prefix(177)) + "…" : normalized
    }

    /// Decodes a Google response, mapping any decode failure to the given
    /// tool error (the Calendar "unreadable response" idiom).
    static func decode<T: Decodable>(_ type: T.Type, from data: Data, orThrow error: Error) throws -> T {
        guard let value = try? decoder.decode(type, from: data) else { throw error }
        return value
    }
}
