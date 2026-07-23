//
//  TerminalTool.swift
//  electragne
//
//  Agent access to the embedded terminal shared with the current chat.
//

import Foundation

nonisolated enum TerminalToolError: LocalizedError, Equatable {
    case unsupportedTool(String)
    case invalidWrite
    case invalidKey
    case invalidModifier(String)
    case invalidMaxLines

    var errorDescription: String? {
        switch self {
        case .unsupportedTool: "That terminal request was invalid."
        case .invalidWrite:
            "Provide either non-empty text or one key. Modifiers only apply to keys, and pressEnter only applies to text."
        case .invalidKey:
            "A terminal key must be one character, a named key, or keycode:<0-65535>."
        case .invalidModifier(let modifier):
            "Unknown terminal modifier ‘\(modifier)’."
        case .invalidMaxLines:
            "maxLines must be a whole number from 1 to 200."
        }
    }
}

nonisolated enum TerminalModifier: String, CaseIterable, Hashable, Sendable {
    case control
    case option
    case command
    case shift
    case capsLock
    case function
    case numericPad
    case help

    var displayName: String {
        switch self {
        case .control: "Control"
        case .option: "Option"
        case .command: "Command"
        case .shift: "Shift"
        case .capsLock: "Caps Lock"
        case .function: "Fn"
        case .numericPad: "Numeric Pad"
        case .help: "Help"
        }
    }
}

nonisolated struct TerminalKeyPress: Equatable, Sendable {
    let key: String
    let modifiers: Set<TerminalModifier>

    var displayName: String {
        (modifiers.sorted { $0.rawValue < $1.rawValue }.map(\.displayName) + [key])
            .joined(separator: "+")
    }

    init(key: String, modifiers rawModifiers: String?) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSupportedKey(key) else { throw TerminalToolError.invalidKey }
        self.key = key
        modifiers = try Self.parseModifiers(rawModifiers)
    }

    static func rawKeyCode(_ key: String) -> UInt16? {
        let parts = key.lowercased().split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[0] == "keycode" else { return nil }
        return UInt16(parts[1])
    }

    static func normalizedKeyName(_ key: String) -> String {
        key.lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    private static func isSupportedKey(_ key: String) -> Bool {
        if key.count == 1 || rawKeyCode(key) != nil { return true }
        let name = normalizedKeyName(key)
        if name.first == "f", let number = Int(name.dropFirst()), (1...35).contains(number) {
            return true
        }
        return [
            "return", "enter", "escape", "esc", "tab", "space", "spacebar",
            "backspace", "delete", "forwarddelete", "insert",
            "up", "uparrow", "down", "downarrow", "left", "leftarrow",
            "right", "rightarrow", "home", "end", "pageup", "pgup",
            "pagedown", "pgdown", "help", "clear", "printscreen", "scrolllock",
            "pause", "menu",
            "keypad0", "keypad1", "keypad2", "keypad3", "keypad4",
            "keypad5", "keypad6", "keypad7", "keypad8", "keypad9",
            "keypaddecimal", "keypaddivide", "keypadmultiply", "keypadminus",
            "keypadsubtract", "keypadplus", "keypadadd", "keypadenter",
            "keypadequals",
        ].contains(name)
    }

    private static func parseModifiers(_ raw: String?) throws -> Set<TerminalModifier> {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        var result: Set<TerminalModifier> = []
        for part in raw.split(whereSeparator: { $0 == "+" || $0 == "," || $0.isWhitespace }) {
            switch part.lowercased().replacingOccurrences(of: "_", with: "-") {
            case "ctrl", "control": result.insert(.control)
            case "alt", "option", "meta": result.insert(.option)
            case "super", "cmd", "command": result.insert(.command)
            case "shift": result.insert(.shift)
            case "caps", "caps-lock", "capslock": result.insert(.capsLock)
            case "fn", "function": result.insert(.function)
            case "numeric-pad", "numericpad", "numpad": result.insert(.numericPad)
            case "help": result.insert(.help)
            case "hyper": result.formUnion([.control, .option, .command, .shift])
            default: throw TerminalToolError.invalidModifier(String(part))
            }
        }
        return result
    }
}

