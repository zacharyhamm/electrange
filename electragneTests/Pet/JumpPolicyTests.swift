import CoreGraphics
import Testing
@testable import electragne

@Suite("Jump policy")
struct JumpPolicyTests {
    @Test("animation movement follows the sprite curve and direction")
    func animationJump() {
        let env = snapshot(frame: CGRect(x: 100, y: 0, width: 40, height: 40))
        let action = JumpPolicy.evaluate(.init(
            env: env,
            motion: .animation(moveX: 3, moveY: -4, isMovingRight: false, screenIndex: 0)
        ))
        #expect(action == .move(to: CGPoint(x: 97, y: 8), ballistic: nil))
    }

    @Test("animation movement crosses a same-level screen seam")
    func seamCrossing() {
        var env = snapshot(frame: CGRect(x: 970, y: 0, width: 40, height: 40))
        env.screens.append(ScreenInfo(
            frame: CGRect(x: 1000, y: 0, width: 800, height: 800),
            visibleFrame: CGRect(x: 1000, y: 0, width: 800, height: 760)
        ))
        let action = JumpPolicy.evaluate(.init(
            env: env,
            motion: .animation(moveX: 20, moveY: 0, isMovingRight: true, screenIndex: 0)
        ))
        #expect(action == .move(to: CGPoint(x: 990, y: 0), ballistic: nil))
    }

    @Test("ballistic movement returns updated progress then its exact target")
    func ballistic() {
        let jump = BallisticJump(start: .zero, target: CGPoint(x: 10, y: 10),
                                 arc: .parabolic(height: 10), step: 0.5,
                                 clampToTargetY: false)
        let first = JumpPolicy.evaluate(.init(env: snapshot(frame: .zero), motion: .ballistic(jump)))
        guard case .move(let point, let updated?) = first else {
            Issue.record("expected an in-flight jump")
            return
        }
        #expect(point == CGPoint(x: 5, y: 15))
        #expect(JumpPolicy.evaluate(.init(env: snapshot(frame: .zero), motion: .ballistic(updated)))
                == .complete(at: CGPoint(x: 10, y: 10)))
    }

    private func snapshot(frame: CGRect) -> EnvironmentSnapshot {
        EnvironmentSnapshot(
            screens: [ScreenInfo(frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                                 visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 760))],
            dockInfo: nil,
            windowSurfaces: [],
            petFrame: frame
        )
    }
}
