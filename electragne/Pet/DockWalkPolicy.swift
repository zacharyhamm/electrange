import CoreGraphics

/// Pure horizontal movement and edge detection while walking on the Dock.
nonisolated enum DockWalkPolicy {
    struct Input: Equatable {
        var env: EnvironmentSnapshot
        var moveX: CGFloat
        var isMovingRight: Bool
    }

    enum Action: Equatable {
        case move(to: CGPoint)
        case lookDown(at: CGPoint)
        case fall
    }

    static func evaluate(_ input: Input) -> Action {
        guard let dock = input.env.dockInfo else { return .fall }
        let frame = input.env.petFrame
        var x = frame.origin.x + (input.isMovingRight ? abs(input.moveX) : -abs(input.moveX))
        let atRightEdge = x + frame.width >= dock.frame.maxX
        let atLeftEdge = x <= dock.frame.minX
        if atRightEdge || atLeftEdge {
            x = atRightEdge ? dock.frame.maxX - frame.width : dock.frame.minX
            return .lookDown(at: CGPoint(x: x, y: frame.origin.y))
        }
        return .move(to: CGPoint(x: x, y: dock.frame.maxY))
    }
}
