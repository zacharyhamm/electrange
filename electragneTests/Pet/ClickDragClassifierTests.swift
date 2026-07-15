import CoreGraphics
import Testing
@testable import electragne

struct ClickDragClassifierTests {
    @Test func staysAClickWithinThreshold() {
        #expect(!ClickDragClassifier.isDrag(from: .zero, to: .zero))
        #expect(!ClickDragClassifier.isDrag(from: .zero, to: CGPoint(x: 2, y: 0)))
        #expect(!ClickDragClassifier.isDrag(from: .zero, to: CGPoint(x: 2, y: 2)))
        #expect(!ClickDragClassifier.isDrag(
            from: CGPoint(x: 100, y: 100), to: CGPoint(x: 102.9, y: 100)
        ))
    }

    @Test func becomesADragAtThreshold() {
        #expect(ClickDragClassifier.isDrag(from: .zero, to: CGPoint(x: 3, y: 0)))
        #expect(ClickDragClassifier.isDrag(from: .zero, to: CGPoint(x: 0, y: -3)))
        #expect(ClickDragClassifier.isDrag(from: .zero, to: CGPoint(x: 2.2, y: 2.2)))
    }

    @Test func honorsCustomThreshold() {
        #expect(!ClickDragClassifier.isDrag(from: .zero, to: CGPoint(x: 4, y: 0), threshold: 5))
        #expect(ClickDragClassifier.isDrag(from: .zero, to: CGPoint(x: 5, y: 0), threshold: 5))
    }
}
