//
//  LEDSignTool.swift
//  electragne
//
//  Sends messages to a MatrixPortal M4 LED sign: POST http://<endpoint>/messages
//  with a JSON body the panel's protocol.py validates (ASCII text ≤ 80 chars,
//  duration 1–60s, fixed animation/icon/color vocabularies).
//

import Foundation

nonisolated enum LEDSignError: LocalizedError, Equatable {
    case invalidText
    case invalidDuration
    case invalidOption(String, String)
    case notConfigured
    case invalidEndpoint
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidText:
            "LED sign text must contain at least one printable ASCII character."
        case .invalidDuration:
            "LED sign duration must be from 1 to 60 seconds."
        case .invalidOption(let name, let allowed):
            "Invalid ‘\(name)’. Allowed values: \(allowed)."
        case .notConfigured:
            "The LED sign has no endpoint configured."
        case .invalidEndpoint:
            "The LED sign endpoint in Settings is not a valid host or host:port."
        case .requestFailed(let message):
            "The LED sign rejected the message: \(message)"
        }
    }
}

nonisolated struct LEDSignMessage: Encodable, Equatable, Sendable {
    static let maxTextLength = 80
    static let durationRange = 1.0...60.0
    static let animations = ["static", "scroll", "blink", "page", "typewriter", "slide"]
    static let icons = [
        "alert", "check", "heart", "smile", "x", "up", "down",
        "bell", "question", "clock", "mail", "zap",
    ]
    static let colorModes = ["solid", "rainbow", "pulse"]
    static let modes = ["panic", "celebrate", "alarm", "rain", "wipe", "siren"]
    static let namedColors = [
        "red", "orange", "amber", "yellow", "green",
        "cyan", "blue", "purple", "pink", "white",
    ]

    let text: String
    let duration: Double
    let animation: String
    let icon: String?
    let color: String?
    let iconColor: String?
    let colorMode: String?
    let mode: String?
    let priority: Bool

    private enum CodingKeys: String, CodingKey {
        case text, duration, animation, icon, color
        case iconColor = "icon_color"
        case colorMode = "color_mode"
        case mode, priority
    }

    init(
        text: String,
        duration: Double = 10,
        animation: String = "scroll",
        icon: String? = nil,
        color: String? = nil,
        iconColor: String? = nil,
        colorMode: String? = nil,
        mode: String? = nil,
        priority: Bool = false
    ) throws {
        self.text = Self.sanitize(text)
        guard !self.text.isEmpty else { throw LEDSignError.invalidText }
        guard Self.durationRange.contains(duration) else { throw LEDSignError.invalidDuration }
        self.duration = duration
        self.animation = try Self.validated(animation, in: Self.animations, name: "animation")
        self.icon = try icon.map { try Self.validated($0, in: Self.icons, name: "icon") }
        self.color = try color.map { try Self.validatedColor($0, name: "color") }
        self.iconColor = try iconColor.map { try Self.validatedColor($0, name: "icon_color") }
        self.colorMode = try colorMode.map {
            try Self.validated($0, in: Self.colorModes, name: "color_mode")
        }
        self.mode = try mode.map { try Self.validated($0, in: Self.modes, name: "mode") }
        self.priority = priority
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(duration, forKey: .duration)
        try container.encode(animation, forKey: .animation)
        try container.encodeIfPresent(icon, forKey: .icon)
        try container.encodeIfPresent(color, forKey: .color)
        try container.encodeIfPresent(iconColor, forKey: .iconColor)
        try container.encodeIfPresent(colorMode, forKey: .colorMode)
        try container.encodeIfPresent(mode, forKey: .mode)
        if priority { try container.encode(priority, forKey: .priority) }
    }

    /// The panel only accepts printable ASCII: strip diacritics, drop the
    /// rest, collapse whitespace, and truncate to the 80-character limit.
    static func sanitize(_ text: String) -> String {
        let folded = text.folding(options: .diacriticInsensitive, locale: nil)
        let ascii = String(String.UnicodeScalarView(folded.unicodeScalars.filter {
            (32...126).contains($0.value)
        }))
        let collapsed = ascii.split(separator: " ").joined(separator: " ")
        return String(collapsed.prefix(maxTextLength))
    }

    private static func validated(
        _ value: String, in allowed: [String], name: String
    ) throws -> String {
        guard allowed.contains(value) else {
            throw LEDSignError.invalidOption(name, allowed.joined(separator: ", "))
        }
        return value
    }

    private static func validatedColor(_ value: String, name: String) throws -> String {
        if namedColors.contains(value) { return value }
        guard value.count == 7, value.hasPrefix("#"),
              UInt32(value.dropFirst(), radix: 16) != nil else {
            throw LEDSignError.invalidOption(
                name, "#RRGGBB or " + namedColors.joined(separator: ", ")
            )
        }
        return value
    }
}

