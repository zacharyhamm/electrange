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

    /// The validated whole-number "limit" argument in 1...max, or the default
    /// when absent. Present-but-invalid values throw so bad model arguments
    /// surface instead of being silently clamped.
    func limit(
        default defaultLimit: Int,
        max maxLimit: Int = 50,
        onInvalid: @autoclosure () -> Error
    ) throws -> Int {
        guard let raw = number("limit") else { return defaultLimit }
        guard raw.isFinite, raw.rounded() == raw, raw >= 1, raw <= Double(maxLimit) else {
            throw onInvalid()
        }
        return Int(raw)
    }
}

/// Date parsing shared by the tool request parsers.
nonisolated enum ToolDate {
    /// ISO8601 timestamp, with or without fractional seconds.
    static func timestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    /// A strictly validated, zero-padded YYYY-MM-DD calendar day. The
    /// round-trip check rejects impossible days like 2026-02-30.
    static func dayComponents(_ value: String, calendar: Calendar) -> DateComponents? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else { return nil }
        let checked = calendar.dateComponents([.year, .month, .day], from: date)
        guard checked.year == year, checked.month == month, checked.day == day else { return nil }
        return components
    }
}
