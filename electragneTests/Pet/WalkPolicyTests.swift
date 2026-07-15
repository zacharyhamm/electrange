import CoreGraphics
import Testing
@testable import electragne

@Suite("Walk policy")
struct WalkPolicyTests {
    @Test("an outer screen edge turns the pet around")
    func turnAround() {
        let action = WalkPolicy.evaluate(input(x: 958, moveX: 3)) { _ in 100 }
        #expect(action == .turnAround(at: CGPoint(x: 960, y: 0)))
    }

    @Test("a same-level adjacent display is crossed without turning")
    func seam() {
        var value = input(x: 958, moveX: 5)
        value.env.screens.append(screen(x: 1000, y: 0))
        #expect(WalkPolicy.evaluate(value) { _ in 100 }
                == .crossSeam(to: CGPoint(x: 963, y: 0), screenIndex: 1))
    }

    @Test("a reachable higher display triggers the ledge jump")
    func ledge() {
        var value = input(x: 958, moveX: 5)
        value.env.screens.append(screen(x: 1000, y: 100))
        #expect(WalkPolicy.evaluate(value) { _ in 100 }
                == .beginLedgeJump(from: CGPoint(x: 960, y: 0), targetX: 1020, targetY: 100))
    }

    @Test("a lower adjacent display causes edge fall-off")
    func fallOff() {
        var value = input(x: 978, y: 100, moveX: 5)
        value.env.screens[0] = screen(x: 0, y: 100)
        value.env.screens.append(screen(x: 1000, y: 0))
        #expect(WalkPolicy.evaluate(value) { _ in 100 }
                == .fallOffEdge(at: CGPoint(x: 983, y: 100)))
    }

    @Test("touching the dock edge begins an approach")
    func dock() {
        var value = input(x: 150, moveX: 10)
        value.env.dockInfo = DockInfo(position: .bottom,
                                     frame: CGRect(x: 200, y: 0, width: 300, height: 80))
        #expect(WalkPolicy.evaluate(value) { _ in 100 }
                == .beginDockApproach(at: CGPoint(x: 160, y: 0)))
    }

    private func screen(x: CGFloat, y: CGFloat) -> ScreenInfo {
        ScreenInfo(frame: CGRect(x: x, y: y, width: 1000, height: 800),
                   visibleFrame: CGRect(x: x, y: y, width: 1000, height: 760))
    }
    private func input(x: CGFloat, y: CGFloat = 0, moveX: CGFloat) -> WalkPolicy.Input {
        .init(env: EnvironmentSnapshot(screens: [screen(x: 0, y: 0)], dockInfo: nil,
                                       windowSurfaces: [],
                                       petFrame: CGRect(x: x, y: y, width: 40, height: 40)),
              screenIndex: 0, moveX: moveX, isMovingRight: true)
    }
}
