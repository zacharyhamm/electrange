import Foundation
import MCP
import Testing
@testable import electragne

// MARK: - Catalog

struct MCPToolCatalogTests {
    @Test func namespacedNameSanitizesAndTruncates() {
        #expect(MCPToolCatalog.namespacedName(server: "My Server!", tool: "run") == "mcp__my_server___run")
        #expect(MCPToolCatalog.namespacedName(server: "docs", tool: "repo/search") == "mcp__docs__repo_search")
        #expect(MCPToolCatalog.namespacedName(server: "docs", tool: "get info") == "mcp__docs__get_info")
        #expect(MCPToolCatalog.namespacePrefix(server: "My-Server") == MCPToolCatalog.namespacePrefix(server: "my server"))
        let long = MCPToolCatalog.namespacedName(
            server: "server",
            tool: String(repeating: "x", count: 100)
        )
        #expect(long.count == 64)
        #expect(long.hasPrefix("mcp__server__xxx"))
    }

    @Test func descriptorRoundTripsThroughTheCatalog() {
        let serverID = UUID()
        defer { MCPToolCatalog.removeServer(serverID) }
        let descriptor = MCPToolDescriptor(
            serverID: serverID,
            serverName: "roundtrip",
            toolName: "echo",
            description: "Echoes",
            inputSchema: .object(["type": .string("object")])
        )
        MCPToolCatalog.setTools([descriptor], forServer: serverID)

        let found = MCPToolCatalog.descriptor(named: "mcp__roundtrip__echo")
        #expect(found == descriptor)
        #expect(found?.toolName == "echo")
        #expect(found?.serverID == serverID)
    }

    @Test func policyDefaultsToAskAndRoundTrips() throws {
        let defaults = try #require(UserDefaults(suiteName: "mcp-policy-tests"))
        defaults.removePersistentDomain(forName: "mcp-policy-tests")

        #expect(MCPToolCatalog.policy(for: "mcp__s__t", in: defaults) == .ask)
        MCPToolCatalog.setPolicy(.forbidden, for: "mcp__s__t", in: defaults)
        #expect(MCPToolCatalog.policy(for: "mcp__s__t", in: defaults) == .forbidden)
        MCPToolCatalog.setPolicy(.allowed, for: "mcp__s__t", in: defaults)
        #expect(MCPToolCatalog.policy(for: "mcp__s__t", in: defaults) == .allowed)
        MCPToolCatalog.setPolicy(.ask, for: "mcp__s__t", in: defaults)
        #expect(defaults.dictionary(forKey: MCPToolCatalog.toolPoliciesKey)?.isEmpty == true)
    }

    @Test func offeredToolsExcludesForbidden() throws {
        let defaults = try #require(UserDefaults(suiteName: "mcp-offered-tests"))
        defaults.removePersistentDomain(forName: "mcp-offered-tests")
        let serverID = UUID()
        defer { MCPToolCatalog.removeServer(serverID) }

        let allowed = MCPToolDescriptor(
            serverID: serverID, serverName: "offered", toolName: "read",
            description: "", inputSchema: .object([:])
        )
        let forbidden = MCPToolDescriptor(
            serverID: serverID, serverName: "offered", toolName: "wipe",
            description: "", inputSchema: .object([:])
        )
        MCPToolCatalog.setTools([allowed, forbidden], forServer: serverID)
        MCPToolCatalog.setPolicy(.forbidden, for: forbidden.namespacedName, in: defaults)

        let offered = MCPToolCatalog.offeredTools(in: defaults)
        #expect(offered.contains(allowed))
        #expect(!offered.contains(forbidden))
    }

