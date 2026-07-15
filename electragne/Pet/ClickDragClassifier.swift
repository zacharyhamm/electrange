//
//  ClickDragClassifier.swift
//  electragne
//
//  Click-vs-drag is decided from screen-space mouse travel, not
//  gesture-local coordinates: while the pet walks, the window moves under
//  a stationary cursor, which reads as pointer movement in window space
//  and would defeat a TapGesture.
//

import CoreGraphics
import Foundation

nonisolated enum ClickDragClassifier {
    /// Screen-space mouse travel below which a press counts as a click.
    static let dragActivationDistance: CGFloat = 3

    static func isDrag(
        from start: CGPoint,
        to end: CGPoint,
        threshold: CGFloat = dragActivationDistance
    ) -> Bool {
        hypot(end.x - start.x, end.y - start.y) >= threshold
    }
}
