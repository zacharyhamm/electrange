import CoreGraphics
import Testing
@testable import electragne

@Suite("Climb policy")
struct ClimbPolicyTests {
    @Test("crossing a valid side obeys the climb probability gate")
    func opportunity() {
        let accepted = ClimbPolicy.evaluate(findInput()) { _ in 25 }
        #expect(accepted == .begin(surface: window, at: CGPoint(x: 160, y: 0)))
        #expect(ClimbPolicy.evaluate(findInput()) { _ in 26 } == .none)
    }

    @Test("ascending snaps to the top and changes phase")
    func topOut() {
        let action = ClimbPolicy.evaluate(climbInput(y: 198, moveY: 3)) { _ in 1 }
        #expect(action == .beginTopOut(at: CGPoint(x: 160, y: 200)))
    }

    @Test("topping out moves at one and a half points per reference tick")
    func toppingOut() {
        var input = climbInput(y: 200, moveY: 0)
        input.env.petFrame.origin.x = 160
        input.mode = .climb(windowID: 9, screen: screen, onLeftSide: true,
                            phase: .toppingOut, moveY: 0, tickScale: 1)
        #expect(ClimbPolicy.evaluate(input) { _ in 1 }
                == .move(to: CGPoint(x: 161.5, y: 200)))
    }

    private var screen: ScreenInfo {
        ScreenInfo(frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                   visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 760))
    }
    private var window: WindowSurface {
        WindowSurface(id: 9, frame: CGRect(x: 200, y: 0, width: 200, height: 200))
    }
    private func findInput() -> ClimbPolicy.Input {
        .init(env: EnvironmentSnapshot(screens: [screen], dockInfo: nil, windowSurfaces: [window],
                                       petFrame: CGRect(x: 150, y: 0, width: 40, height: 40)),
              mode: .find(screen: screen, currentX: 150, newX: 165, footY: 0,
                          isMovingRight: true))
    }
    private func climbInput(y: CGFloat, moveY: CGFloat) -> ClimbPolicy.Input {
        .init(env: EnvironmentSnapshot(screens: [screen], dockInfo: nil, windowSurfaces: [window],
                                       petFrame: CGRect(x: 160, y: y, width: 40, height: 40)),
              mode: .climb(windowID: 9, screen: screen, onLeftSide: true,
                           phase: .ascending, moveY: moveY, tickScale: 1))
    }
}
