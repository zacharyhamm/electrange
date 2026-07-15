//
//  GmailMessageParser.swift
//  electragne
//
//  MIME/HTML-to-text extraction from Gmail message payloads, and MIME
//  encoding for outgoing drafts.
//

import Foundation

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
