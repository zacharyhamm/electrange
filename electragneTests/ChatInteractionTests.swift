import AppKit
import Testing
@testable import electragne

struct ChatInteractionTests {
    @Test func stableStatesMapToTheirChatSurface() {
        #expect(PetState.walking.chatRestingPlace == .ground)
        #expect(PetState.sleeping(phase: 2).chatRestingPlace == .ground)
        #expect(PetState.walkingOnDock.chatRestingPlace == .dock)
        #expect(PetState.walkingOnWindow.chatRestingPlace == .window)
    }

    @Test func movingAndTransitionalStatesCannotStartChat() {
        let ineligibleStates: [PetState] = [
            .falling(velocity: 1, bounceCount: 0),
            .dragging(mouseOffset: .zero),
            .jumping,
            .jumpingToDock,
            .jumpingToLedge,
            .climbingWindow,
            .lookingDown,
            .jumpingOffDock,
            .chatting(restingPlace: .ground),
        ]

        for state in ineligibleStates {
            #expect(!state.canStartChat)
            #expect(state.chatRestingPlace == nil)
        }
    }

    @Test func bubbleIsCenteredAbovePetWhenThereIsRoom() {
        let placement = ChatBubblePlacement.calculate(
            petFrame: CGRect(x: 700, y: 0, width: 40, height: 40),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )

        #expect(placement.origin == CGPoint(x: 580, y: 44))
        #expect(placement.tailEdge == .bottom)
        #expect(placement.tailOffset == 140)
    }

    @Test func bubbleClampsAtHorizontalScreenEdges() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let left = ChatBubblePlacement.calculate(
            petFrame: CGRect(x: 0, y: 100, width: 40, height: 40),
            visibleFrame: screen
        )
        let right = ChatBubblePlacement.calculate(
            petFrame: CGRect(x: 1400, y: 100, width: 40, height: 40),
            visibleFrame: screen
        )

        #expect(left.origin.x == 8)
        #expect(left.tailOffset == 28)
        #expect(right.origin.x == 1152)
        #expect(right.tailOffset == 252)
    }

    @Test func bubbleFlipsBelowPetNearTopOfScreen() {
        let placement = ChatBubblePlacement.calculate(
            petFrame: CGRect(x: 700, y: 820, width: 40, height: 40),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )

        #expect(placement.origin == CGPoint(x: 580, y: 694))
        #expect(placement.tailEdge == .top)
        #expect(placement.tailOffset == 140)
    }

    @Test func expandedBubbleFlipsBelowPetAndClampsNearTopOfScreen() {
        let placement = ChatBubblePlacement.calculate(
            petFrame: CGRect(x: 700, y: 820, width: 40, height: 40),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            bubbleSize: ChatBubblePlacement.expandedSize
        )

        // Desired y (below the pet) would be 820 - 4 - 300 = 516, which fits,
        // and the taller bubble no longer fits above the pet.
        #expect(placement.origin == CGPoint(x: 580, y: 516))
        #expect(placement.tailEdge == .top)
        #expect(placement.tailOffset == 140)
    }

    @Test func summonPlacesPetInRightThirdOnTheGround() {
        let origin = PetViewModel.summonOrigin(
            petSize: 90,
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875)
        )

        // Right third spans x 960...1440; the pet (90 wide) centers at 1155.
        #expect(origin == CGPoint(x: 1155, y: 0))
    }

    @Test func summonRespectsOffsetScreensAndOversizedPets() {
        let offset = PetViewModel.summonOrigin(
            petSize: 90,
            screenFrame: CGRect(x: -1440, y: -100, width: 1440, height: 900),
            visibleFrame: CGRect(x: -1440, y: -100, width: 1440, height: 875)
        )
        #expect(offset == CGPoint(x: -285, y: -100))

        // A pet absurdly wider than the screen clamps to the left edge
        // instead of being pushed off-screen by the centering math.
        let clamped = PetViewModel.summonOrigin(
            petSize: 3000,
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875)
        )
        #expect(clamped == CGPoint(x: 0, y: 0))
    }

    @Test func chatTextTurnsURLsIntoLinks() {
        let attributed = ChatTextFormatter.linkified(
            "check https://example.com/page?q=1 or www.ollama.com for details"
        )

        let links = attributed.runs.compactMap(\.link)
        #expect(links.count == 2)
        #expect(links.contains(URL(string: "https://example.com/page?q=1")!))
        #expect(links.contains { $0.absoluteString.contains("ollama.com") })
    }

    @Test func chatTextWithoutURLsHasNoLinks() {
        let attributed = ChatTextFormatter.linkified("just a friendly plain sentence")

        #expect(attributed.runs.compactMap(\.link).isEmpty)
        #expect(String(attributed.characters) == "just a friendly plain sentence")
    }

    @Test func bubbleUsesOffsetDisplayCoordinates() {
        let placement = ChatBubblePlacement.calculate(
            petFrame: CGRect(x: -1400, y: 100, width: 40, height: 40),
            visibleFrame: CGRect(x: -1440, y: 0, width: 1440, height: 900)
        )

        #expect(placement.origin == CGPoint(x: -1432, y: 144))
        #expect(placement.tailEdge == .bottom)
        #expect(placement.tailOffset == 52)
    }
}
