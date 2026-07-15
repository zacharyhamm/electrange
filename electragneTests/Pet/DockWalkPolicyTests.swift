import CoreGraphics
import Testing
@testable import electragne

@Suite("Dock walk policy")
struct DockWalkPolicyTests {
    @Test("walking rides the dock top")
    func moves() {
        #expect(DockWalkPolicy.evaluate(input(x: 200, moveX: 5, right: true))
                == .move(to: CGPoint(x: 205, y: 80)))
    }

    @Test("the exact edge starts looking down")
    func edge() {
        #expect(DockWalkPolicy.evaluate(input(x: 455, moveX: 5, right: true))
                == .lookDown(at: CGPoint(x: 460, y: 80)))
    }

    @Test("a missing dock causes a fall")
    func missingDock() {
        var value = input(x: 200, moveX: 5, right: true)
        value.env.dockInfo = nil
        #expect(DockWalkPolicy.evaluate(value) == .fall)
    }

    private func input(x: CGFloat, moveX: CGFloat, right: Bool) -> DockWalkPolicy.Input {
        let dock = DockInfo(position: .bottom, frame: CGRect(x: 100, y: 0, width: 400, height: 80))
        return .init(
            env: EnvironmentSnapshot(screens: [], dockInfo: dock, windowSurfaces: [],
                                     petFrame: CGRect(x: x, y: 80, width: 40, height: 40)),
            moveX: moveX,
            isMovingRight: right
        )
    }
}
