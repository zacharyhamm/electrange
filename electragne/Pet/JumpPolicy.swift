//
//  JumpPolicy.swift
//  electragne
//

import CoreGraphics

/// Pure per-tick decisions shared by animation-driven and ballistic jumps.
nonisolated enum JumpPolicy {
    enum Motion: Equatable {
        case animation(moveX: CGFloat, moveY: CGFloat, isMovingRight: Bool, screenIndex: Int)
        case ballistic(BallisticJump)
    }

    struct Input: Equatable {
        var env: EnvironmentSnapshot
        var motion: Motion
    }

    enum Action: Equatable {
        case move(to: CGPoint, ballistic: BallisticJump?)
        case complete(at: CGPoint)
    }

    static func evaluate(_ input: Input) -> Action {
        switch input.motion {
        case .ballistic(var jump):
            guard let point = jump.advance() else { return .complete(at: jump.target) }
            return .move(to: point, ballistic: jump)

        case .animation(let moveX, let moveY, let isMovingRight, let screenIndex):
            guard input.env.screens.indices.contains(screenIndex) else {
                return .move(to: input.env.petFrame.origin, ballistic: nil)
            }
            let screen = input.env.screens[screenIndex]
            let petSize = input.env.petFrame.width
            var point = input.env.petFrame.origin
            point.x += isMovingRight ? abs(moveX) : -abs(moveX)
            point.y -= moveY * 2

            var minX = screen.frame.minX
            var maxX = screen.frame.maxX - petSize
            if let nextIndex = ScreenGeometry.walkableScreen(
                beyond: screenIndex,
                movingRight: isMovingRight,
                footY: screen.frame.minY,
                maxStepUp: PhysicsConstants.maxScreenStepUp,
                in: input.env.screens.map(\.frame)
            ), input.env.screens[nextIndex].frame.minY <= screen.frame.minY + 1 {
                if isMovingRight {
                    maxX = input.env.screens[nextIndex].frame.maxX - petSize
                } else {
                    minX = input.env.screens[nextIndex].frame.minX
                }
            }
            point.x = max(minX, min(point.x, maxX))
            point.y = max(screen.frame.minY, point.y)
            return .move(to: point, ballistic: nil)
        }
    }
}
