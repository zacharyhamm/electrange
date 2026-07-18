import Foundation
import Testing
@testable import electragne

struct MemoryEngineTests {
    @Test func ingestStoresANodeWithEntitiesAndNeighbors() async {
        let (engine, embedder) = makeEngine()
        embedder.vectors["Owner's sister Mara is getting married in October"] = [1, 0, 0]
        await engine.ingest(
            userText: "my sister Mara is getting married in October",
            assistantText: "how exciting!",
            chatID: UUID(),
            client: CannedChatClient(reply: #"""
                {"ownerMemory": {
                 "summary": "Owner's sister Mara is getting married in October",
                 "topic": "family", "entities": ["Mara", "sister"]},
                 "assistantOutcome": null}
                """#)
        )

        #expect(engine.graph.nodes.count == 1)
        let node = engine.graph.nodes[0]
        #expect(node.entities == ["mara", "sister"])
        #expect(node.mentionCount == 1)
        #expect(node.embedding == [1, 0, 0])
        #expect(node.source == .owner)
    }

    @Test func nearDuplicateMergesInsteadOfInserting() async {
        let (engine, embedder) = makeEngine()
        embedder.vectors["Owner works at Anthropic"] = [1, 0, 0]
        let client = CannedChatClient(
            reply: #"{"ownerMemory": {"summary": "Owner works at Anthropic", "topic": "work", "entities": ["anthropic"]}, "assistantOutcome": null}"#
        )
        await engine.ingest(userText: "a", assistantText: "b", chatID: UUID(), client: client)
        await engine.ingest(userText: "a", assistantText: "b", chatID: UUID(), client: client)

        #expect(engine.graph.nodes.count == 1)
        #expect(engine.graph.nodes[0].mentionCount == 2)
    }

    @Test func skippedExtractionStoresNothing() async {
        let (engine, _) = makeEngine()
        await engine.ingest(
            userText: "hi",
            assistantText: "hello!",
            chatID: UUID(),
            client: CannedChatClient(
                reply: #"{"ownerMemory": null, "assistantOutcome": null}"#
            )
        )
        #expect(engine.graph.nodes.isEmpty)
    }

    @Test func assistantRepetitionDoesNotRefreshAnOwnerMemory() async {
        let (engine, embedder) = makeEngine()
        embedder.vectors["Owner works at Anthropic"] = [1, 0, 0]
        await engine.ingest(
            userText: "I work at Anthropic", assistantText: "Got it", chatID: UUID(),
            client: CannedChatClient(
                reply: #"{"ownerMemory": {"summary": "Owner works at Anthropic"}, "assistantOutcome": null}"#
            )
        )
        await engine.ingest(
            userText: "Where do I work?", assistantText: "You work at Anthropic", chatID: UUID(),
            client: CannedChatClient(
                reply: #"{"ownerMemory": null, "assistantOutcome": {"summary": "Owner works at Anthropic"}}"#
            )
        )

        #expect(engine.graph.nodes.count == 1)
        #expect(engine.graph.nodes[0].mentionCount == 1)
        #expect(engine.graph.nodes[0].source == .owner)
    }

    @Test func storesDistinctOwnerMemoryAndAssistantOutcome() async {
        let (engine, embedder) = makeEngine()
        embedder.vectors["Owner is planning a trip to Lisbon"] = [1, 0, 0]
        embedder.vectors["Assistant recommended visiting Sintra"] = [0, 1, 0]
        await engine.ingest(
            userText: "I'm planning a trip to Lisbon",
            assistantText: "I recommend visiting Sintra",
            chatID: UUID(),
            client: CannedChatClient(reply: #"""
                {"ownerMemory": {"summary": "Owner is planning a trip to Lisbon"},
                 "assistantOutcome": {"summary": "Assistant recommended visiting Sintra"}}
                """#)
        )

        #expect(engine.graph.nodes.map(\.source) == [.owner, .assistant])
    }

    @Test func ownerEvidencePromotesAnAssistantMemory() async {
        let (engine, embedder) = makeEngine()
        embedder.vectors["Owner prefers the window seat"] = [1, 0, 0]
        await engine.ingest(
            userText: "Which seat?", assistantText: "You prefer the window seat", chatID: UUID(),
            client: CannedChatClient(
                reply: #"{"ownerMemory": null, "assistantOutcome": {"summary": "Owner prefers the window seat"}}"#
            )
        )
        await engine.ingest(
            userText: "I prefer the window seat", assistantText: "Noted", chatID: UUID(),
            client: CannedChatClient(
                reply: #"{"ownerMemory": {"summary": "Owner prefers the window seat"}, "assistantOutcome": null}"#
            )
        )

        #expect(engine.graph.nodes.count == 1)
        #expect(engine.graph.nodes[0].source == .owner)
        #expect(engine.graph.nodes[0].mentionCount == 2)
    }

    @Test func retrievalRanksVectorMatchesAndExpandsViaSharedEntities() async {
        let (engine, embedder) = makeEngine()
        // A: the vector match. B: unrelated vector, shares an entity with A.
        // C: unrelated on every axis.
        await seed(
            engine, embedder,
            summary: "Owner's sister Mara is getting married in October",
            entities: ["mara", "sister"], vector: [1, 0, 0]
        )
        await seed(
            engine, embedder,
            summary: "Owner's sister lives in Portland",
            entities: ["sister", "portland"], vector: [0, 1, 0]
        )
        await seed(
            engine, embedder,
            summary: "Owner prefers oat milk in coffee",
            entities: ["coffee"], vector: [0, 0, 1]
        )
        embedder.vectors["who is getting married?"] = [1, 0, 0]

        let recalled = engine.retrieve(query: "who is getting married?")
        let summaries = recalled.map(\.summary)
        #expect(summaries.first == "Owner's sister Mara is getting married in October")
        #expect(summaries.contains("Owner's sister lives in Portland"))
        #expect(!summaries.contains("Owner prefers oat milk in coffee"))
    }

    @Test func keywordMatchQualifiesWithoutAVectorMatch() async {
        let (engine, embedder) = makeEngine()
        await seed(
            engine, embedder,
            summary: "Owner's dog is named Biscuit",
            entities: ["biscuit", "dog"], vector: [1, 0, 0]
        )
        // Query embeds far from every node; the term "biscuit" still hits.
        embedder.vectors["tell me about biscuit"] = [0, 0, 1]

        let recalled = engine.retrieve(query: "tell me about biscuit")
        #expect(recalled.map(\.summary) == ["Owner's dog is named Biscuit"])
    }

    @Test func contextBlockIsNilWhenNothingRelevantIsStored() async {
        let (engine, embedder) = makeEngine()
        #expect(engine.contextBlock(for: "anything") == nil)

        await seed(
            engine, embedder,
            summary: "Owner works at Anthropic",
            entities: ["anthropic"], vector: [1, 0, 0]
        )
        embedder.vectors["completely unrelated"] = [0, 0, 1]
        #expect(engine.contextBlock(for: "completely unrelated") == nil)
    }

    @Test func contextBlockListsRelevantMemories() async {
        let (engine, embedder) = makeEngine()
        await seed(
            engine, embedder,
            summary: "Owner works at Anthropic",
            entities: ["anthropic"], vector: [1, 0, 0]
        )
        embedder.vectors["where do I work?"] = [1, 0, 0]

        let block = engine.contextBlock(for: "where do I work?")
        #expect(block?.contains("Relevant memories") == true)
        #expect(block?.contains("Owner works at Anthropic") == true)
    }

    @Test func persistsAcrossEngineInstances() async {
        let store = MemoryStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
        )
        let embedder = StubEmbedder()
        let engine = MemoryEngine(store: store, embedder: embedder)
        await seed(
            engine, embedder,
            summary: "Owner works at Anthropic",
            entities: ["anthropic"], vector: [1, 0, 0]
        )

        let reloaded = MemoryEngine(store: store, embedder: embedder)
        #expect(reloaded.graph.nodes.map(\.summary) == ["Owner works at Anthropic"])
        // The entity index is rebuilt at load: a keyword-miss query that
        // vector-matches still expands through entities without error.
        embedder.vectors["anthropic"] = [1, 0, 0]
        #expect(reloaded.retrieve(query: "anthropic").count == 1)
    }

    // MARK: - Helpers

    private func makeEngine() -> (MemoryEngine, StubEmbedder) {
        let embedder = StubEmbedder()
        let engine = MemoryEngine(
            store: MemoryStore(
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
            ),
            embedder: embedder
        )
        return (engine, embedder)
    }

    /// Ingests one canned memory whose summary embeds to `vector`.
    private func seed(
        _ engine: MemoryEngine,
        _ embedder: StubEmbedder,
        summary: String,
        entities: [String],
        vector: [Float]
    ) async {
        embedder.vectors[summary] = vector
        let entityJSON = entities.map { "\"\($0)\"" }.joined(separator: ", ")
        await engine.ingest(
            userText: "a",
            assistantText: "b",
            chatID: UUID(),
            client: CannedChatClient(
                reply: #"{"ownerMemory": {"summary": "\#(summary)", "topic": "t", "entities": [\#(entityJSON)]}, "assistantOutcome": null}"#
            )
        )
    }
}

private final class StubEmbedder: TextEmbedding {
    var vectors: [String: [Float]] = [:]
    func vector(for text: String) -> [Float]? { vectors[text] }
}
