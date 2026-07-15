//
//  ScreenGeometryTests.swift
//  electragneTests
//

import Testing
import CoreGraphics
@testable import electragne

struct ScreenGeometryTests {

    // MARK: - screenContaining

    @Test func singleScreenContainsPoint() {
        let screens = [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        #expect(ScreenGeometry.screenContaining(x: 500, below: 500, in: screens) == 0)
    }

    @Test func pointOutsideAllScreensIsNil() {
        let screens = [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        #expect(ScreenGeometry.screenContaining(x: 2000, below: 500, in: screens) == nil)
    }

    @Test func prefersHighestGroundBelowPet() {
        // main at y=0, an upper display stacked on top at y=1080
        let screens = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 0, y: 1080, width: 1920, height: 1080),
        ]
        // With the pet high up, the higher display's floor is preferred.
        #expect(ScreenGeometry.screenContaining(x: 500, below: 2000, in: screens) == 1)
        // With the pet low, only the lower display qualifies.
        #expect(ScreenGeometry.screenContaining(x: 500, below: 500, in: screens) == 0)
    }

    // MARK: - walkableScreen

    @Test func crossesSeamToSameLevelDisplay() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 0, width: 1920, height: 1080),
        ]
        #expect(ScreenGeometry.walkableScreen(beyond: 0, movingRight: true, footY: 0,
                                              maxStepUp: 250, in: screens) == 1)
    }

    @Test func hopsUpOntoReachableLedge() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 200, width: 1920, height: 1080),  // 200px step up
        ]
        #expect(ScreenGeometry.walkableScreen(beyond: 0, movingRight: true, footY: 0,
                                              maxStepUp: 250, in: screens) == 1)
    }

    @Test func ledgeTooHighIsNotWalkable() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 300, width: 1920, height: 1080),  // 300 > maxStepUp 250
        ]
        #expect(ScreenGeometry.walkableScreen(beyond: 0, movingRight: true, footY: 0,
                                              maxStepUp: 250, in: screens) == nil)
    }

    @Test func nonAdjacentDisplayIsNotWalkable() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 2000, y: 0, width: 1920, height: 1080),  // 80px gap at the seam
        ]
        #expect(ScreenGeometry.walkableScreen(beyond: 0, movingRight: true, footY: 0,
                                              maxStepUp: 250, in: screens) == nil)
    }

    @Test func crossesSeamMovingLeft() {
        let screens = [
            CGRect(x: -1920, y: 0, width: 1920, height: 1080),  // index 0, to the left
            CGRect(x: 0, y: 0, width: 1920, height: 1080),      // index 1, the pet's screen
        ]
        #expect(ScreenGeometry.walkableScreen(beyond: 1, movingRight: false, footY: 0,
                                              maxStepUp: 250, in: screens) == 0)
    }

    // MARK: - Quartz <-> Cocoa flip

    @Test func cocoaYFlipsAroundPrimaryTop() {
        #expect(ScreenGeometry.cocoaY(quartzY: 0, height: 50, primaryMaxY: 1000) == 950)
        #expect(ScreenGeometry.cocoaY(quartzY: 950, height: 50, primaryMaxY: 1000) == 0)
    }

    @Test func cocoaYRoundTrips() {
        let primaryMaxY: CGFloat = 1440
        let quartzY: CGFloat = 317
        let height: CGFloat = 88
        let cocoa = ScreenGeometry.cocoaY(quartzY: quartzY, height: height, primaryMaxY: primaryMaxY)
        // Flipping the cocoa-origin back through the same transform returns the quartz y.
        #expect(ScreenGeometry.cocoaY(quartzY: cocoa, height: height, primaryMaxY: primaryMaxY) == quartzY)
    }

    @Test func cocoaRectFlipsOrigin() {
        let rect = ScreenGeometry.cocoaRect(x: 10, quartzY: 100, width: 40, height: 60, primaryMaxY: 1000)
        #expect(rect == CGRect(x: 10, y: 840, width: 40, height: 60))
    }
}