    @Test func sanitizerDropsUnsupportedKeysAndKeepsNestedShape() {
        let raw: ChatToolValue = .object([
            "$schema": .string("http://json-schema.org/draft-07/schema#"),
            "$defs": .object([:]),
            "oneOf": .array([]),
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "required": .array([.string("path")]),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "additionalProperties": .bool(false),
                ]),
                // Property named like a schema keyword must survive.
                "items": .object(["type": .string("string")]),
            ]),
            "items": .object([
                "type": .string("string"),
                "$ref": .string("#/$defs/x"),
            ]),
            "anyOf": .array([
                .object(["type": .string("string"), "oneOf": .array([])]),
            ]),
        ])

        let cleaned = MCPToolCatalog.sanitizeSchema(raw)
        let object = cleaned.objectValue
        #expect(object?["$schema"] == nil)
        #expect(object?["$defs"] == nil)
        #expect(object?["oneOf"] == nil)
        #expect(object?["additionalProperties"] == nil)
        #expect(object?["required"] == .array([.string("path")]))
        let path = object?["properties"]?.objectValue?["path"]?.objectValue
        #expect(path?["type"] == .string("string"))
        #expect(path?["additionalProperties"] == nil)
        #expect(object?["properties"]?.objectValue?["items"] == .object(["type": .string("string")]))
        #expect(object?["items"] == .object(["type": .string("string")]))
        #expect(object?["anyOf"] == .array([.object(["type": .string("string")])]))
    }

    @Test func removePoliciesClearsOnlyTheMatchingPrefix() throws {
        let defaults = try #require(UserDefaults(suiteName: "mcp-remove-tests"))
        defaults.removePersistentDomain(forName: "mcp-remove-tests")

        MCPToolCatalog.setPolicy(.allowed, for: "mcp__docs__search", in: defaults)
        MCPToolCatalog.setPolicy(.forbidden, for: "mcp__other__wipe", in: defaults)
        MCPToolCatalog.removePolicies(
            namespacePrefix: MCPToolCatalog.namespacePrefix(server: "Docs"),
            in: defaults
        )

        #expect(MCPToolCatalog.policy(for: "mcp__docs__search", in: defaults) == .ask)
        #expect(MCPToolCatalog.policy(for: "mcp__other__wipe", in: defaults) == .forbidden)
    }

    @Test func mapsContentArraysIntoStatusAndMessage() {
        let ok = MCPToolCatalog.result(
            from: [
                .text(text: "first", annotations: nil, _meta: nil),
                .image(data: "abc", mimeType: "image/png", annotations: nil, _meta: nil),
                .text(text: "second", annotations: nil, _meta: nil),
            ],
            isError: nil
        )
        #expect(ok.response["status"] == .string("ok"))
        #expect(ok.response["message"] == .string("first\n[image: image/png]\nsecond"))

        let failed = MCPToolCatalog.result(
            from: [.text(text: "boom", annotations: nil, _meta: nil)],
            isError: true
        )
        #expect(failed.response["status"] == .string("error"))
        #expect(failed.response["message"] == .string("boom"))
    }

    @Test func valuesRoundTripBetweenMCPAndChatToolValue() {
        let chat: ChatToolValue = .object([
            "text": .string("hi"),
            "count": .number(3),
            "flag": .bool(true),
            "list": .array([.string("a"), .null]),
        ])
        #expect(MCPToolCatalog.chatToolValue(MCPToolCatalog.mcpValue(chat)) == chat)
    }
}

// MARK: - Executor

