//
//  PetViewModel.swift
//  electragne
//
//  Created by zacharyhamm on 2/4/26.
//

import Foundation
import SwiftUI
import AppKit
import os

// MARK: - Pet View Model

@Observable
class PetViewModel {
    // MARK: - State

    private(set) var state: PetState = .falling(velocity: 0, bounceCount: 0)
    var isMovingRight = true
    var lastInteractionTime = Date()

    // MARK: - Managers

    let animationManager = AnimationManager()
    private let environment: PetEnvironmentSensing
    private let surface: PetSurfaceMoving

    // MARK: - Dock State

    private var cachedDockInfo: DockInfo?

    // MARK: - Window Climbing State

    /// Sinks the pet window to a climbed window's z-depth.
    private let depth = WindowDepthController()

    /// The app window the pet is climbing or standing on
    private var climbWindowID: CGWindowID? {
        didSet {
            guard oldValue != climbWindowID else { return }
            if let id = climbWindowID {
                depth.enter(windowID: id)
            } else {
                depth.exit()
            }
        }
    }
    /// Whether the pet is climbing the window's left side (it climbs the left
    /// side when moving right, the right side when moving left)
    private var climbingOnLeftSide = true

    private var climbPhase: ClimbPolicy.Phase = .ascending

    /// Whether the current fall may land on window tops. Set when the pet is
    /// dropped from a drag; ordinary falls go all the way to the ground.
    private var landOnWindowsWhileFalling = false

    // MARK: - Child Windows

    private(set) var childWindowRefs: [Weak<ChildPetWindow>] = []

    // MARK: - Timers

    private let movement = TimerDriver()
    private let physics = TimerDriver()
    private let idle = TimerDriver()
    // The animation timer is non-repeating and self-rescheduling (it re-arms
    // itself with the next frame's interval), so it stays a raw Timer.
    private var animationTimer: Timer?

    // MARK: - Pause State

    private var isPaused = false
    private var stateBeforePause: PetState?

    // MARK: - Window Reference

    weak var petWindow: NSWindow? {
        didSet {
            depth.petWindow = petWindow
            (surface as? WindowSurfaceAdapter)?.window = petWindow
        }
    }

    // MARK: - Initialization

    init(environment: PetEnvironmentSensing? = nil, surface: PetSurfaceMoving? = nil) {
        let liveSurface = surface ?? WindowSurfaceAdapter()
        self.surface = liveSurface
        self.environment = environment ?? LiveEnvironment(surface: liveSurface)
        setupNotificationObservers()
    }

