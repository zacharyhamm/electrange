//
//  BallisticJump.swift
//  electragne
//
//  One in-flight, progress-driven jump arc. Pure value type: no AppKit, no
//  timers, no window. It unifies the dock, ledge, and jump-off-dock arcs that
//  PetViewModel previously hand-rolled with loose jumpProgress/jumpStart*/
//  jumpTarget* ivars. The numeric constants are exactly those the originals
//  used — the arc shapes are hand-tuned by feel, so the BallisticJumpTests
//  golden values pin them against drift.
//
//  The animation-driven "basic jump" is deliberately NOT modelled here: its arc
//  comes from the jump sprite's own movement curve, not a progress parameter.
//

import CoreGraphics

struct BallisticJump {
    enum Arc: Equatable {
        /// Symmetric parabola peaking at the midpoint (dock + ledge jumps).
        case parabolic(height: CGFloat)
        /// Rises linearly to `height` at `peak`, then falls linearly to 0
        /// (the jump-off-dock arc: a quick rise then a long descent).
        case piecewise(height: CGFloat, peak: CGFloat)

        /// Vertical offset above the linear base path at progress `t` in 0...1.
        func offset(at t: CGFloat) -> CGFloat {
            switch self {
            case .parabolic(let h):
                return h * 4 * t * (1 - t)
            case .piecewise(let h, let peak):
                return t < peak ? h * (t / peak) : h * (1 - (t - peak) / (1 - peak))
            }
        }
    }

    let start: CGPoint
    let target: CGPoint
    let arc: Arc
    /// Progress added per tick (0.05 for dock/ledge, 0.033 for jump-off).
    let step: CGFloat
    /// Whether the position is clamped to stay at/above target.y (jump-off).
    let clampToTargetY: Bool
    private(set) var progress: CGFloat = 0

    /// Advance one tick. Returns the new origin, or nil once the arc completes
    /// (progress reached 1.0) so the caller runs its own landing logic.
    mutating func advance() -> CGPoint? {
        progress += step
        if progress >= 1.0 {
            progress = 1.0
            return nil
        }
        let x = start.x + (target.x - start.x) * progress
        let baseY = start.y + (target.y - start.y) * progress
        let y = baseY + arc.offset(at: progress)
        return CGPoint(x: x, y: clampToTargetY ? max(target.y, y) : y)
    }
}
