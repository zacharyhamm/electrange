import AppKit
import SwiftMath

nonisolated struct InlineMathReplacement: Equatable, Sendable {
    let placeholder: Character
    let source: String
    let latex: String?
}

nonisolated struct InlineMathExtraction: Equatable, Sendable {
    let protectedText: String
    let replacements: [Character: InlineMathReplacement]
}

/// Finds inline math before Markdown parsing. Private-use placeholders keep
/// Markdown from interpreting TeX commands or emphasis characters inside a
/// formula; the formatter swaps them for native text attachments afterward.
nonisolated enum InlineMathParser {
    private static let firstPlaceholder = 0xE000

    static func extract(from text: String) -> InlineMathExtraction {
        var output = ""
        var replacements: [Character: InlineMathReplacement] = [:]
        var nextPlaceholder = firstPlaceholder
        var index = text.startIndex

        func placeholder() -> Character? {
            while nextPlaceholder <= 0xF8FF {
                defer { nextPlaceholder += 1 }
                guard let scalar = UnicodeScalar(nextPlaceholder) else { continue }
                let candidate = Character(String(scalar))
                if !text.contains(candidate) && replacements[candidate] == nil {
                    return candidate
                }
            }
            return nil
        }

        func isEscaped(_ position: String.Index) -> Bool {
            var cursor = position
            var slashes = 0
            while cursor > text.startIndex {
                let previous = text.index(before: cursor)
                guard text[previous] == "\\" else { break }
                slashes += 1
                cursor = previous
            }
            return slashes.isMultiple(of: 2) == false
        }

        func endOfDelimitedRegion(
            after contentStart: String.Index,
            closing: String,
            requireTightClosing: Bool
        ) -> String.Index? {
            var cursor = contentStart
            while cursor < text.endIndex {
                if text[cursor] == "\n" { return nil }
                if text[cursor...].hasPrefix(closing), !isEscaped(cursor) {
                    if requireTightClosing {
                        guard cursor > contentStart,
                              text[text.index(before: cursor)].isWhitespace == false else {
                            cursor = text.index(after: cursor)
                            continue
                        }
                        let after = text.index(cursor, offsetBy: closing.count)
                        if after < text.endIndex, text[after] == "$" {
                            cursor = text.index(after: cursor)
                            continue
                        }
                    }
                    return cursor
                }
                cursor = text.index(after: cursor)
            }
            return nil
        }

        func protect(
            start: String.Index,
            contentStart: String.Index,
            closingStart: String.Index,
            closing: String,
            latex: String?
        ) -> String.Index? {
            guard let marker = placeholder() else { return nil }
            let end = text.index(closingStart, offsetBy: closing.count)
            let source = String(text[start..<end])
            output.append(marker)
            replacements[marker] = InlineMathReplacement(
                placeholder: marker,
                source: source,
                latex: latex.map { _ in String(text[contentStart..<closingStart]) }
            )
            return end
        }

        func protectLiteral(start: String.Index, end: String.Index) -> Bool {
            guard let marker = placeholder() else { return false }
            let source = String(text[start..<end])
            output.append(marker)
            replacements[marker] = InlineMathReplacement(
                placeholder: marker,
                source: source,
                latex: nil
            )
            return true
        }

        while index < text.endIndex {
            // Copy code spans as one unit so math delimiters inside backticks
            // are left for Markdown's code-span handling.
            if text[index] == "`", !isEscaped(index) {
                var runEnd = index
                while runEnd < text.endIndex, text[runEnd] == "`" {
                    runEnd = text.index(after: runEnd)
                }
                let delimiter = String(text[index..<runEnd])
                if let close = text.range(of: delimiter, range: runEnd..<text.endIndex) {
                    output.append(contentsOf: text[index..<close.upperBound])
                    index = close.upperBound
                    continue
                }
            }

            // Display math is intentionally out of scope, but protect it so
            // Markdown doesn't eat its backslashes or parse dollars inside it.
            if text[index...].hasPrefix("\\[") && !isEscaped(index) {
                let contentStart = text.index(index, offsetBy: 2)
                if let close = endOfDelimitedRegion(
                    after: contentStart, closing: "\\]", requireTightClosing: false
                ), let end = protect(
                    start: index,
                    contentStart: contentStart,
                    closingStart: close,
                    closing: "\\]",
                    latex: nil
                ) {
                    index = end
                    continue
                }
                if protectLiteral(start: index, end: contentStart) {
                    index = contentStart
                    continue
                }
            }

            if text[index...].hasPrefix("$$") && !isEscaped(index) {
                let contentStart = text.index(index, offsetBy: 2)
                if let close = endOfDelimitedRegion(
                    after: contentStart, closing: "$$", requireTightClosing: false
                ), let end = protect(
                    start: index,
                    contentStart: contentStart,
                    closingStart: close,
                    closing: "$$",
                    latex: nil
                ) {
                    index = end
                    continue
                }
            }

            if text[index...].hasPrefix("\\(") && !isEscaped(index) {
                let contentStart = text.index(index, offsetBy: 2)
                if let close = endOfDelimitedRegion(
                    after: contentStart, closing: "\\)", requireTightClosing: false
                ), close > contentStart,
                   let end = protect(
                    start: index,
                    contentStart: contentStart,
                    closingStart: close,
                    closing: "\\)",
                    latex: ""
                   ) {
                    index = end
                    continue
                }
                if protectLiteral(start: index, end: contentStart) {
                    index = contentStart
                    continue
                }
            }

            if text[index] == "$", !isEscaped(index),
               !text[index...].hasPrefix("$$") {
                let contentStart = text.index(after: index)
                if contentStart < text.endIndex,
                   !text[contentStart].isWhitespace,
                   let close = endOfDelimitedRegion(
                    after: contentStart, closing: "$", requireTightClosing: true
                   ), close > contentStart,
                   let end = protect(
                    start: index,
                    contentStart: contentStart,
                    closingStart: close,
                    closing: "$",
                    latex: ""
                   ) {
                    index = end
                    continue
                }
            }

            // Preserve stray TeX-style closing delimiters verbatim too.
            if (text[index...].hasPrefix("\\)") || text[index...].hasPrefix("\\]")),
               !isEscaped(index) {
                let end = text.index(index, offsetBy: 2)
                if protectLiteral(start: index, end: end) {
                    index = end
                    continue
                }
            }

            output.append(text[index])
            index = text.index(after: index)
        }

        return InlineMathExtraction(protectedText: output, replacements: replacements)
    }
}