@MainActor
struct MCPToolExecutorTests {
    @Test func forbiddenToolThrowsBeforePreparing() async throws {
        let defaults = try testDefaults("exec-forbid")
        let descriptor = registered(server: "exec-forbid", tool: "wipe")
        defer { MCPToolCatalog.removeServer(descriptor.serverID) }
        MCPToolCatalog.setPolicy(.forbidden, for: descriptor.namespacedName, in: defaults)

        let executor = MCPToolExecutor(defaults: defaults) { _, _ in .make(status: "ok", message: "") }
        await #expect(throws: MCPToolError.self) {
            _ = try await executor.prepare(call(descriptor.namespacedName))
        }
    }

    @Test func askPolicyRequiresConfirmationBeforeRunning() async throws {
        let defaults = try testDefaults("exec-ask")
        let descriptor = registered(server: "exec-ask", tool: "send")
        defer { MCPToolCatalog.removeServer(descriptor.serverID) }

        var executedArguments: [String: ChatToolValue]?
        let executor = MCPToolExecutor(defaults: defaults) { _, arguments in
            executedArguments = arguments
            return .make(status: "ok", message: "sent")
        }
        let action = try await executor.prepare(
            call(descriptor.namespacedName, ["to": .string("zed")])
        )

        let confirmation = try #require(action.confirmation)
        #expect(confirmation.primaryText == "exec-ask: send")
        #expect(confirmation.details.map(\.label) == ["to"])

        let result = await action.execute()
        #expect(result.response["message"] == .string("sent"))
        #expect(executedArguments == ["to": .string("zed")])
    }

    @Test func allowedPolicyRunsWithoutConfirmation() async throws {
        let defaults = try testDefaults("exec-allow")
        let descriptor = registered(server: "exec-allow", tool: "read")
        defer { MCPToolCatalog.removeServer(descriptor.serverID) }
        MCPToolCatalog.setPolicy(.allowed, for: descriptor.namespacedName, in: defaults)

        let executor = MCPToolExecutor(defaults: defaults) { _, _ in .make(status: "ok", message: "done") }
        let action = try await executor.prepare(call(descriptor.namespacedName))
        #expect(action.confirmation == nil)
    }

    @Test func unknownToolThrows() async {
        let executor = MCPToolExecutor { _, _ in .make(status: "ok", message: "") }
        await #expect(throws: MCPToolError.self) {
            _ = try await executor.prepare(call("mcp__nowhere__nothing"))
        }
    }

    @Test func confirmationRendersHugeNumbersWithoutTrapping() {
        let descriptor = MCPToolDescriptor(
            serverID: UUID(), serverName: "s", toolName: "t",
            description: "", inputSchema: .object([:])
        )
        let confirmation = MCPToolExecutor.confirmationDetails(
            for: descriptor,
            arguments: ["big": .number(1e30), "small": .number(3)]
        )
        #expect(confirmation.details.map(\.value) == ["1e+30", "3"])
    }

    private func testDefaults(_ suite: String) throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: "mcp-\(suite)-tests"))
        defaults.removePersistentDomain(forName: "mcp-\(suite)-tests")
        return defaults
    }

    private func registered(server: String, tool: String) -> MCPToolDescriptor {
        let descriptor = MCPToolDescriptor(
            serverID: UUID(),
            serverName: server,
            toolName: tool,
            description: "",
            inputSchema: .object([:])
        )
        MCPToolCatalog.setTools([descriptor], forServer: descriptor.serverID)
        return descriptor
    }

    private func call(
        _ name: String,
        _ arguments: [String: ChatToolValue] = [:]
    ) -> ChatToolCall {
        ChatToolCall(id: "test", name: name, arguments: arguments)
    }
}

// MARK: - Router dispatch

@MainActor
struct MCPRouterDispatchTests {
    @Test func mcpPrefixedCallsReachTheMCPExecutor() async {
        let mcp = MockMCPExecutor()
        let router = ChatToolRouter(
            reminderExecutor: UnusedReminderExecutor(),
            notesExecutor: UnusedNotesExecutor(),
            desktopExecutor: UnusedDesktopExecutor(),
            timerExecutor: UnusedTimerExecutor(),
            mcpExecutor: mcp,
            memoryExecutor: MemoryToolExecutor(engine: MemoryEngine(store: MemoryStore(
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
            )))
        )

        let result = await router.execute(
            ChatToolCall(id: "1", name: "mcp__server__tool", arguments: [:]),
            confirm: { _ in true },
            onStatus: { _ in }
        )
        #expect(mcp.prepared == ["mcp__server__tool"])
        #expect(result.response["status"] == .string("ok"))

        let unknown = await router.execute(
            ChatToolCall(id: "2", name: "not_a_tool", arguments: [:]),
            confirm: { _ in true },
            onStatus: { _ in }
        )
        #expect(unknown.response["message"] == .string("Unknown tool ‘not_a_tool’."))
    }
}

@MainActor
private final class MockMCPExecutor: ToolExecuting {
    var prepared: [String] = []
    func prepare(_ call: ChatToolCall) async throws -> PreparedToolAction {
        prepared.append(call.name)
        return PreparedToolAction(confirmation: nil) {
            .make(status: "ok", message: "mcp ran")
        }
    }
}

@MainActor
private final class UnusedReminderExecutor: ReminderToolExecuting {
    func confirmationDetails(for request: ReminderToolRequest) -> ToolConfirmationDetails? { nil }
    func execute(_ request: ReminderToolRequest) async -> ChatToolResult { .error("unused") }
}

@MainActor
private final class UnusedNotesExecutor: NotesToolExecuting {
    func confirmationDetails(for request: NoteToolRequest) -> ToolConfirmationDetails? { nil }
    func execute(_ request: NoteToolRequest) async -> ChatToolResult { .error("unused") }
}

@MainActor
private final class UnusedDesktopExecutor: DesktopToolExecuting {
    func confirmationDetails(for request: DesktopToolRequest) -> ToolConfirmationDetails? { nil }
    func execute(_ request: DesktopToolRequest) async -> ChatToolResult { .error("unused") }
}

@MainActor
private final class UnusedTimerExecutor: TimerToolExecuting {
    func confirmationDetails(for request: TimerToolRequest) -> ToolConfirmationDetails? { nil }
    func execute(_ request: TimerToolRequest) async -> ChatToolResult { .error("unused") }
}

