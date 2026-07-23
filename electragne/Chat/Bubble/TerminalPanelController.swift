//
//  TerminalPanelController.swift
//  electragne
//
//  Owns the embedded terminal sessions (SwiftTerm), one per chat. The views
//  are hosted *inside* the chat bubble (ChatBubbleView shows the current
//  chat's terminal beside the transcript); this store keeps shells and
//  scrollback alive across visibility changes and chat switches, until the
//  app quits. This is also the future agent read/write surface — a session's
//  buffer is reachable via terminalView.getTerminal() and its PTY via
//  terminalView.send(txt:).
//

import AppKit
import Carbon.HIToolbox
import SwiftTerm

@MainActor
final class TerminalPanelController {
    /// One chat's shell. `wantsVisible` goes false only when the user closes
    /// the terminal column explicitly; hiding the bubble never clears it.
    private final class TerminalSession {
        let terminalView: LocalProcessTerminalView
        var wantsVisible = true

        init() {
            terminalView = LocalProcessTerminalView(
                frame: CGRect(x: 0, y: 0, width: 560, height: 380)
            )
            terminalView.nativeBackgroundColor = .windowBackgroundColor
            terminalView.nativeForegroundColor = .labelColor
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            FileManager.default.changeCurrentDirectoryPath(NSHomeDirectory()) // ponytail: app-wide chdir; pass per-tab cwd if we ever need one
            terminalView.startProcess(
                executable: shell,
                args: ["-l"],
                environment: Terminal.getEnvironmentVariables(termName: "xterm-256color")
            )
        }
    }

    private var sessions: [UUID: TerminalSession] = [:]

    /// The chat's terminal view, creating its session (and shell) on first
    /// use and marking it wanted.
    func view(for chatID: UUID) -> LocalProcessTerminalView {
        let session = sessions[chatID] ?? {
            let session = TerminalSession()
            sessions[chatID] = session
            return session
        }()
        session.wantsVisible = true
        return session.terminalView
    }

    /// Whether the chat has a live session the user hasn't closed.
    func wantsVisible(for chatID: UUID) -> Bool {
        sessions[chatID]?.wantsVisible ?? false
    }

    func hasSession(for chatID: UUID) -> Bool {
        sessions[chatID] != nil
    }

    /// The user closed the terminal column; the shell stays alive.
    func markClosed(_ chatID: UUID) {
        sessions[chatID]?.wantsVisible = false
    }

    /// Sends input through SwiftTerm's own keyboard path so terminal modes and
    /// interactive applications see the same bytes as physical typing.
    func send(_ input: TerminalWriteInput, for chatID: UUID) -> Bool {
        let terminalView = view(for: chatID)
        switch input {
        case .text(let text, let pressEnter):
            terminalView.send(txt: text + (pressEnter ? "\r" : ""))
        case .key(let key):
            guard let events = Self.events(for: key, in: terminalView) else { return false }
            terminalView.keyDown(with: events.down)
            terminalView.keyUp(with: events.up)
        }
        return true
    }

    /// Returns a bounded snapshot of the active buffer. The active buffer is
    /// important for full-screen programs such as top, vim, and less.
    func read(maxLines: Int, for chatID: UUID) -> TerminalReadResult? {
        guard let terminal = sessions[chatID]?.terminalView.getTerminal() else { return nil }
        return Self.snapshot(
            buffer: String(decoding: terminal.getBufferAsData(), as: UTF8.self),
            maxLines: maxLines
        )
    }

