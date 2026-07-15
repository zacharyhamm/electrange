//
//  LinkedText.swift
//  electragne
//
//  NSTextView-backed chat text rendering with an offscreen TextKit measurer.
//

import AppKit
import SwiftUI

/// Offscreen TextKit stack used to measure chat text. Measuring must never
/// touch the displayed NSTextView's own text container: mutating it during
/// SwiftUI's sizing probes leaves the container and frame inconsistent, which
/// breaks reflow when the bubble is resized.
@MainActor
private enum ChatTextMeasurer {
    private static let storage = NSTextStorage()
    private static let manager = NSLayoutManager()
    private static let container: NSTextContainer = {
        let container = NSTextContainer(size: .zero)
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        return container
    }()

    static func size(of attributed: NSAttributedString, width: CGFloat) -> CGSize {
        storage.setAttributedString(attributed)
        container.size = NSSize(width: max(width, 8), height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        return CGSize(
            width: min(used.width.rounded(.up), width),
            height: used.height.rounded(.up)
        )
    }
}

/// Chat text rendered by NSTextView so links get the pointing-hand cursor on
/// hover — SwiftUI Text can't change the cursor per-run. Also provides native
/// text selection and opens links with the default browser.
struct LinkedText: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let text: String
    var fontSize: CGFloat = UserPreferences.defaultChatFontSize

    /// Caches the formatted string and its measurements so repeated SwiftUI
    /// update/sizing passes don't re-run markdown parsing, link detection,
    /// and TextKit layout when nothing changed.
    final class Coordinator {
        private var cachedText: String?
        private var cachedFontSize: CGFloat?
        private var cachedColorScheme: ChatMathColorScheme?
        private var cachedDisplay: NSAttributedString?
        private var sizesByWidth: [CGFloat: CGSize] = [:]
        var appliedToView = false

        func display(
            for text: String,
            size: CGFloat,
            colorScheme: ChatMathColorScheme
        ) -> NSAttributedString {
            if let cachedDisplay,
               cachedText == text,
               cachedFontSize == size,
               cachedColorScheme == colorScheme {
                return cachedDisplay
            }
            let display = ChatTextFormatter.displayText(
                text,
                size: size,
                colorScheme: colorScheme
            )
            cachedText = text
            cachedFontSize = size
            cachedColorScheme = colorScheme
            cachedDisplay = display
            sizesByWidth = [:]
            appliedToView = false
            return display
        }

        func measuredSize(for display: NSAttributedString, width: CGFloat) -> CGSize {
            if let cached = sizesByWidth[width] {
                return cached
            }
            let size = ChatTextMeasurer.size(of: display, width: width)
            sizesByWidth[width] = size
            return size
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        // Track the final SwiftUI-assigned frame so text re-wraps to the real
        // width even when it differs from the last sizeThatFits probe.
        view.textContainer?.widthTracksTextView = true
        view.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        let display = context.coordinator.display(
            for: text,
            size: fontSize,
            colorScheme: colorScheme == .dark ? .dark : .light
        )
        if !context.coordinator.appliedToView {
            view.textStorage?.setAttributedString(display)
            context.coordinator.appliedToView = true
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSTextView,
        context: Context
    ) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            ?? ChatBubblePlacement.defaultSize.width
        let display = context.coordinator.display(
            for: text,
            size: fontSize,
            colorScheme: colorScheme == .dark ? .dark : .light
        )
        return context.coordinator.measuredSize(for: display, width: width)
    }
}
