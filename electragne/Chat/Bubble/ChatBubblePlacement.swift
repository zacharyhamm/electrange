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
struct ChatBubblePlacement: Equatable {
    static let defaultSize = CGSize(width: 320, height: 140)
    static let expandedSize = CGSize(width: 340, height: 380)
    static let minPanelSize = CGSize(width: 320, height: 140)
    static let maxPanelSize = CGSize(width: 720, height: 900)
    static let screenMargin: CGFloat = 8
    static let petGap: CGFloat = 4

    let origin: CGPoint
    let tailEdge: ChatBubbleTailEdge
    let tailOffset: CGFloat

    /// The largest bubble that still fits the visible frame with margins and
    /// leaves room for the pet (plus gap) stacked below it. Never smaller
    /// than minPanelSize so the panel's min/max stay consistent.
    static func maxSize(petFrame: CGRect, visibleFrame: CGRect) -> CGSize {
        CGSize(
            width: max(
                minPanelSize.width,
                min(maxPanelSize.width, visibleFrame.width - 2 * screenMargin)
            ),
            height: max(
                minPanelSize.height,
                min(
                    maxPanelSize.height,
                    visibleFrame.height - 2 * screenMargin - petFrame.height - petGap
                )
            )
        )
    }

    static func calculate(
        petFrame: CGRect,
        visibleFrame: CGRect,
        bubbleSize: CGSize = defaultSize
    ) -> ChatBubblePlacement {
        let minX = visibleFrame.minX + screenMargin
        let maxX = visibleFrame.maxX - screenMargin - bubbleSize.width
        let desiredX = petFrame.midX - bubbleSize.width / 2
        let x = maxX >= minX ? min(max(desiredX, minX), maxX) : visibleFrame.minX

        let aboveY = petFrame.maxY + petGap
        let fitsAbove = aboveY + bubbleSize.height <= visibleFrame.maxY - screenMargin
        let tailEdge: ChatBubbleTailEdge = fitsAbove ? .bottom : .top

        let desiredY = fitsAbove
            ? aboveY
            : petFrame.minY - petGap - bubbleSize.height
        let minY = visibleFrame.minY + screenMargin
        let maxY = visibleFrame.maxY - screenMargin - bubbleSize.height
        let y = maxY >= minY ? min(max(desiredY, minY), maxY) : visibleFrame.minY

        let minimumTailOffset: CGFloat = 28
        let tailOffset = min(
            max(petFrame.midX - x, minimumTailOffset),
            bubbleSize.width - minimumTailOffset
        )

        return ChatBubblePlacement(
            origin: CGPoint(x: x, y: y),
            tailEdge: tailEdge,
            tailOffset: tailOffset
        )
    }
}
