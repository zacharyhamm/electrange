# Architecture Refactor — Remaining Phases

Working branch: `refactor/phase-0` (every commit builds clean and passes
`./test.sh`; merge to `main` whenever convenient — each phase is
independently landable).

## Status

| Phase | Scope | Status |
|---|---|---|
| 0 | Hygiene + folder layout + splitting the 5 grab-bag files | **Done** |
| C1 | Tool errors on `LocalizedError`, shared `ChatToolResult.make` | **Done** |
| C2 | Unified `ToolExecuting` protocol, registry-driven router dispatch | **Done** |
| C3 | Gmail parser/MIME tests, `GoogleToolSupport` + `ToolCallArguments` dedup | **Done** |
| A1 | `AppModel` direct calls replacing `petShould*` notifications | **Done** |
| A2 | Single window-wiring path, `ClickDragClassifier`, shared `AnimationPlayback` | **Done** |
| A3 | Environment seams for the pet core | **Done** |
| A4 | Pure per-state movement policies + characterization tests | **Done** |
| A5 | Behavior controllers + declarative timers | **Done** |
| B1 | Chat transport seam + config + first streaming tests | **Done** |
| B2 | Neutral `ChatMessage` + shared `ChatProviderEngine` | **Done** |
| B3 | `ChatBubbleWindowController` slim-down | Pending |

Learnings that changed the original plan:

- The project builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so
  the pet core was already implicitly `@MainActor`; A1's annotation sweep
  was unnecessary. New `nonisolated` policy types must be marked
  explicitly (the codebase already does this consistently).
- `fileSystemSynchronizedGroups` means file moves/creations need no
  pbxproj edits. Resources and `electragne.entitlements` must stay at the
  `electragne/` root (`CODE_SIGN_ENTITLEMENTS` hardcodes that path).
- `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY` is on: new files need
  explicit `import CoreGraphics` for CGRect/CGPoint members when they
  don't import AppKit.

Dependency order: A3 → A4 → A5 are sequential. B1 → B2 → B3 are
sequential (B3 also needed C2, which is done). The A and B tracks are
independent and can interleave.

---

## A3 — Environment seams (mechanical rerouting, no logic movement)

Goal: `PetViewModel` stops touching `NSScreen`, the detector singletons,
and `NSWindow.setFrameOrigin` directly, so A4's policies can consume a
pure snapshot.

New `Pet/PetEnvironment.swift`:

```swift
/// Pure value snapshot; policies never see NSScreen/NSWindow.
nonisolated struct ScreenInfo: Equatable {
    var frame: CGRect
    var visibleFrame: CGRect
}

nonisolated struct EnvironmentSnapshot: Equatable {
    var screens: [ScreenInfo]
    var dockInfo: DockInfo?             // existing type from DockDetector
    var windowSurfaces: [WindowSurface] // existing type from WindowDetector
    var petFrame: CGRect
}

@MainActor protocol PetEnvironmentSensing: AnyObject {
    func snapshot(includeWindows: Bool) -> EnvironmentSnapshot
}

@MainActor protocol PetSurfaceMoving: AnyObject {  // wraps the pet NSWindow
    var frame: CGRect { get }
    func setOrigin(_ p: CGPoint)
}

@MainActor protocol TickScheduling: AnyObject {    // TimerDriver already matches
    func start(interval: TimeInterval, _ tick: @escaping () -> Void)
    func stop()
    var isRunning: Bool { get }
}
```

Steps (one commit each):

1. `LiveEnvironment` adapter wrapping `NSScreen.screens` +
   `DockDetector.shared` + `WindowDetector.shared`; inject via
   `PetViewModel.init(environment:)` with a live default. Route every
   direct `NSScreen.`/`DockDetector.shared`/`WindowDetector.shared` call
   site in PetViewModel through it (~10 sites: `currentScreen`,
   `positionWindowForFall`, `summonToChat`,
   `handleScreenParametersChange`, `groundInfo`, `findClimbOpportunity`,
   dock/window queries).
