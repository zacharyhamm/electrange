//
//  PetWindowPresentation.swift
//  electragne
//
//  Shared WindowServer policy for every piece of the pet UI.
//

import AppKit

@MainActor
enum PetWindowPresentation {
    /// `.canJoinAllApplications` is the cross-application overlay behavior.
    /// Unlike `.fullScreenAuxiliary`, it explicitly allows a floating window
    /// to accompany other apps in their fullscreen spaces.
    static let collectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .stationary,
        .canJoinAllApplications,
    ]

    /// Restore the complete policy rather than merging individual flags:
    /// SwiftUI may add mutually exclusive values such as `.fullScreenNone`.
    static func enforce(on window: NSWindow) {
        guard window.collectionBehavior != collectionBehavior else { return }
        window.collectionBehavior = collectionBehavior
    }

    /// SwiftUI's Window scene can rewrite collectionBehavior after the pet
    /// window has been configured. Observe the property itself so the repair
    /// does not depend on an unrelated window-update notification.
    static func observe(_ window: NSWindow) -> NSKeyValueObservation {
        window.observe(\.collectionBehavior, options: [.new]) { [weak window] _, _ in
            MainActor.assumeIsolated {
                guard let window else { return }
                enforce(on: window)
            }
        }
    }
}
