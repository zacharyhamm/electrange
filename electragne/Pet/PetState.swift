//
//  PetState.swift
//  electragne
//
//  Created by zacharyhamm on 2/4/26.
//

import Foundation

// MARK: - Pet State Machine

/// The surface to return to after the user closes the chat bubble.
nonisolated enum ChatRestingPlace: Equatable {
    case ground
    case dock
    case window
}

/// Represents the current state of the pet with associated data
nonisolated enum PetState: Equatable {
    case falling(velocity: CGFloat, bounceCount: Int)
    case walking
    case walkingOnDock           // Walking on the dock surface
    case sleeping(phase: Int)
    case dragging(mouseOffset: NSPoint)
    case jumping
    case jumpingToDock           // Jumping up onto the dock
    case jumpingToLedge          // Jumping up onto a higher adjacent display
    case climbingWindow          // Climbing up the side of an app window
    case walkingOnWindow         // Walking on top of an app window
    case lookingDown             // Peering over dock/window edge
    case jumpingOffDock          // Jumping down from dock or window top
    case chatting(restingPlace: ChatRestingPlace)

    var isFalling: Bool {
        if case .falling = self { return true }
        return false
    }

    var isWalking: Bool {
        if case .walking = self { return true }
        if case .walkingOnDock = self { return true }
        if case .walkingOnWindow = self { return true }
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

    var isChatting: Bool {
        if case .chatting = self { return true }
        return false
    }

    /// Chat opens only while the pet is resting on a stable surface.
    var canStartChat: Bool {
        chatRestingPlace != nil
    }

    var chatRestingPlace: ChatRestingPlace? {
        switch self {
        case .walking, .sleeping:
            return .ground
        case .walkingOnDock:
            return .dock
        case .walkingOnWindow:
            return .window
        default:
            return nil
        }
    }

    var isJumping: Bool {
        if case .jumping = self { return true }
        if case .jumpingToDock = self { return true }
        if case .jumpingToLedge = self { return true }
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

    var isOnWindow: Bool {
        switch self {
        case .climbingWindow, .walkingOnWindow:
            return true
        default:
            return false
        }
    }

    /// Returns true if the pet can be interacted with (dragged)
    var canInteract: Bool {
        switch self {
        case .falling, .walking, .walkingOnDock, .sleeping, .jumping, .climbingWindow, .walkingOnWindow:
            return true
        case .dragging, .jumpingToDock, .jumpingToLedge, .lookingDown, .jumpingOffDock, .chatting:
            return false
        }
    }
}

/// Chat is a presentation state rather than a resumable pet behavior. Hiding
/// the pet closes the bubble, so resume from the stable surface underneath it.
nonisolated func normalizedForPause(_ state: PetState) -> PetState {
    guard case .chatting(let restingPlace) = state else { return state }
    switch restingPlace {
    case .ground: return .walking
    case .dock: return .walkingOnDock
    case .window: return .walkingOnWindow
    }
}
