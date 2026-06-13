//
//  WindowDepthController.swift
//  electragne
//
//  Owns the pet window's z-depth while it climbs / stands on another app's
//  window. Extracted from PetViewModel: order(_:relativeTo:) accepts other
//  apps' window numbers but the relationship isn't persistent, so it's
//  re-asserted every frame — if the host window is raised the pet comes
//  forward with it without lag.
//

import AppKit

final class WindowDepthController {
    /// Kept in sync by PetViewModel (the pet window is assigned after launch).
    weak var petWindow: NSWindow?

    private var targetWindowID: CGWindowID?
    private let zOrder = TimerDriver()

    /// Sink the pet window to `windowID`'s depth and re-assert it every frame.
    func enter(windowID: CGWindowID) {
        targetWindowID = windowID
        guard let window = petWindow else { return }
        window.level = .normal
        window.order(.above, relativeTo: Int(windowID))

        zOrder.start { [weak self] in
            // The isVisible guard matters: ordering relative to another window
            // puts an ordered-out (hidden) window back on screen.
            guard let self, let id = self.targetWindowID,
                  let window = self.petWindow, window.isVisible else { return }
            window.order(.above, relativeTo: Int(id))
        }
    }

    /// Float the pet back above everything else.
    func exit() {
        zOrder.stop()
        targetWindowID = nil
        guard let window = petWindow else { return }
        window.level = .floating
        // Don't orderFront a pet hidden via the menu bar.
        if window.isVisible {
            window.orderFront(nil)
        }
    }
}
