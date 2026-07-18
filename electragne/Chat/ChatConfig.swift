nonisolated struct ChatConfig: Sendable {
    var ollamaModel = "gemma4:latest"
    var geminiModel = "gemini-3.1-flash-lite"
    var openAICompatibleBaseURL = "https://api.deepseek.com"
    var openAICompatibleModel = "deepseek-v4-flash"
    var deepSeekThinking = true
    var maxToolRounds = 10
    var contextWindowTokens = 32768
    var maxHistoryMessages = 100

    static let `default` = ChatConfig()
}
