//
//  GmailService.swift
//  electragne
//
//  Gmail tool executor: prepare (validation + confirmation details) and
//  execute against the Gmail REST API, plus the response DTOs.
//

import Foundation

nonisolated struct GmailPreparedRequest: Sendable {
    let request: GmailToolRequest
    let account: GoogleAccount?
    let confirmation: ToolConfirmationDetails?
}

@MainActor
protocol GmailToolExecuting {
    func prepare(_ request: GmailToolRequest) async throws -> GmailPreparedRequest
    func execute(_ prepared: GmailPreparedRequest) async -> ChatToolResult
}

@MainActor
final class GmailToolService: GmailToolExecuting {
    private let accounts: any GoogleTokenProviding
    private let transport: any GoogleAPITransporting

    init(
        accounts: (any GoogleTokenProviding)? = nil,
        transport: (any GoogleAPITransporting)? = nil
    ) {
        let resolvedAccounts = accounts ?? GoogleOAuthService.shared
        self.accounts = resolvedAccounts
        self.transport = transport ?? GoogleAPITransport(tokens: resolvedAccounts)
    }

    func prepare(_ request: GmailToolRequest) async throws -> GmailPreparedRequest {
        if case .listAccounts = request {
            return GmailPreparedRequest(request: request, account: nil, confirmation: nil)
        }
        let account = try accounts.resolveAccount(id: request.accountID)
        let confirmation: ToolConfirmationDetails?
        switch request {
        case .createDraft(let to, let cc, let bcc, let subject, let body, _):
            var details = [(label: "Account", value: account.email), (label: "To", value: to)]
            if let cc { details.append(("CC", cc)) }
            if let bcc { details.append(("BCC", bcc)) }
            details.append(("Body", GoogleToolSupport.preview(body)))
            confirmation = ToolConfirmationDetails(
                title: "Create this Gmail draft?", primaryText: subject,
                details: details, actionLabel: "Create Draft"
            )
        case .sendDraft(let draftID, _):
            let draft = try await fetchDraft(id: draftID, accountID: account.id)
            confirmation = ToolConfirmationDetails(
                title: "Send this Gmail draft?",
                primaryText: draft.message.header("Subject") ?? "(No subject)",
                details: [
                    ("Account", account.email),
                    ("To", draft.message.header("To") ?? "Unknown recipient"),
                    ("Body", GoogleToolSupport.preview(GmailMessageParser.bodyText(draft.message.payload))),
                ], actionLabel: "Send"
            )
        default:
            confirmation = nil
        }
        return GmailPreparedRequest(request: request, account: account, confirmation: confirmation)
    }

    func execute(_ prepared: GmailPreparedRequest) async -> ChatToolResult {
        do {
            switch prepared.request {
            case .listAccounts:
                return accountsResult()
            case .search(let query, _, let limit):
                return try await search(query: query, account: try requireAccount(prepared), limit: limit)
            case .read(let messageID, _):
                return try await read(messageID: messageID, account: try requireAccount(prepared))
            case .createDraft(let to, let cc, let bcc, let subject, let body, _):
                return try await createDraft(
                    to: to, cc: cc, bcc: bcc, subject: subject, body: body,
                    account: try requireAccount(prepared)
                )
            case .sendDraft(let draftID, _):
                return try await sendDraft(id: draftID, account: try requireAccount(prepared))
            }
        } catch {
            return .error(error.localizedDescription)
        }
    }

    private func requireAccount(_ prepared: GmailPreparedRequest) throws -> GoogleAccount {
        guard let account = prepared.account else { throw GoogleOAuthError.accountNotFound }
        return account
    }

    private func accountsResult() -> ChatToolResult {
        let connected = accounts.accounts
        guard !connected.isEmpty else { return .error(GoogleOAuthError.noAccounts.localizedDescription) }
        return ChatToolResult(response: [
            "status": .string("ok"),
            "accounts": .array(connected.map { account in
                .object([
                    "accountID": .string(account.id),
                    "email": .string(account.email),
                    "displayName": account.displayName.map(ChatToolValue.string) ?? .null,
                    "isDefault": .bool(account.id == accounts.defaultAccountID),
                ])
            }),
        ])
    }

    private func search(query: String, account: GoogleAccount, limit: Int) async throws -> ChatToolResult {
        let data = try await transport.data(
            accountID: account.id, method: "GET", path: "gmail/v1/users/me/messages",
            query: [URLQueryItem(name: "q", value: query), URLQueryItem(name: "maxResults", value: String(limit))],
            body: nil
        )
        let list = try GoogleToolSupport.decoder.decode(GmailMessageList.self, from: data)
        var summaries: [ChatToolValue] = []
        for item in list.messages ?? [] {
            let message = try await fetchMessage(id: item.id, accountID: account.id, format: "metadata")
            summaries.append(.object([
                "messageID": .string(message.id),
                "threadID": .string(message.threadId ?? ""),
                "from": .string(message.header("From") ?? ""),
                "to": .string(message.header("To") ?? ""),
                "subject": .string(message.header("Subject") ?? "(No subject)"),
                "date": .string(message.header("Date") ?? ""),
                "snippet": .string(message.snippet ?? ""),
            ]))
        }
        return ChatToolResult(response: [
            "status": .string("ok"), "account": .string(account.email),
            "messages": .array(summaries),
        ])
    }

