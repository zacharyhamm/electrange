import Foundation

/// One persisted conversation.
struct StoredChat: Codable, Identifiable {
    let id: UUID
    var title: String
    let createdAt: Date
    var updatedAt: Date
    var messages: [OllamaMessage]

    init(
        id: UUID = UUID(),
        title: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messages: [OllamaMessage] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
    }
}

/// Lightweight listing entry for the browse menu.
struct ChatSummary: Equatable, Identifiable {
    let id: UUID
    let title: String
    let updatedAt: Date
}

/// Persists chats as one JSON file per chat inside the app container's
/// Application Support directory.
struct ChatStore {
    var directory: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("electragne/chats", isDirectory: true)
    }()

    /// A short menu title derived from the chat's first user message.
    nonisolated static func title(for firstUserMessage: String) -> String {
        let collapsed = firstUserMessage
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > 40 else { return collapsed }
        return collapsed.prefix(40).trimmingCharacters(in: .whitespaces) + "…"
    }

    func listSummaries() -> [ChatSummary] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> ChatSummary? in
                guard let data = try? Data(contentsOf: url),
                      let chat = try? Self.decoder.decode(StoredChat.self, from: data) else {
                    return nil
                }
                return ChatSummary(id: chat.id, title: chat.title, updatedAt: chat.updatedAt)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func load(id: UUID) -> StoredChat? {
        guard let data = try? Data(contentsOf: fileURL(for: id)) else { return nil }
        return try? Self.decoder.decode(StoredChat.self, from: data)
    }

    /// Saves the chat; chats that never got a message are not persisted.
    func save(_ chat: StoredChat) {
        guard !chat.messages.isEmpty else { return }
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        guard let data = try? Self.encoder.encode(chat) else { return }
        try? data.write(to: fileURL(for: chat.id), options: .atomic)
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
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