// MARK: - OAuth

// Serialized: several tests toggle the process-global
// ChatAPIKeyStore.useInMemoryStoreForTesting flag; run in parallel, one
// test's reset would flip the store out from under another mid-flight.
@Suite(.serialized) struct MCPOAuthTests {
    @Test func inMemoryStoreToggleResetsAllState() throws {
        ChatAPIKeyStore.useInMemoryStoreForTesting = true
        defer { ChatAPIKeyStore.useInMemoryStoreForTesting = false }
        let id = UUID()
        try ChatAPIKeyStore.setMCPToken("poison", forServer: id)
        #expect(ChatAPIKeyStore.mcpToken(forServer: id) == "poison")

        // Toggling off and on must drop both the backing store and the
        // cache — otherwise test data leaks into later real Keychain writes.
        ChatAPIKeyStore.useInMemoryStoreForTesting = false
        ChatAPIKeyStore.useInMemoryStoreForTesting = true
        #expect(ChatAPIKeyStore.mcpToken(forServer: id) == nil)
    }

    @Test func oauthTokenRoundTripsThroughStorage() throws {
        ChatAPIKeyStore.useInMemoryStoreForTesting = true
        defer { ChatAPIKeyStore.useInMemoryStoreForTesting = false }
        let serverID = UUID()
        let storage = MCPOAuthTokenStorage(serverID: serverID)
        defer { try? ChatAPIKeyStore.setMCPOAuthState("", forServer: serverID) }

        #expect(storage.load() == nil)
        let token = OAuthAccessToken(
            value: "access-abc",
            tokenType: "Bearer",
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
            scopes: ["read", "write"],
            authorizationServer: URL(string: "https://auth.example.com"),
            refreshToken: "refresh-xyz",
            clientID: "client-1"
        )
        storage.save(token)

        let loaded = try #require(storage.load())
        #expect(loaded.value == "access-abc")
        #expect(loaded.refreshToken == "refresh-xyz")
        #expect(loaded.clientID == "client-1")
        #expect(loaded.scopes == ["read", "write"])
        #expect(loaded.expiresAt == token.expiresAt)

        // The SDK clears before attempting the refresh grant; the refresh
        // credentials must survive so a transient refresh failure doesn't
        // force a browser re-sign-in.
        storage.clear()
        let cleared = try #require(storage.load())
        #expect(cleared.value.isEmpty)
        #expect(cleared.refreshToken == "refresh-xyz")
        #expect(cleared.clientID == "client-1")
        // Must read as expired: a nil expiresAt would make the SDK send the
        // empty value as "Bearer " instead of entering the refresh path.
        #expect(cleared.expiresAt == .distantPast)
        #expect(cleared.isExpired())
    }

    @Test func clearWithoutRefreshTokenHardDeletes() throws {
        ChatAPIKeyStore.useInMemoryStoreForTesting = true
        defer { ChatAPIKeyStore.useInMemoryStoreForTesting = false }
        let serverID = UUID()
        let storage = MCPOAuthTokenStorage(serverID: serverID)
        defer { try? ChatAPIKeyStore.setMCPOAuthState("", forServer: serverID) }

        storage.save(
            OAuthAccessToken(
                value: "access-only",
                tokenType: "Bearer",
                expiresAt: nil,
                scopes: [],
                authorizationServer: nil,
                refreshToken: nil
            ))
        storage.clear()
        #expect(storage.load() == nil)
    }

