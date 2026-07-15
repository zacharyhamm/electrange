import Foundation

nonisolated enum GmailToolRequest: Equatable, Sendable {
    case listAccounts
    case search(query: String, accountID: String?, limit: Int)
    case read(messageID: String, accountID: String?)
    case createDraft(to: String, cc: String?, bcc: String?, subject: String, body: String, accountID: String?)
    case sendDraft(draftID: String, accountID: String?)

    init(toolCall: ChatToolCall) throws {
        func value(_ key: String) -> String? {
            let text = toolCall.arguments[key]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        }
        func required(_ key: String) throws -> String {
            guard let text = value(key) else { throw GmailToolError.missingArgument(key) }
            return text
        }
        let accountID = value("accountID")

        switch toolCall.name {
        case "list_google_accounts", "list_gmail_accounts":
            self = .listAccounts
        case "search_gmail":
            let rawLimit = toolCall.arguments["limit"]?.numberValue ?? 10
            guard rawLimit.isFinite, rawLimit.rounded() == rawLimit, (1...25).contains(Int(rawLimit)) else {
                throw GmailToolError.invalidLimit
            }
            self = .search(query: try required("query"), accountID: accountID, limit: Int(rawLimit))
        case "read_gmail_message":
            self = .read(messageID: try required("messageID"), accountID: accountID)
        case "create_gmail_draft":
            let to = try required("to")
            let cc = value("cc")
            let bcc = value("bcc")
            let subject = try required("subject")
            guard Self.validRecipients(to), cc.map(Self.validRecipients) ?? true,
                  bcc.map(Self.validRecipients) ?? true else {
                throw GmailToolError.invalidRecipients
            }
            guard subject.rangeOfCharacter(from: .newlines) == nil else {
                throw GmailToolError.invalidSubject
            }
            self = .createDraft(
                to: to, cc: cc, bcc: bcc,
                subject: subject, body: try required("body"), accountID: accountID
            )
        case "send_gmail_draft":
            self = .sendDraft(draftID: try required("draftID"), accountID: accountID)
        default:
            throw GmailToolError.unsupportedTool(toolCall.name)
        }
    }

    var accountID: String? {
        switch self {
        case .listAccounts: nil
        case .search(_, let id, _), .read(_, let id), .createDraft(_, _, _, _, _, let id), .sendDraft(_, let id): id
        }
    }

    private static func validRecipients(_ raw: String) -> Bool {
        let addresses = raw.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return !addresses.isEmpty && addresses.allSatisfy { address in
            let parts = address.split(separator: "@", omittingEmptySubsequences: false)
            return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".")
                && !address.contains(where: \Character.isWhitespace)
        }
    }
}

nonisolated enum GmailToolError: LocalizedError, Equatable {
    case unsupportedTool(String)
    case missingArgument(String)
    case invalidLimit
    case invalidRecipients
    case invalidSubject
    case invalidResponse
    case api(Int, String)

    var errorDescription: String? {
        switch self {
        case .unsupportedTool: "Unsupported Gmail tool."
        case .missingArgument(let name): "The ‘\(name)’ argument is required."
        case .invalidLimit: "Gmail result limit must be a whole number from 1 to 25."
        case .invalidRecipients: "One or more email recipient addresses are invalid."
        case .invalidSubject: "Email subjects cannot contain line breaks."
        case .invalidResponse: "Gmail returned an unreadable response."
        case .api(let status, let message): "Gmail returned HTTP \(status): \(message)"
        }
    }
}

nonisolated enum GoogleAPIError: LocalizedError, Equatable {
    case invalidResponse
    case api(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Google returned an unreadable response."
        case .api(let status, let message): "Google returned HTTP \(status): \(message)"
        }
    }
}

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
protocol GoogleAPITransporting {
    func data(
        accountID: String,
        method: String,
        path: String,
        query: [URLQueryItem],
        body: Data?
    ) async throws -> Data
}

@MainActor
final class GoogleAPITransport: GoogleAPITransporting {
    private let tokens: any GoogleTokenProviding
    private let session: URLSession
    private let baseURL: URL

    init(
        tokens: (any GoogleTokenProviding)? = nil,
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://gmail.googleapis.com")!
    ) {
        self.tokens = tokens ?? GoogleOAuthService.shared
        self.session = session
        self.baseURL = baseURL
    }

