//
//  ChatTextFormatter.swift
//  electragne
//

import AppKit
import SwiftUI

/// Renders chat Markdown and makes bare URLs tappable.
enum ChatTextFormatter {
    nonisolated static func linkified(_ text: String) -> AttributedString {
        parsed(text, syntax: .inlineOnlyPreservingWhitespace)
    }

    private nonisolated static func parsed(
        _ text: String,
        syntax: AttributedString.MarkdownParsingOptions.InterpretedSyntax
    ) -> AttributedString {
        var attributed = (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: syntax
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

    private struct BlockContext {
        let intent: PresentationIntent?

        var identity: Int? { intent?.components.first?.identity }

        var headerLevel: Int? {
            for component in intent?.components ?? [] {
                if case .header(let level) = component.kind { return level }
            }
            return nil
        }

        var listMarker: String? {
            var ordinal: Int?
            var ordered = false
            for component in intent?.components ?? [] {
                switch component.kind {
                case .listItem(let value): ordinal = value
                case .orderedList: ordered = true
                case .unorderedList: break
                default: continue
                }
            }
            guard let ordinal else { return nil }
            return ordered ? "\(ordinal). " : "• "
        }

        var isCodeBlock: Bool {
            intent?.components.contains { component in
                if case .codeBlock = component.kind { return true }
                return false
            } == true
        }

        var isBlockQuote: Bool {
            intent?.components.contains { component in
                if case .blockQuote = component.kind { return true }
                return false
            } == true
        }

        var table: (identity: Int, columns: [PresentationIntent.TableColumn])? {
            for component in intent?.components ?? [] {
                if case .table(let columns) = component.kind {
                    return (component.identity, columns)
                }
            }
            return nil
        }

        var tableCell: (row: Int, column: Int, isHeader: Bool)? {
            var row: Int?
            var column: Int?
            var isHeader = false
            for component in intent?.components ?? [] {
                switch component.kind {
                case .tableHeaderRow:
                    row = 0
                    isHeader = true
                case .tableRow(let rowIndex): row = rowIndex
                case .tableCell(let columnIndex): column = columnIndex
                default: continue
                }
            }
            guard let row, let column else { return nil }
            return (row, column, isHeader)
        }
    }

    /// AppKit rendition for NSTextView: Markdown intents become concrete
    /// fonts, paragraphs, and native text tables; links keep their attribute.
    static func displayText(
        _ text: String,
        size: CGFloat = 12,
        colorScheme: ChatMathColorScheme = .light
    ) -> NSAttributedString {
        let extraction = InlineMathParser.extract(from: text)
        let attributed = parsed(extraction.protectedText, syntax: .full)
        let base = NSFont.systemFont(ofSize: size)
        let result = NSMutableAttributedString()
        var context: BlockContext?
        var blockStart = 0
        var tables: [Int: NSTextTable] = [:]

        func paragraphStyle(for context: BlockContext) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = context.headerLevel == nil ? 3 : size * 0.35
            if context.isBlockQuote {
                style.headIndent = 10
                style.firstLineHeadIndent = 10
            }
            guard let tableInfo = context.table,
                  let cell = context.tableCell else { return style }

            let table = tables[tableInfo.identity] ?? {
                let table = NSTextTable()
                table.numberOfColumns = tableInfo.columns.count
                table.layoutAlgorithm = .fixedLayoutAlgorithm
                table.collapsesBorders = true
                table.setContentWidth(100, type: .percentageValueType)
                tables[tableInfo.identity] = table
                return table
            }()
            let block = NSTextTableBlock(
                table: table,
                startingRow: cell.row,
                rowSpan: 1,
                startingColumn: cell.column,
                columnSpan: 1
            )
            block.setContentWidth(
                100 / CGFloat(max(tableInfo.columns.count, 1)),
                type: .percentageValueType
            )
            block.setWidth(4, type: .absoluteValueType, for: .padding)
            block.setWidth(0.5, type: .absoluteValueType, for: .border)
            block.setBorderColor(NSColor.separatorColor)
            if cell.isHeader { block.backgroundColor = NSColor.controlBackgroundColor }
            style.textBlocks = [block]
            switch tableInfo.columns[cell.column].alignment {
            case .left: style.alignment = .left
            case .center: style.alignment = .center
            case .right: style.alignment = .right
            @unknown default: style.alignment = .natural
            }
            style.paragraphSpacing = 0
            return style
        }

        func finishBlock(final: Bool = false) {
            guard let context else { return }
            if !final || context.tableCell != nil {
                result.append(NSAttributedString(string: "\n"))
            }
            let range = NSRange(location: blockStart, length: result.length - blockStart)
            result.addAttribute(.paragraphStyle, value: paragraphStyle(for: context), range: range)
        }

        for run in attributed.runs {
            let nextContext = BlockContext(intent: run.presentationIntent)
            if context?.identity != nextContext.identity {
                finishBlock()
                context = nextContext
                blockStart = result.length
                if let marker = nextContext.listMarker {
                    result.append(NSAttributedString(string: marker, attributes: [
                        .font: base,
                        .foregroundColor: NSColor.labelColor,
                    ]))
                }
            }

            let segment = String(attributed.characters[run.range])
            let scale: CGFloat
            if let level = nextContext.headerLevel {
                switch level {
                case 1: scale = 1.5
                case 2: scale = 1.35
                case 3: scale = 1.2
                case 4...6: scale = 1.1
                default: scale = 1
                }
            } else {
                scale = 1
            }
            var font = nextContext.isCodeBlock
                ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
                : NSFont.systemFont(
                    ofSize: size * scale,
                    weight: nextContext.headerLevel != nil || nextContext.tableCell?.isHeader == true
                        ? .bold : .regular
                )
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    font = NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular)
                } else {
                    var traits: NSFontDescriptor.SymbolicTraits = []
                    if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                    if intent.contains(.emphasized) { traits.insert(.italic) }
                    if !traits.isEmpty {
                        traits.formUnion(font.fontDescriptor.symbolicTraits)
                        let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
                        font = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
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
        finishBlock(final: true)
        return result
    }
}
