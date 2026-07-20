import Testing
@testable import electragne

@MainActor
@Suite("Pet behaviors")
struct PetBehaviorTests {
    @Test func stableBehaviorTimerNeedsAreDeclarative() {
        #expect(SleepingBehavior().timerNeeds == [.animation])
        #expect(LookingDownBehavior().timerNeeds == [.animation])
        #expect(DraggingBehavior().timerNeeds == [.animation])
        #expect(WalkingBehavior().timerNeeds == [.movement, .animation, .idle])
        #expect(DockWalkBehavior().timerNeeds == [.movement, .animation, .idle])
        #expect(WindowTopBehavior().timerNeeds == [.movement, .animation, .idle])
        #expect(FallingBehavior().timerNeeds == [.movement, .animation])
    }

    @Test func transitionalBehaviorTimerNeedsAreDeclarative() {
        #expect(BasicJumpBehavior().timerNeeds == [.movement, .animation])
        #expect(BallisticJumpBehavior(destination: .dock).timerNeeds == [.movement, .animation])
        #expect(BallisticJumpBehavior(destination: .ledge).timerNeeds == [.movement, .animation])
        #expect(BallisticJumpBehavior(destination: .ground).timerNeeds == [.movement, .animation])
        #expect(ClimbBehavior().timerNeeds == [.movement, .animation])
        #expect(ChattingBehavior(restingPlace: .ground).timerNeeds == [.animation])
    }
}