    func data(
        accountID: String,
        method: String = "GET",
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil
    ) async throws -> Data {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw GoogleAPIError.invalidResponse
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw GoogleAPIError.invalidResponse }
        let token = try await tokens.freshAccessToken(for: accountID)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GoogleAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = Self.googleErrorMessage(data) ?? "Request failed"
            throw GoogleAPIError.api(http.statusCode, message)
        }
        return data
    }

    nonisolated private static func googleErrorMessage(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }
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
            details.append(("Body", Self.preview(body)))
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
                    ("Body", Self.preview(GmailMessageParser.bodyText(draft.message.payload))),
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
        let list = try JSONDecoder().decode(GmailMessageList.self, from: data)
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
        let requestBody = try JSONEncoder().encode(GmailDraftCreate(message: .init(raw: raw)))
        let data = try await transport.data(
            accountID: account.id, method: "POST", path: "gmail/v1/users/me/drafts",
            query: [], body: requestBody
        )
        let draft = try JSONDecoder().decode(GmailDraft.self, from: data)
        return ChatToolResult(response: [
            "status": .string("created"), "account": .string(account.email),
            "draftID": .string(draft.id), "messageID": .string(draft.message.id),
            "message": .string("Gmail draft created. It has not been sent."),
        ])
    }

    private func sendDraft(id: String, account: GoogleAccount) async throws -> ChatToolResult {
        let body = try JSONEncoder().encode(["id": id])
        let data = try await transport.data(
            accountID: account.id, method: "POST", path: "gmail/v1/users/me/drafts/send",
            query: [], body: body
        )
        let message = try JSONDecoder().decode(GmailMessage.self, from: data)
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
            accountID: accountID, method: "GET", path: "gmail/v1/users/me/messages/\(id)",
            query: query, body: nil
        )
        return try JSONDecoder().decode(GmailMessage.self, from: data)
    }

    private func fetchDraft(id: String, accountID: String) async throws -> GmailDraft {
        let data = try await transport.data(
            accountID: accountID, method: "GET", path: "gmail/v1/users/me/drafts/\(id)",
            query: [URLQueryItem(name: "format", value: "full")], body: nil
        )
        return try JSONDecoder().decode(GmailDraft.self, from: data)
    }

    nonisolated private static func preview(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\n", with: " ")
        return normalized.count > 180 ? String(normalized.prefix(177)) + "…" : normalized
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

nonisolated enum GmailMessageParser {
    struct Attachment: Equatable, Sendable {
        let filename: String
        let mimeType: String
        let size: Int
    }

    static func bodyText(_ payload: GmailMessage.Payload?) -> String {
        guard let payload else { return "" }
        if payload.mimeType?.lowercased() == "text/plain", let text = decoded(payload.body?.data) {
            return text
        }
        if let plain = firstPart(payload, mimeType: "text/plain"), let text = decoded(plain.body?.data) {
            return text
        }
        let htmlPart = payload.mimeType?.lowercased() == "text/html" ? payload : firstPart(payload, mimeType: "text/html")
        guard let html = decoded(htmlPart?.body?.data) else { return "" }
        return htmlToText(html)
    }

    static func attachments(_ payload: GmailMessage.Payload?) -> [Attachment] {
        guard let payload else { return [] }
        var found: [Attachment] = []
        if let filename = payload.filename, !filename.isEmpty {
            found.append(Attachment(
                filename: filename, mimeType: payload.mimeType ?? "application/octet-stream",
                size: payload.body?.size ?? 0
            ))
        }
        for part in payload.parts ?? [] { found += attachments(part) }
        return found
    }

    static func decoded(_ raw: String?) -> String? {
        guard var raw, !raw.isEmpty else { return nil }
        raw = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        raw += String(repeating: "=", count: (4 - raw.count % 4) % 4)
        guard let data = Data(base64Encoded: raw) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func firstPart(_ payload: GmailMessage.Payload, mimeType: String) -> GmailMessage.Payload? {
        for part in payload.parts ?? [] {
            if part.mimeType?.caseInsensitiveCompare(mimeType) == .orderedSame { return part }
            if let nested = firstPart(part, mimeType: mimeType) { return nested }
        }
        return nil
    }

    private static func htmlToText(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(
            of: "(?is)<(script|style)[^>]*>.*?</\\1>", with: " ", options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "(?i)<br\\s*/?>|</(p|div|li|tr|h[1-6])\\s*>", with: "\n", options: .regularExpression
        )
        text = text.replacingOccurrences(of: "(?s)<[^>]+>", with: " ", options: .regularExpression)
        let entities = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#39;": "'", "&apos;": "'",
        ]
        for (entity, value) in entities {
            text = text.replacingOccurrences(of: entity, with: value, options: .caseInsensitive)
        }
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n\\s*\\n+", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

nonisolated enum GmailMIME {
    static func message(to: String, cc: String?, bcc: String?, subject: String, body: String) -> String {
        var headers = [
            "MIME-Version: 1.0",
            "To: \(to)",
        ]
        if let cc { headers.append("Cc: \(cc)") }
        if let bcc { headers.append("Bcc: \(bcc)") }
        headers += [
            "Subject: \(encodedHeader(subject))",
            "Content-Type: text/plain; charset=UTF-8",
            "Content-Transfer-Encoding: 8bit",
        ]
        let normalizedBody = body.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        let mime = headers.joined(separator: "\r\n") + "\r\n\r\n" + normalizedBody
        return Data(mime.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func encodedHeader(_ value: String) -> String {
        value.unicodeScalars.allSatisfy { $0.value < 128 }
            ? value
            : "=?UTF-8?B?\(Data(value.utf8).base64EncodedString())?="
    }
}
