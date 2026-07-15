import CoreGraphics

/// Pure movement decisions while riding the top of another application's window.
nonisolated enum WindowTopPolicy {
    struct Input: Equatable {
        var env: EnvironmentSnapshot
        var windowID: CGWindowID
        var screen: ScreenInfo
        var moveX: CGFloat
        var isMovingRight: Bool
    }

    enum Action: Equatable {
        case move(to: CGPoint)
        case lookDown(at: CGPoint)
        case jumpDown(from: CGRect)
        case fall
    }

    static func evaluate(_ input: Input) -> Action {
        guard let host = input.env.windowSurfaces.first(where: { $0.id == input.windowID }) else {
            return .fall
        }
        let frame = input.env.petFrame
        guard host.frame.maxY + frame.width <= input.screen.visibleFrame.maxY else {
            return .jumpDown(from: host.frame)
        }

        var x = frame.origin.x + (input.isMovingRight ? abs(input.moveX) : -abs(input.moveX))
        let atRightEdge = x + frame.width >= host.frame.maxX
        let atLeftEdge = x <= host.frame.minX
        if atRightEdge || atLeftEdge {
            x = atRightEdge ? host.frame.maxX - frame.width : host.frame.minX
            return .lookDown(at: CGPoint(x: x, y: host.frame.maxY))
        }
        return .move(to: CGPoint(x: x, y: host.frame.maxY))
    }
}
