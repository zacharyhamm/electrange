import AppKit
import Testing
@testable import electragne

@MainActor
@Suite("Pet window presentation")
struct PetWindowPresentationTests {
    @Test("overlay policy joins every app without conflicting roles")
    func overlayPolicy() {
        let behavior = PetWindowPresentation.collectionBehavior

        #expect(behavior.contains(.canJoinAllSpaces))
        #expect(behavior.contains(.stationary))
        #expect(behavior.contains(.canJoinAllApplications))
        #expect(!behavior.contains(.primary))
        #expect(!behavior.contains(.auxiliary))
        #expect(!behavior.contains(.fullScreenNone))
    }

    @Test("observation repairs a SwiftUI collection behavior rewrite")
    func repairsRewrite() {
        let window = makeWindow()
        PetWindowPresentation.enforce(on: window)
        let observation = PetWindowPresentation.observe(window)

        window.collectionBehavior = [.fullScreenNone]

        #expect(window.collectionBehavior == PetWindowPresentation.collectionBehavior)
        withExtendedLifetime(observation) {}
    }

    @Test("window depth changes preserve fullscreen eligibility")
    func levelChanges() {
        let window = makeWindow()
        PetWindowPresentation.enforce(on: window)

        window.level = .normal
        #expect(window.collectionBehavior == PetWindowPresentation.collectionBehavior)

        window.level = .floating
        #expect(window.collectionBehavior == PetWindowPresentation.collectionBehavior)
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 40, height: 40),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
    }
}