    static func snapshot(buffer: String, maxLines: Int) -> TerminalReadResult {
        var lines = buffer
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }
        let truncated = lines.count > maxLines
        let visible = Array(lines.suffix(maxLines))
        return TerminalReadResult(
            content: visible.joined(separator: "\n"),
            lineCount: visible.count,
            truncated: truncated
        )
    }

    private struct KeySpec {
        let keyCode: UInt16
        let characters: String
        var extraFlags: NSEvent.ModifierFlags = []
    }

    private static func events(
        for press: TerminalKeyPress,
        in view: LocalProcessTerminalView
    ) -> (down: NSEvent, up: NSEvent)? {
        let flags = modifierFlags(for: press.modifiers)
        if let rawCode = TerminalKeyPress.rawKeyCode(press.key) {
            return cgEvents(keyCode: rawCode, flags: flags)
        }
        guard let spec = keySpec(press.key) else { return nil }
        let effectiveFlags = flags.union(spec.extraFlags)
        let characters = effectiveFlags.contains(.shift) && spec.characters.count == 1
            ? spec.characters.uppercased()
            : spec.characters
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: effectiveFlags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: view.window?.windowNumber ?? 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: spec.characters,
                isARepeat: false,
                keyCode: spec.keyCode
            )
        }
        guard let down = event(.keyDown), let up = event(.keyUp) else { return nil }
        return (down, up)
    }

    private static func cgEvents(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags
    ) -> (down: NSEvent, up: NSEvent)? {
        func event(_ isDown: Bool) -> NSEvent? {
            guard let cgEvent = CGEvent(
                keyboardEventSource: nil,
                virtualKey: CGKeyCode(keyCode),
                keyDown: isDown
            ) else { return nil }
            cgEvent.flags = cgModifierFlags(from: flags)
            return NSEvent(cgEvent: cgEvent)
        }
        guard let down = event(true), let up = event(false) else { return nil }
        return (down, up)
    }

    private static func keySpec(_ rawKey: String) -> KeySpec? {
        if rawKey.count == 1 { return KeySpec(keyCode: 0, characters: rawKey) }
        let key = TerminalKeyPress.normalizedKeyName(rawKey)
        if key.first == "f", let number = Int(key.dropFirst()), (1...35).contains(number) {
            let codes: [Int: UInt16] = [
                1: 122, 2: 120, 3: 99, 4: 118, 5: 96, 6: 97, 7: 98,
                8: 100, 9: 101, 10: 109, 11: 103, 12: 111, 13: 105,
                14: 107, 15: 113, 16: 106, 17: 64, 18: 79, 19: 80, 20: 90,
            ]
            return KeySpec(
                keyCode: codes[number] ?? 0,
                characters: functionCharacter(Int(NSF1FunctionKey) + number - 1),
                extraFlags: .function
            )
        }
        let function = NSEvent.ModifierFlags.function
        switch key {
        case "return", "enter": return KeySpec(keyCode: UInt16(kVK_Return), characters: "\r")
        case "escape", "esc": return KeySpec(keyCode: UInt16(kVK_Escape), characters: "\u{1b}")
        case "tab": return KeySpec(keyCode: UInt16(kVK_Tab), characters: "\t")
        case "space", "spacebar": return KeySpec(keyCode: UInt16(kVK_Space), characters: " ")
        case "backspace": return KeySpec(keyCode: UInt16(kVK_Delete), characters: "\u{7f}")
        case "delete", "forwarddelete": return KeySpec(keyCode: UInt16(kVK_ForwardDelete), characters: functionCharacter(Int(NSDeleteFunctionKey)), extraFlags: function)
        case "insert": return KeySpec(keyCode: 0, characters: functionCharacter(Int(NSInsertFunctionKey)), extraFlags: function)
        case "up", "uparrow": return KeySpec(keyCode: UInt16(kVK_UpArrow), characters: functionCharacter(Int(NSUpArrowFunctionKey)), extraFlags: function)
        case "down", "downarrow": return KeySpec(keyCode: UInt16(kVK_DownArrow), characters: functionCharacter(Int(NSDownArrowFunctionKey)), extraFlags: function)
        case "left", "leftarrow": return KeySpec(keyCode: UInt16(kVK_LeftArrow), characters: functionCharacter(Int(NSLeftArrowFunctionKey)), extraFlags: function)
        case "right", "rightarrow": return KeySpec(keyCode: UInt16(kVK_RightArrow), characters: functionCharacter(Int(NSRightArrowFunctionKey)), extraFlags: function)
        case "home": return KeySpec(keyCode: UInt16(kVK_Home), characters: functionCharacter(Int(NSHomeFunctionKey)), extraFlags: function)
        case "end": return KeySpec(keyCode: UInt16(kVK_End), characters: functionCharacter(Int(NSEndFunctionKey)), extraFlags: function)
        case "pageup", "pgup": return KeySpec(keyCode: UInt16(kVK_PageUp), characters: functionCharacter(Int(NSPageUpFunctionKey)), extraFlags: function)
        case "pagedown", "pgdown": return KeySpec(keyCode: UInt16(kVK_PageDown), characters: functionCharacter(Int(NSPageDownFunctionKey)), extraFlags: function)
        case "help": return KeySpec(keyCode: UInt16(kVK_Help), characters: functionCharacter(Int(NSHelpFunctionKey)), extraFlags: function)
        case "clear": return KeySpec(keyCode: UInt16(kVK_ANSI_KeypadClear), characters: functionCharacter(Int(NSClearLineFunctionKey)), extraFlags: .numericPad)
        case "printscreen": return KeySpec(keyCode: 0, characters: functionCharacter(Int(NSPrintScreenFunctionKey)), extraFlags: function)
        case "scrolllock": return KeySpec(keyCode: 0, characters: functionCharacter(Int(NSScrollLockFunctionKey)), extraFlags: function)
        case "pause": return KeySpec(keyCode: 0, characters: functionCharacter(Int(NSPauseFunctionKey)), extraFlags: function)
        case "menu": return KeySpec(keyCode: 0, characters: functionCharacter(Int(NSMenuFunctionKey)), extraFlags: function)
        case "keypad0": return KeySpec(keyCode: UInt16(kVK_ANSI_Keypad0), characters: "0", extraFlags: .numericPad)
        case "keypad1": return KeySpec(keyCode: UInt16(kVK_ANSI_Keypad1), characters: "1", extraFlags: .numericPad)
        case "keypad2": return KeySpec(keyCode: UInt16(kVK_ANSI_Keypad2), characters: "2", extraFlags: .numericPad)
        case "keypad3": return KeySpec(keyCode: UInt16(kVK_ANSI_Keypad3), characters: "3", extraFlags: .numericPad)
        case "keypad4": return KeySpec(keyCode: UInt16(kVK_ANSI_Keypad4), characters: "4", extraFlags: .numericPad)
        case "keypad5": return KeySpec(keyCode: UInt16(kVK_ANSI_Keypad5), characters: "5", extraFlags: .numericPad)
        case "keypad6": return KeySpec(keyCode: UInt16(kVK_ANSI_Keypad6), characters: "6", extraFlags: .numericPad)
        case "keypad7": return KeySpec(keyCode: UInt16(kVK_ANSI_Keypad7), characters: "7", extraFlags: .numericPad)
        case "keypad8": return KeySpec(keyCode: UInt16(kVK_ANSI_Keypad8), characters: "8", extraFlags: .numericPad)
        case "keypad9": return KeySpec(keyCode: UInt16(kVK_ANSI_Keypad9), characters: "9", extraFlags: .numericPad)
        case "keypaddecimal": return KeySpec(keyCode: UInt16(kVK_ANSI_KeypadDecimal), characters: ".", extraFlags: .numericPad)
        case "keypaddivide": return KeySpec(keyCode: UInt16(kVK_ANSI_KeypadDivide), characters: "/", extraFlags: .numericPad)
        case "keypadmultiply": return KeySpec(keyCode: UInt16(kVK_ANSI_KeypadMultiply), characters: "*", extraFlags: .numericPad)
        case "keypadminus", "keypadsubtract": return KeySpec(keyCode: UInt16(kVK_ANSI_KeypadMinus), characters: "-", extraFlags: .numericPad)
        case "keypadplus", "keypadadd": return KeySpec(keyCode: UInt16(kVK_ANSI_KeypadPlus), characters: "+", extraFlags: .numericPad)
        case "keypadenter": return KeySpec(keyCode: UInt16(kVK_ANSI_KeypadEnter), characters: "\r", extraFlags: .numericPad)
        case "keypadequals": return KeySpec(keyCode: UInt16(kVK_ANSI_KeypadEquals), characters: "=", extraFlags: .numericPad)
        default: return nil
        }
    }

    private static func functionCharacter(_ value: Int) -> String {
        String(UnicodeScalar(value)!)
    }

    private static func modifierFlags(
        for modifiers: Set<TerminalModifier>
    ) -> NSEvent.ModifierFlags {
        modifiers.reduce(into: []) { flags, modifier in
            switch modifier {
            case .control: flags.insert(.control)
            case .option: flags.insert(.option)
            case .command: flags.insert(.command)
            case .shift: flags.insert(.shift)
            case .capsLock: flags.insert(.capsLock)
            case .function: flags.insert(.function)
            case .numericPad: flags.insert(.numericPad)
            case .help: flags.insert(.help)
            }
        }
    }

    private static func cgModifierFlags(
        from flags: NSEvent.ModifierFlags
    ) -> CGEventFlags {
        var result: CGEventFlags = []
        if flags.contains(.control) { result.insert(.maskControl) }
        if flags.contains(.option) { result.insert(.maskAlternate) }
        if flags.contains(.command) { result.insert(.maskCommand) }
        if flags.contains(.shift) { result.insert(.maskShift) }
        if flags.contains(.capsLock) { result.insert(.maskAlphaShift) }
        if flags.contains(.function) { result.insert(.maskSecondaryFn) }
        if flags.contains(.numericPad) { result.insert(.maskNumericPad) }
        if flags.contains(.help) { result.insert(.maskHelp) }
        return result
    }
}
