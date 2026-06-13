//
//  TimedCacheTests.swift
//  electragneTests
//

import Testing
@testable import electragne

struct TimedCacheTests {
    @Test func missBeforeAnythingStored() {
        let cache = TimedCache<String, Int>(lifetime: 1.0)
        #expect(cache.cached(for: "k", now: 0) == nil)
    }

    @Test func hitWithinLifetime() {
        var cache = TimedCache<String, Int>(lifetime: 1.0)
        cache.store(5, for: "k", now: 0)
        #expect(cache.cached(for: "k", now: 0.5) == 5)
    }

    @Test func expiresAfterLifetime() {
        var cache = TimedCache<String, Int>(lifetime: 1.0)
        cache.store(5, for: "k", now: 0)
        #expect(cache.cached(for: "k", now: 1.0) == nil)   // strict `< lifetime`
        #expect(cache.cached(for: "k", now: 0.999) == 5)
    }

    @Test func keyMismatchMisses() {
        var cache = TimedCache<String, Int>(lifetime: 1.0)
        cache.store(5, for: "k", now: 0)
        #expect(cache.cached(for: "other", now: 0.1) == nil)
    }

    @Test func cachesNilValueAsAHit() {
        // Value is itself optional (e.g. a cached "no dock here" result): a hit
        // returns the stored nil rather than recomputing.
        var cache = TimedCache<String, Int?>(lifetime: 1.0)
        cache.store(nil, for: "k", now: 0)
        if let cachedValue = cache.cached(for: "k", now: 0.5) {
            #expect(cachedValue == nil)
        } else {
            Issue.record("expected a cache hit storing nil")
        }
    }
}
