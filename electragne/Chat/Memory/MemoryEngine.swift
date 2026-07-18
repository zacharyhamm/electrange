//
//  MemoryEngine.swift
//  electragne
//
//  MAGMA-lite long-term memory: one pool of nodes with temporal (array
//  order), entity (derived index), and semantic (stored neighbor) graph
//  views. Formation is one LLM extraction per exchange; retrieval is
//  reciprocal-rank fusion over vector/keyword/recency rankers plus one
//  hop of graph expansion. The causal graph, query-intent classification,
//  and beam search from the paper are deliberately deferred.
//

import Foundation
import Observation
import os

@Observable
final class MemoryEngine {
    private let store: MemoryStore
    private let embedder: any TextEmbedding
    private(set) var graph: MemoryGraph
    private var persistenceEnabled: Bool
    /// The entity graph: lowercased entity name → nodes mentioning it.
    private var entityIndex: [String: Set<UUID>] = [:]

    /// ponytail: similarity thresholds are uncalibrated guesses for
    /// NLEmbedding's range; tune against real chats if recall misbehaves.
    static let duplicateSimilarity: Float = 0.95
    static let neighborSimilarity: Float = 0.75
    static let retrievalFloor: Float = 0.6
    static let topK = 5
    private static let rrfK = 60.0

    init(
        store: MemoryStore = MemoryStore(),
        embedder: any TextEmbedding = NLTextEmbedder()
    ) {
        self.store = store
        self.embedder = embedder
        do {
            graph = try store.load()
            persistenceEnabled = true
        } catch {
            graph = MemoryGraph()
            persistenceEnabled = false
            Log.memory.error("Memory graph load failed; preserving existing file: \(error.localizedDescription)")
        }
        for node in graph.nodes where node.supersededAt == nil { indexEntities(of: node) }
    }

    // MARK: - Formation

    func ingest(
        userText: String,
        assistantText: String,
        chatID: UUID,
        context: [ChatMessage] = [],
        client: any ChatClient
    ) async {
        let extraction = await MemoryExtractor.extract(
            userText: userText,
            assistantText: assistantText,
            context: context,
            client: client
        )
        guard let extraction else { return }
        remember(extraction.ownerMemory, source: .owner, chatID: chatID)
        remember(extraction.assistantOutcome, source: .assistant, chatID: chatID)
    }

    private func remember(
        _ candidate: MemoryExtractor.Candidate?,
        source: MemorySource,
        chatID: UUID
    ) {
        guard let candidate, let summary = candidate.summary, !summary.isEmpty else { return }

        let facts = candidate.facts ?? []
        let entities = (candidate.entities ?? []).map { $0.lowercased() }
        let canonicalKey = source == .owner ? candidate.canonicalKey?.lowercased() : nil
        let canonicalValue = source == .owner ? candidate.canonicalValue?.lowercased() : nil
        let vector = embedder.vector(
            for: ([summary] + facts).joined(separator: "\n")
        ) ?? []

        if let canonicalKey, let canonicalValue,
           let oldIndex = graph.nodes.firstIndex(where: {
               $0.supersededAt == nil && $0.canonicalKey == canonicalKey
                   && $0.canonicalValue != canonicalValue
           }) {
            supersedeNode(at: oldIndex)
        }

        // A stable mutable-fact identity beats fuzzy similarity; otherwise
        // a near-identical memory refreshes the existing node.
        let nearest: (index: Int, similarity: Float)?
        if let canonicalKey, let canonicalValue {
            nearest = graph.nodes.firstIndex(where: {
                $0.supersededAt == nil && $0.canonicalKey == canonicalKey
                    && $0.canonicalValue == canonicalValue
            }).map { ($0, 1) }
        } else {
            nearest = nearestNode(to: vector)
        }
        if let nearest,
           nearest.similarity >= Self.duplicateSimilarity {
            // Assistant output is useful as a new outcome, but repetition is
            // never evidence that an existing memory became newer or truer.
            guard source == .owner else { return }
            var node = graph.nodes.remove(at: nearest.index)
            node.summary = summary
            if let topic = candidate.topic, !topic.isEmpty { node.topic = topic }
            node.timestamp = Date()
            node.mentionCount += 1
            node.source = .owner
            for fact in facts where !node.facts.contains(fact) { node.facts.append(fact) }
            for entity in entities where !node.entities.contains(entity) {
                node.entities.append(entity)
            }
            node.canonicalKey = canonicalKey ?? node.canonicalKey
            node.canonicalValue = canonicalValue ?? node.canonicalValue
            node.embedding = embedder.vector(
                for: ([node.summary] + node.facts).joined(separator: "\n")
            ) ?? []
            graph.nodes.append(node) // newest again; keeps the timestamp sort
            indexEntities(of: node)
            relinkNode(at: graph.nodes.index(before: graph.nodes.endIndex))
            save()
            return
        }

        var node = MemoryNode(
            id: UUID(),
            summary: summary,
            facts: facts,
            entities: entities,
            topic: candidate.topic ?? "",
            timestamp: Date(),
            firstSeen: Date(),
            mentionCount: 1,
            embedding: vector,
            semanticNeighbors: [],
            sourceChatID: chatID,
            source: source,
            canonicalKey: canonicalKey,
            canonicalValue: canonicalValue
        )
        if !vector.isEmpty {
            for i in graph.nodes.indices
            where graph.nodes[i].supersededAt == nil
                && memoryCosine(graph.nodes[i].embedding, vector) >= Self.neighborSimilarity {
                node.semanticNeighbors.append(graph.nodes[i].id)
                graph.nodes[i].semanticNeighbors.append(node.id)
            }
        }
        graph.nodes.append(node)
        indexEntities(of: node)
        save()
        Log.memory.info("Remembered: \(node.summary, privacy: .private)")
    }

