//
//  AnimationManager.swift
//  electragne
//
//  Created by zacharyhamm on 2/3/26.
//

import Foundation
import SwiftUI
import AppKit

// MARK: - Animation Manager

@Observable
class AnimationManager {
    var animations: [String: PetAnimation] = [:]
    var spriteSheet: NSImage?
    var tilesX = 16
    var tilesY = 11
    var shouldLoop = true
    var onAnimationComplete: (() -> Void)?

    /// Frame sequencing/interpolation for the animation now playing.
    private(set) var playback: AnimationPlayback?

    var currentAnimation: PetAnimation? { playback?.animation }

    // Sprite rendering
    private(set) var spriteRenderer: SpriteRenderer?

    // Memoized current-frame image. ContentView.body calls getCurrentFrameImage()
    // on every re-evaluation (direction flips, observation churn), not only when
    // the frame advances, so without this each redraw re-crops and allocates a
    // new NSImage. Keyed by frame (tile) number, so it self-invalidates whenever
    // the displayed tile changes. @ObservationIgnored: derived state the view
    // shouldn't observe, and mutating it during body must not invalidate body.
    @ObservationIgnored private var cachedFrameNumber: Int?
    @ObservationIgnored private var cachedFrameImage: NSImage?

    // Child spawn tracking
    var childSpawns: [String: [ChildSpawn]] = [:]  // Keyed by parent animation ID
    var onChildSpawn: ((ChildSpawn) -> Void)?  // Callback when a child should spawn

    private var spawnedChildrenForCurrentAnimation = false  // Track if we've spawned children

    func loadAnimations(from url: URL) {
        let parser = AnimationParser()
        if let parsedAnimations = parser.parseAnimations(from: url) {
            for animation in parsedAnimations {
                animations[animation.id] = animation
            }
            tilesX = parser.tilesX
            tilesY = parser.tilesY

            // Load child spawns, grouped by parent animation ID
            for childSpawn in parser.childSpawns {
                if childSpawns[childSpawn.parentAnimationID] == nil {
                    childSpawns[childSpawn.parentAnimationID] = []
                }
                childSpawns[childSpawn.parentAnimationID]?.append(childSpawn)
            }

            // Load sprite sheet from embedded PNG data
            if let imageData = parser.imageData {
                spriteSheet = NSImage(data: imageData)
                spriteRenderer = SpriteRenderer(spriteSheet: spriteSheet, tilesX: tilesX, tilesY: tilesY)
            }
        }
    }

    // Check if current animation has children to spawn
    private func getChildSpawnsForCurrentAnimation() -> [ChildSpawn] {
        guard let animation = currentAnimation else { return [] }
        return childSpawns[animation.id] ?? []
    }

    func playAnimation(_ animationID: String) {
        startPlayback(animationID, loop: true, completion: nil)
    }

    func playAnimationOnce(_ animationID: String, completion: @escaping () -> Void) {
        startPlayback(animationID, loop: false, completion: completion)
    }

    private func startPlayback(_ animationID: String, loop: Bool, completion: (() -> Void)?) {
        guard let animation = animations[animationID] else { return }
        playback = AnimationPlayback(
            animation: animation,
            repeatCount: animation.repeatCount.evaluate()
        )
        shouldLoop = loop
        onAnimationComplete = completion
        spawnedChildrenForCurrentAnimation = false
        triggerChildSpawns()
    }

    private func triggerChildSpawns() {
        guard !spawnedChildrenForCurrentAnimation else { return }
        let spawns = getChildSpawnsForCurrentAnimation()
        if !spawns.isEmpty {
            spawnedChildrenForCurrentAnimation = true
            for spawn in spawns {
                onChildSpawn?(spawn)
            }
        }
    }

    func getCurrentFrameNumber() -> Int? {
        playback?.currentFrameNumber
    }

    func getCurrentFrameImage() -> NSImage? {
        guard let frameNumber = getCurrentFrameNumber(),
              let renderer = spriteRenderer else {
            return nil
        }

        if frameNumber == cachedFrameNumber, let cached = cachedFrameImage {
            return cached
        }

        let image = renderer.extractFrame(frameNumber: frameNumber)
        cachedFrameNumber = frameNumber
        cachedFrameImage = image
        return image
    }

    // Returns the current interval (interpolated between start and end)
    func getCurrentInterval() -> TimeInterval {
        playback?.currentInterval ?? 0.1
    }

    // Returns current offsetY (for future interpolation support)
    func getCurrentOffsetY() -> CGFloat {
        currentAnimation?.offsetY ?? 0
    }

    // Returns interpolated X movement per frame
    func getCurrentMoveX() -> CGFloat {
        playback?.currentMoveX ?? 0
    }

    // Returns interpolated Y movement per frame
    func getCurrentMoveY() -> CGFloat {
        playback?.currentMoveY ?? 0
    }

    // Select next animation based on probabilities, returns animation ID or nil
    func selectNextAnimation() -> String? {
        guard let animation = currentAnimation else { return nil }
        let eligible = animation.nextAnimations.filter { $0.only == "none" }
        let totalWeight = eligible.reduce(0) { $0 + $1.probability }
        guard totalWeight > 0 else { return nil }
        return Self.weightedNextAnimation(from: animation.nextAnimations,
                                          roll: Int.random(in: 1...totalWeight))
    }

    /// Pure weighted choice among `only == "none"` transitions for a 1-based
    /// `roll` in `1...totalWeight` (totalWeight = sum of eligible probabilities).
    /// Returns nil when no transition is eligible. The random roll is supplied
    /// by the caller so this stays deterministic and unit-testable.
    static func weightedNextAnimation(from transitions: [NextAnimation], roll: Int) -> String? {
        let eligible = transitions.filter { $0.only == "none" }
        guard !eligible.isEmpty else { return nil }
        var accumulated = 0
        for transition in eligible {
            accumulated += transition.probability
            if roll <= accumulated {
                return transition.animationID
            }
        }
        return eligible.last?.animationID
    }

    func advanceFrame() {
        guard var playback else { return }
        switch playback.advance() {
        case .advanced, .repeated:
            self.playback = playback
        case .finished:
            if shouldLoop {
                playback.restart(repeatCount: playback.animation.repeatCount.evaluate())
                self.playback = playback
            } else {
                self.playback = playback
                onAnimationComplete?()
            }
        }
    }
}
