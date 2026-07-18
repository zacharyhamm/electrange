# Code review — working-tree diff (2026-07-18)

Scope: uncommitted changes on `main` (`git diff HEAD`) — MCPSettingsTab.swift,
ChatAPIKeyStore.swift, MCPServerManager.swift, TimerTool.swift, MCPToolTests.swift.
Process: 4 finder subagents (line-scan/Swift-pitfalls, removed-behavior/wrapper,
cross-file tracer, cleanup/conventions), candidates verified against source, plus a
gap sweep. Ranked most-severe first. CONFIRMED = trigger + wrong outcome traced in
code; PLAUSIBLE = mechanism real, trigger uncertain.

## Correctness

- [ ] **Second Sign In click racing an in-flight browser flow is silently swallowed even when that flow failed** — `electragne/Tools/MCPServerManager.swift:144` (PLAUSIBLE, deliberate trade-off)
  User clicks Sign In, abandons the browser tab (flow hangs until the 300 s timeout), clicks Sign In again: the second `refresh(id, interactive: true)` blocks at `await inflight.task.value` for up to 5 minutes, then hits `if !interactive || inflight.interactive { return }` and returns without opening a browser. The click appears to do nothing; a third click is needed. Piggybacking on a *successful* interactive flow is right; piggybacking on a failed/timed-out one swallows the retry. Possible fix: after awaiting an interactive inflight, re-run instead of returning when `status[id]` is still `.needsAuth`/`.failed`.

- [ ] **Invalid or expired pasted token on an OAuth-capable server leaves no recovery path in Settings** — `electragne/App/MCPSettingsTab.swift:83` (CONFIRMED gap; mechanics pre-existing)
  With a stored token, `canSignIn` now hides Sign In (correct — the token suppresses the OAuth authorizer in `performRefresh`, so the button was a no-op before this diff). But the settings UI has no way to edit or clear a token for an existing server: if the pasted token expires or is wrong, Refresh retries the same dead token forever and the only recovery is Remove + re-add (losing per-tool policies). Needs a clear/edit-token affordance, or clear the stored token on auth-failure so OAuth can take over.

- [ ] **Sign In button visibility depends on non-observable Keychain state** — `electragne/App/MCPSettingsTab.swift:83` (PLAUSIBLE, latent)
  `manager.canSignIn(server.id)` reads `manager.status` (Observation-tracked) *and* `ChatAPIKeyStore.mcpToken` (a non-observable global). Today every token mutation goes through `add`/`remove`, which also mutate observable state, so the view re-renders coincidentally. Any future path that changes only the token (token-edit UI, external keychain change, failed-write recovery) leaves the button stale until an unrelated re-render. Worth a comment at minimum; a fix would surface token presence through observable manager state.

- [ ] **`canSignIn` does lock-guarded, potentially cold Keychain I/O inside SwiftUI body evaluation** — `electragne/Tools/MCPServerManager.swift:131` (CONFIRMED mechanism, impact usually masked by cache)
  The old condition (`status[id]?.canSignIn == true`) was pure in-memory; the new one calls `ChatAPIKeyStore.mcpToken`, which takes the store's `NSLock` and, on a cold cache, runs `SecItemCopyMatching` (and possibly the one-time legacy migration, which *writes*) on the main thread mid-render. It also contends with `MCPOAuthTokenStorage` saves from SDK background tasks that hold the same lock across synchronous keychain I/O, with no priority donation. In practice `connectAll()` at launch warms the cache first, so this is a hang risk only on unlucky timing — but per-render keychain-adjacent work from a view body is fragile. Consider caching token presence in `status` / manager state instead.

- [ ] **`.serialized` protects only `MCPOAuthTests`, but the flag is process-global and tests run inside the live app host** — `electragneTests/Tools/MCPToolTests.swift:327` (PLAUSIBLE, pre-existing class of race)
  `TEST_HOST` is `electragne.app` and `AppDelegate` fires `MCPServerManager.shared.connectAll()` at launch, so the host's real MCP refreshes/OAuth token saves share `ChatAPIKeyStore` with the tests. While any test has `useInMemoryStoreForTesting` on, a real host write (e.g. a rotated OAuth refresh token) is diverted into `inMemoryBacking` and discarded when the test's `defer` toggles it off — on a dev machine with real servers configured this can lose a live credential. Same class of race existed before this diff (writes were skipped rather than diverted); the toggle-resets-state design improves it but doesn't close it. Consider a test-only host-app guard (skip `connectAll` under XCTest) — that closes the race for every suite at once.

## Cleanup

- [ ] **Reuse: the decline↔error mapping now lives in two places** — `electragne/Tools/MCPServerManager.swift:43`
  New `MCPAuthDecline.error` encodes needsAuth→signInRequired, timedOut→signInTimedOut, failed→signInFailed — the same correspondence `MCPOAuth.swift` hand-writes at each record/throw pair (`record(.failed(listenerError)); throw MCPServerError.signInFailed(listenerError)`, `record(.needsAuth); throw MCPServerError.signInRequired`, and the timeout's `finish(with: .failure(.signInTimedOut))` + `record(.timedOut)`). Have those sites build the `MCPAuthDecline` first and `record(decline); throw decline.error` so the mapping has one home.

- [ ] **Altitude: two APIs named `canSignIn` with different answers; the enum property is now single-caller** — `electragne/Tools/MCPServerManager.swift:19`
  `MCPServerStatus.canSignIn` (true for any `.needsAuth`/`.failed`) is only called by the manager's token-aware `canSignIn(_:)`. The looser property remains under the same name, so the next consumer reaching for `status[id]?.canSignIn` silently reinstates the show-Sign-In-with-token bug this diff fixes. Fold the two-case switch into the manager method and delete the property, or rename it to describe what it is (a signed-out terminal state).

## Verified clean

The refresh-loop interleavings (interactive racing background, double-click piggyback
chains, creator-cleanup vs. replacer races, cancellation while awaiting) all resolve
correctly; no `refreshTasks` entry can leak. `ChatAPIKeyStore` test mode can no longer
reach the real Keychain (`readCombined` returns the backing even when empty, so
`migrateLegacyItems` is unreachable with the flag on). `date.formatted(.iso8601)`
output is byte-identical to the removed `ISO8601DateFormatter` + `.withInternetDateTime`.
The cross-file tracer found no broken call sites, and no CLAUDE.md conventions apply.
