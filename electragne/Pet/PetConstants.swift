//
//  PetConstants.swift
//  electragne
//
//  Physics, behavior, and sizing constants for the pet.
//

import Foundation

// MARK: - Physics Constants

/// Centralized physics constants
enum PhysicsConstants {
    static let gravity: CGFloat = 0.8
    static let bounceDamping: CGFloat = 0.6
    static let maxBounces: Int = 3
    static let minBounceVelocity: CGFloat = 2.0
    static let hardLandingThreshold: CGFloat = 15.0

    /// The tick rate the per-frame physics/movement deltas were originally
    /// tuned at. Frozen — it's the baseline `tickScale` divides by, not a
    /// live knob.
    static let referenceInterval: TimeInterval = 0.016  // ~60fps
    /// Live movement/physics tick interval. Currently matches `referenceInterval`
    /// (so `tickScale` == 1.0), running movement/physics at the full 60fps the
    /// deltas were tuned at — smoother motion at the cost of more `setFrameOrigin`
    /// window-server round trips. Raise this to trade smoothness for fewer round
    /// trips; `tickScale` then keeps wall-clock speed/arcs/bounce identical.
    static let frameInterval: TimeInterval = 0.016  // ~60fps

    /// Multiplier applied to every per-tick delta (movement, gravity, jump arc
    /// step) so that lowering the tick rate doesn't change the pet's perceived
    /// speed. Equals 1.0 when `frameInterval == referenceInterval`.
    static let tickScale: CGFloat = CGFloat(frameInterval / referenceInterval)

    // Tallest ledge the pet will jump up when an adjacent display's bottom
    // edge sits above the one it's walking on; bigger gaps act like a wall
    static let maxScreenStepUp: CGFloat = 250.0
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
    static let jumpWhileRunningChance: Int = 30  // 30% chance while running (we like the jumping!)
    static let climbChance: Int = 25    // 25% chance to climb a window the pet bumps into
}

/// Pet window size constants
enum PetSizeConstants {
    static let storageKey = "petSize"
    static let defaultSize: Double = 40
    static let minimumSize: Double = 20
    static let maximumSize: Double = 200
    static let sizeStep: Double = 10
}
