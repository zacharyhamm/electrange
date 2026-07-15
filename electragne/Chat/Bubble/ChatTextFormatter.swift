//
//  ChatTextFormatter.swift
//  electragne
//

import AppKit
import SwiftUI

/// Renders chat text with inline markdown (bold, italics, [title](url)
/// links) and makes bare URLs tappable; SwiftUI Text opens links with the
/// default browser.
enum ChatTextFormatter {
    nonisolated static func linkified(_ text: String) -> AttributedString {
        var attributed = (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(text)

        // Second pass: bare URLs the markdown parser left as plain text.
        if let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) {
            let plain = String(attributed.characters)
            let fullRange = NSRange(plain.startIndex..., in: plain)
            for match in detector.matches(in: plain, options: [], range: fullRange) {
                guard let url = match.url,
                      let range = Range(match.range, in: plain) else { continue }
                let startOffset = plain.distance(from: plain.startIndex, to: range.lowerBound)
                let length = plain.distance(from: range.lowerBound, to: range.upperBound)
                let lower = attributed.index(attributed.startIndex, offsetByCharacters: startOffset)
                let upper = attributed.index(lower, offsetByCharacters: length)
                // Don't clobber markdown links.
                guard !attributed[lower..<upper].runs.contains(where: { $0.link != nil }) else {
                    continue
                }
                attributed[lower..<upper].link = url
            }
        }

        for run in attributed.runs where run.link != nil {
            attributed[run.range].underlineStyle = .single
        }
        return attributed
    }

    /// AppKit rendition of `linkified` for NSTextView: inline presentation
    /// intents become concrete fonts, links keep their `.link` attribute.
    static func displayText(
        _ text: String,
        size: CGFloat = 12,
        colorScheme: ChatMathColorScheme = .light
    ) -> NSAttributedString {
        let extraction = InlineMathParser.extract(from: text)
        let attributed = linkified(extraction.protectedText)
        let base = NSFont.systemFont(ofSize: size)
        let result = NSMutableAttributedString()

        for run in attributed.runs {
            let segment = String(attributed.characters[run.range])
            var font = base
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    font = NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular)
                } else {
                    var traits: NSFontDescriptor.SymbolicTraits = []
                    if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                    if intent.contains(.emphasized) { traits.insert(.italic) }
                    if !traits.isEmpty {
                        let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
                        font = NSFont(descriptor: descriptor, size: size) ?? base
                    }
                }
            }

            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.labelColor,
            ]
            if let link = run.link {
                attributes[.link] = link
            }
            var plain = ""
            func flushPlainText() {
                guard !plain.isEmpty else { return }
                result.append(NSAttributedString(string: plain, attributes: attributes))
                plain = ""
            }

            for character in segment {
                guard let replacement = extraction.replacements[character] else {
                    plain.append(character)
                    continue
                }
                flushPlainText()
                if let latex = replacement.latex,
                   let attachment = InlineMathRenderer.attachment(
                    latex: latex,
                    font: font,
                    colorScheme: colorScheme
                   ) {
                    let rendered = NSMutableAttributedString(attachment: attachment)
                    rendered.addAttributes(
                        attributes,
                        range: NSRange(location: 0, length: rendered.length)
                    )
                    result.append(rendered)
                } else {
                    result.append(NSAttributedString(
                        string: replacement.source,
                        attributes: attributes
                    ))
                }
            }
            flushPlainText()
        }
        return result
    }
}
