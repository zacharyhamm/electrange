import Foundation
import Testing
@testable import electragne

struct ChatToolRegistryTests {
    @Test func definitionsHaveUniqueNamesAndValidRequiredProperties() {
        let definitions = ChatToolRegistry.definitions

        #expect(Set(definitions.map(\.name)).count == definitions.count)
        for definition in definitions {
            #expect(Set(definition.required).isSubset(of: Set(definition.properties.keys)))
        }
    }

    @Test func providerCatalogsContainEveryApplicableDefinition() {
        let gemini = ChatToolRegistry.definitions(for: .gemini)
        let ollama = ChatToolRegistry.definitions(for: .ollama)
        let openAICompatible = ChatToolRegistry.definitions(for: .openAICompatible)

        // Gemini uses server-side grounding; Ollama and OpenAI-compatible
        // providers can use the hosted Ollama web-search executor.
        #expect(gemini.count == ChatToolRegistry.definitions.count - 1)
        #expect(!gemini.contains { $0.name == "web_search" })
        #expect(ollama.count == ChatToolRegistry.definitions.count)
        #expect(ollama.first?.name == "web_search")
        #expect(openAICompatible.count == ChatToolRegistry.definitions.count)
        #expect(openAICompatible.first?.name == "web_search")
        #expect(Set(gemini.map(\.name)).isSubset(of: Set(ollama.map(\.name))))
    }

    @Test func lookupReturnsRoutingAndStatusMetadata() {
        let timer = ChatToolRegistry.definition(named: "create_timer")

        #expect(timer?.family == .timers)
        #expect(timer?.initialStatus == "Confirm timer…")
        #expect(timer?.executionStatus == "Updating timers…")
        #expect(ChatToolRegistry.definition(named: "not_a_tool") == nil)
    }

    @Test func sharedDefinitionsEncodeEquivalentlyForBothProviders() throws {
        let geminiData = try GeminiClient.makeRequestBody(history: [])
        let geminiJSON = try #require(
            try JSONSerialization.jsonObject(with: geminiData) as? [String: Any]
        )
        let geminiTools = try #require(geminiJSON["tools"] as? [[String: Any]])
        let geminiFunctions = try #require(
            geminiTools[1]["functionDeclarations"] as? [[String: Any]]
        )

        let ollamaData = try OllamaClient.makeRequestBody(model: "test", history: [])
        let ollamaJSON = try #require(
            try JSONSerialization.jsonObject(with: ollamaData) as? [String: Any]
        )
        let ollamaTools = try #require(ollamaJSON["tools"] as? [[String: Any]])
        let ollamaFunctions = ollamaTools.compactMap { $0["function"] as? [String: Any] }

        for definition in ChatToolRegistry.definitions(for: .gemini) {
            let gemini = try #require(geminiFunctions.first {
                $0["name"] as? String == definition.name
            })
            let ollama = try #require(ollamaFunctions.first {
                $0["name"] as? String == definition.name
            })
            #expect(gemini["description"] as? String == ollama["description"] as? String)

            let geminiParameters = try #require(gemini["parameters"] as? [String: Any])
            let ollamaParameters = try #require(ollama["parameters"] as? [String: Any])
            #expect(
                geminiParameters["required"] as? [String]
                    == ollamaParameters["required"] as? [String]
            )

            let geminiProperties = try #require(
                geminiParameters["properties"] as? [String: [String: Any]]
            )
            let ollamaProperties = try #require(
                ollamaParameters["properties"] as? [String: [String: Any]]
            )
            #expect(Set(geminiProperties.keys) == Set(ollamaProperties.keys))
            for name in geminiProperties.keys {
                #expect(
                    (geminiProperties[name]?["type"] as? String)?.lowercased()
                        == ollamaProperties[name]?["type"] as? String
                )
                #expect(
                    geminiProperties[name]?["description"] as? String
                        == ollamaProperties[name]?["description"] as? String
                )
            }
        }
    }
}
