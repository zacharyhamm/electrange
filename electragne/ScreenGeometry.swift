//
//  ScreenGeometry.swift
//  electragne
//
//  Pure, display-free geometry helpers extracted from PetViewModel and the
//  window/dock detectors so the multi-monitor seam logic and the Quartz↔Cocoa
//  coordinate flip can be unit-tested with synthetic [CGRect] layouts.
//

import CoreGraphics

enum ScreenGeometry {
    /// Index of the screen frame spanning `x` whose bottom edge is at or below
    /// `y`, preferring the highest such ground (the surface a falling pet would
    /// meet first). Returns nil if no frame qualifies.
    ///
    /// Mirrors the former PetViewModel.screenContaining(x:below:).
    static func screenContaining(x: CGFloat, below y: CGFloat, in frames: [CGRect]) -> Int? {
        frames.indices
            .filter { x >= frames[$0].minX && x < frames[$0].maxX && frames[$0].minY <= y + 1 }
            .max { frames[$0].minY < frames[$1].minY }
    }

    /// Index of a frame the pet can step onto across `screenIndex`'s left or
    /// right edge: it must touch that seam, be open at the pet's height, and
    /// have ground reachable (at/below the feet, or a ledge within `maxStepUp`).
    /// Prefers the candidate whose ground is nearest the pet's feet.
    ///
    /// Mirrors the former PetViewModel.walkableScreen(beyond:movingRight:footY:).
    static func walkableScreen(beyond screenIndex: Int, movingRight: Bool, footY: CGFloat,
                               maxStepUp: CGFloat, in frames: [CGRect]) -> Int? {
        guard frames.indices.contains(screenIndex) else { return nil }
        let screen = frames[screenIndex]
        let seamX = movingRight ? screen.maxX : screen.minX
        let candidates = frames.indices.filter { i in
            guard i != screenIndex else { return false }
            let touchingEdge = movingRight ? frames[i].minX : frames[i].maxX
            guard abs(touchingEdge - seamX) < 1 else { return false }
            guard frames[i].maxY > footY else { return false }
            return frames[i].minY <= footY + maxStepUp
        }
        return candidates.min { abs(frames[$0].minY - footY) < abs(frames[$1].minY - footY) }
    }

    /// Convert a Quartz (top-left origin, y measured downward from the primary
    /// screen's top) y-coordinate to a Cocoa (bottom-left origin) y-coordinate.
    static func cocoaY(quartzY y: CGFloat, height: CGFloat, primaryMaxY: CGFloat) -> CGFloat {
        primaryMaxY - y - height
    }

    /// Convert a Quartz-origin rect to NSScreen (bottom-left origin) coordinates.
    static func cocoaRect(x: CGFloat, quartzY y: CGFloat, width: CGFloat, height: CGFloat,
                          primaryMaxY: CGFloat) -> CGRect {
        CGRect(x: x, y: cocoaY(quartzY: y, height: height, primaryMaxY: primaryMaxY),
               width: width, height: height)
    }
}
