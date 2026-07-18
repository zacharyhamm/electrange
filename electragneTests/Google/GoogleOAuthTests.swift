import Foundation
import Testing
@testable import electragne

@MainActor
struct GoogleOAuthTests {
    @Test func storesOAuthClientCredentialsAndResolvesDefaultOrExplicitAccount() throws {
        let suite = try #require(UserDefaults(suiteName: "GoogleOAuthTests.\(UUID().uuidString)"))
        let accounts = [
            GoogleAccount(id: "one", email: "one@example.com", displayName: "One"),
            GoogleAccount(id: "two", email: "two@example.com", displayName: "Two"),
        ]
        suite.set(try JSONEncoder().encode(accounts), forKey: GoogleOAuthService.accountsKey)
        let service = GoogleOAuthService(defaults: suite, keychain: MemoryGoogleCredentialStore())

        service.clientID = "  client.apps.googleusercontent.com  "
        service.clientSecret = "  desktop-secret  "
        service.setDefaultAccount(id: "two")

        #expect(service.clientID == "client.apps.googleusercontent.com")
        #expect(service.clientSecret == "desktop-secret")
        #expect(try service.resolveAccount(id: nil).id == "two")
        #expect(try service.resolveAccount(id: "one").email == "one@example.com")
        #expect(throws: GoogleOAuthError.accountNotFound) {
            try service.resolveAccount(id: "missing")
        }
    }

    @Test func pathSegmentNeutralizesSeparatorsAndDotSegments() {
        #expect(GoogleAPITransport.pathSegment("work@example.com") == "work%40example.com")
        #expect(GoogleAPITransport.pathSegment("../../gmail/v1/users/me/messages")
            == "..%2F..%2Fgmail%2Fv1%2Fusers%2Fme%2Fmessages")
        #expect(GoogleAPITransport.pathSegment("..") == "%2E%2E")
        #expect(GoogleAPITransport.pathSegment("a?b#c") == "a%3Fb%23c")
    }

    @Test func requestsLeastPrivilegeGmailScopes() {
        #expect(Set(GoogleOAuthService.gmailScopes) == [
            "openid", "email", "profile",
            "https://www.googleapis.com/auth/gmail.readonly",
            "https://www.googleapis.com/auth/gmail.compose",
        ])
        #expect(!GoogleOAuthService.gmailScopes.contains("https://www.googleapis.com/auth/gmail.modify"))
        #expect(Set(GoogleOAuthService.calendarScopes) == [
            "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
            "https://www.googleapis.com/auth/calendar.events",
        ])
        #expect(GoogleOAuthService.requestedScopes == GoogleOAuthService.gmailScopes + GoogleOAuthService.calendarScopes)
    }
}

private final class MemoryGoogleCredentialStore: GoogleCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func save(_ data: Data, accountID: String) throws { lock.withLock { values[accountID] = data } }
    func load(accountID: String) throws -> Data? { lock.withLock { values[accountID] } }
    func delete(accountID: String) throws { lock.withLock { _ = values.removeValue(forKey: accountID) } }
}
