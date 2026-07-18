import Foundation
import Testing
@testable import electragne

@MainActor
struct MemoryProviderPreferenceTests {
    @Test func unsetMeansFollowChat() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        #expect(MemoryProviderPreference.selected(in: defaults) == nil)
        #expect(MemoryProviderPreference.model(in: defaults) == nil)
    }

    @Test func storedProviderAndModelRoundTrip() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(ChatProvider.ollama.rawValue, forKey: MemoryProviderPreference.providerKey)
        defaults.set("qwen3:4b", forKey: MemoryProviderPreference.modelKey)
        #expect(MemoryProviderPreference.selected(in: defaults) == .ollama)
        #expect(MemoryProviderPreference.model(in: defaults) == "qwen3:4b")
    }

    @Test func emptyOrGarbageValuesFallBackToDefaults() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("", forKey: MemoryProviderPreference.providerKey)
        defaults.set("", forKey: MemoryProviderPreference.modelKey)
        #expect(MemoryProviderPreference.selected(in: defaults) == nil)
        #expect(MemoryProviderPreference.model(in: defaults) == nil)
        defaults.set("not-a-provider", forKey: MemoryProviderPreference.providerKey)
        #expect(MemoryProviderPreference.selected(in: defaults) == nil)
    }
}
