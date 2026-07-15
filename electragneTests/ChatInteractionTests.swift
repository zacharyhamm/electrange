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

        #expect(placement.origin == CGPoint(x: 560, y: 44))
        #expect(placement.tailEdge == .bottom)
        #expect(placement.tailOffset == 160)
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
        #expect(right.origin.x == 1112)
        #expect(right.tailOffset == 292)
    }

    @Test func bubbleFlipsBelowPetNearTopOfScreen() {
        let placement = ChatBubblePlacement.calculate(
            petFrame: CGRect(x: 700, y: 820, width: 40, height: 40),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )

        #expect(placement.origin == CGPoint(x: 560, y: 676))
        #expect(placement.tailEdge == .top)
        #expect(placement.tailOffset == 160)
    }

    @Test func expandedBubbleFlipsBelowPetAndClampsNearTopOfScreen() {
        let placement = ChatBubblePlacement.calculate(
            petFrame: CGRect(x: 700, y: 820, width: 40, height: 40),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            bubbleSize: ChatBubblePlacement.expandedSize
        )

        // Desired y (below the pet) would be 820 - 4 - 380 = 436, which fits,
        // and the taller bubble no longer fits above the pet.
        #expect(placement.origin == CGPoint(x: 550, y: 436))
        #expect(placement.tailEdge == .top)
        #expect(placement.tailOffset == 170)
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

    @Test func summonLeavesRestingPetsOnTheMainScreenInPlace() {
        let mainScreen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let onMain = CGRect(x: 500, y: 0, width: 90, height: 90)

        let stayPutStates: [PetState] = [
            .walking,
            .sleeping(phase: 1),
            .walkingOnDock,
            .walkingOnWindow,
            .chatting(restingPlace: .ground),
        ]
        for state in stayPutStates {
            #expect(!PetViewModel.shouldRelocateForSummon(
                state: state, petFrame: onMain, mainScreenFrame: mainScreen
            ))
        }
    }

    @Test func summonRelocatesMovingPetsAndPetsOnOtherScreens() {
        let mainScreen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let onMain = CGRect(x: 500, y: 0, width: 90, height: 90)
        let onSecondScreen = CGRect(x: -800, y: 100, width: 90, height: 90)

        let movingStates: [PetState] = [
            .falling(velocity: 2, bounceCount: 0),
            .jumping,
            .jumpingToDock,
            .jumpingToLedge,
            .jumpingOffDock,
            .climbingWindow,
            .lookingDown,
            .dragging(mouseOffset: .zero),
        ]
        for state in movingStates {
            #expect(PetViewModel.shouldRelocateForSummon(
                state: state, petFrame: onMain, mainScreenFrame: mainScreen
            ))
        }

        // Even a resting pet relocates when it's on another screen.
        #expect(PetViewModel.shouldRelocateForSummon(
            state: .walking, petFrame: onSecondScreen, mainScreenFrame: mainScreen
        ))
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

    @Test func chatTextRendersInlineMarkdown() {
        let attributed = ChatTextFormatter.linkified(
            "A **bold** claim!\nSee [KC Weather](https://example.com/wx) or https://openweather.org today."
        )
        let plain = String(attributed.characters)

        // Markdown syntax is consumed, newline preserved.
        #expect(plain == "A bold claim!\nSee KC Weather or https://openweather.org today.")

        let boldRun = attributed.runs.first { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        }
        #expect(boldRun.map { String(attributed.characters[$0.range]) } == "bold")

        let links = attributed.runs.compactMap { run in
            run.link.map { (String(attributed.characters[run.range]), $0.absoluteString) }
        }
        #expect(links.contains { $0 == ("KC Weather", "https://example.com/wx") })
        #expect(links.contains { $0 == ("https://openweather.org", "https://openweather.org") })
    }

    @Test @MainActor func displayTextCarriesFontsAndLinksForAppKit() throws {
        let display = ChatTextFormatter.displayText(
            "A **bold** [link](https://example.com/wx) here"
        )

        #expect(display.string == "A bold link here")

        var foundBold = false
        var foundLink = false
        display.enumerateAttributes(
            in: NSRange(location: 0, length: display.length)
        ) { attributes, range, _ in
            let segment = (display.string as NSString).substring(with: range)
            if segment == "bold", let font = attributes[.font] as? NSFont {
                foundBold = font.fontDescriptor.symbolicTraits.contains(.bold)
            }
            if segment == "link" {
                foundLink = (attributes[.link] as? URL)?.absoluteString == "https://example.com/wx"
            }
        }
        #expect(foundBold)
        #expect(foundLink)
    }

    @Test func inlineMathParserFindsBothSupportedDelimiterStyles() {
        let extraction = InlineMathParser.extract(
            from: "Euler: $e^{i\\pi}+1=0$ and \\(a^2+b^2=c^2\\)."
        )

        #expect(extraction.replacements.count == 2)
        let replacements = Array(extraction.replacements.values)
        #expect(replacements.contains { $0.source == "$e^{i\\pi}+1=0$" && $0.latex == "e^{i\\pi}+1=0" })
        #expect(replacements.contains { $0.source == "\\(a^2+b^2=c^2\\)" && $0.latex == "a^2+b^2=c^2" })
        #expect(!extraction.protectedText.contains("e^{i"))
    }

    @Test func inlineMathParserIgnoresCodeEscapesAndUnmatchedDelimiters() {
        let source = #"`$code$` costs \$5, then $unfinished"#
        let extraction = InlineMathParser.extract(from: source)

        #expect(extraction.replacements.isEmpty)
        #expect(extraction.protectedText == source)
    }

    @Test @MainActor func unmatchedBackslashDelimitersRemainVerbatim() {
        let unfinished = #"Unfinished \(x + 1."#
        let stray = #"A stray \) delimiter."#

        #expect(ChatTextFormatter.displayText(unfinished).string == unfinished)
        #expect(ChatTextFormatter.displayText(stray).string == stray)
    }

    @Test func displayMathDelimitersAreKeptAsLiteralText() {
        let source = #"Keep $$x^2$$ and \[y^2\] literal."#
        let extraction = InlineMathParser.extract(from: source)

        #expect(extraction.replacements.count == 2)
        #expect(extraction.replacements.values.allSatisfy { $0.latex == nil })
    }

    @Test @MainActor func displayTextRendersValidInlineMathAsAttachments() {
        let display = ChatTextFormatter.displayText(
            "Energy **$E=mc^2$** and \\(\\frac{a}{b}\\)."
        )

        var attachments = 0
        var boldAttachment = false
        display.enumerateAttributes(
            in: NSRange(location: 0, length: display.length)
        ) { attributes, _, _ in
            guard attributes[.attachment] is NSTextAttachment else { return }
            attachments += 1
            if let font = attributes[.font] as? NSFont,
               font.fontDescriptor.symbolicTraits.contains(.bold) {
                boldAttachment = true
            }
        }
        #expect(attachments == 2)
        #expect(boldAttachment)
    }

    @Test @MainActor func invalidAndUnsupportedMathFallsBackToItsSource() {
        let display = ChatTextFormatter.displayText(
            #"Bad $\notARealCommand{x}$; keep $$z^2$$ and \[q\]."#
        )

        #expect(display.string == #"Bad $\notARealCommand{x}$; keep $$z^2$$ and \[q\]."#)
        var attachmentFound = false
        display.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: display.length)
        ) { value, _, _ in
            attachmentFound = attachmentFound || value != nil
        }
        #expect(!attachmentFound)
    }

    @Test @MainActor func inlineMathCanRenderForBothAppearances() {
        let light = ChatTextFormatter.displayText("$x+1$", colorScheme: .light)
        let dark = ChatTextFormatter.displayText("$x+1$", colorScheme: .dark)

        #expect(light.attribute(.attachment, at: 0, effectiveRange: nil) is NSTextAttachment)
        #expect(dark.attribute(.attachment, at: 0, effectiveRange: nil) is NSTextAttachment)
        #expect((light.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)?.image?.size.width ?? 0 > 0)
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