2. `WindowSurfaceAdapter: PetSurfaceMoving` wrapping the pet `NSWindow`;
   route all ~30 `setFrameOrigin` sites and frame reads through it.
3. `TimerDriver: TickScheduling` conformance (already structurally
   identical) so A5 can inject fake clocks later.

Keep `ChatBubbleWindowController` and `AppDelegate` window access as-is —
this phase is only about PetViewModel.

**Verify:** build + tests + smoke; then grep-assert inside
PetViewModel.swift: zero occurrences of `NSScreen.`,
`DockDetector.shared`, `WindowDetector.shared`, `setFrameOrigin`.

## A4 — Pure per-state policies + characterization tests

Goal: each `update*Movement()`/`updatePhysics()` body becomes
"build Input from snapshot → call pure policy → apply Action", with the
decision core unit-tested. This is where the currently untestable state
machine gets locked down, before A5 moves any structure.

Policy shape (mirrors the proven `summonOrigin`/`BallisticJump` pattern —
`nonisolated`, static, randomness injected):

```swift
nonisolated enum WalkPolicy {
    struct Input {
        var env: EnvironmentSnapshot
        var moveX: CGFloat            // already tickScale-adjusted
        var isMovingRight: Bool
        // + the specific fields the current updateMovement() reads
    }
    enum Action: Equatable {
        case move(to: CGPoint)
        case turnAround
        case crossSeam(to: CGPoint, screenIndex: Int)
        case beginClimb(WindowSurface)
        case beginLedgeJump(targetX: CGFloat, targetY: CGFloat)
        case fallOffEdge
        case beginDockApproach
    }
    static func evaluate(_ input: Input, random: (Int) -> Int) -> Action
}
```

Extraction order, one policy per commit, **characterization tests in the
same commit** (encode the thresholds read from the current code — seam
crossing, bounce cutoffs, climb-probability gates, edge fall-off):

1. `FallPolicy` — gravity/bounce/ground resolution; absorbs
   `groundInfo(at:petWidth:below:)` and the bounce constants.
2. `JumpPolicy` — ONE policy parameterized by landing rule, subsuming
   `updateBasicJumpMovement`, `updateDockJumpMovement`,
   `updateLedgeJumpMovement`, `updateJumpOffMovement` (all are
   ballistic-arc + landing-condition; compose the already-tested
   `BallisticJump`).
3. `DockWalkPolicy` — includes the edge/look-down branching.
4. `WindowTopPolicy` — shares the edge/look-down shape with DockWalk;
   dedupe if it falls out naturally, don't force it.
5. `ClimbPolicy` — ascend/top-out phases; absorbs `findClimbOpportunity`.
6. `WalkPolicy` — biggest and last (`updateMovement`, ~100 lines):
   dock collision, climb opportunity, screen-seam crossing, ledge-jump
   trigger, fall-off-edge.

Also extract the random-behavior weighting in `handleAnimationComplete`
(the `Int.random(in: 1...100)` + `BehaviorConstants` cumulative
arithmetic) into a pure `IdleBehaviorPolicy` with an injected roll.

**Verify per commit:** tests green; smoke the specific state (walk,
climb, dock, jumps).

## A5 — Behavior controllers + declarative timers

**Status: Done.** Pause normalization is pure and characterized; every
`PetState` now maps through one behavior factory. State entry and resume both
apply the behavior's declarative `TimerNeeds`, and the old per-state timer
starters, update methods, and 13-case resume switch have been removed.

Goal: kill the duplicated timer knowledge — each `start*()` method's
ritual and the 13-case `resume()` switch collapse into one declarative
`timerNeeds` per behavior.

`Pet/Behaviors/PetBehavior.swift`:

```swift
nonisolated struct TimerNeeds: OptionSet {
    let rawValue: Int
    static let movement  = TimerNeeds(rawValue: 1 << 0)
    static let physics   = TimerNeeds(rawValue: 1 << 1)
    static let animation = TimerNeeds(rawValue: 1 << 2)
    static let idle      = TimerNeeds(rawValue: 1 << 3)
}

@MainActor struct PetContext {
    let surface: PetSurfaceMoving
    let environment: PetEnvironmentSensing
    let animator: AnimationManager
    let transition: (PetState) -> Void   // coordinator-owned
}

@MainActor protocol PetBehavior: AnyObject {
    var timerNeeds: TimerNeeds { get }   // single source of truth for entry AND resume
    func begin(_ ctx: PetContext)        // what start*() did (state entry, play anim)
    func tick(_ ctx: PetContext)         // movement/physics tick: policy + apply
    func idleFired(_ ctx: PetContext)    // default no-op
}
```

PetViewModel becomes a coordinator:

```swift
func enter(_ state: PetState) {
    self.state = state
    current = behavior(for: state)      // the ONLY state→behavior map
    current.begin(context)
    applyTimers(current.timerNeeds)     // used by BOTH entry and resume
}
func pause()  { savedState = normalizedForPause(state); stopAllTimers(); pauseChildWindows() }
func resume() { applyTimers(behavior(for: savedState).timerNeeds); resumeChildWindows() }
```

Steps:

1. **First commit:** extract `normalizedForPause(_:)` (the chatting/
   mid-jump pause normalization currently inline in `pause()`) as a pure
   function and unit-test it — before any migration.
2. Introduce the protocol + `applyTimers(_:)` + behavior factory with the
   first trivial behaviors, keeping unmigrated states on the old paths.
3. Migrate one state per commit, simplest first:
   sleeping → lookingDown → dragging → the four jumps (share one
   `JumpBehavior` parameterized like `JumpPolicy`) → dock walk →
   window top → climb → walking → falling → chatting (last; it owns the
   resting-place logic).
   Each commit deletes that state's `update*`/`start*Timer` pair from
   PetViewModel and its arm from the old `resume()` switch; the switch
   dies with the final migration.
4. Optional polish (independent): fold the raw self-rescheduling
   animation `Timer` (`scheduleNextAnimationFrame`) into a one-shot
   chaining variant on `TimerDriver` so every timer goes through one
   type; then the whole timer set is fake-clock injectable via
   `TickScheduling`.

Target end state: PetViewModel ≈ 350–450 lines (coordination, chat
summon/resting logic, child windows); behaviors 60–120 lines each;
policies pure and tested.

**Risk (highest remaining):** feel regressions and pause/resume edges.
Mitigation: A4 characterization tests land first; one state per commit;
per-state smoke item after each.

---

## B1 — Chat transport seam + config (shapes unchanged)

**Status: Done.** Both providers and Ollama web search now use the injected
`ChatHTTPTransport`; API-key fallback and chat limits/defaults are centralized,
Gemini request URLs fail safely, and stub-transport tests cover streaming,
status callbacks, multi-round tools, HTTP failures, and cancellation.

1. `Chat/ChatHTTPTransport.swift`:

```swift
nonisolated protocol ChatHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    /// Both providers parse line-delimited bodies (NDJSON / SSE).
    func lines(for request: URLRequest) async throws
        -> (AsyncThrowingStream<String, Error>, URLResponse)
}
struct URLSessionTransport: ChatHTTPTransport { let session: URLSession }
```

   Inject into `OllamaClient` and `GeminiClient`
   (`init(transport: ChatHTTPTransport = URLSessionTransport(session: .shared))`),
   mirroring `GoogleOAuthService`'s injection. Replace the three
   hardcoded `URLSession.shared` call sites (OllamaClient chat +
   OllamaWebSearch + GeminiClient).
2. Move the copy-pasted 3-tier `loadAPIKey` (keychain → env var → key
   file) from both clients into `ChatAPIKeyStore`;
   `OllamaWebSearch.realHomeDirectory()` moves to a neutral home
   (`Support/`), Gemini stops reaching into Ollama's type.
3. `Chat/ChatConfig.swift`: per-provider default model, `maxToolRounds`,
   `contextWindowTokens`, `maxHistoryMessages` (currently
   `ChatBubbleWindowController.maxOllamaHistoryMessages`); injected
   `.default`.
4. Fix the force-unwrapped `URLComponents(...)!`/`components.url!` in
   GeminiClient's request construction → throw
   `GeminiError.invalidModelName`.
