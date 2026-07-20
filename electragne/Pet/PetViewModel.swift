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
    let environment: PetEnvironmentSensing
    let surface: PetSurfaceMoving

    // MARK: - Dock State

    var cachedDockInfo: DockInfo?

    // MARK: - Window Climbing State

    /// Sinks the pet window to a climbed window's z-depth.
    private let depth = WindowDepthController()

    /// The app window the pet is climbing or standing on
    var climbWindowID: CGWindowID? {
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
    var climbingOnLeftSide = true

    var climbPhase: ClimbPolicy.Phase = .ascending

    /// Whether the current fall may land on window tops. Set when the pet is
    /// dropped from a drag; ordinary falls go all the way to the ground.
    var landOnWindowsWhileFalling = false

    // MARK: - Child Windows

    private(set) var childWindowRefs: [Weak<ChildPetWindow>] = []

    // MARK: - Timers

    private let movement = TimerDriver()
    private let idle = TimerDriver()
    // The animation timer is non-repeating and self-rescheduling (it re-arms
    // itself with the next frame's interval), so it stays a raw Timer.
    private var animationTimer: Timer?

    private var currentBehavior: PetBehavior?

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
        self.currentBehavior = nil
        setupNotificationObservers()
    }

    private var context: PetContext {
        PetContext(
            surface: surface,
            environment: environment,
            animator: animationManager,
            updateState: { [weak self] state in self?.state = state },
            coordinator: self
        )
    }

    /// The only state-to-controller mapping in the pet core.
    private func behavior(for state: PetState) -> PetBehavior {
        switch state {
        case .falling: FallingBehavior()
        case .walking: WalkingBehavior()
        case .walkingOnDock: DockWalkBehavior()
        case .sleeping: SleepingBehavior()
        case .dragging: DraggingBehavior()
        case .jumping: BasicJumpBehavior()
        case .jumpingToDock: BallisticJumpBehavior(destination: .dock)
        case .jumpingToLedge: BallisticJumpBehavior(destination: .ledge)
        case .climbingWindow: ClimbBehavior()
        case .walkingOnWindow: WindowTopBehavior()
        case .lookingDown: LookingDownBehavior()
        case .jumpingOffDock: BallisticJumpBehavior(destination: .ground)
        case .chatting(let restingPlace): ChattingBehavior(restingPlace: restingPlace)
        }
    }

    func enter(_ state: PetState) {
        stopAllTimers()
        self.state = state
        let next = behavior(for: state)
        currentBehavior = next
        next.begin(context)
        applyTimers(next.timerNeeds)
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
        enter(.falling(velocity: 0, bounceCount: 0))
    }

    func startWalking() {
        enter(.walking)
    }

    func startDragging(mouseOffset: NSPoint) {
        enter(.dragging(mouseOffset: mouseOffset))
    }

    func endDragging() {
        guard state.isDragging else { return }
        // A dropped pet may land on the first window top it falls onto
        landOnWindowsWhileFalling = true
        recordInteraction()
        enter(.falling(velocity: 0, bounceCount: 0))
    }

    func startSleeping() {
        guard case .walking = state else { return }

        enter(.sleeping(phase: 0))
    }

    func wakeUp() {
        guard case .sleeping = state else { return }
        startWalking()
    }

    // MARK: - Chat

    /// Stops the pet on its current surface and turns it toward the user.
    func beginChat() {
        guard let restingPlace = state.chatRestingPlace else { return }

        enter(.chatting(restingPlace: restingPlace))
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

    func freezeFrontFacingFrame() {
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

        enter(.jumping)
    }

    func endJumping() {
        guard petWindow != nil else {
            startWalking()
            return
        }

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

        startWalking()
    }

    // MARK: - Ledge Jump (onto a higher adjacent display)

    func startJumpingToLedge(targetX: CGFloat, targetY: CGFloat) {
        guard petWindow != nil else {
            startWalking()
            return
        }

        // Linear X, parabolic arc for Y (same shape as the dock jump).
        activeJump = BallisticJump(
            start: surface.frame.origin,
            target: CGPoint(x: targetX, y: targetY),
            arc: .parabolic(height: 30),
            step: 0.05 * PhysicsConstants.tickScale,
            clampToTargetY: false
        )

        enter(.jumpingToLedge)
    }

    // MARK: - Window Climbing

    /// Begins climbing the given window's near side (ClimbPolicy decides
    /// whether a step qualifies).
    func startClimbingWindow(_ surface: WindowSurface) {
        climbWindowID = surface.id
        climbingOnLeftSide = isMovingRight
        climbPhase = .ascending
        enter(.climbingWindow)
    }

    func finishToppingOut() {
        guard case .climbingWindow = state else { return }
        startWalkingOnWindow()
    }

    func abortClimb() {
        startFalling()
    }

    func startWalkingOnWindow() {
        enter(.walkingOnWindow)
    }

    // MARK: - Dock State Transitions

    /// The in-flight progress-driven jump arc (dock / ledge / jump-off). The
    /// animation-driven basic jump does not use this. Preserved across pause
    /// so a paused-mid-jump pet resumes from its saved progress.
    var activeJump: BallisticJump?

    func startJumpingToDock() {
        guard petWindow != nil,
              let dockInfo = cachedDockInfo else {
            startWalking()
            return
        }

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

        enter(.jumpingToDock)
    }

    func landOnDock() {
        guard petWindow != nil,
              let dockInfo = cachedDockInfo else {
            startWalking()
            return
        }

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
        enter(.walkingOnDock)
    }

    func handleDockAnimationComplete() {
        guard case .walkingOnDock = state else { return }

        // Continue walking on dock
        animationManager.playAnimationOnce(AnimationID.walkTask2.rawValue) { [weak self] in
            self?.handleDockAnimationComplete()
        }
    }

    func startLookingDown() {
        enter(.lookingDown)
    }

    func handleLookDownComplete() {
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

        enter(.jumpingOffDock)
    }

    func finishJumpDown(at target: CGPoint) {
        guard petWindow != nil else { return }
        surface.setOrigin(target)
        // Play landing animation then resume walking
        animationManager.playAnimationOnce(AnimationID.jumpDown3.rawValue) { [weak self] in
            self?.startWalking()
        }
    }

    // MARK: - Screen Helpers

    /// The screen the pet is currently on (by window midpoint). Falls back to
    /// horizontal containment for positions above/below any screen (e.g. while
    /// falling in from the top), then to the window's own screen.
    var currentScreen: ScreenInfo? {
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

    func windowFrame(id: CGWindowID) -> CGRect? {
        environment.snapshot(includeWindows: true).windowSurfaces
            .first(where: { $0.id == id })?.frame
    }

    // MARK: - Animation Playback

    func playFallAnimation() {
        animationManager.playAnimation(AnimationID.fall.rawValue)
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

    func playSleepSequence(remaining: [AnimationID]) {
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
        let nextID = IdleBehaviorPolicy.evaluate(.init(
            currentAnimationName: currentName,
            proposedNextAnimationID: animationManager.selectNextAnimation()
        )) { Int.random(in: 1...$0) }

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

    private func applyTimers(_ needs: TimerNeeds) {
        if needs.contains(.movement) {
            movement.start { [weak self] in
                guard let self, let behavior = self.currentBehavior else { return }
                behavior.tick(self.context)
            }
        }
        if needs.contains(.animation) {
            startDynamicAnimationTimer()
        }
        if needs.contains(.idle) {
            idle.start(interval: BehaviorConstants.idleCheckInterval) { [weak self] in
                guard let self, let behavior = self.currentBehavior else { return }
                behavior.idleFired(self.context)
            }
        }
    }

    func stopAllTimers() {
        movement.stop()
        animationTimer?.invalidate()
        animationTimer = nil
        idle.stop()
    }

    // MARK: - Pause/Resume

    func pause() {
        guard !isPaused else { return }
        isPaused = true

        // Hiding the pet also closes chat. Resume the stable surface behavior
        // beneath the presentation-only chatting state.
        state = normalizedForPause(state)
        stateBeforePause = state
        stopAllTimers()
        pauseChildWindows()
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false

        guard let savedState = stateBeforePause else {
            startWalking()
            resumeChildWindows()
            return
        }
        state = savedState
        let resumed = behavior(for: savedState)
        currentBehavior = resumed
        resumed.begin(context)
        applyTimers(resumed.timerNeeds)
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
    func scaledMoveX() -> CGFloat {
        animationManager.getCurrentMoveX() * PhysicsConstants.tickScale
    }

    /// The animation's per-frame Y movement, scaled to the current tick rate.
    func scaledMoveY() -> CGFloat {
        animationManager.getCurrentMoveY() * PhysicsConstants.tickScale
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
        childWindowRefs.removeAll { $0.value == nil }
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
