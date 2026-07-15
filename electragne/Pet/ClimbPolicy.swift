import CoreGraphics

/// Pure window-side discovery and climb/topping-out movement.
nonisolated enum ClimbPolicy {
    enum Phase: Equatable { case ascending, toppingOut }

    enum Mode: Equatable {
        case find(screen: ScreenInfo, currentX: CGFloat, newX: CGFloat,
                  footY: CGFloat, isMovingRight: Bool)
        case climb(windowID: CGWindowID, screen: ScreenInfo, onLeftSide: Bool,
                   phase: Phase, moveY: CGFloat, tickScale: CGFloat)
    }

    struct Input: Equatable {
        var env: EnvironmentSnapshot
        var mode: Mode
    }

    enum Action: Equatable {
        case none
        case begin(surface: WindowSurface, at: CGPoint)
        case move(to: CGPoint)
        case beginTopOut(at: CGPoint)
        case abort
    }

    static func evaluate(_ input: Input, random: (Int) -> Int) -> Action {
        switch input.mode {
        case .find(let screen, let currentX, let newX, let footY, let isMovingRight):
            let petSize = input.env.petFrame.width
            for candidate in input.env.windowSurfaces {
                let frame = candidate.frame
                guard frame.maxY + petSize <= screen.visibleFrame.maxY,
                      frame.maxY > footY + petSize,
                      frame.minY <= footY + petSize,
                      frame.width >= petSize else { continue }

                let crossed = isMovingRight
                    ? currentX + petSize <= frame.minX && newX + petSize >= frame.minX
                    : currentX >= frame.maxX && newX <= frame.maxX
                guard crossed, random(100) <= BehaviorConstants.climbChance else { continue }
                let x = isMovingRight ? frame.minX - petSize : frame.maxX
                return .begin(surface: candidate, at: CGPoint(x: x, y: footY))
            }
            return .none

        case .climb(let windowID, let screen, let onLeftSide, let phase, let moveY, let tickScale):
            guard let host = input.env.windowSurfaces.first(where: { $0.id == windowID }) else {
                return .abort
            }
            let petSize = input.env.petFrame.width
            guard host.frame.maxY + petSize <= screen.visibleFrame.maxY else { return .abort }
            let wallX = onLeftSide ? host.frame.minX - petSize : host.frame.maxX

            switch phase {
            case .ascending:
                let y = input.env.petFrame.origin.y + abs(moveY)
                if y >= host.frame.maxY {
                    return .beginTopOut(at: CGPoint(x: wallX, y: host.frame.maxY))
                }
                return .move(to: CGPoint(x: wallX, y: y))
            case .toppingOut:
                let targetX = onLeftSide ? host.frame.minX : host.frame.maxX - petSize
                let currentX = input.env.petFrame.origin.x
                let step = 1.5 * tickScale
                let x = abs(targetX - currentX) <= step
                    ? targetX
                    : currentX + (targetX > currentX ? step : -step)
                return .move(to: CGPoint(x: x, y: host.frame.maxY))
            }
        }
    }
}
