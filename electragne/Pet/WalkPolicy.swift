import CoreGraphics

/// Pure ground-walking decisions across docks, windows, and display seams.
nonisolated enum WalkPolicy {
    struct Input: Equatable {
        var env: EnvironmentSnapshot
        var screenIndex: Int
        var moveX: CGFloat
        var isMovingRight: Bool
    }

    enum Action: Equatable {
        case move(to: CGPoint)
        case turnAround(at: CGPoint)
        case crossSeam(to: CGPoint, screenIndex: Int)
        case beginClimb(WindowSurface, at: CGPoint)
        case beginLedgeJump(from: CGPoint, targetX: CGFloat, targetY: CGFloat)
        case fallOffEdge(at: CGPoint)
        case beginDockApproach(at: CGPoint)
    }

    static func evaluate(_ input: Input, random: (Int) -> Int) -> Action {
        guard input.env.screens.indices.contains(input.screenIndex) else {
            return .move(to: input.env.petFrame.origin)
        }
        let screen = input.env.screens[input.screenIndex]
        let frame = input.env.petFrame
        let petSize = frame.width
        let currentX = frame.origin.x
        let footY = frame.origin.y
        let newX = currentX + (input.isMovingRight ? abs(input.moveX) : -abs(input.moveX))

        if let dock = input.env.dockInfo, dock.position == .bottom, footY < dock.frame.maxY {
            if input.isMovingRight,
               currentX + petSize <= dock.frame.minX,
               newX + petSize >= dock.frame.minX {
                return .beginDockApproach(at: CGPoint(x: dock.frame.minX - petSize, y: footY))
            }
            if !input.isMovingRight,
               currentX >= dock.frame.maxX,
               newX <= dock.frame.maxX {
                return .beginDockApproach(at: CGPoint(x: dock.frame.maxX, y: footY))
            }
        }

        let climb = ClimbPolicy.evaluate(.init(
            env: input.env,
            mode: .find(screen: screen, currentX: currentX, newX: newX,
                        footY: footY, isMovingRight: input.isMovingRight)
        ), random: random)
        if case .begin(let surface, let point) = climb {
            return .beginClimb(surface, at: point)
        }

        var crossedScreenIndex: Int?
        if input.isMovingRight, newX + petSize > screen.frame.maxX {
            if let next = walkableScreen(input, footY: footY) {
                if input.env.screens[next].frame.minY > footY + 1 {
                    return .beginLedgeJump(
                        from: CGPoint(x: min(newX, screen.frame.maxX - petSize), y: footY),
                        targetX: screen.frame.maxX + petSize * 0.5,
                        targetY: input.env.screens[next].frame.minY
                    )
                }
                crossedScreenIndex = next
            } else {
                return .turnAround(at: CGPoint(x: screen.frame.maxX - petSize, y: footY))
            }
        } else if !input.isMovingRight, newX < screen.frame.minX {
            if let next = walkableScreen(input, footY: footY) {
                if input.env.screens[next].frame.minY > footY + 1 {
                    return .beginLedgeJump(
                        from: CGPoint(x: max(newX, screen.frame.minX), y: footY),
                        targetX: screen.frame.minX - petSize * 1.5,
                        targetY: input.env.screens[next].frame.minY
                    )
                }
                crossedScreenIndex = next
            } else {
                return .turnAround(at: CGPoint(x: screen.frame.minX, y: footY))
            }
        }

        guard let support = ScreenGeometry.screenContaining(
            x: newX + petSize / 2,
            below: footY,
            in: input.env.screens.map(\.frame)
        ) else {
            return .move(to: CGPoint(x: newX, y: footY))
        }
        if footY > input.env.screens[support].frame.minY + 1 {
            return .fallOffEdge(at: CGPoint(x: newX, y: footY))
        }
        let point = CGPoint(x: newX, y: input.env.screens[support].frame.minY)
        if let crossedScreenIndex { return .crossSeam(to: point, screenIndex: crossedScreenIndex) }
        return .move(to: point)
    }

    private static func walkableScreen(_ input: Input, footY: CGFloat) -> Int? {
        ScreenGeometry.walkableScreen(
            beyond: input.screenIndex,
            movingRight: input.isMovingRight,
            footY: footY,
            maxStepUp: PhysicsConstants.maxScreenStepUp,
            in: input.env.screens.map(\.frame)
        )
    }
}