nonisolated enum TerminalWriteInput: Equatable, Sendable {
    case text(String, pressEnter: Bool)
    case key(TerminalKeyPress)
}

nonisolated struct TerminalReadResult: Equatable, Sendable {
    let content: String
    let lineCount: Int
    let truncated: Bool
}

nonisolated enum TerminalToolRequest: Equatable, Sendable {
    case open
    case read(maxLines: Int)
    case write(TerminalWriteInput)

    init(toolCall: ChatToolCall) throws {
        switch toolCall.name {
        case "open_terminal":
            self = .open
        case "read_terminal":
            let raw = toolCall.arguments["maxLines"]?.numberValue ?? 100
            guard raw.isFinite, raw.rounded() == raw, raw >= 1, raw <= 200 else {
                throw TerminalToolError.invalidMaxLines
            }
            self = .read(maxLines: Int(raw))
        case "write_terminal":
            let text = toolCall.arguments["text"]?.stringValue
            let key = toolCall.arguments["key"]?.stringValue
            let modifiers = toolCall.arguments["modifiers"]?.stringValue
            let hasPressEnter = toolCall.arguments["pressEnter"] != nil
            guard (text == nil) != (key == nil), modifiers == nil || key != nil,
                  !hasPressEnter || text != nil else {
                throw TerminalToolError.invalidWrite
            }
            if let text {
                guard !text.isEmpty, text.utf8.count <= 16_384 else {
                    throw TerminalToolError.invalidWrite
                }
                self = .write(.text(
                    text,
                    pressEnter: toolCall.arguments["pressEnter"]?.boolValue ?? true
                ))
            } else {
                self = .write(.key(try TerminalKeyPress(key: key ?? "", modifiers: modifiers)))
            }
        default:
            throw TerminalToolError.unsupportedTool(toolCall.name)
        }
    }
}

@MainActor
final class TerminalToolService {
    var present: @MainActor (UUID?) -> Bool = { _ in false }
    var write: @MainActor (TerminalWriteInput, UUID?) -> Bool = { _, _ in false }
    var read: @MainActor (Int, UUID?) -> TerminalReadResult? = { _, _ in nil }

    func confirmationDetails(for request: TerminalToolRequest) -> ToolConfirmationDetails? {
        guard case .write(let input) = request else { return nil }
        switch input {
        case .text(let text, let pressEnter):
            return ToolConfirmationDetails(
                title: "Send this to the terminal?",
                primaryText: text,
                details: [("Press Enter", pressEnter ? "Yes" : "No")],
                actionLabel: "Send"
            )
        case .key(let key):
            return ToolConfirmationDetails(
                title: "Press this terminal key?",
                primaryText: key.displayName,
                details: [],
                actionLabel: "Press"
            )
        }
    }

    func execute(_ request: TerminalToolRequest) async -> ChatToolResult {
        let run = AutomationRunScope.current
        let chatID = run?.chatID
        switch request {
        case .open:
            guard run == nil || run?.terminalAccess == true else {
                return .error("This automation was not granted terminal access.")
            }
            guard present(chatID) else { return unavailable }
            return .make(status: "ok", message: "Opened the embedded terminal inside the chat window.")
        case .write(let input):
            guard run?.terminalAccess != false else {
                return .error("This automation was not granted terminal write access.")
            }
            guard write(input, chatID) else { return unavailable }
            return .make(status: "ok", message: "Sent input to the terminal.")
        case .read(let maxLines):
            guard run == nil || run?.terminalAccess == true else {
                return .error("This automation was not granted terminal access.")
            }
            guard let result = read(maxLines, chatID) else {
                return .error("This chat does not have a terminal session yet. Open it or write to it first.")
            }
            return ChatToolResult(response: [
                "status": .string("ok"),
                "content": .string(result.content),
                "lineCount": .number(Double(result.lineCount)),
                "truncated": .bool(result.truncated),
            ])
        }
    }

    private var unavailable: ChatToolResult {
        .error("The target chat does not have an available terminal session.")
    }
}
