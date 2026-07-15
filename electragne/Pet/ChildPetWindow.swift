//
//  ChildPetWindow.swift
//  electragne
//
//  Created by zacharyhamm on 2/4/26.
//

import Foundation
import AppKit
import SwiftUI

class ChildPetWindow: NSWindow {
    private let petAnimations: [String: PetAnimation]
    private weak var spriteRenderer: SpriteRenderer?
    private var animationTimer: Timer?
    private var childSize: CGFloat

    // Animation state for interval interpolation
    private var currentAnimation: PetAnimation?
    private var currentFrameIndex = 0
    private var totalFramesPlayed = 0
    private var estimatedTotalFrames = 0
    private var repeatCountRemaining = 0

    // Pause state
    private var isPaused = false
    private var isClosing = false  // Prevent operations during cleanup
    private var closeWorkItem: DispatchWorkItem?  // Track pending close operation
    private var hasBeenClosed = false  // Track if close() was already called

    // Access imageView through contentView to avoid retain issues
    private var imageView: NSImageView? {
        return contentView as? NSImageView
    }

    init?(animations: [String: PetAnimation], spriteRenderer: SpriteRenderer?,
          spawn: ChildSpawn, parentPosition: NSPoint, parentSize: CGFloat, isMovingRight: Bool,
          screen: NSScreen) {
        self.petAnimations = animations
        self.spriteRenderer = spriteRenderer
        self.childSize = parentSize

        let screenW = screen.frame.width
        let screenH = screen.frame.height
        let areaW = screen.visibleFrame.width
        let areaH = screen.visibleFrame.height
        let random = Int.random(in: 0...99)
        let randS = Int.random(in: 0...99)

        // The spawn expressions assume a single screen with origin (0,0), so
        // evaluate them in screen-local coordinates and convert back
        let localParentX = parentPosition.x - screen.frame.minX
        let localParentY = parentPosition.y - screen.frame.minY

        var spawnX = spawn.evaluateX(
            imageX: localParentX, imageY: localParentY,
            imageW: parentSize, imageH: parentSize,
            screenW: screenW, screenH: screenH,
            areaW: areaW, areaH: areaH,
            random: random, randS: randS
        )

        let spawnY = spawn.evaluateY(
            imageX: localParentX, imageY: localParentY,
            imageW: parentSize, imageH: parentSize,
            screenW: screenW, screenH: screenH,
            areaW: areaW, areaH: areaH,
            random: random, randS: randS
        )

        // Mirror X position if parent is moving right
        if isMovingRight {
            spawnX = localParentX + parentSize - (spawnX - localParentX) - parentSize
        }

        let frame = NSRect(
            x: screen.frame.minX + spawnX,
            y: screen.frame.minY + spawnY,
            width: parentSize, height: parentSize
        )

        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)

        // ARC manages this window's lifetime; the default (true) would make
        // close() perform an extra release and crash with a use-after-free
        self.isReleasedWhenClosed = false

        // Configure window to be transparent and floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .stationary]
        self.hasShadow = false

        // Setup image view
        let imgView = NSImageView()
        imgView.frame = NSRect(x: 0, y: 0, width: parentSize, height: parentSize)
        imgView.imageScaling = .scaleProportionallyUpOrDown
        self.contentView = imgView

