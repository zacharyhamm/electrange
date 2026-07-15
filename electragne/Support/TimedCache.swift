//
//  TimedCache.swift
//  electragne
//
//  A single-slot, time-expiring cache shared by DockDetector and WindowDetector
//  so the 60Hz movement/physics timers don't hit CGWindowListCopyWindowInfo (an
//  expensive syscall) on every tick. The owner supplies the current time (e.g.
//  ProcessInfo.processInfo.systemUptime) so the type stays pure and testable
//  with an injected clock.
//

import Foundation

struct TimedCache<Key: Equatable, Value> {
    let lifetime: TimeInterval
    private var key: Key?
    private var value: Value?
    private var timestamp: TimeInterval = 0

    init(lifetime: TimeInterval) {
        self.lifetime = lifetime
    }

    /// The stored value if `key` matches the last stored key and it hasn't
    /// expired as of `now`; otherwise nil. Note `Value` may itself be optional
    /// (e.g. a cached "no dock here" result), in which case a hit returns
    /// `.some(nil)` and a miss returns `nil`.
    func cached(for key: Key, now: TimeInterval) -> Value? {
        guard let storedKey = self.key, storedKey == key, now - timestamp < lifetime else {
            return nil
        }
        return value
    }

    /// Store a freshly computed value for `key` as of `now`.
    mutating func store(_ value: Value, for key: Key, now: TimeInterval) {
        self.value = value
        self.key = key
        self.timestamp = now
    }
}
