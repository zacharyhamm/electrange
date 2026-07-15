import CoreGraphics
import Testing
@testable import electragne

@Suite("Window top policy")
struct WindowTopPolicyTests {
    @Test("walking follows a moving host window")
    func ridesWindow() {
        #expect(WindowTopPolicy.evaluate(input(x: 150, moveX: 5))
                == .move(to: CGPoint(x: 155, y: 300)))
    }

    @Test("the edge is inclusive")
    func edge() {
        #expect(WindowTopPolicy.evaluate(input(x: 255, moveX: 5))
                == .lookDown(at: CGPoint(x: 260, y: 300)))
    }

    @Test("a window under the menu bar triggers a jump down")
    func menuBar() {
        var value = input(x: 150, moveX: 5)
        value.env.windowSurfaces = [WindowSurface(id: 7, frame: CGRect(x: 100, y: 500, width: 200, height: 230))]
        #expect(WindowTopPolicy.evaluate(value) == .jumpDown(from: CGRect(x: 100, y: 500, width: 200, height: 230)))
    }

    private func input(x: CGFloat, moveX: CGFloat) -> WindowTopPolicy.Input {
        let screen = ScreenInfo(frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                                visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 760))
        return .init(
            env: EnvironmentSnapshot(screens: [screen], dockInfo: nil,
                                     windowSurfaces: [WindowSurface(id: 7, frame: CGRect(x: 100, y: 100, width: 200, height: 200))],
                                     petFrame: CGRect(x: x, y: 300, width: 40, height: 40)),
            windowID: 7,
            screen: screen,
            moveX: moveX,
            isMovingRight: true
        )
    }
}
