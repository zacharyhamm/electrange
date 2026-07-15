import Foundation
import Testing
@testable import electragne

struct GmailToolRequestTests {
    @Test func parsesSearchReadAndDraftRequests() throws {
        #expect(try GmailToolRequest(toolCall: call(
            "search_gmail", ["query": .string(" from:alice "), "limit": .number(5)]
        )) == .search(query: "from:alice", accountID: nil, limit: 5))
        #expect(try GmailToolRequest(toolCall: call(
            "read_gmail_message", ["messageID": .string("m1"), "accountID": .string("a1")]
        )) == .read(messageID: "m1", accountID: "a1"))
        #expect(try GmailToolRequest(toolCall: call(
            "create_gmail_draft", [
                "to": .string("a@example.com, b@example.com"),
                "subject": .string("Hello"), "body": .string("Hi there"),
            ]
        )) == .createDraft(
            to: "a@example.com, b@example.com", cc: nil, bcc: nil,
            subject: "Hello", body: "Hi there", accountID: nil
        ))
    }

    @Test func rejectsInvalidLimitsRecipientsAndMissingArguments() {
        #expect(throws: GmailToolError.invalidLimit) {
            try GmailToolRequest(toolCall: call(
                "search_gmail", ["query": .string("in:inbox"), "limit": .number(26)]
            ))
        }
        #expect(throws: GmailToolError.invalidRecipients) {
            try GmailToolRequest(toolCall: call(
                "create_gmail_draft", [
                    "to": .string("not-an-address"), "subject": .string("Hi"), "body": .string("Body"),
                ]
            ))
        }
        #expect(throws: GmailToolError.invalidSubject) {
            try GmailToolRequest(toolCall: call(
                "create_gmail_draft", [
                    "to": .string("a@example.com"), "subject": .string("Hi\r\nBcc: x@example.com"),
                    "body": .string("Body"),
                ]
            ))
        }
        #expect(throws: GmailToolError.missingArgument("draftID")) {
            try GmailToolRequest(toolCall: call("send_gmail_draft"))
        }
    }

    private func call(_ name: String, _ arguments: [String: ChatToolValue] = [:]) -> ChatToolCall {
        ChatToolCall(id: "test", name: name, arguments: arguments)
    }
}

struct GmailContentTests {
    @Test func mimeIsRFCStyleBase64URLAndEncodesUnicodeSubject() throws {
        let raw = GmailMIME.message(
            to: "friend@example.com", cc: nil, bcc: nil,
            subject: "Hello 🐑", body: "First\nSecond"
        )
        let decoded = try #require(decodeBase64URL(raw))
        #expect(decoded.contains("To: friend@example.com\r\n"))
        #expect(decoded.contains("Subject: =?UTF-8?B?"))
        #expect(decoded.hasSuffix("First\r\nSecond"))
    }

    @Test func parserPrefersPlainTextAndListsAttachments() {
        let plain = encoded("Plain body")
        let html = encoded("<p>HTML body</p>")
        let payload = GmailMessage.Payload(
            mimeType: "multipart/mixed", filename: nil, headers: nil, body: nil,
            parts: [
                GmailMessage.Payload(
                    mimeType: "multipart/alternative", filename: nil, headers: nil, body: nil,
                    parts: [
                        GmailMessage.Payload(
                            mimeType: "text/html", filename: nil, headers: nil,
                            body: .init(data: html, size: 16, attachmentId: nil), parts: nil
                        ),
                        GmailMessage.Payload(
                            mimeType: "text/plain", filename: nil, headers: nil,
                            body: .init(data: plain, size: 10, attachmentId: nil), parts: nil
                        ),
                    ]
                ),
                GmailMessage.Payload(
                    mimeType: "application/pdf", filename: "report.pdf", headers: nil,
                    body: .init(data: nil, size: 1234, attachmentId: "att1"), parts: nil
                ),
            ]
        )

        #expect(GmailMessageParser.bodyText(payload) == "Plain body")
        #expect(GmailMessageParser.attachments(payload) == [
            .init(filename: "report.pdf", mimeType: "application/pdf", size: 1234)
        ])
    }

    private func encoded(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func decodeBase64URL(_ value: String) -> String? {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64).flatMap { String(data: $0, encoding: .utf8) }
    }
}

@MainActor
struct GmailToolServiceTests {
    @Test func usesDefaultAccountAndSeparatesDraftFromSend() async throws {
        let tokens = MockGoogleTokens()
        let transport = MockGoogleTransport()
        let service = GmailToolService(accounts: tokens, transport: transport)

        let create = GmailToolRequest.createDraft(
            to: "friend@example.com", cc: nil, bcc: nil,
            subject: "Lunch", body: "Noon?", accountID: nil
        )
        let preparedCreate = try await service.prepare(create)
        #expect(preparedCreate.account?.email == "one@example.com")
        #expect(preparedCreate.confirmation?.actionLabel == "Create Draft")
        let created = await service.execute(preparedCreate)
        #expect(created.response["draftID"]?.stringValue == "d1")
        #expect(transport.requests.last?.path == "gmail/v1/users/me/drafts")

        let preparedSend = try await service.prepare(.sendDraft(draftID: "d1", accountID: nil))
        #expect(preparedSend.confirmation?.primaryText == "Lunch")
        #expect(preparedSend.confirmation?.details.first { $0.label == "To" }?.value == "friend@example.com")
        #expect(!transport.requests.contains { $0.path.hasSuffix("drafts/send") })

        let sent = await service.execute(preparedSend)
        #expect(sent.response["status"]?.stringValue == "sent")
        #expect(transport.requests.last?.path == "gmail/v1/users/me/drafts/send")
    }
}

@MainActor
private final class MockGoogleTokens: GoogleTokenProviding {
    let accounts = [
        GoogleAccount(id: "a1", email: "one@example.com", displayName: "One"),
        GoogleAccount(id: "a2", email: "two@example.com", displayName: "Two"),
    ]
    let defaultAccountID: String? = "a1"

    func resolveAccount(id: String?) throws -> GoogleAccount {
        let resolved = id ?? defaultAccountID
        guard let account = accounts.first(where: { $0.id == resolved }) else {
            throw GoogleOAuthError.accountNotFound
        }
        return account
    }

    func freshAccessToken(for accountID: String) async throws -> String { "token" }
}

@MainActor
private final class MockGoogleTransport: GoogleAPITransporting {
    struct Request { let accountID: String; let method: String; let path: String; let body: Data? }
    var requests: [Request] = []

    func data(
        accountID: String, method: String, path: String,
        query: [URLQueryItem], body: Data?
    ) async throws -> Data {
        requests.append(Request(accountID: accountID, method: method, path: path, body: body))
        switch (method, path) {
        case ("POST", "gmail/v1/users/me/drafts"):
            return Data(#"{"id":"d1","message":{"id":"m1"}}"#.utf8)
        case ("GET", "gmail/v1/users/me/drafts/d1"):
            return Data(#"{"id":"d1","message":{"id":"m1","payload":{"headers":[{"name":"To","value":"friend@example.com"},{"name":"Subject","value":"Lunch"}],"body":{"data":"Tm9vbj8","size":5}}}}"#.utf8)
        case ("POST", "gmail/v1/users/me/drafts/send"):
            return Data(#"{"id":"m1","threadId":"t1"}"#.utf8)
        default:
            throw GmailToolError.invalidResponse
        }
    }
}
