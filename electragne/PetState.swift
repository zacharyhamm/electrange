//
//  PetState.swift
//  electragne
//
//  Created by zacharyhamm on 2/4/26.
//

import Foundation

// MARK: - Notifications

extension Notification.Name {
    static let petShouldPause = Notification.Name("petShouldPause")
    static let petShouldResume = Notification.Name("petShouldResume")
}

// MARK: - Weak Reference Wrapper

/// Weak reference wrapper to avoid retaining objects like child windows
struct Weak<T: AnyObject> {
    weak var value: T?
    init(_ value: T) {
        self.value = value
    }
}

// MARK: - Pet State Machine

/// Represents the current state of the pet with associated data
enum PetState: Equatable {
    case falling(velocity: CGFloat, bounceCount: Int)
    case walking
    case walkingOnDock           // Walking on the dock surface
    case sleeping(phase: Int)
    case dragging(mouseOffset: NSPoint)
    case jumping
    case jumpingToDock           // Jumping up onto the dock
    case lookingDown             // Peering over dock edge
    case jumpingOffDock          // Jumping down from dock
    case fallingFromDock         // Falling after jumping off dock

    var isFalling: Bool {
        if case .falling = self { return true }
        if case .fallingFromDock = self { return true }
        return false
    }

    var isWalking: Bool {
        if case .walking = self { return true }
        if case .walkingOnDock = self { return true }
        return false
    }

    var isSleeping: Bool {
        if case .sleeping = self { return true }
        return false
    }

    var isDragging: Bool {
        if case .dragging = self { return true }
        return false
    }

    var isJumping: Bool {
        if case .jumping = self { return true }
        if case .jumpingToDock = self { return true }
        if case .jumpingOffDock = self { return true }
        return false
    }

    var isOnDock: Bool {
        switch self {
        case .walkingOnDock, .lookingDown:
            return true
        default:
            return false
        }
    }

    /// Returns true if the pet can be interacted with (dragged)
    var canInteract: Bool {
        switch self {
        case .falling, .walking, .walkingOnDock, .sleeping, .jumping:
            return true
        case .dragging, .jumpingToDock, .lookingDown, .jumpingOffDock, .fallingFromDock:
            return false
        }
    }
}

// MARK: - Animation IDs

/// Type-safe animation identifiers to replace magic strings
enum AnimationID: String {
    // Basic movements
    case walk = "1"
    case rotate1a = "2"
    case rotate1b = "3"
    case drag = "4"
    case fall = "5"

    // Landing
    case fallSoft = "9"
    case fallHard = "10"

    // Behaviors
    case piss = "11"
    case pissEnd = "12"

    // Sleep sequence
    case sleep1 = "15"
    case sleep2 = "16"
    case sleep3 = "17"
    case sleep4 = "18"
    case sleep5 = "19"
    case sleep6 = "20"

    // Actions
    case jump = "25"
    case eat = "26"
    case flower = "27"

    // Running
    case runBegin = "35"

    // Dock animations
    case lookDown = "43"
    case jumpDown = "44"
    case jumpDown2 = "45"
    case jumpDown3 = "46"
    case walkTask2 = "50"

    /// Sleep animation sequence in order
    static let sleepSequence: [AnimationID] = [.sleep1, .sleep2, .sleep3, .sleep4, .sleep5, .sleep6]
}

// MARK: - Physics Constants

/// Centralized physics constants
enum PhysicsConstants {
    static let gravity: CGFloat = 0.8
    static let bounceDamping: CGFloat = 0.6
    static let maxBounces: Int = 3
    static let minBounceVelocity: CGFloat = 2.0
    static let hardLandingThreshold: CGFloat = 15.0
    static let frameInterval: TimeInterval = 0.016  // ~60fps
}

// MARK: - Behavior Constants

/// Centralized behavior constants
enum BehaviorConstants {
    static let idleTimeBeforeSleep: TimeInterval = 60.0
    static let idleCheckInterval: TimeInterval = 5.0
    static let childWindowFadeDelay: TimeInterval = 5.0
    static let childWindowFadeDuration: TimeInterval = 1.0

    // Random behavior chances (independent percentages, not cumulative)
    static let pissChance: Int = 2      // 2% chance
    static let eatChance: Int = 3       // 3% chance
    static let runChance: Int = 20 // 20% chance
    static let jumpWhileRunningChance: Int = 60  // 60% chance while running (we like the jumping!)
}

/// Pet window size constants
enum PetSizeConstants {
    static let defaultSize: Double = 40
    static let minimumSize: Double = 20
    static let maximumSize: Double = 200
    static let sizeStep: Double = 10
}