5. **First `streamChat` tests** for both clients against a stub
   transport: token assembly, status callbacks, tool-call round trip
   (including multi-round), HTTP error paths, cancellation. These lock
   behavior before B2 restructures.

## B2 — Neutral `ChatMessage` + shared `ChatProviderEngine`

**Status: Done.** Stored chats now use the Ollama-JSON-compatible neutral
`ChatMessage`; both providers translate through thin backends while
`ChatProviderEngine` owns history trimming, tool rounds, and event fan-out.
Provider errors and prompt scaffolding are shared, and missing Ollama web-search
keys still surface the Settings hint.

1. `ChatMessage` (role / content / toolCalls / toolName) with a Codable
   representation **byte-compatible with the current `OllamaMessage`
   JSON** in stored chats (same coding keys, including
   `tool_calls`/`tool_name`). Verify with a round-trip test against
   fixture JSON captured from a real chat file in
   `Application Support/electragne/chats` **before** starting.
   `OllamaMessage` becomes a private wire type inside OllamaClient.
2. `ChatClient.streamChat(history: [ChatMessage], ...)`; `StoredChat`
   holds `[ChatMessage]`; GeminiClient translates from the neutral type.
3. `ChatProviderEngine` owns the bounded tool-round loop (currently
   duplicated in both clients) over a backend protocol:

```swift
nonisolated enum ProviderEvent {
    case status(String), token(String), toolCall(ChatToolCall)
}
protocol ChatProviderBackend: Sendable {
    func stream(messages: [ChatMessage]) async throws
        -> AsyncThrowingStream<ProviderEvent, Error>
    func appendToolResult(_ r: ChatToolResult, for call: ChatToolCall,
                          to messages: inout [ChatMessage])
}
final class ChatProviderEngine: ChatClient { /* round loop, trimming, fan-out */ }
```

   The clients shrink to backends (request encoding + stream parsing).
4. **web_search rewiring decision:** OllamaClient currently intercepts
   `web_search` inline and *throws* `missingAPIKey` (aborting the stream
   with a Settings hint in the UI). C2 already registered a router-side
   `WebSearchExecutor` that instead returns a model-visible error result.
   When the engine forwards web_search through the normal `onToolCall`
   path, pick one semantics deliberately: recommend keeping the abort
   (engine maps a missing-key tool result back to a thrown error) so the
   user-facing Settings hint survives.
5. System prompt: shared scaffold template + two small per-provider
   variance strings (the prompts have drifted — Gemini mentions inline
   math/date, Ollama mentions web_search; preserve each provider's
   current text rather than unifying wording).
6. One `ChatProviderError: LocalizedError` replaces
   `OllamaError`/`GeminiError`; the 7-arm catch ladder in
   `ChatBubbleWindowController.startStream` becomes one generic catch
   (plus the cancellation cases).

**Risk:** stored-chat decode regression → the fixture round-trip test
lands in the same commit as the type swap.

## B3 — `ChatBubbleWindowController` slim-down

1. Replace the 8-executor-parameter init with a single injected
   `ChatToolRouter` (C2's dispatch table already exists; tests inject
   mock executors through the router instead).
2. Wrap the stored tool-confirmation `CheckedContinuation` in a small
   `ConfirmationBroker` type that guards double-resume and owns the
   cancellation path; unit-test approve/cancel/supersede.
3. No UI changes.

---

## Verification protocol (every phase)

- `./test.sh` green (CI runs the identical script); build clean.
- New seams ship with tests in the same commit.
- Manual smoke checklist after each A-phase (needs human eyes): pet
  falls/lands; walks; crosses screen seam on two displays; drag+drop;
  climbs a window and walks its top; jumps to/walks/jumps off dock;
  sleeps after ~60s idle; Cmd-Shift-E summons chat; message streams on
  both providers; one tool confirmation; Hide/Show Pet while on the dock
  and mid-jump.
- Chat phases (B1/B2): additionally send a message on both providers,
  trigger web search on Ollama, and reload an old stored chat after B2.
