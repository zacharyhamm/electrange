import AppKit
import Foundation

nonisolated struct TimerNeeds: OptionSet, Equatable {
    let rawValue: Int

    static let movement = TimerNeeds(rawValue: 1 << 0)
    static let physics = TimerNeeds(rawValue: 1 << 1)
    static let animation = TimerNeeds(rawValue: 1 << 2)
    static let idle = TimerNeeds(rawValue: 1 << 3)
}

@MainActor struct PetContext {
    let surface: PetSurfaceMoving
    let environment: PetEnvironmentSensing
    let animator: AnimationManager
    let updateState: (PetState) -> Void
    unowned let coordinator: PetViewModel
}

@MainActor protocol PetBehavior: AnyObject {
    var timerNeeds: TimerNeeds { get }
    func begin(_ context: PetContext)
    func tick(_ context: PetContext)
    func idleFired(_ context: PetContext)
}

extension PetBehavior {
    func begin(_ context: PetContext) {}
    func tick(_ context: PetContext) {}
    func idleFired(_ context: PetContext) {}
}

@MainActor final class SleepingBehavior: PetBehavior {
    let timerNeeds: TimerNeeds = [.animation]

    func begin(_ context: PetContext) {
        context.coordinator.playSleepSequence(remaining: AnimationID.sleepSequence)
    }
}

@MainActor final class LookingDownBehavior: PetBehavior {
    let timerNeeds: TimerNeeds = [.animation]

    func begin(_ context: PetContext) {
        context.animator.playAnimationOnce(AnimationID.lookDown.rawValue) { [weak pet = context.coordinator] in
            pet?.handleLookDownComplete()
        }
    }
}

@MainActor final class DraggingBehavior: PetBehavior {
    let timerNeeds: TimerNeeds = [.animation]

    func begin(_ context: PetContext) {
        let pet = context.coordinator
        pet.climbWindowID = nil
        context.animator.playAnimation(AnimationID.drag.rawValue)
        pet.recordInteraction()
    }
}

@MainActor final class BasicJumpBehavior: PetBehavior {
    let timerNeeds: TimerNeeds = [.movement, .animation]

    func tick(_ context: PetContext) {
        let pet = context.coordinator
        guard pet.petWindow != nil, let screen = pet.currentScreen else { return }
        let snapshot = context.environment.snapshot(includeWindows: false)
        guard let screenIndex = snapshot.screens.firstIndex(of: screen) else { return }
        let action = JumpPolicy.evaluate(.init(
            env: snapshot,
            motion: .animation(
                moveX: pet.scaledMoveX(), moveY: pet.scaledMoveY(),
                isMovingRight: pet.isMovingRight, screenIndex: screenIndex
            )
        ))
        guard case .move(let point, _) = action else { return }
        context.surface.setOrigin(point)
    }
}

@MainActor final class BallisticJumpBehavior: PetBehavior {
    enum Destination {
        case dock
        case ledge
        case ground
    }

    let timerNeeds: TimerNeeds = [.movement, .animation]
    private let destination: Destination

    init(destination: Destination) {
        self.destination = destination
    }

    func begin(_ context: PetContext) {
        let animation: AnimationID = destination == .ground ? .jumpDown : .jump
        context.animator.playAnimation(animation.rawValue)
    }

    func tick(_ context: PetContext) {
        let pet = context.coordinator
        guard pet.petWindow != nil, let jump = pet.activeJump else { return }
        switch JumpPolicy.evaluate(.init(
            env: context.environment.snapshot(includeWindows: false), motion: .ballistic(jump)
        )) {
        case .move(let point, let nextJump):
            pet.activeJump = nextJump
            context.surface.setOrigin(point)
        case .complete(let target):
            pet.activeJump = nil
            switch destination {
            case .dock:
                pet.landOnDock()
            case .ledge:
                context.surface.setOrigin(target)
                pet.startWalking()
            case .ground:
                pet.finishJumpDown(at: target)
            }
        }
    }
}

@MainActor final class DockWalkBehavior: PetBehavior {
    let timerNeeds: TimerNeeds = [.movement, .animation, .idle]

    func begin(_ context: PetContext) {
        let pet = context.coordinator
        context.animator.playAnimationOnce(AnimationID.walkTask2.rawValue) { [weak pet] in
            pet?.handleDockAnimationComplete()
        }
        pet.recordInteraction()
    }

    func tick(_ context: PetContext) {
        let pet = context.coordinator
        guard pet.petWindow != nil else { return }
        var snapshot = context.environment.snapshot(includeWindows: false)
        snapshot.dockInfo = pet.cachedDockInfo
        switch DockWalkPolicy.evaluate(.init(
            env: snapshot, moveX: pet.scaledMoveX(), isMovingRight: pet.isMovingRight
        )) {
        case .move(let point):
            context.surface.setOrigin(point)
        case .lookDown(let point):
            context.surface.setOrigin(point)
            pet.startLookingDown()
        case .fall:
            pet.startFalling()
        }
    }
}

@MainActor final class WindowTopBehavior: PetBehavior {
    let timerNeeds: TimerNeeds = [.movement, .animation, .idle]

    func begin(_ context: PetContext) {
        context.animator.playAnimation(AnimationID.walk.rawValue)
        context.coordinator.recordInteraction()
    }

    func tick(_ context: PetContext) {
        let pet = context.coordinator
        guard pet.petWindow != nil, let id = pet.climbWindowID,
              let screen = pet.currentScreen else { return }
        switch WindowTopPolicy.evaluate(.init(
            env: context.environment.snapshot(includeWindows: true), windowID: id,
            screen: screen, moveX: pet.scaledMoveX(), isMovingRight: pet.isMovingRight
        )) {
        case .move(let point):
            context.surface.setOrigin(point)
        case .lookDown(let point):
            context.surface.setOrigin(point)
            pet.startLookingDown()
        case .jumpDown(let frame):
            pet.startJumpingDown(fromPlatform: frame)
        case .fall:
            pet.startFalling()
        }
    }
}

