//
//  ChatBubblePlacement.swift
//  electragne
//

import CoreGraphics
import Foundation

enum ChatBubbleTailEdge: Equatable {
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
