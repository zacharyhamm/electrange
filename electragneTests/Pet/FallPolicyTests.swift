import CoreGraphics
import Testing
@testable import electragne

@Suite("Fall policy")
struct FallPolicyTests {
    private let screen = ScreenInfo(
        frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
        visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 760)
    )

    @Test("gravity advances a fall without landing")
    func gravity() {
        let action = FallPolicy.evaluate(input(y: 100, velocity: 1))
        #expect(action == .move(to: CGPoint(x: 100, y: 98.2), velocity: 1.8,
                                bounceCount: 0, landedHard: nil))
    }

    @Test("the fourth bounce settles")
    func bounceCutoff() {
        let action = FallPolicy.evaluate(input(y: 1, velocity: 4, bounceCount: 3))
        #expect(action == .settle(at: CGPoint(x: 100, y: 0), surface: .ground,
                                  landedHard: false))
    }

    @Test("a slow first bounce settles on the highest eligible window")
    func windowLanding() {
        var value = input(y: 202, velocity: 2, landOnWindows: true)
        value.env.windowSurfaces = [WindowSurface(id: 42, frame: CGRect(x: 50, y: 50, width: 200, height: 150))]
        let action = FallPolicy.evaluate(value)
        #expect(action == .settle(at: CGPoint(x: 100, y: 200), surface: .window(42),
                                  landedHard: false))
    }

    private func input(y: CGFloat, velocity: CGFloat, bounceCount: Int = 0,
                       landOnWindows: Bool = false) -> FallPolicy.Input {
        FallPolicy.Input(
            env: EnvironmentSnapshot(screens: [screen], dockInfo: nil, windowSurfaces: [],
                                     petFrame: CGRect(x: 100, y: y, width: 40, height: 40)),
            velocity: velocity,
            bounceCount: bounceCount,
            tickScale: 1,
            landOnWindows: landOnWindows
        )
    }
}