enum ChatMathColorScheme: String, Equatable {
    case light
    case dark
}

@MainActor
enum InlineMathRenderer {
    private static let cache = NSCache<NSString, NSImage>()

    static func attachment(
        latex: String,
        font: NSFont,
        colorScheme: ChatMathColorScheme
    ) -> NSTextAttachment? {
        let key = "\(colorScheme.rawValue)|\(font.pointSize)|\(latex)" as NSString
        let image: NSImage
        if let cached = cache.object(forKey: key) {
            image = cached
        } else {
            guard let rendered = render(
                latex: latex,
                fontSize: font.pointSize,
                colorScheme: colorScheme
            ) else { return nil }
            cache.setObject(rendered, forKey: key)
            image = rendered
        }

        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(
            x: 0,
            y: font.descender * 0.55,
            width: image.size.width,
            height: image.size.height
        )
        return attachment
    }

    private static func render(
        latex: String,
        fontSize: CGFloat,
        colorScheme: ChatMathColorScheme
    ) -> NSImage? {
        let label = MTMathUILabel(frame: .zero)
        label.displayErrorInline = false
        label.labelMode = .text
        label.fontSize = fontSize
        label.textColor = colorScheme == .dark ? .white : .black
        label.latex = latex
        guard label.error == nil else { return nil }

        let fitting = label.fittingSize
        guard fitting.width.isFinite, fitting.height.isFinite,
              fitting.width > 0, fitting.height > 0 else { return nil }
        let size = CGSize(width: fitting.width.rounded(.up), height: fitting.height.rounded(.up))
        label.frame = CGRect(origin: .zero, size: size)
        label.layoutSubtreeIfNeeded()

        let data = label.dataWithPDF(inside: label.bounds)
        guard let image = NSImage(data: data) else { return nil }
        image.size = size
        return image
    }
}
