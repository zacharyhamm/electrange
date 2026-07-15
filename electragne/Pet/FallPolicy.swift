//
//  FallPolicy.swift
//  electragne
//

import CoreGraphics

/// Pure gravity, collision, and bounce decisions for the falling state.
nonisolated enum FallPolicy {
    enum LandingSurface: Equatable {
        case ground
        case dock
        case window(CGWindowID)
    }

    struct Input: Equatable {
        var env: EnvironmentSnapshot
        var velocity: CGFloat
        var bounceCount: Int
        var tickScale: CGFloat
        var landOnWindows: Bool
    }

    enum Action: Equatable {
        case move(to: CGPoint, velocity: CGFloat, bounceCount: Int, landedHard: Bool?)
        case settle(at: CGPoint, surface: LandingSurface, landedHard: Bool)
    }

    static func evaluate(_ input: Input) -> Action {
        let frame = input.env.petFrame
        let velocity = input.velocity + PhysicsConstants.gravity * input.tickScale
        var newY = frame.origin.y - velocity * input.tickScale
        let ground = groundInfo(
            in: input.env,
            x: frame.origin.x,
            petWidth: frame.width,
            below: frame.origin.y,
            includeWindows: input.landOnWindows
        )

        guard newY <= ground.level else {
            return .move(
                to: CGPoint(x: frame.origin.x, y: newY),
                velocity: velocity,
                bounceCount: input.bounceCount,
                landedHard: nil
            )
        }

        newY = ground.level
        let landedHard = abs(velocity) > PhysicsConstants.hardLandingThreshold
        let bouncedVelocity = -velocity * PhysicsConstants.bounceDamping
        let bounceCount = input.bounceCount + 1

        if bounceCount > PhysicsConstants.maxBounces
            || abs(bouncedVelocity) < PhysicsConstants.minBounceVelocity {
            return .settle(
                at: CGPoint(x: frame.origin.x, y: newY),
                surface: ground.surface,
                landedHard: landedHard
            )
        }

        return .move(
            to: CGPoint(x: frame.origin.x, y: newY),
            velocity: bouncedVelocity,
            bounceCount: bounceCount,
            landedHard: landedHard
        )
    }

    private static func groundInfo(
        in env: EnvironmentSnapshot,
        x: CGFloat,
        petWidth: CGFloat,
        below y: CGFloat,
        includeWindows: Bool
    ) -> (level: CGFloat, surface: LandingSurface) {
        guard let screenIndex = ScreenGeometry.screenContaining(
            x: x + petWidth / 2,
            below: y,
            in: env.screens.map(\.frame)
        ) else { return (0, .ground) }

        let screen = env.screens[screenIndex]
        var level = screen.frame.minY
        var surface = LandingSurface.ground

        if let dock = env.dockInfo, dock.position == .bottom,
           dock.containsX(x, petWidth: petWidth) {
            level = dock.frame.maxY
            surface = .dock
        }

        if includeWindows {
            for candidate in env.windowSurfaces {
                let frame = candidate.frame
                guard frame.maxY > level, frame.maxY <= y,
                      x + petWidth > frame.minX, x < frame.maxX,
                      frame.maxY + petWidth <= screen.visibleFrame.maxY,
                      frame.width >= petWidth else { continue }
                level = frame.maxY
                surface = .window(candidate.id)
            }
        }

        return (level, surface)
    }
}
