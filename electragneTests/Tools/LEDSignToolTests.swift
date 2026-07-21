import Foundation
import Testing
@testable import electragne

struct LEDSignToolTests {
    @Test func sanitizesTextToPrintableASCIIAndTruncates() throws {
        #expect(LEDSignMessage.sanitize("Réunion  ☕  d'équipe") == "Reunion d'equipe")
        #expect(LEDSignMessage.sanitize(String(repeating: "a", count: 100)).count == 80)
        #expect(try LEDSignMessage(text: " Build done ").text == "Build done")
        #expect(throws: LEDSignError.invalidText) { try LEDSignMessage(text: "☕☕☕") }
    }

    @Test func validatesDurationEnumsAndColors() throws {
        #expect(throws: LEDSignError.invalidDuration) {
            try LEDSignMessage(text: "hi", duration: 0)
        }
        #expect(throws: LEDSignError.invalidDuration) {
            try LEDSignMessage(text: "hi", duration: 61)
        }
        #expect(throws: LEDSignError.invalidOption(
            "animation", LEDSignMessage.animations.joined(separator: ", ")
        )) { try LEDSignMessage(text: "hi", animation: "sparkle") }
        #expect(try LEDSignMessage(text: "hi", icon: "clock").icon == "clock")
        #expect(try LEDSignMessage(text: "hi", color: "amber").color == "amber")
        #expect(try LEDSignMessage(text: "hi", color: "#00FF88").color == "#00FF88")
        for bad in ["00FF88", "#00FF8", "#GGGGGG", "mauve"] {
            #expect(throws: LEDSignError.self) { try LEDSignMessage(text: "hi", color: bad) }
        }
    }

    @Test func buildsThePanelRequest() throws {
        let message = try LEDSignMessage(
            text: "Standup in 3 min", duration: 30, icon: "clock",
            iconColor: "amber", colorMode: "pulse", priority: true
        )
        let request = try LEDSignClient.request(for: message, endpoint: "192.168.1.50:8080")

        #expect(request.url?.absoluteString == "http://192.168.1.50:8080/messages")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try #require(request.httpBody)
        let payload = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["text"] as? String == "Standup in 3 min")
        #expect(payload["duration"] as? Double == 30)
        #expect(payload["animation"] as? String == "scroll")
        #expect(payload["icon"] as? String == "clock")
        #expect(payload["icon_color"] as? String == "amber")
        #expect(payload["color_mode"] as? String == "pulse")
        #expect(payload["priority"] as? Bool == true)
        #expect(payload["color"] == nil)
        #expect(payload["mode"] == nil)
    }

    @Test func rejectsMissingOrMalformedEndpoints() throws {
        let message = try LEDSignMessage(text: "hi")
        #expect(throws: LEDSignError.notConfigured) {
            try LEDSignClient.request(for: message, endpoint: nil)
        }
        #expect(throws: LEDSignError.invalidEndpoint) {
            try LEDSignClient.request(for: message, endpoint: "not a host")
        }
    }

    @Test func parsesTheChatToolCall() throws {
        let request = try LEDSignToolRequest(toolCall: ChatToolCall(
            id: "test", name: "send_led_sign", arguments: [
                "text": .string(" Deploy done "),
                "duration": .number(5),
                "animation": .string("blink"),
                "icon": .string("check"),
                "priority": .bool(true),
            ]
        ))
        #expect(request.message.text == "Deploy done")
        #expect(request.message.duration == 5)
        #expect(request.message.animation == "blink")
        #expect(request.message.icon == "check")
        #expect(request.message.priority)

        #expect(throws: LEDSignToolError.missingArgument("text")) {
            try LEDSignToolRequest(toolCall: ChatToolCall(
                id: "test", name: "send_led_sign", arguments: [:]
            ))
        }
    }

    @MainActor
    @Test func serviceReportsSuccessAndFailure() async throws {
        let request = try LEDSignToolRequest(toolCall: ChatToolCall(
            id: "test", name: "send_led_sign", arguments: ["text": .string("hi")]
        ))

        let ok = await LEDSignToolService(send: { _ in }).execute(request)
        #expect(ok.response["status"] == .string("ok"))

        let unconfigured = await LEDSignToolService(
            send: { _ in throw LEDSignError.notConfigured }
        ).execute(request)
        #expect(unconfigured.response["status"] == .string("error"))
    }
}
