import SwiftUI

struct MemoryBrowserView: View {
    enum SearchMode: String, CaseIterable, Identifiable {
        case text = "Text"
        case related = "Related"

        var id: Self { self }
    }

    let engine: MemoryEngine
    @State private var query = ""
    @State private var mode = SearchMode.text
    @State private var selection: UUID?

    var body: some View {
        NavigationSplitView {
            Group {
                if engine.graph.nodes.isEmpty {
                    ContentUnavailableView(
                        "No Memories",
                        systemImage: "brain",
                        description: Text("Memories formed from conversations will appear here.")
                    )
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(results, selection: $selection) { node in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(node.summary)
                                .lineLimit(2)
                            HStack(spacing: 6) {
                                Text(node.timestamp, style: .date)
                                if node.supersededAt != nil {
                                    Text("Superseded")
                                        .foregroundStyle(.orange)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .tag(node.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 300)
            .searchable(text: $query, prompt: "Search memories")
            .toolbar {
                Picker("Search mode", selection: $mode) {
                    ForEach(SearchMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        } detail: {
            if let node = results.first(where: { $0.id == selection }) {
                MemoryDetailView(node: node)
            } else {
                ContentUnavailableView(
                    "Select a Memory",
                    systemImage: "brain.head.profile"
                )
            }
        }
        .frame(minWidth: 620, minHeight: 400)
    }

    private var results: [MemoryNode] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return engine.graph.nodes.sorted { $0.timestamp > $1.timestamp }
        }
        switch mode {
        case .text:
            return Self.textResults(in: engine.graph.nodes, query: trimmed)
        case .related:
            return engine.retrieve(query: trimmed, includingSuperseded: true)
        }
    }

    static func textResults(in nodes: [MemoryNode], query: String) -> [MemoryNode] {
        nodes.filter { node in
            ([node.summary, node.topic] + node.facts + node.entities)
                .joined(separator: " ")
                .localizedCaseInsensitiveContains(query)
        }
        .sorted { $0.timestamp > $1.timestamp }
    }
}

private struct MemoryDetailView: View {
    let node: MemoryNode

    var body: some View {
        Form {
            Section("Memory") {
                Text(node.summary)
                    .font(.title3.weight(.semibold))
                LabeledContent("Status", value: node.supersededAt == nil ? "Active" : "Superseded")
                LabeledContent("Source", value: node.source?.rawValue.capitalized ?? "Unknown")
                if !node.topic.isEmpty { LabeledContent("Topic", value: node.topic) }
            }

            if !node.facts.isEmpty {
                Section("Facts") {
                    ForEach(node.facts, id: \.self) { Text($0) }
                }
            }

            if !node.entities.isEmpty {
                Section("Entities") {
                    Text(node.entities.joined(separator: ", "))
                }
            }

            Section("History") {
                LabeledContent("First seen") { Text(node.firstSeen, style: .date) }
                LabeledContent("Last mentioned") { Text(node.timestamp, style: .date) }
                LabeledContent("Mentions", value: String(node.mentionCount))
                if let supersededAt = node.supersededAt {
                    LabeledContent("Superseded") { Text(supersededAt, style: .date) }
                }
                LabeledContent("Chat ID", value: node.sourceChatID.uuidString)
            }
        }
        .formStyle(.grouped)
    }
}
