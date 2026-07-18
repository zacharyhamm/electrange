import Foundation
import Testing
@testable import electragne

struct MemoryStoreTests {
    @Test func roundTripsAGraph() {
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
        store.save(MemoryGraph(nodes: [node]))

        #expect(store.load().nodes == [node])
    }

    @Test func loadsAnEmptyGraphWhenNothingIsStored() {
        let store = MemoryStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
        )
        #expect(store.load().nodes.isEmpty)
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

        let graph = MemoryStore(directory: directory).load()
        #expect(graph.nodes.count == 1)
        #expect(graph.nodes[0].source == nil)
    }
}