    private func read(messageID: String, account: GoogleAccount) async throws -> ChatToolResult {
        let message = try await fetchMessage(id: messageID, accountID: account.id, format: "full")
        return ChatToolResult(response: [
            "status": .string("ok"), "account": .string(account.email),
            "messageID": .string(message.id), "threadID": .string(message.threadId ?? ""),
            "from": .string(message.header("From") ?? ""), "to": .string(message.header("To") ?? ""),
            "cc": .string(message.header("Cc") ?? ""),
            "subject": .string(message.header("Subject") ?? "(No subject)"),
            "date": .string(message.header("Date") ?? ""),
            "body": .string(GmailMessageParser.bodyText(message.payload)),
            "attachments": .array(GmailMessageParser.attachments(message.payload).map { attachment in
                .object([
                    "filename": .string(attachment.filename),
                    "mimeType": .string(attachment.mimeType),
                    "size": .number(Double(attachment.size)),
                ])
            }),
        ])
    }

    private func createDraft(
        to: String, cc: String?, bcc: String?, subject: String, body: String,
        account: GoogleAccount
    ) async throws -> ChatToolResult {
        let raw = GmailMIME.message(to: to, cc: cc, bcc: bcc, subject: subject, body: body)
        let requestBody = try GoogleToolSupport.encoder.encode(GmailDraftCreate(message: .init(raw: raw)))
        let data = try await transport.data(
            accountID: account.id, method: "POST", path: "gmail/v1/users/me/drafts",
            query: [], body: requestBody
        )
        let draft = try GoogleToolSupport.decoder.decode(GmailDraft.self, from: data)
        return ChatToolResult(response: [
            "status": .string("created"), "account": .string(account.email),
            "draftID": .string(draft.id), "messageID": .string(draft.message.id),
            "message": .string("Gmail draft created. It has not been sent."),
        ])
    }

    private func sendDraft(id: String, account: GoogleAccount) async throws -> ChatToolResult {
        let body = try GoogleToolSupport.encoder.encode(["id": id])
        let data = try await transport.data(
            accountID: account.id, method: "POST", path: "gmail/v1/users/me/drafts/send",
            query: [], body: body
        )
        let message = try GoogleToolSupport.decoder.decode(GmailMessage.self, from: data)
        return ChatToolResult(response: [
            "status": .string("sent"), "account": .string(account.email),
            "messageID": .string(message.id), "threadID": .string(message.threadId ?? ""),
            "message": .string("The Gmail draft was sent."),
        ])
    }

    private func fetchMessage(id: String, accountID: String, format: String) async throws -> GmailMessage {
        var query = [URLQueryItem(name: "format", value: format)]
        if format == "metadata" {
            ["From", "To", "Subject", "Date"].forEach {
                query.append(URLQueryItem(name: "metadataHeaders", value: $0))
            }
        }
        let data = try await transport.data(
            accountID: accountID, method: "GET", path: "gmail/v1/users/me/messages/\(GoogleAPITransport.pathSegment(id))",
            query: query, body: nil
        )
        return try GoogleToolSupport.decoder.decode(GmailMessage.self, from: data)
    }

    private func fetchDraft(id: String, accountID: String) async throws -> GmailDraft {
        let data = try await transport.data(
            accountID: accountID, method: "GET", path: "gmail/v1/users/me/drafts/\(GoogleAPITransport.pathSegment(id))",
            query: [URLQueryItem(name: "format", value: "full")], body: nil
        )
        return try GoogleToolSupport.decoder.decode(GmailDraft.self, from: data)
    }

}

nonisolated private struct GmailMessageList: Decodable {
    struct Item: Decodable { let id: String }
    let messages: [Item]?
}

nonisolated struct GmailMessage: Codable, Sendable {
    struct Payload: Codable, Sendable {
        struct Header: Codable, Sendable { let name: String; let value: String }
        struct Body: Codable, Sendable { let data: String?; let size: Int?; let attachmentId: String? }
        let mimeType: String?
        let filename: String?
        let headers: [Header]?
        let body: Body?
        let parts: [Payload]?
    }
    let id: String
    let threadId: String?
    let snippet: String?
    let payload: Payload?

    func header(_ name: String) -> String? {
        payload?.headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

nonisolated struct GmailDraft: Decodable, Sendable {
    let id: String
    let message: GmailMessage
}

nonisolated private struct GmailDraftCreate: Encodable {
    struct Message: Encodable { let raw: String }
    let message: Message
}
