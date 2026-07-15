nonisolated struct ChatConfig: Sendable {
    var ollamaModel = "gemma4:latest"
    var geminiModel = "gemini-3.1-flash-lite"
    var maxToolRounds = 3
    var contextWindowTokens = 32768
    var maxHistoryMessages = 100

    static let `default` = ChatConfig()
}
