//
//  MemoryStore.swift
//  electragne
//
//  MAGMA-lite memory graph persistence. One pool of nodes carries every
//  graph view: temporal order is the array's timestamp sort, entity edges
//  are derived from each node's entity names, and semantic edges are the
//  stored neighbor IDs.
//

import Foundation

nonisolated enum MemorySource: String, Codable, Sendable {
    case owner
    case assistant
}

/// One remembered fact-cluster distilled from a single chat exchange.
nonisolated struct MemoryNode: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var summary: String
    var facts: [String]
    /// Lowercased entity names; the entity graph is an index over these.
    var entities: [String]
    var topic: String
    /// Last mention; bumped when a near-duplicate memory merges in.
    var timestamp: Date
    let firstSeen: Date
    var mentionCount: Int
    /// Unit-length sentence embedding, so cosine similarity is a dot
    /// product. Empty when embedding was unavailable.
    var embedding: [Float]
    var semanticNeighbors: [UUID]
    let sourceChatID: UUID
    /// Nil only for graphs written before source-aware extraction.
    var source: MemorySource? = nil
}

nonisolated struct MemoryGraph: Codable, Sendable {
    /// Kept sorted by timestamp ascending — this ordering IS the temporal graph.
    var nodes: [MemoryNode] = []
}

/// Persists the whole memory graph as one JSON file, mirroring ChatStore.
/// ponytail: whole-file rewrite per ingest + in-RAM linear scans; revisit
/// (SQLite / inverted index) if the node count ever nears ~100k.
struct MemoryStore {
    var directory: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("electragne/memory", isDirectory: true)
    }()

    private var fileURL: URL { directory.appendingPathComponent("graph.json") }

    func load() -> MemoryGraph {
        guard let data = try? Data(contentsOf: fileURL),
              let graph = try? Self.decoder.decode(MemoryGraph.self, from: data) else {
            return MemoryGraph()
        }
        return graph
    }

    func save(_ graph: MemoryGraph) {
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        guard let data = try? Self.encoder.encode(graph) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
