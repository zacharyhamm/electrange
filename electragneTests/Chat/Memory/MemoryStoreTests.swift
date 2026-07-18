import Foundation
import Testing
@testable import electragne

struct MemoryStoreTests {
    @Test func roundTripsAGraph() throws {
        let store = MemoryStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
        )
        let node = MemoryNode(
            id: UUID(),
            summary: "Owner works at Anthropic",
            facts: ["works at anthropic"],
            entities: ["anthropic"],
            topic: "work",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            firstSeen: Date(timeIntervalSince1970: 1_600_000_000),
            mentionCount: 2,
            embedding: [1, 0, 0],
            semanticNeighbors: [UUID()],
            sourceChatID: UUID(),
            source: .owner
        )
        try store.save(MemoryGraph(nodes: [node]))

        #expect(try store.load().nodes == [node])
    }

    @Test func loadsAnEmptyGraphWhenNothingIsStored() throws {
        let store = MemoryStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
        )
        #expect(try store.load().nodes.isEmpty)
    }

    @Test func loadsLegacyGraphWithoutSource() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let chatID = UUID()
        let json = #"""
        {"nodes":[{"id":"\#(id.uuidString)","summary":"Legacy memory","facts":[],
        "entities":[],"topic":"legacy","timestamp":"2026-01-01T00:00:00Z",
        "firstSeen":"2026-01-01T00:00:00Z","mentionCount":1,"embedding":[],
        "semanticNeighbors":[],"sourceChatID":"\#(chatID.uuidString)"}]}
        """#
        try Data(json.utf8).write(to: directory.appendingPathComponent("graph.json"))

        let graph = try MemoryStore(directory: directory).load()
        #expect(graph.nodes.count == 1)
        #expect(graph.nodes[0].source == nil)
        #expect(graph.nodes[0].canonicalKey == nil)
        #expect(graph.nodes[0].supersededAt == nil)
    }

    @Test func failedSavePreservesThePreviousGraph() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let store = MemoryStore(directory: directory)
        let valid = MemoryNode(
            id: UUID(), summary: "Valid", facts: [], entities: [], topic: "",
            timestamp: Date(), firstSeen: Date(), mentionCount: 1,
            embedding: [1], semanticNeighbors: [], sourceChatID: UUID()
        )
        try store.save(MemoryGraph(nodes: [valid]))
        let before = try Data(contentsOf: directory.appendingPathComponent("graph.json"))
        var invalid = valid
        invalid.embedding = [.nan]

        #expect(throws: (any Error).self) {
            try store.save(MemoryGraph(nodes: [invalid]))
        }
        #expect(try Data(contentsOf: directory.appendingPathComponent("graph.json")) == before)
    }
}
