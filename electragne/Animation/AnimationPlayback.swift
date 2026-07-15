//
//  AnimationPlayback.swift
//  electragne
//
//  The pure frame-sequencing core shared by AnimationManager (the pet) and
//  ChildPetWindow (spawned children): frame advancement, repeat-section
//  looping, and interval/movement interpolation over the estimated run
//  length. Callers decide what a finished run means (loop, transition,
//  complete); this type never re-evaluates repeat counts itself because
//  RepeatValue.evaluate() reads live app state.
//

import CoreGraphics
import Foundation

nonisolated struct AnimationPlayback {
    /// What a call to advance() did.
    enum Advance: Equatable {
        case advanced           // moved to the next frame in the sequence
        case repeated           // jumped back to repeatFrom for another pass
        case finished           // sequence exhausted; caller decides what's next
    }

    let animation: PetAnimation

    private(set) var frameIndex = 0
    private(set) var framesPlayed = 0
    private(set) var repeatRemaining: Int
    private(set) var estimatedTotalFrames: Int

    init(animation: PetAnimation, repeatCount: Int) {
        self.animation = animation
        repeatRemaining = repeatCount
        estimatedTotalFrames = Self.totalFrames(animation: animation, repeatCount: repeatCount)
    }

    /// First pass plus the repeated tail section. max(0,...) guards against a
    /// repeatFrom past the frame count (empty/corrupt data) producing a
    /// negative section that would corrupt the frame total.
    static func totalFrames(animation: PetAnimation, repeatCount: Int) -> Int {
        animation.frames.count + max(0, animation.frames.count - animation.repeatFrom) * repeatCount
    }

    var currentFrameNumber: Int? {
        animation.frames.indices.contains(frameIndex) ? animation.frames[frameIndex] : nil
    }

    /// Progress through the estimated run (0.0 to 1.0).
    var progress: CGFloat {
        guard estimatedTotalFrames > 1 else { return 0 }
        return min(1.0, max(0.0, CGFloat(framesPlayed) / CGFloat(estimatedTotalFrames - 1)))
    }

    var currentInterval: TimeInterval {
        animation.startInterval + (animation.endInterval - animation.startInterval) * progress
    }

    var currentMoveX: CGFloat {
        animation.startMoveX + (animation.endMoveX - animation.startMoveX) * progress
    }

    var currentMoveY: CGFloat {
        animation.startMoveY + (animation.endMoveY - animation.startMoveY) * progress
    }

    /// Advances one frame. On .finished the frame index stays on the last
    /// frame of the sequence so the final image keeps displaying.
    mutating func advance() -> Advance {
        framesPlayed += 1
        let next = frameIndex + 1
        guard next >= animation.frames.count else {
            frameIndex = next
            return .advanced
        }
        if repeatRemaining > 0 {
            repeatRemaining -= 1
            frameIndex = min(max(0, animation.repeatFrom), animation.frames.count - 1)
            return .repeated
        }
        return .finished
    }

    /// Restarts from the beginning with a freshly evaluated repeat count
    /// (the looping path).
    mutating func restart(repeatCount: Int) {
        frameIndex = 0
        framesPlayed = 0
        repeatRemaining = repeatCount
        estimatedTotalFrames = Self.totalFrames(animation: animation, repeatCount: repeatCount)
    }
}