@MainActor final class ClimbBehavior: PetBehavior {
    let timerNeeds: TimerNeeds = [.movement, .animation]

    func begin(_ context: PetContext) {
        context.animator.playAnimation(AnimationID.verticalWalkUp.rawValue)
        context.coordinator.recordInteraction()
    }

    func tick(_ context: PetContext) {
        let pet = context.coordinator
        guard pet.petWindow != nil else { return }
        guard let id = pet.climbWindowID, let screen = pet.currentScreen else {
            pet.abortClimb()
            return
        }
        let action = ClimbPolicy.evaluate(.init(
            env: context.environment.snapshot(includeWindows: true),
            mode: .climb(
                windowID: id, screen: screen, onLeftSide: pet.climbingOnLeftSide,
                phase: pet.climbPhase, moveY: pet.scaledMoveY(),
                tickScale: PhysicsConstants.tickScale
            )
        )) { Int.random(in: 1...$0) }
        switch action {
        case .move(let point):
            context.surface.setOrigin(point)
        case .beginTopOut(let point):
            pet.climbPhase = .toppingOut
            context.surface.setOrigin(point)
            context.animator.playAnimationOnce(AnimationID.verticalWalkOver.rawValue) { [weak pet] in
                pet?.finishToppingOut()
            }
        case .abort:
            pet.abortClimb()
        case .none, .begin:
            break
        }
    }
}

@MainActor final class WalkingBehavior: PetBehavior {
    let timerNeeds: TimerNeeds = [.movement, .animation, .idle]

    func begin(_ context: PetContext) {
        let pet = context.coordinator
        pet.climbWindowID = nil
        pet.playAnimationWithTransitions(.walk)
        pet.recordInteraction()
    }

    func tick(_ context: PetContext) {
        let pet = context.coordinator
        guard pet.petWindow != nil, let screen = pet.currentScreen else { return }
        let snapshot = context.environment.snapshot(includeWindows: true)
        guard let screenIndex = snapshot.screens.firstIndex(of: screen) else { return }
        pet.cachedDockInfo = snapshot.dockInfo
        let action = WalkPolicy.evaluate(.init(
            env: snapshot, screenIndex: screenIndex, moveX: pet.scaledMoveX(),
            isMovingRight: pet.isMovingRight
        )) { Int.random(in: 1...$0) }
        switch action {
        case .move(let point), .crossSeam(let point, _):
            context.surface.setOrigin(point)
        case .turnAround(let point):
            context.surface.setOrigin(point)
            pet.isMovingRight.toggle()
        case .beginClimb(let candidate, let point):
            context.surface.setOrigin(point)
            pet.startClimbingWindow(candidate)
        case .beginLedgeJump(let point, let targetX, let targetY):
            context.surface.setOrigin(point)
            pet.startJumpingToLedge(targetX: targetX, targetY: targetY)
        case .fallOffEdge(let point):
            context.surface.setOrigin(point)
            pet.startFalling()
        case .beginDockApproach(let point):
            context.surface.setOrigin(point)
            pet.startJumpingToDock()
        }
    }

    func idleFired(_ context: PetContext) {
        let pet = context.coordinator
        if Date().timeIntervalSince(pet.lastInteractionTime) >= BehaviorConstants.idleTimeBeforeSleep {
            pet.startSleeping()
        }
    }
}

@MainActor final class FallingBehavior: PetBehavior {
    let timerNeeds: TimerNeeds = [.physics, .animation]

    func begin(_ context: PetContext) {
        context.coordinator.playFallAnimation()
    }

    func tick(_ context: PetContext) {
        let pet = context.coordinator
        guard pet.petWindow != nil,
              case .falling(let velocity, let bounceCount) = pet.state else { return }
        let snapshot = context.environment.snapshot(includeWindows: pet.landOnWindowsWhileFalling)
        pet.cachedDockInfo = snapshot.dockInfo
        switch FallPolicy.evaluate(.init(
            env: snapshot, velocity: velocity, bounceCount: bounceCount,
            tickScale: PhysicsConstants.tickScale,
            landOnWindows: pet.landOnWindowsWhileFalling
        )) {
        case .move(let point, let velocity, let bounceCount, let landedHard):
            if let landedHard { pet.playLandingAnimation(hard: landedHard) }
            context.updateState(.falling(velocity: velocity, bounceCount: bounceCount))
            context.surface.setOrigin(point)
        case .settle(let point, let groundSurface, let landedHard):
            pet.playLandingAnimation(hard: landedHard)
            context.surface.setOrigin(point)
            switch groundSurface {
            case .dock:
                pet.startWalkingOnDock()
            case .window(let id):
                pet.climbWindowID = id
                pet.startWalkingOnWindow()
            case .ground:
                pet.startWalking()
            }
        }
    }
}

@MainActor final class ChattingBehavior: PetBehavior {
    let timerNeeds: TimerNeeds = [.animation]
    private let restingPlace: ChatRestingPlace

    init(restingPlace: ChatRestingPlace) {
        self.restingPlace = restingPlace
    }

    func begin(_ context: PetContext) {
        let pet = context.coordinator
        pet.recordInteraction()
        context.animator.playAnimationOnce(AnimationID.rotate1a.rawValue) { [weak pet] in
            pet?.freezeFrontFacingFrame()
        }
    }
}
