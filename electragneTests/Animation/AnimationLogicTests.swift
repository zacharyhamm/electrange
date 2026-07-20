//
//  AnimationLogicTests.swift
//  electragneTests
//

import Testing
@testable import electragne

/// Builds a minimal PetAnimation for the pure frame-count / transition tests.
private func makeAnimation(
    frameCount: Int,
    repeatFrom: Int = 0,
    next: [NextAnimation] = []
) -> PetAnimation {
    PetAnimation(
        id: "test",
        name: "test",
        frames: Array(0..<frameCount),
        startInterval: 0.1,
        endInterval: 0.1,
        repeatCount: .fixed(0),
        repeatFrom: repeatFrom,
        offsetY: 0,
        startMoveX: 0, startMoveY: 0, endMoveX: 0, endMoveY: 0,
        nextAnimations: next
    )
}

@MainActor
struct AnimationLogicTests {

    // MARK: - totalFrames

    @Test func totalFramesWithoutRepeatFrom() {
        let anim = makeAnimation(frameCount: 5, repeatFrom: 0)
        #expect(AnimationPlayback.totalFrames(animation: anim, repeatCount: 2) == 15)  // 5 + 5*2
    }

    @Test func totalFramesWithRepeatFrom() {
        let anim = makeAnimation(frameCount: 5, repeatFrom: 3)
        #expect(AnimationPlayback.totalFrames(animation: anim, repeatCount: 2) == 9)   // 5 + 2*2
    }

    @Test func totalFramesNoRepeats() {
        let anim = makeAnimation(frameCount: 5, repeatFrom: 0)
        #expect(AnimationPlayback.totalFrames(animation: anim, repeatCount: 0) == 5)
    }

    @Test func repeatFromPastFrameCountDoesNotGoNegative() {
        let anim = makeAnimation(frameCount: 5, repeatFrom: 7)  // repeatFrom > frames.count
        // Without the max(0,...) guard this would be 5 + (5-7)*4 = -3.
        #expect(AnimationPlayback.totalFrames(animation: anim, repeatCount: 4) == 5)
    }

    // MARK: - weightedNextAnimation

    @Test func weightedPickRespectsBoundaries() {
        let transitions = [
            NextAnimation(animationID: "A", probability: 30, only: "none"),
            NextAnimation(animationID: "B", probability: 70, only: "none"),
        ]
        #expect(AnimationManager.weightedNextAnimation(from: transitions, roll: 1) == "A")
        #expect(AnimationManager.weightedNextAnimation(from: transitions, roll: 30) == "A")
        #expect(AnimationManager.weightedNextAnimation(from: transitions, roll: 31) == "B")
        #expect(AnimationManager.weightedNextAnimation(from: transitions, roll: 100) == "B")
    }

    @Test func weightedPickFiltersNonNoneTransitions() {
        let transitions = [
            NextAnimation(animationID: "A", probability: 30, only: "none"),
            NextAnimation(animationID: "T", probability: 50, only: "taskbar"),
            NextAnimation(animationID: "B", probability: 70, only: "none"),
        ]
        // "T" is ineligible; the roll range is over A(30)+B(70).
        #expect(AnimationManager.weightedNextAnimation(from: transitions, roll: 30) == "A")
        #expect(AnimationManager.weightedNextAnimation(from: transitions, roll: 31) == "B")
    }

    @Test func weightedPickEmptyOrIneligibleIsNil() {
        #expect(AnimationManager.weightedNextAnimation(from: [], roll: 1) == nil)
        let onlyTaskbar = [NextAnimation(animationID: "T", probability: 50, only: "taskbar")]
        #expect(AnimationManager.weightedNextAnimation(from: onlyTaskbar, roll: 1) == nil)
    }
}
