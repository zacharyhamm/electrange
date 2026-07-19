# AGENTS.md

Electragne — a macOS desktop pet (SwiftUI/AppKit menu-bar app, `LSUIElement`)
with an LLM chat bubble, tool calling, and a long-term memory system.

Repo is `electrange`; the Xcode target, bundle id (`org.impolexg.electragne`),
and source dir are `electragne`. Both spellings are intentional — never
"fix" one to match the other; renaming the bundle id invalidates stored
Keychain items and preferences.

## Build & test

```sh
./test.sh    # Debug, Swift Testing suite. Same command CI runs.
./build.sh   # Release; copies the bundle to ./Electragne.app
```

Run **both** before calling work done. `./test.sh` builds Debug (incremental);
`./build.sh` builds Release with `SWIFT_COMPILATION_MODE = wholemodule`, which
surfaces actor-isolation diagnostics the Debug build does not (see below).
A green `./test.sh` is not evidence the release build is clean.

Targets macOS 26.2 with Xcode 26.x.

## Swift 6 actor isolation — read this before writing any Swift here

The project builds in Swift language mode 5 with:

```
SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor
SWIFT_APPROACHABLE_CONCURRENCY = YES
SWIFT_STRICT_CONCURRENCY = targeted
```

**Every unannotated declaration in this codebase is implicitly `@MainActor`.**
That includes plain enums and structs, their static methods, and their
compiler-synthesized `Equatable`/`Hashable` conformances. That default is
right for views and view models and wrong for everything else.

The failure mode: a main-actor-bound value type gets used from a `nonisolated`
context and the compiler complains — most often in Release only, because
whole-module compilation sees the cross-file use that incremental Debug builds
miss. Two real instances (fixed in 92f4dac):

- `ChatBubbleTailEdge` was implicitly `@MainActor`, so its synthesized `==` was
  too — but `Shape.path(in:)`, which compares it, is `nonisolated`.
- `MemoryExtractor.decode` was implicitly `@MainActor` and got passed to
  `compactMap`, which takes a `nonisolated` closure.

**Rule: mark it `nonisolated` unless it genuinely touches UI or main-actor
state.** Anything that is pure logic, pure data, or does I/O gets `nonisolated`
on the *type* declaration (which covers its members and synthesized
conformances) — not on individual methods after the compiler complains:

```swift
nonisolated enum WalkPolicy { ... }                       // pure decision logic
nonisolated struct TimerRecord: Codable, Equatable, Sendable { ... }
nonisolated enum ChatAPIKeyStore { ... }                  // keychain I/O
nonisolated enum Log { ... }                              // os.Logger
```

Concretely: policy/decision types (`electragne/Pet/*Policy.swift`), tool
request/response/error value types (`electragne/Tools/`), parsers, stores, and
clients are all `nonisolated`. `@MainActor` belongs on views, window
controllers, `AppDelegate`, `AppModel`, `PetViewModel` — where it is already
implied and stating it is redundant.

Grep for `nonisolated` in `electragne/Tools/` for the house style. If you find
yourself adding `nonisolated` to one method to silence a warning, the type
should have been `nonisolated` in the first place — annotate the type instead.

Use `nonisolated(unsafe)` only for mutable statics already protected by an
explicit lock, with a comment naming the lock (see `ChatAPIKeyStore`).

## Layout

```
electragne/Animation/  sprite sheet parsing + playback (animations.xml)
electragne/Pet/        movement: policies (pure) + PetViewModel/windows (MainActor)
electragne/Chat/       providers (Gemini/Ollama/OpenAI-compatible), bubble UI, memory
electragne/Tools/      chat-callable tools: Gmail, Calendar, Reminders, MCP, timers…
electragne/Google/     OAuth + API transport
electragne/Support/    logging, caches, small utilities
electragneTests/       mirrors the source tree
```

## Conventions

- **Pure policy + thin shell.** Behavior lives in `nonisolated` types taking a
  snapshot struct and returning an action enum (`WalkPolicy`, `JumpPolicy`,
  `ClimbPolicy`, `FallPolicy`). The `@MainActor` view model just applies the
  action. New behavior goes in a policy with unit tests, not in the view model.
- **Tests use Swift Testing** (`import Testing`, `@Suite`, `@Test`, `#expect`),
  not XCTest. Mirror the source path.
- **Never let tests touch the real Keychain.** `ChatAPIKeyStore` detects XCTest
  and forces in-memory backing; the unsigned test build can't match the item's
  ACL, so any real access prompts for the login password. Keep that guard
  intact. Keychain code is also the one place a bug destroys user data
  (see 216c556) — treat a failed read as an error, never as "not present".
- **Log via `Log.*` (`os.Logger`), never `print()`.**
  `log stream --predicate 'subsystem == "org.impolexg.electragne"'`
- Rebuilding the app changes its signature, so the next Keychain read
  re-prompts for authorization. Expected, not a bug.

## Gotchas

- The app is `LSUIElement` — no Dock icon; it lives in the menu bar.
- UI automation from a terminal-launched agent silently fails (the terminal
  lacks Accessibility permission). Verify window state via CGWindowList or the
  app's own debug output instead.
- `build/` is derived data and gitignored; `Electragne.app` at the repo root is
  a build artifact, also gitignored.