        // Start playing the child animation
        playAnimation(spawn.nextAnimationID)
    }

    // MARK: - Public Pause/Resume (called by PetViewModel)

    func pause() {
        guard !isPaused, !isClosing, !hasBeenClosed else { return }
        isPaused = true
        animationTimer?.invalidate()
        animationTimer = nil
        closeWorkItem?.cancel()
        closeWorkItem = nil
        orderOut(nil)  // Hide window
    }

    func resume() {
        guard isPaused, !isClosing, !hasBeenClosed else { return }
        isPaused = false
        orderFront(nil)  // Show window

        // Resume animation if we have one
        if currentAnimation != nil {
            scheduleNextFrame()
        }
    }

    // MARK: - Cleanup

    private func cleanup() {
        isClosing = true
        animationTimer?.invalidate()
        animationTimer = nil
        closeWorkItem?.cancel()
        closeWorkItem = nil
        currentAnimation = nil
    }

    override func close() {
        guard !hasBeenClosed else { return }
        hasBeenClosed = true
        cleanup()
        super.close()
    }

    private func playAnimation(_ animationID: String) {
        guard let animation = petAnimations[animationID] else {
            closeAfterDelay()
            return
        }

        // Initialize animation state
        currentAnimation = animation
        currentFrameIndex = 0
        totalFramesPlayed = 0
        repeatCountRemaining = animation.repeatCount.evaluate()
        estimatedTotalFrames = calculateTotalFrames(animation: animation, repeatCount: repeatCountRemaining)

        // Show first frame immediately
        updateFrame()

        // Start animation timer with dynamic intervals
        animationTimer?.invalidate()
        scheduleNextFrame()
    }

    private func scheduleNextFrame() {
        guard currentAnimation != nil, !isClosing, !isPaused else { return }

        let interval = getCurrentInterval()
        animationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            guard !self.isClosing, !self.isPaused else { return }
            self.advanceFrame()
        }
    }

    private func advanceFrame() {
        guard let animation = currentAnimation, !isClosing, !hasBeenClosed else { return }

        currentFrameIndex += 1
        totalFramesPlayed += 1

        if currentFrameIndex >= animation.frames.count {
            // End of sequence
            if repeatCountRemaining > 0 {
                repeatCountRemaining -= 1
                currentFrameIndex = min(max(0, animation.repeatFrom), animation.frames.count - 1)
            } else {
                // Check for next animation
                if let nextAnim = animation.nextAnimations.first(where: { $0.only == "none" }) {
                    playAnimation(nextAnim.animationID)
                    return
                } else {
                    // No next animation, close after a delay
                    closeAfterDelay()
                    return
                }
            }
        }

        updateFrame()
        scheduleNextFrame()
    }

    private func updateFrame() {
        guard !isClosing, !hasBeenClosed,
              let animation = currentAnimation,
              animation.frames.indices.contains(currentFrameIndex),
              let imgView = imageView else { return }

        let frameNumber = animation.frames[currentFrameIndex]
        if let image = extractFrame(frameNumber: frameNumber) {
            imgView.image = image
        }
    }

    private func getCurrentInterval() -> TimeInterval {
        guard let animation = currentAnimation else { return 0.1 }
        let progress = getAnimationProgress()
        return animation.startInterval + (animation.endInterval - animation.startInterval) * progress
    }

    private func getAnimationProgress() -> Double {
        if estimatedTotalFrames > 1 {
            return min(1.0, max(0.0, Double(totalFramesPlayed) / Double(estimatedTotalFrames - 1)))
        }
        return 0
    }

    private func calculateTotalFrames(animation: PetAnimation, repeatCount: Int) -> Int {
        let firstPass = animation.frames.count
        // max(0,...) guards against a repeatFrom past the frame count producing
        // a negative section (mirrors AnimationManager.calculateTotalFrames).
        let repeatSection = max(0, animation.frames.count - animation.repeatFrom)
        return firstPass + (repeatSection * repeatCount)
    }

    private func extractFrame(frameNumber: Int) -> NSImage? {
        return spriteRenderer?.extractFrame(frameNumber: frameNumber)
    }

    private func closeAfterDelay() {
        guard !isClosing, !hasBeenClosed else { return }

        // Mark as closing immediately to prevent further operations
        isClosing = true

        // Stop all animations
        animationTimer?.invalidate()
        animationTimer = nil
        currentAnimation = nil

        // Cancel any existing close work
        closeWorkItem?.cancel()

        // Schedule close after delay; close() manages the hasBeenClosed flag
        closeWorkItem = DispatchWorkItem { [weak self] in
            self?.close()
        }
        if let workItem = closeWorkItem {
            DispatchQueue.main.asyncAfter(deadline: .now() + BehaviorConstants.childWindowFadeDelay, execute: workItem)
        }
    }

    deinit {
        // Cancel any pending work - do this unconditionally to be safe
        // Note: accessing ivars in deinit is safe in Swift, but we keep it minimal
        animationTimer?.invalidate()
        closeWorkItem?.cancel()
    }
}