    // MARK: - Retrieval

    /// RRF anchor fusion over vector, keyword, and recency rankers, then
    /// one hop of expansion via semantic neighbors and shared entities.
    func retrieve(query: String, includingSuperseded: Bool = false) -> [MemoryNode] {
        let nodes = graph.nodes.filter { includingSuperseded || $0.supersededAt == nil }
        guard !nodes.isEmpty else { return [] }
        let queryVector = embedder.vector(for: query) ?? []
        let terms = Self.terms(in: query)

        let sims = nodes.map { memoryCosine($0.embedding, queryVector) }
        let keywordHits = nodes.map { keywordScore($0, terms: terms) }

        // Only nodes resembling the query may anchor; recency alone never
        // qualifies a node, it only breaks ties among relevant ones.
        let relevant = nodes.indices.filter {
            sims[$0] >= Self.retrievalFloor || keywordHits[$0] > 0
        }
        guard !relevant.isEmpty else { return [] }

        var fused: [Int: Double] = [:]
        func fuse(_ ranking: [Int]) {
            for (rank, i) in ranking.enumerated() {
                fused[i, default: 0] += 1.0 / (Self.rrfK + Double(rank + 1))
            }
        }
        fuse(nodes.indices.sorted { sims[$0] > sims[$1] })
        fuse(nodes.indices.filter { keywordHits[$0] > 0 }
            .sorted { keywordHits[$0] > keywordHits[$1] })
        fuse(Array(nodes.indices.reversed())) // newest first

        let anchors = relevant
            .sorted { fused[$0] ?? 0 > fused[$1] ?? 0 }
            .prefix(Self.topK)

        // One hop out: neighbors join at half their anchor's score.
        var scored: [UUID: Double] = [:]
        for i in anchors { scored[nodes[i].id] = fused[i] ?? 0 }
        for i in anchors {
            let anchor = nodes[i]
            var neighborIDs = Set(anchor.semanticNeighbors)
            for entity in anchor.entities {
                neighborIDs.formUnion(entityIndex[entity] ?? [])
            }
            neighborIDs.remove(anchor.id)
            let half = (fused[i] ?? 0) / 2
            for id in neighborIDs { scored[id] = max(scored[id] ?? 0, half) }
        }

        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        return scored
            .sorted { $0.value > $1.value }
            .prefix(Self.topK)
            .compactMap { byID[$0.key] }
    }

    /// Retrieved memories linearized chronologically for prompt injection;
    /// nil when nothing relevant is stored.
    func contextBlock(for query: String) -> String? {
        let recalled = retrieve(query: query).sorted { $0.timestamp < $1.timestamp }
        guard !recalled.isEmpty else { return nil }
        let lines = recalled.map { node in
            let facts = node.facts.isEmpty ? "" : " (\(node.facts.joined(separator: "; ")))"
            return "[\(Self.dateFormatter.string(from: node.timestamp))] \(node.summary)\(facts)"
        }
        return "Relevant memories about the owner from past conversations:\n"
            + lines.joined(separator: "\n")
    }

    // MARK: - Internals

    private func nearestNode(to vector: [Float]) -> (index: Int, similarity: Float)? {
        guard !vector.isEmpty else { return nil }
        var best: (index: Int, similarity: Float)?
        for (i, node) in graph.nodes.enumerated() where node.supersededAt == nil {
            let similarity = memoryCosine(node.embedding, vector)
            if similarity > (best?.similarity ?? 0) { best = (i, similarity) }
        }
        return best
    }

    private func indexEntities(of node: MemoryNode) {
        for entity in node.entities {
            entityIndex[entity, default: []].insert(node.id)
        }
    }

    private func keywordScore(_ node: MemoryNode, terms: Set<String>) -> Int {
        guard !terms.isEmpty else { return 0 }
        let tokens = Self.tokens(in: ([node.summary, node.topic] + node.facts + node.entities)
            .joined(separator: " "))
        return terms.intersection(tokens).count
    }

    private static func terms(in query: String) -> Set<String> {
        tokens(in: query).subtracting(stopwords)
    }

    private static func tokens(in text: String) -> Set<String> {
        Set(text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 })
    }

    private static let stopwords: Set<String> = [
        "about", "and", "does", "for", "from", "have", "how", "please",
        "remember", "tell", "that", "the", "this", "what", "when", "where",
        "which", "who", "why", "with",
    ]

    private func supersedeNode(at index: Int) {
        let id = graph.nodes[index].id
        graph.nodes[index].supersededAt = Date()
        for entity in graph.nodes[index].entities { entityIndex[entity]?.remove(id) }
        for i in graph.nodes.indices { graph.nodes[i].semanticNeighbors.removeAll { $0 == id } }
        graph.nodes[index].semanticNeighbors.removeAll()
    }

    private func relinkNode(at index: Int) {
        let id = graph.nodes[index].id
        for i in graph.nodes.indices { graph.nodes[i].semanticNeighbors.removeAll { $0 == id } }
        graph.nodes[index].semanticNeighbors.removeAll()
        guard !graph.nodes[index].embedding.isEmpty else { return }
        for i in graph.nodes.indices where i != index && graph.nodes[i].supersededAt == nil
            && memoryCosine(graph.nodes[i].embedding, graph.nodes[index].embedding)
                >= Self.neighborSimilarity {
            graph.nodes[index].semanticNeighbors.append(graph.nodes[i].id)
            graph.nodes[i].semanticNeighbors.append(id)
        }
    }

    private func save() {
        guard persistenceEnabled else { return }
        do {
            try store.save(graph)
        } catch {
            Log.memory.error("Memory graph save failed; preserving previous file: \(error.localizedDescription)")
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
