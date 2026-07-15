import Testing
@testable import electragne

@Suite("Idle behavior policy")
struct IdleBehaviorPolicyTests {
    @Test("walk behavior boundaries preserve the cumulative weights",
          arguments: [
            (2, AnimationID.piss.rawValue),
            (3, AnimationID.eat.rawValue),
            (5, AnimationID.eat.rawValue),
            (6, AnimationID.runBegin.rawValue),
            (25, AnimationID.runBegin.rawValue),
            (26, AnimationID.walk.rawValue)
          ])
    func walkWeights(roll: Int, expected: String) {
        let input = IdleBehaviorPolicy.Input(currentAnimationName: "walk",
                                             proposedNextAnimationID: AnimationID.walk.rawValue)
        #expect(IdleBehaviorPolicy.evaluate(input) { _ in roll } == expected)
    }

    @Test("running jumps through thirty percent")
    func runJump() {
        let input = IdleBehaviorPolicy.Input(currentAnimationName: "run",
                                             proposedNextAnimationID: AnimationID.runBegin.rawValue)
        #expect(IdleBehaviorPolicy.evaluate(input) { _ in 30 } == AnimationID.jump.rawValue)
        #expect(IdleBehaviorPolicy.evaluate(input) { _ in 31 } == AnimationID.runBegin.rawValue)
    }
}
