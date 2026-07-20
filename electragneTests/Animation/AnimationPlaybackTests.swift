import Foundation
import Testing
@testable import electragne

/// Fixture with distinct interval/movement endpoints so interpolation is
/// observable.
private func makeAnimation(
    frameCount: Int,
    repeatFrom: Int = 0,
    startInterval: TimeInterval = 0.1,
    endInterval: TimeInterval = 0.5
) -> PetAnimation {
    PetAnimation(
        id: "test",
        name: "test",
        frames: Array(100..<(100 + frameCount)),
        startInterval: startInterval,
        endInterval: endInterval,
        repeatCount: .fixed(0),
        repeatFrom: repeatFrom,
        offsetY: 0,
        startMoveX: 2, startMoveY: 0, endMoveX: 6, endMoveY: 0,
        nextAnimations: []
    )
}

struct AnimationPlaybackTests {
    @Test func advancesThroughSequenceThenFinishes() {
        var playback = AnimationPlayback(animation: makeAnimation(frameCount: 3), repeatCount: 0)

        #expect(playback.currentFrameNumber == 100)
        #expect(playback.advance() == .advanced)
        #expect(playback.currentFrameNumber == 101)
        #expect(playback.advance() == .advanced)
        #expect(playback.currentFrameNumber == 102)
        #expect(playback.advance() == .finished)
        // The last frame keeps displaying after the run finishes.
        #expect(playback.currentFrameNumber == 102)
    }

    @Test func repeatsTailSectionBeforeFinishing() {
        // 4 frames, repeatFrom 2, two repeats: 0 1 2 3 | 2 3 | 2 3 | finished
        var playback = AnimationPlayback(
            animation: makeAnimation(frameCount: 4, repeatFrom: 2), repeatCount: 2
        )
        var indices: [Int] = [playback.frameIndex]
        var events: [AnimationPlayback.Advance] = []
        for _ in 0..<7 {
            events.append(playback.advance())
            indices.append(playback.frameIndex)
        }
        #expect(events == [.advanced, .advanced, .advanced, .repeated, .advanced, .repeated, .advanced])
        #expect(indices == [0, 1, 2, 3, 2, 3, 2, 3])
        #expect(playback.advance() == .finished)
    }

    @Test func estimatedTotalMatchesActualFramesShown() {
        // The estimate drives interval interpolation; it must equal the
        // number of frames a full run actually displays.
        let animation = makeAnimation(frameCount: 4, repeatFrom: 2)
        var playback = AnimationPlayback(animation: animation, repeatCount: 2)
        var shown = 1  // initial frame
        while playback.advance() != .finished { shown += 1 }
        #expect(shown == playback.estimatedTotalFrames)
        #expect(AnimationPlayback.totalFrames(animation: animation, repeatCount: 2) == 8)
    }

    @Test func repeatFromPastFrameCountDoesNotCorruptTotals() {
        let animation = makeAnimation(frameCount: 5, repeatFrom: 9)
        #expect(AnimationPlayback.totalFrames(animation: animation, repeatCount: 4) == 5)
        var playback = AnimationPlayback(animation: animation, repeatCount: 1)
        for _ in 0..<4 { #expect(playback.advance() == .advanced) }
        // The repeat pass clamps to the last frame instead of running off the end.
        #expect(playback.advance() == .repeated)
        #expect(playback.frameIndex == 4)
    }

    @Test func intervalInterpolatesFromStartToEnd() {
        var playback = AnimationPlayback(animation: makeAnimation(frameCount: 5), repeatCount: 0)
        #expect(playback.progress == 0)
        #expect(abs(playback.currentInterval - 0.1) < 0.0001)

        _ = playback.advance()
        _ = playback.advance()  // framesPlayed 2 of (5-1) → progress 0.5
        #expect(abs(playback.progress - 0.5) < 0.0001)
        #expect(abs(playback.currentInterval - 0.3) < 0.0001)
        #expect(abs(playback.currentMoveX - 4) < 0.0001)

        _ = playback.advance()
        _ = playback.advance()
        #expect(playback.progress == 1)
        #expect(abs(playback.currentInterval - 0.5) < 0.0001)
        #expect(abs(playback.currentMoveX - 6) < 0.0001)
    }

    @Test func progressIsZeroForSingleFrameAnimation() {
        let playback = AnimationPlayback(animation: makeAnimation(frameCount: 1), repeatCount: 0)
        #expect(playback.progress == 0)
        #expect(abs(playback.currentInterval - 0.1) < 0.0001)
    }

    @Test func restartResetsStateAndReestimates() {
        var playback = AnimationPlayback(
            animation: makeAnimation(frameCount: 3, repeatFrom: 1), repeatCount: 0
        )
        _ = playback.advance()
        _ = playback.advance()
        #expect(playback.advance() == .finished)

        playback.restart(repeatCount: 1)
        #expect(playback.frameIndex == 0)
        #expect(playback.framesPlayed == 0)
        #expect(playback.progress == 0)
        #expect(playback.estimatedTotalFrames == 5)  // 3 + (3-1)*1
        #expect(playback.advance() == .advanced)
    }
}
