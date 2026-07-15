import Testing
@testable import electragne

@Suite("Pet state")
struct PetStateTests {
    @Test("Pause normalization restores the surface beneath chat", arguments: [
        (PetState.chatting(restingPlace: .ground), PetState.walking),
        (PetState.chatting(restingPlace: .dock), PetState.walkingOnDock),
        (PetState.chatting(restingPlace: .window), PetState.walkingOnWindow),
    ])
    func normalizesChatForPause(input: PetState, expected: PetState) {
        #expect(normalizedForPause(input) == expected)
    }

    @Test func leavesResumableStatesUnchanged() {
        let states: [PetState] = [
            .falling(velocity: -3, bounceCount: 1), .walking, .walkingOnDock,
            .sleeping(phase: 2), .dragging(mouseOffset: .init(x: 4, y: 5)),
            .jumping, .jumpingToDock, .jumpingToLedge, .climbingWindow,
            .walkingOnWindow, .lookingDown, .jumpingOffDock,
        ]

        for state in states {
            #expect(normalizedForPause(state) == state)
        }
    }
}
