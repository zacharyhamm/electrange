//
//  ToolCallArguments.swift
//  electragne
//
//  Trimmed string/number extraction from a ChatToolCall, shared by the
//  request parsers.
//

import Foundation

nonisolated struct ToolCallArguments {
    private let arguments: [String: ChatToolValue]

    init(_ call: ChatToolCall) {
        arguments = call.arguments
    }

    /// The trimmed string for key, or nil when absent/blank.
    func string(_ key: String) -> String? {
        let text = arguments[key]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    /// The trimmed string for key, throwing the family's missing-argument
    /// error when absent/blank.
    func required(_ key: String, onMissing: (String) -> Error) throws -> String {
        guard let text = string(key) else { throw onMissing(key) }
        return text
    }

    func number(_ key: String) -> Double? {
        arguments[key]?.numberValue
    }
}