    private func setupNotificationObservers() {
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
        guard petWindow != nil else { return }
        let snapshot = environment.snapshot(includeWindows: false)
        guard !snapshot.screens.contains(where: { $0.frame.intersects(surface.frame) }) else { return }

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

    deinit {
        // Only thread-safe primitives here (deinit is non-isolated): the
        // TimerDriver/WindowDepthController instances invalidate their own
        // timers in their deinits, so only the raw animation timer and the
        // observers need explicit teardown.
        NotificationCenter.default.removeObserver(self)
        animationTimer?.invalidate()
    }

    func loadAnimations() {
        guard let url = Bundle.main.url(forResource: "animations", withExtension: "xml") else {
            Log.lifecycle.error("Failed to find animations.xml in bundle")
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

    // MARK: - Chat

    /// Stops the pet on its current surface and turns it toward the user.
    func beginChat() {
        guard let restingPlace = state.chatRestingPlace else { return }

        stopAllTimers()
        state = .chatting(restingPlace: restingPlace)
        recordInteraction()

        animationManager.playAnimationOnce(AnimationID.rotate1a.rawValue) { [weak self] in
            self?.freezeFrontFacingFrame()
        }
        startDynamicAnimationTimer()
    }

    /// Closes chat and returns the pet to motion on the surface it was using.
    func dismissChat() {
        guard case .chatting(let restingPlace) = state else { return }
        stopAllTimers()
        resumeAfterChat(from: restingPlace)
    }

    /// Where the pet stands when summoned: centered in the right third of the
    /// screen, on the ground. Pure so it can be unit tested.
    nonisolated static func summonOrigin(
        petSize: CGFloat,
        screenFrame: CGRect,
        visibleFrame: CGRect
    ) -> CGPoint {
        let thirdWidth = visibleFrame.width / 3
        let x = visibleFrame.maxX - thirdWidth + (thirdWidth - petSize) / 2
        return CGPoint(x: max(visibleFrame.minX, x), y: screenFrame.minY)
    }

    /// A summoned pet stays put if it's already somewhere it can chat from on
    /// the main screen (walking, sleeping, on the dock or a window top); it
    /// relocates when it's mid-motion (jumping, falling, climbing, …) or on
    /// any other screen. Pure so it can be unit tested.
    nonisolated static func shouldRelocateForSummon(
        state: PetState,
        petFrame: CGRect,
        mainScreenFrame: CGRect
    ) -> Bool {
        guard mainScreenFrame.intersects(petFrame) else { return true }
        return state.chatRestingPlace == nil && !state.isChatting
    }

    /// Opens chat where the pet stands, or teleports it to the right third of
    /// the primary screen first if needed (global-hotkey entry point).
    func summonToChat() {
        guard !isPaused,
              petWindow != nil,
              let screen = environment.snapshot(includeWindows: false).screens.first else { return }

        guard Self.shouldRelocateForSummon(
            state: state,
            petFrame: surface.frame,
            mainScreenFrame: screen.frame
        ) else {
            if !state.isChatting {
                beginChat()
            }
            return
        }

        stopAllTimers()
        climbWindowID = nil
        landOnWindowsWhileFalling = false

        let origin = Self.summonOrigin(
            petSize: surface.frame.width,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame
        )
        surface.setOrigin(origin)

        if state.isChatting {
            // Bubble is already open and follows the window move; the pet now
            // rests on the ground regardless of where chat started.
            state = .chatting(restingPlace: .ground)
            return
        }
        state = .walking
        beginChat()
    }

    private func freezeFrontFacingFrame() {
        guard state.isChatting else { return }
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func resumeAfterChat(from restingPlace: ChatRestingPlace) {
        switch restingPlace {
        case .ground:
            startWalking()

        case .dock:
            guard petWindow != nil, currentScreen != nil else {
                startFalling()
                return
            }
            cachedDockInfo = environment.snapshot(includeWindows: false).dockInfo
            guard let dockInfo = cachedDockInfo,
                  dockInfo.position == .bottom,
                  dockInfo.containsX(surface.frame.origin.x, petWidth: surface.frame.width) else {
                startFalling()
                return
            }
            surface.setOrigin(NSPoint(x: surface.frame.origin.x, y: dockInfo.frame.maxY))
            startWalkingOnDock()

        case .window:
            guard petWindow != nil,
                  let id = climbWindowID,
                  let hostFrame = windowFrame(id: id) else {
                startFalling()
                return
            }
            let clampedX = min(max(surface.frame.origin.x, hostFrame.minX),
                               hostFrame.maxX - surface.frame.width)
            surface.setOrigin(NSPoint(x: clampedX, y: hostFrame.maxY))
            startWalkingOnWindow()
        }
    }

    func startJumping() {
        // The basic jump is animation-driven (updateBasicJumpMovement reads the
        // jump sprite's own movement curve), so it needs no ballistic arc — only
        // a window and screen to move within.
        guard petWindow != nil, currentScreen != nil else { return }

        stopMovementTimer()
        stopIdleTimer()
        state = .jumping

        // Start animation timer to advance sprite frames
        startDynamicAnimationTimer()

        // Start jump physics timer
        startBasicJumpTimer()
    }

    private func startBasicJumpTimer() {
        movement.start { [weak self] in self?.updateBasicJumpMovement() }
    }

    private func updateBasicJumpMovement() {
        guard petWindow != nil,
              let screen = currentScreen else { return }
        let snapshot = environment.snapshot(includeWindows: false)
        guard let screenIndex = snapshot.screens.firstIndex(of: screen) else { return }
        applyJumpAction(JumpPolicy.evaluate(.init(
            env: snapshot,
            motion: .animation(moveX: scaledMoveX(), moveY: scaledMoveY(),
                               isMovingRight: isMovingRight, screenIndex: screenIndex)
        )))
    }

    func endJumping() {
        guard petWindow != nil else {
            state = .walking
            return
        }

        // Stop jump timer
        movement.stop()

        // Land at the ground of the screen under the pet (not the dock top:
        // the pet may legitimately end up at ground level within the dock's
        // x-range, as before)
        let landingScreen = screenContaining(
            x: surface.frame.midX,
            below: surface.frame.origin.y
        ) ?? currentScreen
        let ground = landingScreen?.frame.minY ?? surface.frame.origin.y

        // If the jump carried the pet across a seam onto a lower display,
        // let it fall the rest of the way
        if surface.frame.origin.y > ground + 4 {
            startFalling()
            return
        }

        surface.setOrigin(NSPoint(x: surface.frame.origin.x, y: ground))

        // Resume walking state and start movement timer
        state = .walking
        startMovementTimer()
    }

    // MARK: - Ledge Jump (onto a higher adjacent display)

    func startJumpingToLedge(targetX: CGFloat, targetY: CGFloat) {
        guard petWindow != nil else {
            startWalking()
            return
        }

        stopMovementTimer()
        stopIdleTimer()
        state = .jumpingToLedge

        // Linear X, parabolic arc for Y (same shape as the dock jump).
        activeJump = BallisticJump(
            start: surface.frame.origin,
            target: CGPoint(x: targetX, y: targetY),
            arc: .parabolic(height: 30),
            step: 0.05 * PhysicsConstants.tickScale,
            clampToTargetY: false
        )

        animationManager.playAnimation(AnimationID.jump.rawValue)
        startDynamicAnimationTimer()
        startLedgeJumpTimer()
    }

    private func startLedgeJumpTimer() {
        movement.start { [weak self] in self?.updateLedgeJumpMovement() }
    }

    private func updateLedgeJumpMovement() {
        guard petWindow != nil else { return }
        guard case .jumpingToLedge = state else { return }

        guard let activeJump else { return }
        let action = JumpPolicy.evaluate(.init(
            env: environment.snapshot(includeWindows: false), motion: .ballistic(activeJump)
        ))
        switch action {
        case .move(let point, let jump):
            self.activeJump = jump
            surface.setOrigin(point)
        case .complete(let target):
            self.activeJump = nil
            movement.stop()
            surface.setOrigin(target)
            startWalking()
        }
    }

    // MARK: - Window Climbing

    /// Check whether the pet's step from currentX to newX crosses the side of
    /// a climbable window. The window qualifies only if its top leaves room
    /// for the pet below the top of the screen, its top is above the pet's
    /// head (something to actually climb), and its side reaches down to the
    /// pet. Rolls the climb chance per crossing.
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
        movement.start { [weak self] in self?.updateClimbMovement() }
    }

    private func updateClimbMovement() {
        guard petWindow != nil else { return }
        guard case .climbingWindow = state else { return }
        guard let id = climbWindowID, let screen = currentScreen else {
            abortClimb()
            return
        }
        let action = ClimbPolicy.evaluate(.init(
            env: environment.snapshot(includeWindows: true),
            mode: .climb(windowID: id, screen: screen, onLeftSide: climbingOnLeftSide,
                         phase: climbPhase, moveY: scaledMoveY(),
                         tickScale: PhysicsConstants.tickScale)
        )) { Int.random(in: 1...$0) }
        switch action {
        case .move(let point):
            surface.setOrigin(point)
        case .beginTopOut(let point):
            climbPhase = .toppingOut
            surface.setOrigin(point)
            animationManager.playAnimationOnce(AnimationID.verticalWalkOver.rawValue) { [weak self] in
                self?.finishToppingOut()
            }
        case .abort:
            abortClimb()
        case .none, .begin:
            break
        }
    }

    private func finishToppingOut() {
        guard case .climbingWindow = state else { return }
        startWalkingOnWindow()
    }

    private func abortClimb() {
        movement.stop()
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
        movement.start { [weak self] in self?.updateWindowTopMovement() }
    }

    private func updateWindowTopMovement() {
        guard petWindow != nil else { return }
        guard case .walkingOnWindow = state else { return }
        guard let id = climbWindowID, let screen = currentScreen else { return }
        let action = WindowTopPolicy.evaluate(.init(
            env: environment.snapshot(includeWindows: true),
            windowID: id,
            screen: screen,
            moveX: scaledMoveX(),
            isMovingRight: isMovingRight
        ))
        switch action {
        case .move(let point):
            surface.setOrigin(point)
        case .lookDown(let point):
            surface.setOrigin(point)
            startLookingDown()
        case .jumpDown(let frame):
            stopIdleTimer()
            startJumpingDown(fromPlatform: frame)
        case .fall:
            stopMovementTimer()
            stopIdleTimer()
            startFalling()
        }
    }

    // MARK: - Dock State Transitions

    /// The in-flight progress-driven jump arc (dock / ledge / jump-off). The
    /// animation-driven basic jump does not use this. Preserved across pause
    /// so a paused-mid-jump pet resumes from its saved progress.
    private var activeJump: BallisticJump?

    func startJumpingToDock() {
        guard petWindow != nil,
              let dockInfo = cachedDockInfo else {
            startWalking()
            return
        }

        stopMovementTimer()
        stopIdleTimer()
        state = .jumpingToDock

        // Target X: move onto the dock a bit
        let petSize = surface.frame.width
        let targetX: CGFloat
        if isMovingRight {
            targetX = dockInfo.frame.minX + petSize  // Land just inside left edge
        } else {
            targetX = dockInfo.frame.maxX - petSize * 2  // Land just inside right edge
        }

        // Linear X, parabolic arc up onto the dock top.
        activeJump = BallisticJump(
            start: surface.frame.origin,
            target: CGPoint(x: targetX, y: dockInfo.frame.maxY),
            arc: .parabolic(height: 30),
            step: 0.05 * PhysicsConstants.tickScale,
            clampToTargetY: false
        )

        animationManager.playAnimation(AnimationID.jump.rawValue)
        startDynamicAnimationTimer()
        startDockJumpTimer()
    }

    private func startDockJumpTimer() {
        movement.start { [weak self] in self?.updateDockJumpMovement() }
    }

    private func updateDockJumpMovement() {
        guard petWindow != nil else { return }
        guard case .jumpingToDock = state else { return }

        guard let activeJump else { return }
        switch JumpPolicy.evaluate(.init(
            env: environment.snapshot(includeWindows: false), motion: .ballistic(activeJump)
        )) {
        case .move(let point, let jump):
            self.activeJump = jump
            surface.setOrigin(point)
        case .complete:
            self.activeJump = nil
            landOnDock()
        }
    }

    private func landOnDock() {
        guard petWindow != nil,
              let dockInfo = cachedDockInfo else {
            startWalking()
            return
        }

        movement.stop()

        // Ensure pet is exactly on dock top and within dock bounds
        var finalX = surface.frame.origin.x
        let petSize = surface.frame.width

        // Clamp X to dock bounds
        if finalX < dockInfo.frame.minX {
            finalX = dockInfo.frame.minX
        }
        if finalX + petSize > dockInfo.frame.maxX {
            finalX = dockInfo.frame.maxX - petSize
        }

        let finalY = dockInfo.frame.maxY
        surface.setOrigin(NSPoint(x: finalX, y: finalY))

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
        movement.start { [weak self] in self?.updateDockMovement() }
    }

    private func updateDockMovement() {
        guard petWindow != nil else { return }
        guard case .walkingOnDock = state else { return }
        var snapshot = environment.snapshot(includeWindows: false)
        // Preserve the detector result captured when the dock state began.
        snapshot.dockInfo = cachedDockInfo
        switch DockWalkPolicy.evaluate(.init(
            env: snapshot, moveX: scaledMoveX(), isMovingRight: isMovingRight
        )) {
        case .move(let point):
            surface.setOrigin(point)
        case .lookDown(let point):
            surface.setOrigin(point)
            startLookingDown()
        case .fall:
            startFalling()
        }
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
            guard let frame = windowFrame(id: id) else {
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
        guard petWindow != nil,
              let screen = currentScreen else {
            startWalking()
            return
        }

        climbWindowID = nil
        state = .jumpingOffDock

        // Target X: jump away from platform edge
        let petSize = surface.frame.width
        let jumpDistance: CGFloat = 50  // How far to jump horizontally
        let targetX: CGFloat
        if isMovingRight {
            // At right edge of platform, jump right
            targetX = min(platformFrame.maxX + jumpDistance, screen.frame.maxX - petSize)
        } else {
            // At left edge of platform, jump left
            targetX = max(platformFrame.minX - jumpDistance - petSize, screen.frame.minX)
        }

        // Quick rise then a long descent to ground; clamped so it never dips
        // below the ground while arcing.
        activeJump = BallisticJump(
            start: surface.frame.origin,
            target: CGPoint(x: targetX, y: screen.frame.minY),
            arc: .piecewise(height: 20, peak: 0.2),
            step: 0.033 * PhysicsConstants.tickScale,
            clampToTargetY: true
        )

        animationManager.playAnimation(AnimationID.jumpDown.rawValue)
        startDynamicAnimationTimer()
        startJumpOffMovementTimer()
    }

    private func startJumpOffMovementTimer() {
        movement.start { [weak self] in self?.updateJumpOffMovement() }
    }

    private func updateJumpOffMovement() {
        guard petWindow != nil else { return }
        guard case .jumpingOffDock = state else { return }

        guard let activeJump else { return }
        switch JumpPolicy.evaluate(.init(
            env: environment.snapshot(includeWindows: false), motion: .ballistic(activeJump)
        )) {
        case .move(let point, let jump):
            self.activeJump = jump
            surface.setOrigin(point)
        case .complete:
            finishJumpOffDock()
        }
    }

    private func applyJumpAction(_ action: JumpPolicy.Action) {
        guard case .move(let point, _) = action else { return }
        surface.setOrigin(point)
    }

    private func finishJumpOffDock() {
        guard petWindow != nil else { return }

        movement.stop()

        // Ensure pet is on the ground (the jump's target Y).
        let groundY = activeJump?.target.y ?? surface.frame.origin.y
        activeJump = nil
        surface.setOrigin(NSPoint(x: surface.frame.origin.x, y: groundY))

        // Play landing animation then resume walking
        animationManager.playAnimationOnce(AnimationID.jumpDown3.rawValue) { [weak self] in
            self?.startWalking()
        }
        startDynamicAnimationTimer()
    }

    // MARK: - Screen Helpers

    /// The screen the pet is currently on (by window midpoint). Falls back to
    /// horizontal containment for positions above/below any screen (e.g. while
    /// falling in from the top), then to the window's own screen.
    private var currentScreen: ScreenInfo? {
        let snapshot = environment.snapshot(includeWindows: false)
        guard petWindow != nil else { return snapshot.screens.first }
        let mid = NSPoint(x: snapshot.petFrame.midX, y: snapshot.petFrame.midY)
        if let screen = snapshot.screens.first(where: { $0.frame.contains(mid) }) { return screen }
        if let screen = screenContaining(x: mid.x, below: .greatestFiniteMagnitude) {
            return screen
        }
        return snapshot.screens.first
    }

    /// The screen spanning the given x whose bottom edge is at or below y.
    /// With displays stacked beyond a seam, prefers the highest ground that's
    /// still beneath the pet.
    private func screenContaining(x: CGFloat, below y: CGFloat) -> ScreenInfo? {
        let screens = environment.snapshot(includeWindows: false).screens
        guard let index = ScreenGeometry.screenContaining(x: x, below: y, in: screens.map(\.frame)) else {
            return nil
        }
        return screens[index]
    }

    /// A display the pet can walk onto across the given screen's left or right
    /// edge. The adjacent screen must touch that edge, be open at the pet's
    /// height, and have a ground that's reachable: at/below the pet's feet, or
    /// a jumpable ledge above them.
    private func walkableScreen(beyond screen: ScreenInfo, movingRight: Bool, footY: CGFloat) -> ScreenInfo? {
        let screens = environment.snapshot(includeWindows: false).screens
        guard let screenIndex = screens.firstIndex(of: screen),
              let index = ScreenGeometry.walkableScreen(
                beyond: screenIndex, movingRight: movingRight, footY: footY,
                maxStepUp: PhysicsConstants.maxScreenStepUp, in: screens.map(\.frame)) else {
            return nil
        }
        return screens[index]
    }

    private func windowFrame(id: CGWindowID) -> CGRect? {
        environment.snapshot(includeWindows: true).windowSurfaces
            .first(where: { $0.id == id })?.frame
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
        let snapshot = environment.snapshot(includeWindows: includeWindows)
        cachedDockInfo = snapshot.dockInfo

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
            for candidate in snapshot.windowSurfaces {
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
        physics.start { [weak self] in self?.updatePhysics() }
    }

    private func startMovementTimer() {
        movement.start { [weak self] in self?.updateMovement() }
    }

    private func stopMovementTimer() {
        movement.stop()
    }

    private func startIdleTimer() {
        idle.start(interval: BehaviorConstants.idleCheckInterval) { [weak self] in self?.checkIdle() }
    }

    private func stopIdleTimer() {
        idle.stop()
    }

    func stopAllTimers() {
        movement.stop()
        physics.stop()
        animationTimer?.invalidate()
        animationTimer = nil
        idle.stop()
    }

    // MARK: - Pause/Resume

    func pause() {
        guard !isPaused else { return }
        isPaused = true

        // Hiding the pet also closes chat. Save the corresponding resting
        // state so showing it again resumes normal behavior without briefly
        // reopening the bubble.
        if case .chatting(let restingPlace) = state {
            switch restingPlace {
            case .ground: state = .walking
            case .dock: state = .walkingOnDock
            case .window: state = .walkingOnWindow
            }
        }
        stateBeforePause = state
        stopAllTimers()
        pauseChildWindows()
    }

    func resume() {
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
        case .chatting:
            break
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

    // MARK: - Per-Tick Movement Deltas

    /// The animation's per-frame X movement, scaled to the current tick rate so
    /// the pet's wall-clock walking speed is independent of `frameInterval`.
    private func scaledMoveX() -> CGFloat {
        animationManager.getCurrentMoveX() * PhysicsConstants.tickScale
    }

    /// The animation's per-frame Y movement, scaled to the current tick rate.
    private func scaledMoveY() -> CGFloat {
        animationManager.getCurrentMoveY() * PhysicsConstants.tickScale
    }

    // MARK: - Physics Updates

    private func updatePhysics() {
        guard petWindow != nil else { return }
        guard case .falling(let velocity, let bounceCount) = state else { return }

        let action = FallPolicy.evaluate(.init(
            env: environment.snapshot(includeWindows: landOnWindowsWhileFalling),
            velocity: velocity,
            bounceCount: bounceCount,
            tickScale: PhysicsConstants.tickScale,
            landOnWindows: landOnWindowsWhileFalling
        ))

        switch action {
        case .move(let point, let velocity, let bounceCount, let landedHard):
            if let landedHard { playLandingAnimation(hard: landedHard) }
            state = .falling(velocity: velocity, bounceCount: bounceCount)
            surface.setOrigin(point)
        case .settle(let point, let groundSurface, let landedHard):
            playLandingAnimation(hard: landedHard)
            surface.setOrigin(point)
            physics.stop()
            switch groundSurface {
            case .dock:
                startWalkingOnDock()
            case .window(let id):
                climbWindowID = id
                startWalkingOnWindow()
            case .ground:
                startWalking()
            }
        }
    }

    private func updateMovement() {
        guard petWindow != nil else { return }
        guard case .walking = state else { return }  // Only for ground walking
        guard let screen = currentScreen else { return }
        let snapshot = environment.snapshot(includeWindows: true)
        guard let screenIndex = snapshot.screens.firstIndex(of: screen) else { return }
        cachedDockInfo = snapshot.dockInfo
        let action = WalkPolicy.evaluate(.init(
            env: snapshot, screenIndex: screenIndex, moveX: scaledMoveX(),
            isMovingRight: isMovingRight
        )) { Int.random(in: 1...$0) }
        switch action {
        case .move(let point), .crossSeam(let point, _):
            surface.setOrigin(point)
        case .turnAround(let point):
            surface.setOrigin(point)
            isMovingRight.toggle()
        case .beginClimb(let candidate, let point):
            surface.setOrigin(point)
            startClimbingWindow(candidate)
        case .beginLedgeJump(let point, let targetX, let targetY):
            surface.setOrigin(point)
            startJumpingToLedge(targetX: targetX, targetY: targetY)
        case .fallOffEdge(let point):
            surface.setOrigin(point)
            stopMovementTimer()
            stopIdleTimer()
            startFalling()
        case .beginDockApproach(let point):
            surface.setOrigin(point)
            startJumpingToDock()
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
        guard petWindow != nil, let screen = currentScreen else { return }

        let parentPosition = surface.frame.origin
        let parentSize = surface.frame.width

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
        guard petWindow != nil,
              let screen = environment.snapshot(includeWindows: false).screens.randomElement() else { return }

        let petSize = surface.frame.width
        let minX = screen.visibleFrame.minX
        // max() keeps the range valid if the pet is wider than the visible screen
        let maxX = max(minX, screen.visibleFrame.maxX - petSize)
        let startX = CGFloat.random(in: minX...maxX)
        let startY = screen.frame.maxY

        surface.setOrigin(NSPoint(x: startX, y: startY))
    }

    func updateWindowPosition(to mouseLocation: NSPoint) {
        guard petWindow != nil else { return }
        guard case .dragging(let offset) = state else { return }

        let newX = mouseLocation.x - offset.x
        let newY = mouseLocation.y - offset.y
        surface.setOrigin(NSPoint(x: newX, y: newY))
    }
}
