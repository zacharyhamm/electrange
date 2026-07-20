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

    /// Frame sequencing/interpolation shared with AnimationManager.
    private var playback: AnimationPlayback?

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
          screen: ScreenInfo) {
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

        let variables: [String: Double] = [
            "imageX": localParentX, "imageY": localParentY,
            "imageW": parentSize, "imageH": parentSize,
            "screenW": screenW, "screenH": screenH,
            "areaW": areaW, "areaH": areaH,
            "random": Double(random), "randS": Double(randS),
        ]
        var spawnX = spawn.x(variables: variables)
        let spawnY = spawn.y(variables: variables)

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
        PetWindowPresentation.enforce(on: self)
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
        if playback != nil {
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
        playback = nil
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

        playback = AnimationPlayback(
            animation: animation,
            repeatCount: animation.repeatCount.evaluate()
        )

        // Show first frame immediately
        updateFrame()

        // Start animation timer with dynamic intervals
        animationTimer?.invalidate()
        scheduleNextFrame()
    }

    private func scheduleNextFrame() {
        guard let playback, !isClosing, !isPaused else { return }

        animationTimer = Timer.scheduledTimer(withTimeInterval: playback.currentInterval, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            guard !self.isClosing, !self.isPaused else { return }
            self.advanceFrame()
        }
    }

    private func advanceFrame() {
        guard var playback, !isClosing, !hasBeenClosed else { return }

        switch playback.advance() {
        case .advanced, .repeated:
            self.playback = playback
            updateFrame()
            scheduleNextFrame()
        case .finished:
            self.playback = playback
            // Chain into the next animation, or close after a delay.
            if let nextAnim = playback.animation.nextAnimations.first(where: { $0.only == "none" }) {
                playAnimation(nextAnim.animationID)
            } else {
                closeAfterDelay()
            }
        }
    }

    private func updateFrame() {
        guard !isClosing, !hasBeenClosed,
              let frameNumber = playback?.currentFrameNumber,
              let imgView = imageView else { return }

        if let image = extractFrame(frameNumber: frameNumber) {
            imgView.image = image
        }
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
        playback = nil

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
