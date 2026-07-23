//
//  ChatBubblePlacement.swift
//  electragne
//

import CoreGraphics
import Foundation

nonisolated enum ChatBubbleTailEdge: Equatable {
    case top
    case bottom
}

/// Pure placement result so screen-edge behavior can be unit tested without a window.
nonisolated struct ChatBubblePlacement: Equatable {
    static let defaultSize = CGSize(width: 320, height: 140)
    static let expandedSize = CGSize(width: 340, height: 380)
    static let minPanelSize = CGSize(width: 320, height: 140)
    static let maxPanelSize = CGSize(width: 1440, height: 900)
    static let screenMargin: CGFloat = 8
    static let petGap: CGFloat = 4
    static let terminalLayoutSpacing: CGFloat = 25 // Two 12pt gaps and a 1pt divider.

    let origin: CGPoint
    let size: CGSize
    let tailEdge: ChatBubbleTailEdge
    let tailOffset: CGFloat

    /// The largest bubble that fits above the pet inside the visible frame.
    static func maxSize(petFrame: CGRect, visibleFrame: CGRect) -> CGSize {
        CGSize(
            width: max(0, min(maxPanelSize.width, visibleFrame.width - 2 * screenMargin)),
            height: max(
                0,
                min(maxPanelSize.height, visibleFrame.maxY - screenMargin - petFrame.maxY - petGap)
            )
        )
    }

    /// Gives horizontal resize space to the terminal after preserving the
    /// chat's saved width and the layout chrome between the two columns.
    static func terminalWidth(panelWidth: CGFloat, chatWidth: CGFloat) -> CGFloat {
        max(0, panelWidth - chatWidth - terminalLayoutSpacing)
    }

    static func preferredTerminalWidth(forHeight height: CGFloat) -> CGFloat {
        (height * 1.5).rounded()
    }

    static func calculate(
        petFrame: CGRect,
        visibleFrame: CGRect,
        bubbleSize: CGSize = defaultSize
    ) -> ChatBubblePlacement {
        let maximumSize = maxSize(petFrame: petFrame, visibleFrame: visibleFrame)
        let bubbleSize = CGSize(
            width: min(max(0, bubbleSize.width), maximumSize.width),
            height: min(max(0, bubbleSize.height), maximumSize.height)
        )
        let minX = visibleFrame.minX + screenMargin
        let maxX = visibleFrame.maxX - screenMargin - bubbleSize.width
        let desiredX = petFrame.midX - bubbleSize.width / 2
        let x = maxX >= minX ? min(max(desiredX, minX), maxX) : visibleFrame.minX

        let tailInset = min(28, bubbleSize.width / 2)
        let tailOffset = min(
            max(petFrame.midX - x, tailInset),
            bubbleSize.width - tailInset
        )

        return ChatBubblePlacement(
            origin: CGPoint(x: x, y: petFrame.maxY + petGap),
            size: bubbleSize,
            tailEdge: .bottom,
            tailOffset: tailOffset
        )
    }
}