nonisolated enum LEDSignClient {
    /// Builds the POST /messages request, or throws when the endpoint is
    /// missing/malformed. Split from send() so tests cover it without a server.
    static func request(for message: LEDSignMessage, endpoint: String?) throws -> URLRequest {
        guard let endpoint else { throw LEDSignError.notConfigured }
        guard let url = URL(string: "http://\(endpoint)/messages"),
              let host = url.host, !host.isEmpty, url.path == "/messages" else {
            throw LEDSignError.invalidEndpoint
        }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(message)
        return request
    }

    static func send(
        _ message: LEDSignMessage,
        endpoint: String? = UserPreferences.ledSignEndpoint(),
        session: URLSession? = nil
    ) async throws {
        let request = try request(for: message, endpoint: endpoint)
        let session = session ?? SOCKSProxy.urlSession(proxied: UserPreferences.ledSignUseProxy())
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw LEDSignError.requestFailed(body.isEmpty ? "HTTP \(status)" : body)
        }
    }
}

// MARK: - Chat tool

nonisolated enum LEDSignToolError: LocalizedError, Equatable {
    case unsupportedTool(String)
    case missingArgument(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedTool: "That LED sign request was invalid."
        case .missingArgument(let name): "The ‘\(name)’ argument is required."
        }
    }
}

nonisolated struct LEDSignToolRequest: Equatable, Sendable {
    let message: LEDSignMessage

    init(toolCall: ChatToolCall) throws {
        guard toolCall.name == "send_led_sign" else {
            throw LEDSignToolError.unsupportedTool(toolCall.name)
        }
        let args = ToolCallArguments(toolCall)
        message = try LEDSignMessage(
            text: try args.required("text", onMissing: LEDSignToolError.missingArgument),
            duration: args.number("duration") ?? 10,
            animation: args.string("animation") ?? "scroll",
            icon: args.string("icon"),
            color: args.string("color"),
            iconColor: args.string("icon_color"),
            colorMode: args.string("color_mode"),
            mode: args.string("mode"),
            priority: toolCall.arguments["priority"]?.boolValue ?? false
        )
    }
}

@MainActor
final class LEDSignToolService {
    private let send: @MainActor (LEDSignMessage) async throws -> Void

    init(send: @escaping @MainActor (LEDSignMessage) async throws -> Void = {
        try await LEDSignClient.send($0)
    }) {
        self.send = send
    }

    func execute(_ request: LEDSignToolRequest) async -> ChatToolResult {
        do {
            try await send(request.message)
            return ChatToolResult(response: [
                "status": .string("ok"),
                "message": .string("Displayed “\(request.message.text)” on the LED sign."),
            ])
        } catch LEDSignError.notConfigured {
            return .error("The LED sign has no endpoint. Set one in Electragne Settings → Integrations.")
        } catch {
            return .error("LED sign send failed: \(error.localizedDescription)")
        }
    }
}
