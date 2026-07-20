import Foundation
import Testing
@testable import electragne

struct PetSizeAdjustmentTests {
    @Test func clampsSizeAndFallsBackToDefault() {
        // Unset (0) storage falls back to the default before applying delta.
        #expect(PetSizeAdjustment.newSize(current: 0, delta: 10)
            == PetSizeConstants.defaultSize + 10)
        #expect(PetSizeAdjustment.newSize(current: 40, delta: -10) == 30)
        // Clamped at both ends.
        #expect(PetSizeAdjustment.newSize(current: PetSizeConstants.minimumSize, delta: -10)
            == PetSizeConstants.minimumSize)
        #expect(PetSizeAdjustment.newSize(current: PetSizeConstants.maximumSize, delta: 10)
            == PetSizeConstants.maximumSize)
    }

    @Test func groundedOriginCompensatesForHeightChangeAndRespectsFloor() {
        let frame = CGRect(x: 100, y: 50, width: 40, height: 40)
        // Growing by 20 drops the origin by 20 so the feet stay put.
        #expect(PetSizeAdjustment.groundedOrigin(frame: frame, newSize: 60, floorY: 0)
            == CGPoint(x: 100, y: 30))
        // Never below the screen's floor.
        #expect(PetSizeAdjustment.groundedOrigin(frame: frame, newSize: 200, floorY: 0)
            == CGPoint(x: 100, y: 0))
        // A negative-Y floor (secondary screen) is honored, not clamped to 0.
        #expect(PetSizeAdjustment.groundedOrigin(frame: frame, newSize: 200, floorY: -500)
            == CGPoint(x: 100, y: -110))
    }
}
