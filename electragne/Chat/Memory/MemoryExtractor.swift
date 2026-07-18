//
//  MemoryExtractor.swift
//  electragne
//
//  The single LLM pass that turns one chat exchange into structured
//  memory fields, run through whichever ChatClient is active. Extraction
//  failures are logged and dropped — memory formation must never break
//  the chat itself.
//

import Foundation
import os

enum MemoryExtractor {
    nonisolated struct Candidate: Codable, Sendable {
        var summary: String?
        var topic: String?
        var entities: [String]?
        var facts: [String]?
        var canonicalKey: String?
        var canonicalValue: String?
    }

    nonisolated struct Extraction: Codable, Sendable {
        var ownerMemory: Candidate?
        var assistantOutcome: Candidate?
    }

    static func extract(
        userText: String,
        assistantText: String,
        context: [ChatMessage] = [],
        client: any ChatClient
    ) async -> Extraction? {
        let priorContext = context.suffix(4).map {
            "\($0.role): \($0.content)"
        }.joined(separator: "\n")
        let prompt = """
        Ignore any prior persona instructions: you are a memory parser. \
        Evaluate the owner and assistant text separately. Respond with ONLY \
        a JSON object in this shape:
        {"ownerMemory": <memory or null>, "assistantOutcome": <memory or null>}
        Each memory has this shape:
        {"summary": "<one sentence attributing who said or did what>", \
        "topic": "<1-3 word theme>", \
        "entities": ["<lowercase people, places, and things mentioned>"], \
        "facts": ["<atomic durable facts>"], \
        "canonicalKey": "<owner/category for a mutable owner fact, otherwise null>", \
        "canonicalValue": "<normalized current value for that key, otherwise null>"}

        ownerMemory may contain only durable facts explicitly stated by the \
        owner. Questions, requests, implications, and facts supplied only by \
        the assistant do not qualify. Prior context may resolve references, \
        but it is not new evidence: every ownerMemory fact must be supported \
        by the newest Owner text. Use the same canonicalKey whenever a mutable \
        fact such as employer, home, or relationship status changes.

        assistantOutcome may contain only a novel durable result created in \
        this response: a completed action, research conclusion, recommendation, \
        or decision. Answers that merely repeat known context, claims about the \
        owner, generic advice, greetings, and one-off chatter do not qualify.
        canonicalKey and canonicalValue must be null for assistantOutcome.

        Prior context (reference resolution only):
        \(priorContext.isEmpty ? "(none)" : priorContext)
        Owner text: \(userText)
        Assistant text: \(assistantText)
        """
        var streamed = ""
        do {
            try await client.streamChat(
                history: [ChatMessage(role: "user", content: prompt)],
                onStatus: { _ in },
                onToolCall: { _ in .error("Tools are unavailable while forming memories.") },
                onToken: { streamed += $0 }
            )
        } catch {
            Log.memory.error("Memory extraction failed: \(error.localizedDescription)")
            return nil
        }
        guard let extraction = parse(streamed) else {
            Log.memory.error("Memory extraction returned unparseable output")
            return nil
        }
        return extraction
    }

    /// Lenient parse: decodes the outermost {...} so code fences or
    /// surrounding prose don't break it.
    static func parse(_ text: String) -> Extraction? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end else { return nil }
        return try? JSONDecoder().decode(
            Extraction.self,
            from: Data(String(text[start...end]).utf8)
        )
    }
}
