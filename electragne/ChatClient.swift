import Foundation

/// A chat backend the bubble can stream a reply from.
protocol ChatClient {
    func streamChat(
        history: [OllamaMessage],
        onStatus: (String) -> Void,
        onToken: (String) -> Void
    ) async throws
}

/// Which backend the menu-bar toggle has selected.
enum ChatProviderPreference {
    nonisolated static let useGeminiKey = "useGeminiChat"

    static var useGemini: Bool {
        UserDefaults.standard.bool(forKey: useGeminiKey)
    }
}
