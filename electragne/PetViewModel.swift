//
//  PetViewModel.swift
//  electragne
//
//  Created by zacharyhamm on 2/4/26.
//

import Foundation
import SwiftUI
import AppKit

// MARK: - Pet View Model

@Observable
class PetViewModel {
    // MARK: - State

    private(set) var state: PetState = .falling(velocity: 0, bounceCount: 0)
    var isMovingRight = true
    var lastInteractionTime = Date()

    // MARK: - Managers

    let animationManager = AnimationManager()
    private let dockDetector = DockDetector.shared
    private let windowDetector = WindowDetector.shared

    // MARK: - Dock State

    private var cachedDockInfo: DockInfo?

    // MARK: - Window Climbing State

    /// The app window the pet is climbing or standing on
    private var climbWindowID: CGWindowID?
    /// Whether the pet is climbing the window's left side (it climbs the left
    /// side when moving right, the right side when moving left)
    private var climbingOnLeftSide = true

    private enum ClimbPhase {
        case ascending   // Going up the side
        case toppingOut  // Crawling over the edge onto the top
    }
    private var climbPhase: ClimbPhase = .ascending

    /// Whether the current fall may land on window tops. Set when the pet is
    /// dropped from a drag; ordinary falls go all the way to the ground.
    private var landOnWindowsWhileFalling = false

    // MARK: - Child Windows

    private(set) var childWindowRefs: [Weak<ChildPetWindow>] = []

    // MARK: - Timers

    private var movementTimer: Timer?
    private var physicsTimer: Timer?
    private var animationTimer: Timer?
    private var idleTimer: Timer?

    // MARK: - Pause State

    private var isPaused = false
    private var stateBeforePause: PetState?

    // MARK: - Window Reference

    weak var petWindow: NSWindow?

    // MARK: - Initialization

