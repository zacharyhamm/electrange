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
    var currentAnimation: PetAnimation?
    var currentFrameIndex = 0
    var spriteSheet: NSImage?
    var tilesX = 16
    var tilesY = 11
    var shouldLoop = true
    var onAnimationComplete: (() -> Void)?

    // Sprite rendering
    private(set) var spriteRenderer: SpriteRenderer?

    // Child spawn tracking
    var childSpawns: [String: [ChildSpawn]] = [:]  // Keyed by parent animation ID
    var onChildSpawn: ((ChildSpawn) -> Void)?  // Callback when a child should spawn

    // Repeat tracking
    private var repeatCountRemaining = 0
    private var totalFramesPlayed = 0 // For interval interpolation
    private var estimatedTotalFrames = 0 // Estimated total frames for this animation run
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
    func getChildSpawnsForCurrentAnimation() -> [ChildSpawn] {
        guard let animation = currentAnimation else { return [] }
        return childSpawns[animation.id] ?? []
    }

    func playAnimation(_ animationID: String) {
        guard let animation = animations[animationID] else { return }
        currentAnimation = animation
        currentFrameIndex = 0
        totalFramesPlayed = 0
        shouldLoop = true  // Default to looping
        onAnimationComplete = nil  // Clear any previous completion handler
        repeatCountRemaining = animation.repeatCount.evaluate()
        estimatedTotalFrames = calculateTotalFrames(animation: animation, repeatCount: repeatCountRemaining)
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
        guard let animation = currentAnimation,
              currentFrameIndex < animation.frames.count else {
            return nil
        }
        return animation.frames[currentFrameIndex]
    }

    func getCurrentFrameImage() -> NSImage? {
        guard let frameNumber = getCurrentFrameNumber(),
              let renderer = spriteRenderer else {
            return nil
        }

        return renderer.extractFrame(frameNumber: frameNumber)
    }

    // Returns the current interval (interpolated between start and end)
    func getCurrentInterval() -> TimeInterval {
        guard let animation = currentAnimation else { return 0.1 }
        let clampedProgress = getAnimationProgress()
        return animation.startInterval + (animation.endInterval - animation.startInterval) * clampedProgress
    }

    // Returns current offsetY (for future interpolation support)
    func getCurrentOffsetY() -> CGFloat {
        return currentAnimation?.offsetY ?? 0
    }

    // Returns interpolated X movement per frame
    func getCurrentMoveX() -> CGFloat {
        guard let animation = currentAnimation else { return 0 }
        let progress = getAnimationProgress()
        return animation.startMoveX + (animation.endMoveX - animation.startMoveX) * progress
    }

    // Returns interpolated Y movement per frame
    func getCurrentMoveY() -> CGFloat {
        guard let animation = currentAnimation else { return 0 }
        let progress = getAnimationProgress()
        return animation.startMoveY + (animation.endMoveY - animation.startMoveY) * progress
    }

    // Calculate progress through animation (0.0 to 1.0)
    private func getAnimationProgress() -> CGFloat {
        if estimatedTotalFrames > 1 {
            return min(1.0, max(0.0, CGFloat(totalFramesPlayed) / CGFloat(estimatedTotalFrames - 1)))
        }
        return 0
    }

    // Select next animation based on probabilities, returns animation ID or nil
    func selectNextAnimation() -> String? {
        guard let animation = currentAnimation else { return nil }
        let transitions = animation.nextAnimations.filter { $0.only == "none" }
        guard !transitions.isEmpty else { return nil }

        // Calculate total probability weight
        let totalWeight = transitions.reduce(0) { $0 + $1.probability }
        guard totalWeight > 0 else { return nil }

        // Random selection based on weights
        let random = Int.random(in: 1...totalWeight)
        var accumulated = 0
        for transition in transitions {
            accumulated += transition.probability
            if random <= accumulated {
                return transition.animationID
            }
        }
        return transitions.last?.animationID
    }

    // Check if current animation has movement defined
    func hasMovement() -> Bool {
        guard let animation = currentAnimation else { return false }
        return animation.startMoveX != 0 || animation.endMoveX != 0
    }

    func advanceFrame() {
        guard let animation = currentAnimation else { return }
        let nextIndex = currentFrameIndex + 1
        totalFramesPlayed += 1

        if nextIndex >= animation.frames.count {
            // Reached end of frame sequence
            if repeatCountRemaining > 0 {
                // Loop back to repeatFrom position
                repeatCountRemaining -= 1
                currentFrameIndex = min(animation.repeatFrom, animation.frames.count - 1)
            } else if shouldLoop {
                // Standard looping (restart from beginning)
                currentFrameIndex = 0
                totalFramesPlayed = 0
                repeatCountRemaining = animation.repeatCount.evaluate()
                estimatedTotalFrames = calculateTotalFrames(animation: animation, repeatCount: repeatCountRemaining)
            } else {
                // Animation complete - call handler
                onAnimationComplete?()
            }
        } else {
            currentFrameIndex = nextIndex
        }
    }

    func playAnimationOnce(_ animationID: String, completion: @escaping () -> Void) {
        guard let animation = animations[animationID] else { return }
        currentAnimation = animation
        currentFrameIndex = 0
        totalFramesPlayed = 0
        shouldLoop = false
        repeatCountRemaining = animation.repeatCount.evaluate()
        estimatedTotalFrames = calculateTotalFrames(animation: animation, repeatCount: repeatCountRemaining)
        onAnimationComplete = completion
        spawnedChildrenForCurrentAnimation = false
        triggerChildSpawns()
    }

    func playAnimationLooping(_ animationID: String) {
        guard let animation = animations[animationID] else { return }
        currentAnimation = animation
        currentFrameIndex = 0
        totalFramesPlayed = 0
        shouldLoop = true
        repeatCountRemaining = animation.repeatCount.evaluate()
        estimatedTotalFrames = calculateTotalFrames(animation: animation, repeatCount: repeatCountRemaining)
        onAnimationComplete = nil
        spawnedChildrenForCurrentAnimation = false
        triggerChildSpawns()
    }

    private func calculateTotalFrames(animation: PetAnimation, repeatCount: Int) -> Int {
        // First pass through all frames
        let firstPass = animation.frames.count
        // Repeated section (from repeatFrom to end)
        let repeatSection = animation.frames.count - animation.repeatFrom
        // Total = first pass + (repeatSection * repeatCount)
        return firstPass + (repeatSection * repeatCount)
    }

}
