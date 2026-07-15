//
//  GmailToolRequest.swift
//  electragne
//
//  Parsing and validation of Gmail tool calls.
//

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
        case "list_google_accounts":
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
