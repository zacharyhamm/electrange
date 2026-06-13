//
//  TimerDriver.swift
//  electragne
//
//  Owns at most one repeating Timer. Starting again invalidates the previous
//  one, so it replaces the copy-pasted "invalidate-then-schedule" boilerplate
//  that the movement / physics / idle timers all used.
//

import Foundation

final class TimerDriver {
    private var timer: Timer?

    /// (Re)start the repeating timer. Any previously running timer is invalidated.
    func start(interval: TimeInterval = PhysicsConstants.frameInterval, _ tick: @escaping () -> Void) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in tick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    var isRunning: Bool { timer != nil }

    deinit { timer?.invalidate() }
}