    @Test func nonInteractiveDelegateDeclinesWithoutOpeningBrowser() async {
        let delegate = MCPOAuthBrowserDelegate(interactive: false)
        #expect(delegate.redirectURL == nil)

        await #expect(throws: MCPServerError.self) {
            _ = try await delegate.presentAuthorizationURL(
                URL(string: "https://auth.example.com/authorize")!
            )
        }
        #expect(delegate.takeAuthError() == .needsAuth)
        #expect(delegate.takeAuthError() == nil)
    }

    @Test func delegateAnswersTheSelectorTheRedirectHandlerCalls() {
        // OIDRedirectHTTPHandler calls this selector without checking for it
        // first; a miss is an unrecognized-selector crash mid sign-in.
        let delegate = MCPOAuthBrowserDelegate(interactive: false)
        #expect(delegate.responds(to: NSSelectorFromString("resumeExternalUserAgentFlowWithURL:error:")))
        #expect(delegate.responds(to: NSSelectorFromString("failExternalUserAgentFlowWithError:")))
        #expect(delegate.responds(to: NSSelectorFromString("cancel")))
    }

    @Test func interactiveDelegateConsumesOnlyTheOAuthRedirect() async throws {
        let delegate = MCPOAuthBrowserDelegate(interactive: true, openURL: { _ in })
        let redirectURL = try #require(delegate.redirectURL)

        async let redirect = delegate.presentAuthorizationURL(
            URL(string: "https://auth.example.com/authorize")!
        )
        // Give presentAuthorizationURL a moment to install the continuation.
        try await Task.sleep(for: .milliseconds(50))

        // A stray favicon request must not complete the flow.
        #expect(delegate.resumeExternalUserAgentFlow(with: URL(string: "/favicon.ico")!) == false)
        // The listener hands over a host-relative URL; it should be consumed
        // and rebuilt onto the listener's absolute base.
        #expect(delegate.resumeExternalUserAgentFlow(with: URL(string: "/?code=c1&state=s1")!))

        let result = try await redirect
        #expect(result.host == redirectURL.host)
        #expect(result.port == redirectURL.port)
        #expect(result.query == "code=c1&state=s1")

        // The listener is dead after one presentation; a retry must fail fast
        // (mapped to .needsAuth) instead of opening a browser onto a dead port
        // and hanging until the timeout.
        await #expect(throws: MCPServerError.self) {
            _ = try await delegate.presentAuthorizationURL(
                URL(string: "https://auth.example.com/authorize")!
            )
        }
        #expect(delegate.takeAuthError() == .needsAuth)
    }

    @Test func redirectBeforePresentationIsNotConsumed() async throws {
        let delegate = MCPOAuthBrowserDelegate(interactive: true, openURL: { _ in })
        _ = try #require(delegate.redirectURL)

        // A code-bearing request before presentAuthorizationURL installs the
        // continuation (stale tab, local probe) must be refused, or the
        // handler kills the listener before the real redirect arrives.
        #expect(delegate.resumeExternalUserAgentFlow(with: URL(string: "/?code=stale")!) == false)

        async let redirect = delegate.presentAuthorizationURL(
            URL(string: "https://auth.example.com/authorize")!
        )
        try await Task.sleep(for: .milliseconds(50))
        #expect(delegate.resumeExternalUserAgentFlow(with: URL(string: "/?code=real")!))
        let result = try await redirect
        #expect(result.query == "code=real")
    }

    @Test func keychainWritesFromConcurrentTasksBothLand() async throws {
        ChatAPIKeyStore.useInMemoryStoreForTesting = true
        defer { ChatAPIKeyStore.useInMemoryStoreForTesting = false }
        let idA = UUID()
        let idB = UUID()
        defer {
            try? ChatAPIKeyStore.setMCPToken("", forServer: idA)
            try? ChatAPIKeyStore.setMCPToken("", forServer: idB)
        }
        // Tripwire for the read-modify-write lock: without it, one of the two
        // interleaved writers overwrites the other's key.
        await withTaskGroup(of: Void.self) { group in
            for (id, value) in [(idA, "token-a"), (idB, "token-b")] {
                group.addTask {
                    for _ in 0..<50 {
                        try? ChatAPIKeyStore.setMCPToken(value, forServer: id)
                    }
                }
            }
        }
        #expect(ChatAPIKeyStore.mcpToken(forServer: idA) == "token-a")
        #expect(ChatAPIKeyStore.mcpToken(forServer: idB) == "token-b")
    }

    @Test func keychainReadsDuringWritesDoNotLoseKeys() async throws {
        ChatAPIKeyStore.useInMemoryStoreForTesting = true
        defer { ChatAPIKeyStore.useInMemoryStoreForTesting = false }
        let id = UUID()
        defer { try? ChatAPIKeyStore.setMCPToken("", forServer: id) }
        // Tripwire for the read-populate race: a cache-miss read racing a
        // write must not repopulate the cache with a pre-write snapshot that
        // the next write persists (deleting the racing write's key).
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for i in 0..<100 {
                    try? ChatAPIKeyStore.setMCPToken("token-\(i)", forServer: id)
                }
            }
            group.addTask {
                for _ in 0..<100 {
                    _ = ChatAPIKeyStore.mcpToken(forServer: id)
                }
            }
        }
        try ChatAPIKeyStore.setMCPToken("final", forServer: id)
        #expect(ChatAPIKeyStore.mcpToken(forServer: id) == "final")
    }
}
