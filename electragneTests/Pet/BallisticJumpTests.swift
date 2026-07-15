//
//  BallisticJumpTests.swift
//  electragneTests
//
//  Golden values that pin the hand-tuned jump arcs against drift.
//

import Testing
import CoreGraphics
@testable import electragne

struct BallisticJumpTests {

    private func approx(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1e-9 }

    // MARK: - Arc shapes

    @Test func parabolicArc() {
        let arc = BallisticJump.Arc.parabolic(height: 30)
        #expect(approx(arc.offset(at: 0), 0))
        #expect(approx(arc.offset(at: 0.5), 30))      // apex at the midpoint
        #expect(approx(arc.offset(at: 0.25), 22.5))   // 30 * 4 * 0.25 * 0.75
        #expect(approx(arc.offset(at: 1.0), 0))
    }

    @Test func piecewiseArc() {
        let arc = BallisticJump.Arc.piecewise(height: 20, peak: 0.2)
        #expect(approx(arc.offset(at: 0.0), 0))
        #expect(approx(arc.offset(at: 0.1), 10))      // halfway up the rise
        #expect(approx(arc.offset(at: 0.2), 20))      // peak
        #expect(approx(arc.offset(at: 0.6), 10))      // 20 * (1 - 0.4/0.8)
        #expect(approx(arc.offset(at: 1.0), 0))
    }

    // MARK: - advance()

    @Test func advanceFollowsTheArcThenCompletes() {
        var jump = BallisticJump(start: CGPoint(x: 0, y: 0),
                                 target: CGPoint(x: 100, y: 0),
                                 arc: .parabolic(height: 30),
                                 step: 0.5,
                                 clampToTargetY: false)
        let first = jump.advance()   // progress -> 0.5
        #expect(first != nil)
        #expect(approx(first!.x, 50))
        #expect(approx(first!.y, 30))   // baseY 0 + apex 30
        #expect(jump.advance() == nil)  // progress -> 1.0: arc complete
    }

    @Test func clampKeepsPositionAtOrAboveTargetY() {
        // Descending jump-off arc: y must never dip below the ground target.
        var jump = BallisticJump(start: CGPoint(x: 0, y: 100),
                                 target: CGPoint(x: 0, y: 0),
                                 arc: .piecewise(height: 20, peak: 0.2),
                                 step: 0.05,
                                 clampToTargetY: true)
        while let point = jump.advance() {
            #expect(point.y >= 0)
        }
    }
}
