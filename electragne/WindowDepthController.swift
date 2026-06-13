//
//  WindowDepthController.swift
//  electragne
//
//  Owns the pet window's z-depth while it climbs / stands on another app's
//  window. Extracted from PetViewModel: order(_:relativeTo:) accepts other
//  apps' window numbers but the relationship isn't persistent, so it has to be
//  re-asserted — if the host window is raised the pet must come forward with it.
//
//  The host comes forward almost exclusively when its app is activated, so we
//  re-assert on the activation notification (no lag on the common case) and keep
//  only a slow safety tick for same-app window raises that don't post one. This
//  replaces a 60Hz timer that hammered the window server every frame.
//

import AppKit

final class WindowDepthController {
    /// Kept in sync by PetViewModel (the pet window is assigned after launch).
    weak var petWindow: NSWindow?

    private var targetWindowID: CGWindowID?
    private let zOrder = TimerDriver()
    private var activationObserver: NSObjectProtocol?

    /// Safety re-assert interval (~4Hz). Imperceptible versus the old 60Hz, at a
    /// tiny fraction of the window-server traffic.
    private static let safetyReassertInterval: TimeInterval = 0.25

    /// Sink the pet window to `windowID`'s depth and keep it there.
    func enter(windowID: CGWindowID) {
        targetWindowID = windowID
        guard let window = petWindow else { return }
        window.level = .normal
        window.order(.above, relativeTo: Int(windowID))

        // Re-assert the instant another app comes forward — the exact moment the
        // host window can rise above the pet, so there's no visible lag.
        if activationObserver == nil {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.reassert()
            }
        }

        // Catch host raises that don't post an activation (e.g. another window
        // of the same app being raised over the host).
        zOrder.start(interval: Self.safetyReassertInterval) { [weak self] in
            self?.reassert()
        }
    }

    /// Float the pet back above everything else.
    func exit() {
        zOrder.stop()
        removeActivationObserver()
        targetWindowID = nil
        guard let window = petWindow else { return }
        window.level = .floating
        // Don't orderFront a pet hidden via the menu bar.
        if window.isVisible {
            window.orderFront(nil)
        }
    }

    /// Put the pet back above the target window. The isVisible guard matters:
    /// ordering relative to another window puts an ordered-out (hidden) window
    /// back on screen, which would un-hide a pet hidden via the menu bar.
    private func reassert() {
        guard let id = targetWindowID,
              let window = petWindow, window.isVisible else { return }
        window.order(.above, relativeTo: Int(id))
    }

    private func removeActivationObserver() {
        if let observer = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            activationObserver = nil
        }
    }

    deinit {
        if let observer = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}
