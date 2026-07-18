# Voice input (STT), spoken responses (TTS), and "Hey Sheep" wake phrase for Electragne

## Context

Electragne's chat bubble (summoned via Cmd-Shift-E) is currently type-only. Goal: talk to the pet and have it talk back. User decisions:

1. **Mic button** in the chat bubble (tap to start/stop; live transcript fills the text field).
2. **Wake phrase**: saying **"hey sheep"** at any time summons the pet to chat and starts voice mode (listening → auto-submit on silence → spoken reply). Gated behind a Settings toggle (default **off** — it keeps the mic hot). Replaces the earlier auto-listen-on-summon toggle idea.
3. **TTS policy: voice-in → voice-out** — responses are spoken aloud only when the question came in by voice; typed questions stay silent.
4. **TTS timing: sentence-by-sentence** while the response streams.

Native frameworks only (`Speech`: SFSpeechRecognizer + AVAudioEngine; `AVFoundation`: AVSpeechSynthesizer). No new dependencies. App is sandboxed with no existing audio code or entitlements.

## New files (2)

### `electragne/Chat/VoiceController.swift`
One class owning all audio (shared by the wake listener and the chat bubble — it must outlive the bubble, see ownership below), plus a pure `SentenceChunker` struct.

- **Chat STT**: `SFSpeechRecognizer` + `AVAudioEngine` (tap on `inputNode` → `SFSpeechAudioBufferRecognitionRequest`).
  - `beginListening(autoSubmit: Bool)` / `stopListening()`.
  - Callbacks: `onTranscript: (String) -> Void` (partial results), `onAutoSubmit: () -> Void`, `onDenied: () -> Void`.
  - Silence detection for auto-submit: restart a ~1.5s timer on each partial result; on fire with non-empty transcript (or `result.isFinal`), call `onAutoSubmit`. `// ponytail: timer heuristic; upgrade to audio-level VAD if it misfires`
  - `beginListening` calls `stopSpeaking()` first (otherwise the mic transcribes the pet's own TTS).
  - Chat recognition leaves `requiresOnDeviceRecognition` at default (server is more accurate; app already needs network for chat).
- **Wake listening**: `startWakeListening(onWake: () -> Void)` / `stopWakeListening()`.
  - Continuous on-device recognition (`requiresOnDeviceRecognition = true` — always-on audio must not stream to Apple; also avoids server duration limits). Guard on `supportsOnDeviceRecognition`; if unsupported, report via `onDenied`-style callback and leave the feature off.
  - Scan partial transcripts case-insensitively for the phrase; accept common misrecognitions: `"hey sheep"`, `"hay sheep"`, `"a sheep"`. `// ponytail: substring match on a small alias list; add fuzzier matching only if recognition misses in practice`
  - Recognition tasks end (~1-minute limit, errors, `isFinal`): restart the request/task in the completion handler. A wake phrase split across a restart boundary is missed — acceptable.
  - One mode at a time: `beginListening` (chat) suspends wake listening; `stopListening` resumes it if the toggle is on. `speak(...)` also suspends wake listening until TTS finishes (`AVSpeechSynthesizerDelegate didFinish`) so the pet doesn't wake itself.
- **TTS**: one retained `AVSpeechSynthesizer`; `speak(_ sentence: String)` (synthesizer queues utterances natively — streaming is just one `speak` per sentence) and `stopSpeaking()` (`.immediate`). Default system voice.
- **Permissions**: `requestPermissionsIfNeeded(completion:)` — `SFSpeechRecognizer.requestAuthorization` + `AVAudioApplication.requestRecordPermission` (check deployment target; fall back to `AVCaptureDevice.requestAccess(for: .audio)` if < macOS 14). On denial call `onDenied`, do nothing else.
- **`SentenceChunker`** (pure, testable):
  ```swift
  struct SentenceChunker {
      mutating func consume(_ token: String) -> [String]  // completed sentences
      mutating func flush() -> String?                    // trailing remainder
  }
  ```
  Buffer + split on `.` `!` `?` `\n` followed by whitespace/end; keep incomplete tail. Skip abbreviation handling ("Dr.") — an early TTS pause is harmless.
  Also a pure `static func matchesWakePhrase(_ transcript: String) -> Bool` (testable without audio).

### `electragneTests/Chat/VoiceControllerTests.swift`
Swift Testing (`@Test`/`#expect`): SentenceChunker — fragment reassembly, multi-sentence token, flush of trailing text, empty stream; wake-phrase matcher — aliases, case, mid-sentence, negatives.

## Ownership / wiring

`AppModel` (electragne/App/AppModel.swift) owns the single `VoiceController` and passes it into `ChatBubbleWindowController.init`. `AppDelegate.applicationDidFinishLaunching` starts wake listening if the preference is on; the Settings toggle starts/stops it live. `onWake` → same path as the hotkey: `summonPetToChat()` (AppDelegate.swift:164), then tell the bubble controller to enter voice mode (`beginVoiceCapture()` below).

## Existing-file edits

- **`electragne/Chat/Bubble/ChatBubbleModel.swift`** — add `var isListening = false` (mic button state). Denial message reuses existing `model.status`.

- **`electragne/Chat/Bubble/ChatBubbleViews.swift`** — mic button in the input HStack (lines 78–91) before the send button: new prop `onToggleMic: () -> Void`; icon `model.isListening ? "mic.fill"` (red) `: "mic"`; accessibility label.

- **`electragne/Chat/Bubble/ChatBubbleWindowController.swift`** — takes the shared `VoiceController` in init. This is the whole voice-gating mechanism:
  - Wire `onToggleMic` at the `ChatBubbleView(...)` construction (line 73).
  - `toggleMic()`: listening → `stopListening()`; else permissions → `beginListening(autoSubmit: false)` with `onTranscript = { model.text = $0 }`, `onDenied` → `model.status = "Enable microphone in System Settings → Privacy & Security"`.
  - `beginVoiceCapture()` (public; called after wake-phrase summon): permissions → `beginListening(autoSubmit: true)`; `onAutoSubmit` guards non-empty trimmed text then `startStream(userMessage: model.text, spoken: true)` and clears `model.text`.
  - `startStream(userMessage:...)` (line 152) gains `spoken: Bool = false`. Voice paths (auto-submit callback; submit while `model.isListening`) pass `true`; typed `.onSubmit` stays `false`.
  - In `startStream`: always `voice.stopListening()` + `voice.stopSpeaking()` (new message interrupts speech). If `spoken`: `var chunker = SentenceChunker()`; inside the existing `onToken` closure (line 189) add `chunker.consume(token).forEach(voice.speak)`; after the stream completes, `chunker.flush().map(voice.speak)`.
  - `teardownStream()` (line 274): add `voice.stopListening(); voice.stopSpeaking()` — covers dismiss, Esc (routes via `onExitCommand → onDismiss → dismiss`), new chat, and chat switch in one place. (stopListening resumes wake listening per VoiceController's mode logic.)

- **`electragne/App/AppModel.swift`** — create and hold the `VoiceController`, pass to bubble controller.

- **`electragne/App/AppDelegate.swift`** — on launch, if `UserPreferences.wakePhraseEnabled()` → permissions → `voice.startWakeListening { summonPetToChat(); …beginVoiceCapture() }`.

- **`electragne/Chat/UserPreferences.swift`** — one key + accessor in existing style: `wakePhraseEnabledKey = "wakePhraseEnabled"`, `static func wakePhraseEnabled(...) -> Bool` (default false).

- **`electragne/App/SettingsView.swift`** — one `Toggle("Listen for \"Hey Sheep\"")` with a caption noting the mic stays on, in the General tab's Personalization section (~line 62); toggling starts/stops wake listening live.

- **`electragne/electragne.entitlements`** — add `com.apple.security.device.audio-input` = true.

- **`electragne.xcodeproj/project.pbxproj`** — in both Debug (~line 402) and Release (~line 441) config blocks, alongside existing usage strings:
  - `INFOPLIST_KEY_NSMicrophoneUsageDescription`
  - `INFOPLIST_KEY_NSSpeechRecognitionUsageDescription`

## Sequencing

1. Entitlement + pbxproj usage strings (unblocks runtime testing).
2. `VoiceController.swift` incl. `SentenceChunker` + wake matcher + tests.
3. `UserPreferences` key + Settings toggle.
4. Wire mic button + `spoken` gating in bubble controller/views.
5. Wake listener wiring in AppModel/AppDelegate.
6. Verification pass.

## Deliberate cuts

- No voice picker / rate config — system default voice.
- No custom wake-word model (Porcupine etc.) — SFSpeechRecognizer transcript matching is free and dependency-less; accuracy ceiling noted in code.
- Barge-in = "starting the mic stops TTS" (needed anyway to avoid self-transcription); true mid-speech voice-activity interrupt is speculative.
- Gating (`spoken` flag) is a one-line closure — verified manually, not refactored for injectability.

## Verification

- **Automated**: `./test.sh` — chunker + wake-matcher tests plus existing suite green.
- **Manual** (`./build.sh`, run `Electragne.app`; reset TCC with `tccutil reset Microphone <bundle-id>` / `tccutil reset SpeechRecognition <bundle-id>` for fresh-prompt testing):
  1. First mic use → both permission prompts appear (usage strings render).
  2. Tap mic, speak → live transcript fills the field; submit → response is spoken sentence-by-sentence while streaming.
  3. Typed question → silent response.
  4. Enable "Hey Sheep" toggle → say "hey sheep" with bubble closed → pet summons, listens; speak, pause → auto-submits and speaks reply; wake listening resumes afterward.
  5. Pet speaking doesn't retrigger the wake phrase or transcribe itself.
  6. Esc/dismiss/new-chat mid-speech → TTS and mic stop; wake listening resumes.
  7. Deny mic permission → status shows the System Settings hint, no crash.
  8. Toggle off → mic indicator (menu bar orange dot) goes away.
