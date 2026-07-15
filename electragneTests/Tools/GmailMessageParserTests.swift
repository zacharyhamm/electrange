import Foundation
import Testing
@testable import electragne

struct GmailMessageParserTests {
    // MARK: - base64url decoding

    @Test func decodedHandlesBase64URLAlphabetAndMissingPadding() {
        // "ab?de>" encodes to "YWI/ZGU+" in standard base64; Gmail sends the
        // URL-safe alphabet without padding.
        #expect(GmailMessageParser.decoded("YWI_ZGU-") == "ab?de>")
        // One and two padding characters stripped.
        #expect(GmailMessageParser.decoded("aGk") == "hi")
        #expect(GmailMessageParser.decoded("aGV5YQ") == "heya")
        #expect(GmailMessageParser.decoded("") == nil)
        #expect(GmailMessageParser.decoded(nil) == nil)
        #expect(GmailMessageParser.decoded("!!!!") == nil)
    }

    // MARK: - bodyText

    private func payload(
        mimeType: String,
        data: String? = nil,
        filename: String? = nil,
        size: Int? = nil,
        parts: [GmailMessage.Payload]? = nil
    ) -> GmailMessage.Payload {
        GmailMessage.Payload(
            mimeType: mimeType,
            filename: filename,
            headers: nil,
            body: data != nil || size != nil
                ? GmailMessage.Payload.Body(data: data, size: size, attachmentId: nil)
                : nil,
            parts: parts
        )
    }

    private func base64URL(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    @Test func bodyTextPrefersTopLevelPlainText() {
        let plain = payload(mimeType: "text/plain", data: base64URL("hello sheep"))
        #expect(GmailMessageParser.bodyText(plain) == "hello sheep")
    }

    @Test func bodyTextFindsNestedPlainTextPart() {
        let multipart = payload(mimeType: "multipart/alternative", parts: [
            payload(mimeType: "text/html", data: base64URL("<p>html</p>")),
            payload(mimeType: "multipart/related", parts: [
                payload(mimeType: "TEXT/PLAIN", data: base64URL("nested plain")),
            ]),
        ])
        #expect(GmailMessageParser.bodyText(multipart) == "nested plain")
    }

    @Test func bodyTextFallsBackToHTML() {
        let html = """
        <html><head><style>p { color: red }</style>\
        <script type="text/javascript">alert("hi")</script></head>
        <body><p>First&nbsp;line</p><div>Second &amp; third</div>
        Line<br>break &lt;kept&gt; &quot;quoted&quot; &#39;apos&#39;</body></html>
        """
        let message = payload(mimeType: "text/html", data: base64URL(html))
        let text = GmailMessageParser.bodyText(message)

        // Script/style bodies and all tags are stripped.
        #expect(!text.contains("alert"))
        #expect(!text.contains("color: red"))
        #expect(!text.contains("<p>") && !text.contains("<div>"))
        // Entities are decoded, &nbsp; becomes a plain space.
        #expect(text.hasPrefix("First line"))
        #expect(text.contains("Second & third"))
        #expect(text.contains("<kept> \"quoted\" 'apos'"))
        // Block-level closes become line breaks.
        #expect(text.contains("First line\n"))
    }

    @Test func bodyTextCollapsesBlankLinesAndSpaces() {
        let html = "<div>a</div><div></div><div></div><div>b   c</div>"
        let message = payload(mimeType: "text/html", data: base64URL(html))
        // The three-way blank run collapses to one blank line; the inner
        // space run collapses to one space.
        #expect(GmailMessageParser.bodyText(message) == "a\n\n b c")
    }

    @Test func bodyTextIsEmptyForMissingPayloadOrUndecodableBody() {
        #expect(GmailMessageParser.bodyText(nil) == "")
        let broken = payload(mimeType: "text/html", data: "!!!!")
        #expect(GmailMessageParser.bodyText(broken) == "")
    }

    // MARK: - attachments

    @Test func attachmentsWalksNestedParts() {
        let message = payload(mimeType: "multipart/mixed", parts: [
            payload(mimeType: "text/plain", data: base64URL("body")),
            payload(mimeType: "application/pdf", filename: "invoice.pdf", size: 1234),
            payload(mimeType: "multipart/related", parts: [
                payload(mimeType: "image/png", filename: "cat.png", size: 99),
            ]),
        ])
        let attachments = GmailMessageParser.attachments(message)
        #expect(attachments == [
            GmailMessageParser.Attachment(filename: "invoice.pdf", mimeType: "application/pdf", size: 1234),
            GmailMessageParser.Attachment(filename: "cat.png", mimeType: "image/png", size: 99),
        ])
        #expect(GmailMessageParser.attachments(nil) == [])
    }

    // MARK: - outgoing MIME

    private func decodeMIME(_ raw: String) -> String {
        var padded = raw
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
        return String(decoding: Data(base64Encoded: padded)!, as: UTF8.self)
    }

    @Test func mimeMessageBuildsCRLFHeadersAndBody() {
        let raw = GmailMIME.message(
            to: "a@example.com", cc: "b@example.com", bcc: nil,
            subject: "Hello", body: "line one\nline two"
        )
        let mime = decodeMIME(raw)
        #expect(mime == "MIME-Version: 1.0\r\n"
            + "To: a@example.com\r\n"
            + "Cc: b@example.com\r\n"
            + "Subject: Hello\r\n"
            + "Content-Type: text/plain; charset=UTF-8\r\n"
            + "Content-Transfer-Encoding: 8bit\r\n"
            + "\r\n"
            + "line one\r\nline two")
        // Output alphabet is base64url with no padding.
        #expect(!raw.contains("+") && !raw.contains("/") && !raw.contains("="))
    }

    @Test func mimeMessageEncodesNonASCIISubject() {
        let raw = GmailMIME.message(
            to: "a@example.com", cc: nil, bcc: nil,
            subject: "Grüße 🐑", body: "hi"
        )
        let mime = decodeMIME(raw)
        let expected = "Subject: =?UTF-8?B?\(Data("Grüße 🐑".utf8).base64EncodedString())?="
        #expect(mime.contains(expected))
        #expect(!mime.contains("Subject: Grüße"))
    }
}