    init() {
        setupNotificationObservers()
    }

    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePauseNotification),
            name: .petShouldPause,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleResumeNotification),
            name: .petShouldResume,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// If a display is unplugged or rearranged out from under the pet,
    /// drop it back in from the top of a remaining screen.
    @objc private func handleScreenParametersChange() {
        guard let window = petWindow else { return }
        guard !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) else { return }

        positionWindowForFall()
        if isPaused {
            climbWindowID = nil
            landOnWindowsWhileFalling = false
            stateBeforePause = .falling(velocity: 0, bounceCount: 0)
            state = .falling(velocity: 0, bounceCount: 0)
        } else {
            stopAllTimers()
            startFalling()
        }
    }

    @objc private func handlePauseNotification() {
        pause()
    }

    @objc private func handleResumeNotification() {
        resume()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        stopAllTimers()
    }

    func loadAnimations() {
        guard let url = Bundle.main.url(forResource: "animations", withExtension: "xml") else {
            print("Failed to find animations.xml")
            return
        }

        animationManager.loadAnimations(from: url)

        // Set up child spawn callback
        animationManager.onChildSpawn = { [weak self] spawn in
            self?.spawnChildWindow(spawn: spawn)
        }

        // Initialize with walk animation
        animationManager.playAnimation(AnimationID.walk.rawValue)
    }

    // MARK: - State Transitions

    func startFalling() {
        climbWindowID = nil
        landOnWindowsWhileFalling = false
        state = .falling(velocity: 0, bounceCount: 0)
        playFallAnimation()
        startPhysicsTimer()
    }

    func startWalking() {
        climbWindowID = nil
        state = .walking
        playAnimationWithTransitions(AnimationID.walk)
        recordInteraction()
        startDynamicAnimationTimer()
        startIdleTimer()
        startMovementTimer()
    }

    func startDragging(mouseOffset: NSPoint) {
        stopAllTimers()
        climbWindowID = nil
        state = .dragging(mouseOffset: mouseOffset)
        animationManager.playAnimation(AnimationID.drag.rawValue)
        startDynamicAnimationTimer()
        recordInteraction()
    }

    func endDragging() {
        guard state.isDragging else { return }
        state = .falling(velocity: 0, bounceCount: 0)
        // A dropped pet may land on the first window top it falls onto
        landOnWindowsWhileFalling = true
        recordInteraction()
        playFallAnimation()
        startPhysicsTimer()
    }

    func startSleeping() {
        guard case .walking = state else { return }

        stopMovementTimer()
        state = .sleeping(phase: 0)
        stopIdleTimer()
        startDynamicAnimationTimer()
        playSleepSequence(remaining: AnimationID.sleepSequence)
    }

    func wakeUp() {
        guard case .sleeping = state else { return }
        startWalking()
    }

    func startJumping() {
        guard let window = petWindow,
              let screen = currentScreen else {
            return
        }

        stopMovementTimer()
        stopIdleTimer()
        state = .jumping

        // Calculate jump start position
        jumpStartX = window.frame.origin.x
        jumpStartY = window.frame.origin.y

        // Calculate jump target position
        // Horizontal: continue forward with momentum
        let jumpDistance: CGFloat = 120  // Distance to travel forward during jump
        let petSize = window.frame.width

        if isMovingRight {
            jumpTargetX = min(jumpStartX + jumpDistance, screen.frame.maxX - petSize)
        } else {
            jumpTargetX = max(jumpStartX - jumpDistance, screen.frame.minX)
        }

        // Vertical: return to ground level
        jumpTargetY = screen.frame.minY

        // Initialize jump progress
        jumpProgress = 0

        // Start animation timer to advance sprite frames
        startDynamicAnimationTimer()

        // Start jump physics timer
        startBasicJumpTimer()
    }

    private func startBasicJumpTimer() {
        movementTimer?.invalidate()
        movementTimer = Timer.scheduledTimer(withTimeInterval: PhysicsConstants.frameInterval, repeats: true) { [weak self] _ in
            self?.updateBasicJumpMovement()
        }
    }

    private func updateBasicJumpMovement() {
        guard let window = petWindow,
              let screen = currentScreen else { return }

        // Use the animation's built-in movement values (like desktopPet)
        // The jump animation has startY=-15 (up) to endY=+15 (down) which creates the arc
        let moveX = abs(animationManager.getCurrentMoveX())
        let moveY = animationManager.getCurrentMoveY()

        let petSize = window.frame.width
        var newX = window.frame.origin.x
        var newY = window.frame.origin.y

        // Apply horizontal movement based on direction
        if isMovingRight {
            newX += moveX
        } else {
            newX -= moveX
        }

        // Apply vertical movement from animation (creates the arc)
        // Multiply by scale factor to make the jump more impressive
        let jumpScale: CGFloat = 2.0
        newY -= moveY * jumpScale  // Subtract because screen Y is inverted (negative moveY = up)

        // Clamp to screen bounds, extended across the seam when an adjacent
        // display continues at the same level or lower
        var minX = screen.frame.minX
        var maxX = screen.frame.maxX - petSize
        if let next = walkableScreen(beyond: screen, movingRight: isMovingRight, footY: screen.frame.minY),
           next.frame.minY <= screen.frame.minY + 1 {
            if isMovingRight {
                maxX = next.frame.maxX - petSize
            } else {
                minX = next.frame.minX
            }
        }
        newX = max(minX, min(newX, maxX))
        newY = max(screen.frame.minY, newY)  // Don't go below ground

        // Update window position
        window.setFrameOrigin(NSPoint(x: newX, y: newY))
    }

    func endJumping() {
        guard let window = petWindow else {
            state = .walking
            return
        }

        // Stop jump timer
        movementTimer?.invalidate()

        // Reset jump progress
        jumpProgress = 0

        // Land at the ground of the screen under the pet (not the dock top:
        // the pet may legitimately end up at ground level within the dock's
        // x-range, as before)
        let landingScreen = screenContaining(
            x: window.frame.midX,
            below: window.frame.origin.y
        ) ?? currentScreen
        let ground = landingScreen?.frame.minY ?? window.frame.origin.y

        // If the jump carried the pet across a seam onto a lower display,
        // let it fall the rest of the way
        if window.frame.origin.y > ground + 4 {
            startFalling()
            return
        }

        window.setFrameOrigin(NSPoint(x: window.frame.origin.x, y: ground))

        // Resume walking state and start movement timer
        state = .walking
        startMovementTimer()
    }

    // MARK: - Ledge Jump (onto a higher adjacent display)

    func startJumpingToLedge(targetX: CGFloat, targetY: CGFloat) {
        guard let window = petWindow else {
            startWalking()
            return
        }

        stopMovementTimer()
        stopIdleTimer()
        state = .jumpingToLedge

        jumpStartX = window.frame.origin.x
        jumpStartY = window.frame.origin.y
        jumpTargetX = targetX
        jumpTargetY = targetY
        jumpProgress = 0

        animationManager.playAnimation(AnimationID.jump.rawValue)
        startDynamicAnimationTimer()
        startLedgeJumpTimer()
    }

    private func startLedgeJumpTimer() {
        movementTimer?.invalidate()
        movementTimer = Timer.scheduledTimer(withTimeInterval: PhysicsConstants.frameInterval, repeats: true) { [weak self] _ in
            self?.updateLedgeJumpMovement()
        }
    }

    private func updateLedgeJumpMovement() {
        guard let window = petWindow else { return }
        guard case .jumpingToLedge = state else { return }

        // Advance jump progress (complete in ~0.3 seconds)
        jumpProgress += 0.05
        if jumpProgress >= 1.0 {
            movementTimer?.invalidate()
            movementTimer = nil
            window.setFrameOrigin(NSPoint(x: jumpTargetX, y: jumpTargetY))
            startWalking()
            return
        }

        // Linear interpolation for X, parabolic arc for Y (same as the dock jump)
        let arcHeight: CGFloat = 30
        let newX = jumpStartX + (jumpTargetX - jumpStartX) * jumpProgress
        let baseY = jumpStartY + (jumpTargetY - jumpStartY) * jumpProgress
        let newY = baseY + arcHeight * 4 * jumpProgress * (1 - jumpProgress)

        window.setFrameOrigin(NSPoint(x: newX, y: newY))
    }

    // MARK: - Window Climbing

    /// A window edge the pet just walked into and decided to climb
    private struct ClimbOpportunity {
        let surface: WindowSurface
        let startX: CGFloat
    }

    /// Check whether the pet's step from currentX to newX crosses the side of
    /// a climbable window. The window qualifies only if its top leaves room
    /// for the pet below the top of the screen, its top is above the pet's
    /// head (something to actually climb), and its side reaches down to the
    /// pet. Rolls the climb chance per crossing.
    private func findClimbOpportunity(on screen: NSScreen, currentX: CGFloat, newX: CGFloat,
                                      footY: CGFloat, petSize: CGFloat) -> ClimbOpportunity? {
        let topLimit = screen.visibleFrame.maxY

        for surface in windowDetector.windows(on: screen) {
            let frame = surface.frame

            // The pet must fit between the window top and the top of the screen
            guard frame.maxY + petSize <= topLimit else { continue }
            // The top must be above the pet's head, else there's nothing to climb
            guard frame.maxY > footY + petSize else { continue }
            // The side must reach down to where the pet is walking
            guard frame.minY <= footY + petSize else { continue }
            // And the top must be wide enough to stand on
            guard frame.width >= petSize else { continue }

            if isMovingRight {
                // Just crossed the window's left edge this tick
                if currentX + petSize <= frame.minX && newX + petSize >= frame.minX,
                   Int.random(in: 1...100) <= BehaviorConstants.climbChance {
                    return ClimbOpportunity(surface: surface, startX: frame.minX - petSize)
                }
            } else {
                // Just crossed the window's right edge this tick
                if currentX >= frame.maxX && newX <= frame.maxX,
                   Int.random(in: 1...100) <= BehaviorConstants.climbChance {
                    return ClimbOpportunity(surface: surface, startX: frame.maxX)
                }
            }
        }

        return nil
    }

    func startClimbingWindow(_ surface: WindowSurface) {
        stopMovementTimer()
        stopIdleTimer()

        climbWindowID = surface.id
        climbingOnLeftSide = isMovingRight
        climbPhase = .ascending
        state = .climbingWindow
        recordInteraction()

        // The climbing sprites are drawn vertically; the existing
        // direction flip mirrors them onto the correct side
        animationManager.playAnimation(AnimationID.verticalWalkUp.rawValue)
        startDynamicAnimationTimer()
        startClimbTimer()
    }

    private func startClimbTimer() {
        movementTimer?.invalidate()
        movementTimer = Timer.scheduledTimer(withTimeInterval: PhysicsConstants.frameInterval, repeats: true) { [weak self] _ in
            self?.updateClimbMovement()
        }
    }

    private func updateClimbMovement() {
        guard let window = petWindow else { return }
        guard case .climbingWindow = state else { return }
        guard let id = climbWindowID,
              let frame = windowDetector.frame(ofWindow: id),
              let screen = currentScreen else {
            // The window went away mid-climb
            abortClimb()
            return
        }

        let petSize = window.frame.width

        // If the window moved up so the pet no longer fits on top, let go
        if frame.maxY + petSize > screen.visibleFrame.maxY {
            abortClimb()
            return
        }

        // Hug the wall, following the window if it moves
        let wallX = climbingOnLeftSide ? frame.minX - petSize : frame.maxX

        switch climbPhase {
        case .ascending:
            // Climb at the animation's own vertical speed
            let climbSpeed = abs(animationManager.getCurrentMoveY())
            let newY = window.frame.origin.y + climbSpeed

            if newY >= frame.maxY {
                // Reached the top: crawl over the edge
                climbPhase = .toppingOut
                window.setFrameOrigin(NSPoint(x: wallX, y: frame.maxY))
                animationManager.playAnimationOnce(AnimationID.verticalWalkOver.rawValue) { [weak self] in
                    self?.finishToppingOut()
                }
            } else {
                window.setFrameOrigin(NSPoint(x: wallX, y: newY))
            }

        case .toppingOut:
            // Slide from the wall onto the window top while crawling over
            let targetX = climbingOnLeftSide ? frame.minX : frame.maxX - petSize
            var newX = window.frame.origin.x
            let step: CGFloat = 1.5
            if abs(targetX - newX) <= step {
                newX = targetX
            } else {
                newX += targetX > newX ? step : -step
            }
            window.setFrameOrigin(NSPoint(x: newX, y: frame.maxY))
        }
    }

    private func finishToppingOut() {
        guard case .climbingWindow = state else { return }
        startWalkingOnWindow()
    }

    private func abortClimb() {
        movementTimer?.invalidate()
        movementTimer = nil
        startFalling()
    }

    func startWalkingOnWindow() {
        state = .walkingOnWindow
        // Note: top_walk2 (39) looks right but is the upside-down
        // hanging-from-the-screen-top sprite; on a window we walk normally
        animationManager.playAnimation(AnimationID.walk.rawValue)
        recordInteraction()
        startDynamicAnimationTimer()
        startIdleTimer()
        startWindowTopMovementTimer()
    }

    private func startWindowTopMovementTimer() {
        movementTimer?.invalidate()
        movementTimer = Timer.scheduledTimer(withTimeInterval: PhysicsConstants.frameInterval, repeats: true) { [weak self] _ in
            self?.updateWindowTopMovement()
        }
    }

    private func updateWindowTopMovement() {
        guard let window = petWindow else { return }
        guard case .walkingOnWindow = state else { return }
        guard let id = climbWindowID,
              let frame = windowDetector.frame(ofWindow: id),
              let screen = currentScreen else {
            // The window disappeared from under the pet
            stopMovementTimer()
            stopIdleTimer()
            startFalling()
            return
        }

        let petSize = window.frame.width

        // If the window moved up under the menu bar, hop down
        if frame.maxY + petSize > screen.visibleFrame.maxY {
            stopIdleTimer()
            startJumpingDown(fromPlatform: frame)
            return
        }

        let moveX = abs(animationManager.getCurrentMoveX())
        var newX = window.frame.origin.x

        if isMovingRight {
            newX += moveX
        } else {
            newX -= moveX
        }

        // Check window-top boundaries
        let atRightEdge = newX + petSize >= frame.maxX
        let atLeftEdge = newX <= frame.minX

        if atRightEdge || atLeftEdge {
            // At edge of the window, trigger look_down
            newX = atRightEdge ? frame.maxX - petSize : frame.minX
            window.setFrameOrigin(NSPoint(x: newX, y: frame.maxY))
            startLookingDown()
            return
        }

        // Ride the window top (it may be moving)
        window.setFrameOrigin(NSPoint(x: newX, y: frame.maxY))
    }

    // MARK: - Dock State Transitions

    // Track jump progress
    private var jumpProgress: CGFloat = 0
    private var jumpStartX: CGFloat = 0
    private var jumpStartY: CGFloat = 0
    private var jumpTargetX: CGFloat = 0
    private var jumpTargetY: CGFloat = 0

    func startJumpingToDock() {
        guard let window = petWindow,
              let dockInfo = cachedDockInfo else {
            startWalking()
            return
        }

        stopMovementTimer()
        stopIdleTimer()
        state = .jumpingToDock

        // Calculate jump start and target positions
        jumpStartX = window.frame.origin.x
        jumpStartY = window.frame.origin.y
        jumpTargetY = dockInfo.frame.maxY  // Land on top of dock

        // Target X: move onto the dock a bit
        let petSize = window.frame.width
        if isMovingRight {
            jumpTargetX = dockInfo.frame.minX + petSize  // Land just inside left edge
        } else {
            jumpTargetX = dockInfo.frame.maxX - petSize * 2  // Land just inside right edge
        }
        jumpProgress = 0

        animationManager.playAnimation(AnimationID.jump.rawValue)
        startDynamicAnimationTimer()
        startDockJumpTimer()
    }

    private func startDockJumpTimer() {
        movementTimer?.invalidate()
        movementTimer = Timer.scheduledTimer(withTimeInterval: PhysicsConstants.frameInterval, repeats: true) { [weak self] _ in
            self?.updateDockJumpMovement()
        }
    }

    private func updateDockJumpMovement() {
        guard let window = petWindow else { return }
        guard case .jumpingToDock = state else { return }

        // Advance jump progress (complete in ~0.3 seconds)
        jumpProgress += 0.05
        if jumpProgress >= 1.0 {
            jumpProgress = 1.0
            landOnDock()
            return
        }

        // Linear interpolation for X
        let newX = jumpStartX + (jumpTargetX - jumpStartX) * jumpProgress

        // Parabolic arc for Y (jump up then land)
        // y = startY + (targetY - startY) * t + arcHeight * 4 * t * (1 - t)
        let arcHeight: CGFloat = 30  // How high the jump arcs above the target
        let baseY = jumpStartY + (jumpTargetY - jumpStartY) * jumpProgress
        let arcOffset = arcHeight * 4 * jumpProgress * (1 - jumpProgress)
        let newY = baseY + arcOffset

        window.setFrameOrigin(NSPoint(x: newX, y: newY))
    }

    private func landOnDock() {
        guard let window = petWindow,
              let dockInfo = cachedDockInfo else {
            startWalking()
            return
        }

        movementTimer?.invalidate()
        movementTimer = nil

        // Ensure pet is exactly on dock top and within dock bounds
        var finalX = window.frame.origin.x
        let petSize = window.frame.width

        // Clamp X to dock bounds
        if finalX < dockInfo.frame.minX {
            finalX = dockInfo.frame.minX
        }
        if finalX + petSize > dockInfo.frame.maxX {
            finalX = dockInfo.frame.maxX - petSize
        }

        let finalY = dockInfo.frame.maxY
        window.setFrameOrigin(NSPoint(x: finalX, y: finalY))

        startWalkingOnDock()
    }

    func startWalkingOnDock() {
        state = .walkingOnDock
        animationManager.playAnimationOnce(AnimationID.walkTask2.rawValue) { [weak self] in
            self?.handleDockAnimationComplete()
        }
        recordInteraction()
        startDynamicAnimationTimer()
        startIdleTimer()
        startDockMovementTimer()
    }

    private func startDockMovementTimer() {
        movementTimer?.invalidate()
        movementTimer = Timer.scheduledTimer(withTimeInterval: PhysicsConstants.frameInterval, repeats: true) { [weak self] _ in
            self?.updateDockMovement()
        }
    }

    private func updateDockMovement() {
        guard let window = petWindow else { return }
        guard case .walkingOnDock = state else { return }
        guard let dockInfo = cachedDockInfo else {
            // Dock disappeared, fall down
            startFalling()
            return
        }

        let moveX = abs(animationManager.getCurrentMoveX())
        var newX = window.frame.origin.x
        let petSize = window.frame.width

        if isMovingRight {
            newX += moveX
        } else {
            newX -= moveX
        }

        // Check dock boundaries
        let atRightEdge = newX + petSize >= dockInfo.frame.maxX
        let atLeftEdge = newX <= dockInfo.frame.minX

        if atRightEdge || atLeftEdge {
            // At edge of dock, trigger look_down
            if atRightEdge {
                newX = dockInfo.frame.maxX - petSize
            } else {
                newX = dockInfo.frame.minX
            }
            window.setFrameOrigin(NSPoint(x: newX, y: window.frame.origin.y))
            startLookingDown()
            return
        }

        // Keep Y position on dock top
        let newY = dockInfo.frame.maxY
        window.setFrameOrigin(NSPoint(x: newX, y: newY))
    }

    private func handleDockAnimationComplete() {
        guard case .walkingOnDock = state else { return }

        // Continue walking on dock
        animationManager.playAnimationOnce(AnimationID.walkTask2.rawValue) { [weak self] in
            self?.handleDockAnimationComplete()
        }
    }

    func startLookingDown() {
        stopMovementTimer()
        stopIdleTimer()
        state = .lookingDown
        animationManager.playAnimationOnce(AnimationID.lookDown.rawValue) { [weak self] in
            self?.handleLookDownComplete()
        }
        startDynamicAnimationTimer()
    }

    private func handleLookDownComplete() {
        // Roll to decide: turn around or jump off
        let roll = Int.random(in: 1...100)

        // Peering over a window edge?
        if let id = climbWindowID {
            guard let frame = windowDetector.frame(ofWindow: id) else {
                startFalling()
                return
            }
            if roll <= 50 {
                // Turn around, stay on the window top
                isMovingRight.toggle()
                startWalkingOnWindow()
            } else {
                // Jump down from the window
                climbWindowID = nil
                startJumpingDown(fromPlatform: frame)
            }
            return
        }

        if roll <= 50 {
            // Turn around, stay on dock
            isMovingRight.toggle()
            startWalkingOnDock()
        } else {
            // Jump off the dock
            startJumpingOffDock()
        }
    }

    func startJumpingOffDock() {
        guard let dockInfo = cachedDockInfo else {
            startWalking()
            return
        }
        startJumpingDown(fromPlatform: dockInfo.frame)
    }

    /// Jump down to the ground from the edge of a platform (the dock or an
    /// app window's top), arcing away from the platform in the facing direction.
    func startJumpingDown(fromPlatform platformFrame: NSRect) {
        guard let window = petWindow,
              let screen = currentScreen else {
            startWalking()
            return
        }

        climbWindowID = nil
        state = .jumpingOffDock

        // Calculate jump arc from platform to ground
        jumpStartX = window.frame.origin.x
        jumpStartY = window.frame.origin.y
        jumpTargetY = screen.frame.minY  // Ground level

        // Target X: jump away from platform edge
        let petSize = window.frame.width
        let jumpDistance: CGFloat = 50  // How far to jump horizontally

        if isMovingRight {
            // At right edge of platform, jump right
            jumpTargetX = min(platformFrame.maxX + jumpDistance, screen.frame.maxX - petSize)
        } else {
            // At left edge of platform, jump left
            jumpTargetX = max(platformFrame.minX - jumpDistance - petSize, screen.frame.minX)
        }
        jumpProgress = 0

        animationManager.playAnimation(AnimationID.jumpDown.rawValue)
        startDynamicAnimationTimer()
        startJumpOffMovementTimer()
    }

    private func startJumpOffMovementTimer() {
        movementTimer?.invalidate()
        movementTimer = Timer.scheduledTimer(withTimeInterval: PhysicsConstants.frameInterval, repeats: true) { [weak self] _ in
            self?.updateJumpOffMovement()
        }
    }

    private func updateJumpOffMovement() {
        guard let window = petWindow else { return }
        guard case .jumpingOffDock = state else { return }

        // Advance jump progress (complete in ~0.5 seconds)
        jumpProgress += 0.033
        if jumpProgress >= 1.0 {
            jumpProgress = 1.0
            finishJumpOffDock()
            return
        }

        // Linear interpolation for X
        let newX = jumpStartX + (jumpTargetX - jumpStartX) * jumpProgress

        // Parabolic arc for Y - starts high, arcs up slightly, then down
        // Peak should be early in the jump (around 20% progress)
        let peakProgress: CGFloat = 0.2
        let arcHeight: CGFloat = 20

        let baseY = jumpStartY + (jumpTargetY - jumpStartY) * jumpProgress
        let arcOffset: CGFloat
        if jumpProgress < peakProgress {
            // Going up
            arcOffset = arcHeight * (jumpProgress / peakProgress)
        } else {
            // Coming down
            let downProgress = (jumpProgress - peakProgress) / (1 - peakProgress)
            arcOffset = arcHeight * (1 - downProgress)
        }
        let newY = baseY + arcOffset

        window.setFrameOrigin(NSPoint(x: newX, y: max(jumpTargetY, newY)))
    }

    private func finishJumpOffDock() {
        guard let window = petWindow else { return }

        movementTimer?.invalidate()
        movementTimer = nil

        // Ensure pet is on ground
        window.setFrameOrigin(NSPoint(x: window.frame.origin.x, y: jumpTargetY))

        // Play landing animation then resume walking
        animationManager.playAnimationOnce(AnimationID.jumpDown3.rawValue) { [weak self] in
            self?.startWalking()
        }
        startDynamicAnimationTimer()
    }

    private func startFallingFromDock() {
        // This is now handled by finishJumpOffDock
        // Keep for compatibility but redirect
        finishJumpOffDock()
    }

    private func startFallingFromDockTimer() {
        // No longer used - jump arc handles the full motion
    }

    private func updateFallingFromDock(timer: Timer) {
        // No longer used - jump arc handles the full motion
    }

    // MARK: - Screen Helpers

    /// The screen the pet is currently on (by window midpoint). Falls back to
    /// horizontal containment for positions above/below any screen (e.g. while
    /// falling in from the top), then to the window's own screen.
    private var currentScreen: NSScreen? {
        guard let window = petWindow else { return NSScreen.main }
        let mid = NSPoint(x: window.frame.midX, y: window.frame.midY)
        if let screen = NSScreen.screens.first(where: { NSPointInRect(mid, $0.frame) }) {
            return screen
        }
        if let screen = screenContaining(x: mid.x, below: .greatestFiniteMagnitude) {
            return screen
        }
        return window.screen ?? NSScreen.main
    }

    /// The screen spanning the given x whose bottom edge is at or below y.
    /// With displays stacked beyond a seam, prefers the highest ground that's
    /// still beneath the pet.
    private func screenContaining(x: CGFloat, below y: CGFloat) -> NSScreen? {
        NSScreen.screens
            .filter { x >= $0.frame.minX && x < $0.frame.maxX && $0.frame.minY <= y + 1 }
            .max { $0.frame.minY < $1.frame.minY }
    }

    /// A display the pet can walk onto across the given screen's left or right
    /// edge. The adjacent screen must touch that edge, be open at the pet's
    /// height, and have a ground that's reachable: at/below the pet's feet, or
    /// a jumpable ledge above them.
    private func walkableScreen(beyond screen: NSScreen, movingRight: Bool, footY: CGFloat) -> NSScreen? {
        let seamX = movingRight ? screen.frame.maxX : screen.frame.minX
        let candidates = NSScreen.screens.filter { other in
            guard other != screen else { return false }
            let touchingEdge = movingRight ? other.frame.minX : other.frame.maxX
            guard abs(touchingEdge - seamX) < 1 else { return false }
            guard other.frame.maxY > footY else { return false }
            return other.frame.minY <= footY + PhysicsConstants.maxScreenStepUp
        }
        // With stacked displays beyond the seam, prefer the ground nearest the pet's feet
        return candidates.min { abs($0.frame.minY - footY) < abs($1.frame.minY - footY) }
    }

    // MARK: - Ground Level Calculation

    /// What the pet would land on at the end of a fall
    private enum GroundSurface {
        case ground
        case dock
        case window(CGWindowID)
    }

    /// Ground level beneath the pet: the dock top when the pet is over the
    /// dock on its screen, otherwise the bottom edge of the screen under it.
    /// With includeWindows, app window tops below the pet count too, and the
    /// highest one (the first the pet would encounter falling) wins.
    private func groundInfo(at x: CGFloat, petWidth: CGFloat, below y: CGFloat,
                            includeWindows: Bool = false) -> (level: CGFloat, surface: GroundSurface) {
        let screen = screenContaining(x: x + petWidth / 2, below: y) ?? currentScreen

        guard let screen else { return (0, .ground) }

        // Refresh dock info for the screen the pet is over
        cachedDockInfo = dockDetector.getDockInfo(for: screen)

        var level = screen.frame.minY
        var surface = GroundSurface.ground

        // For bottom dock, check if pet is above the dock
        if let dockInfo = cachedDockInfo, dockInfo.position == .bottom,
           dockInfo.containsX(x, petWidth: petWidth) {
            level = dockInfo.frame.maxY
            surface = .dock
        }

        if includeWindows {
            let topLimit = screen.visibleFrame.maxY
            for candidate in windowDetector.windows(on: screen) {
                let frame = candidate.frame
                // Must be the highest surface so far, below the pet
                guard frame.maxY > level, frame.maxY <= y else { continue }
                // Pet must horizontally overlap the window top
                guard x + petWidth > frame.minX, x < frame.maxX else { continue }
                // Pet must fit between the window top and the top of the screen
                guard frame.maxY + petWidth <= topLimit else { continue }
                // And the top must be wide enough to stand on
                guard frame.width >= petWidth else { continue }

                level = frame.maxY
                surface = .window(candidate.id)
            }
        }

        return (level, surface)
    }

    // MARK: - Animation Playback

    private func playFallAnimation() {
        animationManager.playAnimation(AnimationID.fall.rawValue)
        startDynamicAnimationTimer()
    }

    func playLandingAnimation(hard: Bool) {
        let animID = hard ? AnimationID.fallHard : AnimationID.fallSoft
        animationManager.playAnimation(animID.rawValue)
    }

    func playAnimationWithTransitions(_ animationID: AnimationID) {
        animationManager.playAnimationOnce(animationID.rawValue) { [weak self] in
            self?.handleAnimationComplete()
        }
    }

    private func playSleepSequence(remaining: [AnimationID]) {
        guard case .sleeping = state else { return }

        if let first = remaining.first {
            let rest = Array(remaining.dropFirst())
            animationManager.playAnimationOnce(first.rawValue) { [weak self] in
                self?.playSleepSequence(remaining: rest)
            }
        } else {
            wakeUp()
        }
    }

    private func handleAnimationComplete() {
        guard !state.isDragging && !state.isFalling && !state.isSleeping
                && !state.isOnDock && !state.isOnWindow else { return }

        // Check if we just finished jumping - handle before the walking guard
        if state.isJumping && animationManager.currentAnimation?.name == "jump" {
            endJumping()
            return
        }

        guard case .walking = state else { return }  // Only handle for normal walking

        let currentName = animationManager.currentAnimation?.name ?? ""
        var nextID = animationManager.selectNextAnimation()

        // Special handling for walk - roll random behaviors
        // Each behavior has independent chance, checked in sequence
        if currentName == "walk" && nextID == AnimationID.walk.rawValue {
            let roll = Int.random(in: 1...100)
            if roll <= BehaviorConstants.pissChance {
                // 1-2: piss (2%)
                nextID = AnimationID.piss.rawValue
            } else if roll <= BehaviorConstants.pissChance + BehaviorConstants.eatChance {
                // 3-5: eat (3%)
                nextID = AnimationID.eat.rawValue
            } else if roll <= BehaviorConstants.pissChance + BehaviorConstants.eatChance + BehaviorConstants.runChance {
                // 6-20: run (15%)
                nextID = AnimationID.runBegin.rawValue
            }
        }

        // Special handling for run
        if currentName == "run" {
            if Int.random(in: 1...100) <= BehaviorConstants.jumpWhileRunningChance {
                nextID = AnimationID.jump.rawValue
            }
        }

        if let nextID = nextID {
            if nextID == AnimationID.jump.rawValue {
                startJumping()
            }
            animationManager.playAnimationOnce(nextID) { [weak self] in
                self?.handleAnimationComplete()
            }
        } else {
            playAnimationWithTransitions(.walk)
        }
    }

    // MARK: - Timers

    func startDynamicAnimationTimer() {
        animationTimer?.invalidate()
        scheduleNextAnimationFrame()
    }

    private func scheduleNextAnimationFrame() {
        guard !isPaused else { return }
        let interval = animationManager.getCurrentInterval()
        let newTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self = self, !self.isPaused else { return }
            let timerBefore = self.animationTimer
            self.animationManager.advanceFrame()
            if self.animationTimer === timerBefore {
                self.scheduleNextAnimationFrame()
            }
        }
        animationTimer = newTimer
    }

    private func startPhysicsTimer() {
        physicsTimer?.invalidate()
        physicsTimer = Timer.scheduledTimer(withTimeInterval: PhysicsConstants.frameInterval, repeats: true) { [weak self] timer in
            self?.updatePhysics(timer: timer)
        }
    }

    private func startMovementTimer() {
        movementTimer?.invalidate()
        movementTimer = Timer.scheduledTimer(withTimeInterval: PhysicsConstants.frameInterval, repeats: true) { [weak self] _ in
            self?.updateMovement()
        }
    }

    private func stopMovementTimer() {
        movementTimer?.invalidate()
        movementTimer = nil
    }

    private func startIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: BehaviorConstants.idleCheckInterval, repeats: true) { [weak self] _ in
            self?.checkIdle()
        }
    }

    private func stopIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    func stopAllTimers() {
        movementTimer?.invalidate()
        movementTimer = nil
        physicsTimer?.invalidate()
        physicsTimer = nil
        animationTimer?.invalidate()
        animationTimer = nil
        idleTimer?.invalidate()
        idleTimer = nil
    }

    // MARK: - Pause/Resume

    private func pause() {
        guard !isPaused else { return }
        isPaused = true
        stateBeforePause = state
        stopAllTimers()
        pauseChildWindows()
    }

    private func resume() {
        guard isPaused else { return }
        isPaused = false

        // Restore timers based on saved state
        guard let savedState = stateBeforePause else {
            startWalking()
            resumeChildWindows()
            return
        }

        switch savedState {
        case .falling:
            startPhysicsTimer()
            startDynamicAnimationTimer()
        case .walking:
            startDynamicAnimationTimer()
            startIdleTimer()
            startMovementTimer()
        case .walkingOnDock:
            startDynamicAnimationTimer()
            startIdleTimer()
            startDockMovementTimer()
        case .sleeping:
            startDynamicAnimationTimer()
        case .dragging:
            // Unlikely to pause while dragging, but handle it
            startDynamicAnimationTimer()
        case .jumping:
            startDynamicAnimationTimer()
            startMovementTimer()
        case .jumpingToDock:
            startDynamicAnimationTimer()
            startDockJumpTimer()
        case .jumpingToLedge:
            startDynamicAnimationTimer()
            startLedgeJumpTimer()
        case .climbingWindow:
            startDynamicAnimationTimer()
            startClimbTimer()
        case .walkingOnWindow:
            startDynamicAnimationTimer()
            startIdleTimer()
            startWindowTopMovementTimer()
        case .lookingDown:
            startDynamicAnimationTimer()
        case .jumpingOffDock:
            startDynamicAnimationTimer()
            startJumpOffMovementTimer()
        case .fallingFromDock:
            startDynamicAnimationTimer()
            startFallingFromDockTimer()
        }

        stateBeforePause = nil
        resumeChildWindows()
    }

    private func pauseChildWindows() {
        // Clean up nil refs first, then iterate
        cleanupChildWindowRefs()
        for ref in childWindowRefs {
            ref.value?.pause()
        }
    }

    private func resumeChildWindows() {
        // Clean up nil refs first, then iterate
        cleanupChildWindowRefs()
        for ref in childWindowRefs {
            ref.value?.resume()
        }
    }

    // MARK: - Physics Updates

    private func updatePhysics(timer: Timer) {
        guard let window = petWindow else { return }
        guard case .falling(var velocity, var bounceCount) = state else { return }

        velocity += PhysicsConstants.gravity
        var newY = window.frame.origin.y - velocity

        // Calculate ground level (may be a window top, dock top, or screen bottom)
        let (ground, surface) = groundInfo(
            at: window.frame.origin.x,
            petWidth: window.frame.width,
            below: window.frame.origin.y,
            includeWindows: landOnWindowsWhileFalling
        )

        if newY <= ground {
            newY = ground
            playLandingAnimation(hard: abs(velocity) > PhysicsConstants.hardLandingThreshold)

            velocity = -velocity * PhysicsConstants.bounceDamping
            bounceCount += 1

            if bounceCount > PhysicsConstants.maxBounces || abs(velocity) < PhysicsConstants.minBounceVelocity {
                timer.invalidate()
                physicsTimer = nil

                // Start appropriate walking based on where we landed
                switch surface {
                case .dock:
                    startWalkingOnDock()
                case .window(let id):
                    climbWindowID = id
                    startWalkingOnWindow()
                case .ground:
                    startWalking()
                }
                return
            }
        }

        state = .falling(velocity: velocity, bounceCount: bounceCount)
        window.setFrameOrigin(NSPoint(x: window.frame.origin.x, y: newY))
    }

    private func updateMovement() {
        guard let window = petWindow else { return }
        guard case .walking = state else { return }  // Only for ground walking
        guard let screen = currentScreen else { return }

        let petSize = window.frame.width
        let currentX = window.frame.origin.x
        let footY = window.frame.origin.y

        let moveX = abs(animationManager.getCurrentMoveX())  // Use absolute value

        var newX = currentX

        if isMovingRight {
            newX += moveX
        } else {
            newX -= moveX
        }

        // Refresh dock info for the screen the pet is on
        cachedDockInfo = dockDetector.getDockInfo(for: screen)

        // Check for dock collision (pet is on ground level)
        if let dockInfo = cachedDockInfo, dockInfo.position == .bottom {
            let petRight = newX + petSize
            let petLeft = newX
            let dockLeft = dockInfo.frame.minX
            let dockRight = dockInfo.frame.maxX

            // Pet is on ground (not on dock) - check if hitting dock edge
            if footY < dockInfo.frame.maxY {
                // Moving right and about to hit dock's left edge
                if isMovingRight && currentX + petSize <= dockLeft && petRight >= dockLeft {
                    newX = dockLeft - petSize  // Stop at dock edge
                    window.setFrameOrigin(NSPoint(x: newX, y: footY))
                    startJumpingToDock()
                    return
                }

                // Moving left and about to hit dock's right edge
                if !isMovingRight && currentX >= dockRight && petLeft <= dockRight {
                    newX = dockRight  // Stop at dock edge
                    window.setFrameOrigin(NSPoint(x: newX, y: footY))
                    startJumpingToDock()
                    return
                }
            }
        }

        // Check for a window side the pet feels like climbing
        if let climb = findClimbOpportunity(on: screen, currentX: currentX, newX: newX,
                                            footY: footY, petSize: petSize) {
            window.setFrameOrigin(NSPoint(x: climb.startX, y: footY))
            startClimbingWindow(climb.surface)
            return
        }

        // Screen edge: cross onto an adjacent display, or turn around
        let seamRight = screen.frame.maxX
        let seamLeft = screen.frame.minX

        if isMovingRight && newX + petSize > seamRight {
            if let next = walkableScreen(beyond: screen, movingRight: true, footY: footY) {
                if next.frame.minY > footY + 1 {
                    // The next display's ground is a ledge above us - hop up
                    window.setFrameOrigin(NSPoint(x: min(newX, seamRight - petSize), y: footY))
                    startJumpingToLedge(targetX: seamRight + petSize * 0.5, targetY: next.frame.minY)
                    return
                }
                // Same level or lower: keep walking across the seam
            } else {
                newX = seamRight - petSize
                isMovingRight = false
            }
        } else if !isMovingRight && newX < seamLeft {
            if let next = walkableScreen(beyond: screen, movingRight: false, footY: footY) {
                if next.frame.minY > footY + 1 {
                    window.setFrameOrigin(NSPoint(x: max(newX, seamLeft), y: footY))
                    startJumpingToLedge(targetX: seamLeft - petSize * 1.5, targetY: next.frame.minY)
                    return
                }
            } else {
                newX = seamLeft
                isMovingRight = true
            }
        }

        // Keep on the ground under the pet's midpoint; once it crosses a seam
        // above a lower display, the ground drops away and the pet falls
        if let support = screenContaining(x: newX + petSize / 2, below: footY) {
            if footY > support.frame.minY + 1 {
                window.setFrameOrigin(NSPoint(x: newX, y: footY))
                stopMovementTimer()
                stopIdleTimer()
                startFalling()
                return
            }
            window.setFrameOrigin(NSPoint(x: newX, y: support.frame.minY))
        } else {
            window.setFrameOrigin(NSPoint(x: newX, y: footY))
        }
    }

    private func checkIdle() {
        guard case .walking = state else { return }

        let idleTime = Date().timeIntervalSince(lastInteractionTime)
        if idleTime >= BehaviorConstants.idleTimeBeforeSleep {
            startSleeping()
        }
    }

    // MARK: - Interaction

    func recordInteraction() {
        lastInteractionTime = Date()
    }

    // MARK: - Child Windows

    private func spawnChildWindow(spawn: ChildSpawn) {
        guard let window = petWindow, let screen = currentScreen else { return }

        let parentPosition = window.frame.origin
        let parentSize = window.frame.width

        guard let childWindow = ChildPetWindow(
            animations: animationManager.animations,
            spriteRenderer: animationManager.spriteRenderer,
            spawn: spawn,
            parentPosition: parentPosition,
            parentSize: parentSize,
            isMovingRight: isMovingRight,
            screen: screen
        ) else { return }

        childWindow.orderFront(nil)
        childWindowRefs.append(Weak(childWindow))

        // Clean up nil references periodically (only if array is getting large)
        if childWindowRefs.count > 10 {
            cleanupChildWindowRefs()
        }
    }

    private func cleanupChildWindowRefs() {
        // Create new array with only valid references to avoid accessing deallocating objects
        var validRefs: [Weak<ChildPetWindow>] = []
        for ref in childWindowRefs {
            if ref.value != nil {
                validRefs.append(ref)
            }
        }
        childWindowRefs = validRefs
    }

    // MARK: - Window Management

    func positionWindowForFall() {
        guard let window = petWindow,
              let screen = NSScreen.screens.randomElement() ?? NSScreen.main else { return }

        let petSize = window.frame.width
        let minX = screen.visibleFrame.minX
        // max() keeps the range valid if the pet is wider than the visible screen
        let maxX = max(minX, screen.visibleFrame.maxX - petSize)
        let startX = CGFloat.random(in: minX...maxX)
        let startY = screen.frame.maxY

        window.setFrameOrigin(NSPoint(x: startX, y: startY))
    }

    func updateWindowPosition(to mouseLocation: NSPoint) {
        guard let window = petWindow else { return }
        guard case .dragging(let offset) = state else { return }

        let newX = mouseLocation.x - offset.x
        let newY = mouseLocation.y - offset.y
        window.setFrameOrigin(NSPoint(x: newX, y: newY))
    }
}
