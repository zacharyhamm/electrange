import Foundation
import Testing
@testable import electragne

struct SOCKSProxyTests {
    @Test func parseAcceptsHostPort() {
        let parsed = SOCKSProxy.parse("127.0.0.1:1055")
        #expect(parsed?.host == "127.0.0.1")
        #expect(parsed?.port == 1055)
    }

    @Test func parseRejectsMalformedEndpoints() {
        #expect(SOCKSProxy.parse("") == nil)
        #expect(SOCKSProxy.parse("no-port") == nil)
        #expect(SOCKSProxy.parse(":1055") == nil)
        #expect(SOCKSProxy.parse("host:notaport") == nil)
    }

    @Test func unproxiedSessionIsShared() {
        #expect(SOCKSProxy.urlSession(proxied: false) === URLSession.shared)
    }

    @Test func proxiedSessionIsCachedAndRebuiltOnEndpointChange() {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: UserPreferences.socksProxyEndpointKey)
        defer { defaults.set(saved, forKey: UserPreferences.socksProxyEndpointKey) }

        defaults.set("127.0.0.1:1055", forKey: UserPreferences.socksProxyEndpointKey)
        let first = SOCKSProxy.urlSession(proxied: true)
        #expect(SOCKSProxy.urlSession(proxied: true) === first)
        #expect(first !== URLSession.shared)

        defaults.set("127.0.0.1:2055", forKey: UserPreferences.socksProxyEndpointKey)
        #expect(SOCKSProxy.urlSession(proxied: true) !== first)
    }
}
