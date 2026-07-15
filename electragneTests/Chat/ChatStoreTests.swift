import Foundation
import Testing
@testable import electragne

struct ChatStoreTests {
    private func makeTempStore() throws -> ChatStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-store-test-\(UUID().uuidString)")
        return ChatStore(directory: directory)
    }

    @Test func savedChatRoundTrips() throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }

        let chat = StoredChat(
            title: "Sheep talk",
            messages: [
                OllamaMessage(role: "user", content: "hello"),
                OllamaMessage(role: "assistant", content: "Baa! **Hi** there."),
            ]
        )
        store.save(chat)

        let loaded = store.load(id: chat.id)
        #expect(loaded?.id == chat.id)
        #expect(loaded?.title == "Sheep talk")
        #expect(loaded?.messages == chat.messages)
        #expect(loaded?.messages.first?.toolCalls == nil)
    }

    @Test func summariesAreSortedMostRecentFirstAndEmptyChatsSkipped() throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }

        let older = StoredChat(
            title: "older",
            updatedAt: Date(timeIntervalSince1970: 1000),
            messages: [OllamaMessage(role: "user", content: "a")]
        )
        let newer = StoredChat(
            title: "newer",
            updatedAt: Date(timeIntervalSince1970: 2000),
            messages: [OllamaMessage(role: "user", content: "b")]
        )
        let empty = StoredChat(title: "empty")
        store.save(older)
        store.save(newer)
        store.save(empty)

        let summaries = store.listSummaries()
        #expect(summaries.map(\.title) == ["newer", "older"])
        #expect(store.load(id: empty.id) == nil)
    }

    @Test func titlesCollapseWhitespaceAndTruncate() {
        #expect(ChatStore.title(for: "  what's   the\nweather? ") == "what's the weather?")

        let long = ChatStore.title(for: String(repeating: "sheep ", count: 20))
        #expect(long.count <= 41)
        #expect(long.hasSuffix("…"))
    }

    @Test func listingAnEmptyOrMissingDirectoryIsEmpty() throws {
        let store = try makeTempStore()
        #expect(store.listSummaries().isEmpty)
        #expect(store.load(id: UUID()) == nil)
    }
}

struct UserPreferencesTests {
    @Test func preferredNameIsTrimmedAndBlankMeansUnset() throws {
        let suite = "prefs-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(UserPreferences.preferredName(in: defaults) == nil)

        defaults.set("   ", forKey: UserPreferences.preferredNameKey)
        #expect(UserPreferences.preferredName(in: defaults) == nil)

        defaults.set("  Zed the Owner \n", forKey: UserPreferences.preferredNameKey)
        #expect(UserPreferences.preferredName(in: defaults) == "Zed the Owner")
    }

    @Test func chatFontSizeDefaultsAndClamps() throws {
        let suite = "font-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(UserPreferences.chatFontSize(in: defaults) == UserPreferences.defaultChatFontSize)

        UserPreferences.setChatFontSize(100, in: defaults)
        #expect(UserPreferences.chatFontSize(in: defaults) == UserPreferences.chatFontSizeRange.upperBound)

        UserPreferences.setChatFontSize(1, in: defaults)
        #expect(UserPreferences.chatFontSize(in: defaults) == UserPreferences.chatFontSizeRange.lowerBound)

        UserPreferences.setChatFontSize(16, in: defaults)
        #expect(UserPreferences.chatFontSize(in: defaults) == 16)
    }
}
