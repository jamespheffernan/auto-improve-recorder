# AIR App Subsystem Boundaries Plan

Date: 2026-06-04

## Scope

This is a design sketch for Auto Improve Recorder's app subsystem boundaries. It is based on the current repo state, especially:

- `AutoImproveRecorder/AppState.swift`
- `AutoImproveRecorder/AppDelegate.swift`
- `AutoImproveRecorder/Support/AccessibilityPasteController.swift`
- `AutoImproveRecorder/Support/AppDeliveryRules.swift`
- `AutoImproveRecorder/Support/KeychainStore.swift`
- `AutoImproveRecorder/Support/TranscriptArchiveStore.swift`
- `AutoImproveRecorder/Support/DictionaryStore.swift`
- `AutoImproveRecorder/Recording/AudioRecorder.swift`
- `AutoImproveRecorder/Engines/*`
- `AutoImproveRecorder/UI/SettingsView.swift`

Monologue artifacts were used only as inspiration. The useful lesson is not to copy Monologue's structure, but to keep live side effects behind typed clients and let feature code coordinate flows. AIR should stay smaller and more direct.

## Current Shape

`AppState` is currently the application brain and the side-effect hub. It owns SwiftUI-observed state, hot-key behavior, recording lifecycle, microphone permission caching, archive draft prewarming, realtime OpenAI setup, transcription provider selection and fallback, improvement provider selection, dictionary snapshots, delivery policy, pasteboard side effects, diagnostics persistence, and most settings persistence.

That is understandable for the current product stage, but it is now starting to hide distinct responsibilities:

- Recording start/stop and prewarm decisions are tangled with UI phase updates.
- Transcription fallback policy lives inside `AppState` instead of a typed transcription service.
- Delivery policy is mostly pure in `AppDeliveryRules.swift`, but the live paste/accessibility side effects still sit directly in `AppState`.
- Settings bind directly from `SettingsView` into `AppState`, and many `didSet` observers synchronously write `UserDefaults` or Keychain.
- Archive and dictionary stores are real app services, but their usage is still orchestrated inline.
- Diagnostics are provider-specific and currently skewed toward OpenAI realtime.

The target is not a broad rewrite. The target is a small set of typed service seams that make the app easier to test, safer to evolve, and less likely to regress the hot path.

## Opinionated Target

Keep `AppState` as the user-flow orchestrator.

`AppState` should continue to own:

- Published UI state: `phase`, `session`, `statusMessage`, `processingVisualState`, preview/settings visibility, and display toggles.
- The high-level flow: start, stop, cancel, transcribe, improve, deliver, reset visuals.
- Hot-key intent handling: walkie-talkie vs toggle behavior, latch state, and cancel semantics.
- User-visible status language at flow boundaries.
- MainActor coordination and callbacks into window/menu controllers.

Move logic out when it is one of these:

- Direct macOS or process side effects: permissions, pasteboard, Accessibility, Keychain, UserDefaults, file archives, local runtime process probing.
- Provider selection and fallback policy.
- Pure policy or state transformation that can be tested without launching the app.
- Diagnostics collection, persistence, and readiness checks.

Do not introduce a full reducer architecture or a large dependency framework. AIR is a compact menu-bar utility; the best version is service-oriented and testable, not abstract for its own sake.

## Proposed Boundaries

### `AppEnvironment`

Add one lightweight dependency container, passed into `AppState` with a `.live` default.

Suggested shape:

```swift
struct AppEnvironment {
    var recording: RecordingClient
    var permissions: PermissionsClient
    var transcription: TranscriptionService
    var improvement: ImprovementService
    var delivery: DeliveryService
    var settings: SettingsStore
    var secrets: SecretsStore
    var archive: TranscriptArchiveClient
    var dictionary: UserDictionaryStore
    var diagnostics: DiagnosticsStore
    var now: () -> Date
    var uuid: () -> UUID
}
```

This should be boring Swift, not a framework. `AppState.shared` can remain:

```swift
static let shared = AppState(environment: .live)
```

Tests can construct `AppState(environment: .test(...))` once the initializer is made internal.

### Recording

Current anchor: `AudioRecorder`.

Introduce:

```swift
protocol RecordingClient {
    var hasMicrophonePermission: Bool { get }
    func requestMicrophonePermission() async throws
    func prepareForFastStartIfAuthorized()
    func startRecording(
        at url: URL,
        bufferSize: AVAudioFrameCount,
        streamHandler: AudioRecorder.AudioBufferHandler?,
        onFirstBuffer: (() -> Void)?
    ) throws -> URL
    func stopRecording() -> URL?
    func releaseWarmResources()
}
```

`AudioRecorder` can become `AudioRecorderClientLive` or be wrapped by one. Keep the existing `AudioRecorder` implementation largely intact because it contains performance-sensitive work: file-open queue, fast buffer size, HAL prewarm, and first-buffer logging.

`AppState` should still decide when a recording begins or ends. The client should only own microphone/audio engine mechanics.

### Permissions

Current anchors: `AudioRecorder.requestMicrophonePermission`, `AccessibilityPasteController.isTrusted`, Apple Speech availability errors, Apple Foundation Models availability errors, and possibly screen capture only if AIR later needs screen context.

Introduce:

```swift
struct PermissionStatus: Equatable {
    var microphone: PermissionState
    var accessibility: PermissionState
    var appleSpeech: PermissionState
    var appleIntelligence: PermissionState
}

protocol PermissionsClient {
    func snapshot(promptForAccessibility: Bool) async -> PermissionStatus
    func requestMicrophone() async throws
    func requestAccessibilityPrompt()
}
```

This should power a Settings diagnostics section and delivery failure messages. Avoid Monologue-style screen capture unless AIR actually adds screen-aware prompting. For now, screen capture belongs in a future optional `ScreenContextClient`, not in the initial carve-out.

### Delivery

Current anchors: `AccessibilityPasteController`, `AppDeliveryRules.swift`, `AppState.completeWithText`.

Keep `DeliveryPolicyResolver` pure. It is already the right shape.

Introduce:

```swift
struct DeliveryRequest: Equatable {
    var text: String
    var globalSettings: GlobalCompletionSettings
    var rules: [AppDeliveryRule]
}

struct DeliveryResult: Equatable {
    var visualState: ProcessingVisualState
    var statusMessage: String
    var context: DeliveryContext
    var policy: ResolvedDeliveryPolicy
    var errorSummary: String?
}

protocol DeliveryService {
    func focusedContext(promptForPermission: Bool) -> DeliveryContext
    func deliver(_ request: DeliveryRequest) async -> DeliveryResult
}
```

The live service should use `AccessibilityPasteController` and `NSPasteboard`. `AppState.finishProcessing()` should only switch to `.delivering`, call `delivery.deliver`, then apply `DeliveryResult`.

That lets tests cover:

- WhatsApp suppresses submit.
- Missing Accessibility falls back to copy when copying is enabled.
- App-specific do-not-paste creates "Text ready" or "Copied" messages.
- Delivery status messages do not drift from visual states.

### Transcription

Current anchors: `TranscriptionEngine`, `OpenAIRealtimeTranscriber`, `OpenAIAudioTranscriber`, `WhisperCppTranscriber`, `ParakeetTranscriber`, `ParakeetCppTranscriber`, `AppleLocalAudioTranscriber`, and `AppState.transcribe`.

Introduce a service above individual engines:

```swift
struct TranscriptionRequest {
    var audioURL: URL
    var mode: TranscriptionMode
    var apiKey: String
    var parakeetRuntime: ParakeetRuntime
    var dictionarySnapshot: String
    var streamingTranscriber: OpenAIRealtimeTranscriber?
}

struct TranscriptionServiceResult: Equatable {
    var transcript: String
    var engineName: String
    var diagnostics: [DiagnosticEvent]
    var statusUpdates: [String]
}

protocol TranscriptionService {
    func prepareRealtimeIfNeeded(
        mode: TranscriptionMode,
        apiKey: String,
        dictionarySnapshot: String
    ) async -> RealtimePreparationResult

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionServiceResult
    func warmUp(settings: AppSettingsSnapshot) async
}
```

This service should own the provider fallback matrix:

- `.openAIAPI` uses `OpenAIAudioTranscriber`.
- `.localWhisper` uses `WhisperCppTranscriber`.
- `.appleLocal` uses `AppleLocalAudioTranscriber`.
- `.localParakeetCppFast` uses `ParakeetCppTranscriber(.fast110M)`.
- `.localParakeetCppRecommended` uses `ParakeetCppTranscriber(.recommended06B)`.
- `.localParakeet` uses Python `ParakeetTranscriber`.
- `.fastest` prefers realtime OpenAI if prepared, verifies suspicious short transcripts, falls back to OpenAI API on realtime finalize failure, and falls back to Parakeet.cpp Recommended when no OpenAI key is available.

`AppState` should not know the construction details for every engine. It should know that transcription is in progress, which dictionary snapshot was used, and which final result came back.

### Improvement

Current anchors: `ImproveEngine`, `OpenAIImproveEngine`, `GeminiImproveEngine`, `AnthropicImproveEngine`, `AppleLocalImproveEngine`, `OllamaImproveEngine`, and `AppState.makeImproveEngine`.

Introduce:

```swift
struct ImprovementRequest {
    var rawTranscript: String
    var mode: ImprovementMode
    var outputMode: OutputMode
    var modificationStrength: Int
    var dictionarySnapshot: String
    var credentials: ProviderCredentials
    var ollama: OllamaSettings
    var onPartialText: @Sendable (String) -> Void
}

protocol ImprovementService {
    func improve(_ request: ImprovementRequest) async throws -> String
    func warmUp(settings: AppSettingsSnapshot) async
}
```

Keep streaming behavior exactly as the current `ImproveEngine.improveStreaming` contract defines: `onPartialText` receives cumulative text and delivery side effects only happen after the final result.

### Settings

Current anchors: `AppState` `@Published` properties with `didSet`, `SettingsView` direct bindings, `KeychainStore`, `UserDefaults`, `AppDeliveryRuleStore`, and realtime diagnostics `UserDefaults` persistence.

Introduce a single settings model:

```swift
struct AppSettingsSnapshot: Codable, Equatable {
    var autoImproveMode: AutoImproveMode
    var recordingTriggerMode: RecordingTriggerMode
    var recordingHotKey: RecordingHotKey
    var transcriptionMode: TranscriptionMode
    var improvementMode: ImprovementMode
    var thresholdWords: Int
    var modificationStrength: Int
    var outputMode: OutputMode
    var parakeetRuntime: ParakeetRuntime
    var ollama: OllamaSettings
    var preferredMicrophoneID: String
    var completion: GlobalCompletionSettings
    var appDeliveryRules: [AppDeliveryRule]
}
```

Add:

```swift
protocol SettingsStore {
    func load() -> AppSettingsSnapshot
    func save(_ snapshot: AppSettingsSnapshot, reason: SettingsSaveReason)
    func saveDebounced(_ snapshot: AppSettingsSnapshot, reason: SettingsSaveReason)
}
```

The live store can continue to use `UserDefaults` at first. The important change is that `AppState` mutates settings in memory and schedules persistence through the store rather than writing synchronously in every property observer.

Recommended behavior:

- Hot-key changes save immediately because they change global registration and must survive relaunch.
- API keys go through `SecretsStore` and are saved on field commit or debounced, not on every keystroke.
- Text fields like Ollama URL/model and Parakeet paths use debounced saves.
- App delivery rules save after row-level changes but through a store method, so tests can assert one logical save.
- Runtime diagnostics persistence stays off the main actor.

Future sync/import/export posture:

- Keep local settings as `AppSettingsSnapshot`.
- Add export/import as JSON around that snapshot.
- Keep secrets out of exported settings by default.
- Reserve a `settingsSchemaVersion` for future migration.
- If sync is added later, sync snapshots and rule/dictionary records, not arbitrary `UserDefaults`.

This gets the useful part of Monologue's `SettingsSyncService` and `LocalSettingsSnapshotCache` without adopting a sync subsystem before AIR needs one.

### Secrets

Current anchor: `KeychainStore`.

Replace static API-key methods with:

```swift
struct ProviderCredentials: Equatable {
    var openAIAPIKey: String
    var geminiAPIKey: String
    var anthropicAPIKey: String
}

protocol SecretsStore {
    func loadCredentials() -> ProviderCredentials
    func saveCredentials(_ credentials: ProviderCredentials)
}
```

The live implementation should wrap `KeychainStore`. Existing methods can remain as compatibility helpers during migration.

### Transcript Archive And History

Current anchor: `TranscriptArchiveStore`.

`TranscriptArchiveStore` has two jobs today: prepare the audio directory and persist truth records plus an index. That is useful, but `AppState` has to know too much about drafts and reconstruction.

Introduce:

```swift
protocol TranscriptArchiveClient {
    func prepareRecording(createdAt: Date) throws -> TranscriptArchiveDraft
    func deleteDraft(_ draft: TranscriptArchiveDraft?)
    func save(_ record: TranscriptArchiveRecord)
    func record(for session: TranscriptSession, metadata: TranscriptArchiveMetadata) -> TranscriptArchiveRecord?
}
```

The archive client should own:

- Pre-created draft slots for the fast microphone path.
- Audio path and record path calculation.
- Record/index truncation rules.
- Archive schema migration.
- Later history listing/search.

`AppState` should own:

- Which active draft belongs to the current user flow.
- When a failed or cancelled draft should be deleted.
- When session changes should be persisted.

History UI should not be built yet unless required. But the archive boundary should make it easy to add later without teaching Settings or Preview about file layout.

### Diagnostics

Current anchors: `lastOpenAIRealtimeDiagnostics`, `NSLog`, `statusMessage`, `RecordingStartup` loggers, local model error descriptions, Settings OpenAI diagnostics section.

Introduce:

```swift
struct DiagnosticEvent: Codable, Equatable, Identifiable {
    var id: UUID
    var createdAt: Date
    var subsystem: DiagnosticSubsystem
    var severity: DiagnosticSeverity
    var summary: String
    var details: String
    var relatedProvider: String?
}

protocol DiagnosticsStore {
    func record(_ event: DiagnosticEvent)
    func latestEvents(limit: Int) -> [DiagnosticEvent]
    func clear()
}
```

Diagnostics should become provider-neutral:

- Microphone permission denied or input unavailable.
- Accessibility not trusted.
- Hot-key registration failure.
- Realtime OpenAI start/finalize failure.
- Local runtime missing executable/model.
- Ollama unavailable or missing model.
- Apple local unavailable reasons.
- Archive save/index failures.

Settings should show "Diagnostics" instead of only "OpenAI diagnostics", with copy-details buttons for the latest provider/runtime issue.

## Suggested File Layout

Keep it simple and close to current files:

- `AutoImproveRecorder/AppEnvironment.swift`
- `AutoImproveRecorder/Services/SettingsStore.swift`
- `AutoImproveRecorder/Services/SecretsStore.swift`
- `AutoImproveRecorder/Services/RecordingClient.swift`
- `AutoImproveRecorder/Services/PermissionsClient.swift`
- `AutoImproveRecorder/Services/TranscriptionService.swift`
- `AutoImproveRecorder/Services/ImprovementService.swift`
- `AutoImproveRecorder/Services/DeliveryService.swift`
- `AutoImproveRecorder/Services/DiagnosticsStore.swift`
- `AutoImproveRecorder/Services/TranscriptArchiveClient.swift`

If `Services/` feels too generic, use narrower folders:

- `Recording/RecordingClient.swift`
- `Transcription/TranscriptionService.swift`
- `Improvement/ImprovementService.swift`
- `Delivery/DeliveryService.swift`
- `Settings/AppSettingsSnapshot.swift`
- `Diagnostics/DiagnosticsStore.swift`

The second option is better once the project grows. For the next migration, either is fine.

## Dependency Injection Strategy

Use initializer injection only.

Do not introduce a global dependency registry. Do not introduce environment keys for every service. Do not move to a reducer architecture unless the app gains multiple independent flows.

Recommended implementation pattern:

```swift
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState(environment: .live)

    private let environment: AppEnvironment

    init(environment: AppEnvironment = .live) {
        self.environment = environment
        let settings = environment.settings.load()
        let credentials = environment.secrets.loadCredentials()
        ...
    }
}
```

The first pass can keep `AppState.shared` and all existing SwiftUI `.environmentObject(AppState.shared)` usage unchanged.

For tests, provide fakes:

- `FakeRecordingClient`
- `FakeDeliveryService`
- `FakeTranscriptionService`
- `FakeImprovementService`
- `InMemorySettingsStore`
- `InMemoryDiagnosticsStore`
- `TemporaryTranscriptArchiveClient`

This makes high-value flows testable without touching AppKit, Accessibility, Keychain, network, or local model processes.

## Permission And Diagnostics UX

Settings should gain a compact "Readiness" or "Diagnostics" section:

- Microphone: granted, denied, not determined, with a button to request or open System Settings.
- Accessibility: trusted/not trusted, with a button that triggers the existing macOS prompt.
- Selected transcription provider: ready/not ready/unknown.
- Selected improvement provider: ready/not ready/unknown.
- Last runtime issue: summary plus copy details.

Do not put this behind a separate advanced screen initially. AIR fails in user-visible ways when these are wrong, so the main Settings view should surface them.

Delivery-specific user messages should remain concrete:

- "Copied. Enable Accessibility for AutoImproveRecorder in System Settings to paste automatically."
- "Pasted. Auto-submit is off for WhatsApp."
- "Text ready. Pasting is off for [app]."

Provider diagnostics should not leak raw API keys or full prompt text. Audio paths and model paths are acceptable because this is a local developer/operator utility, but they should be grouped as details, not menu text.

## Migration Plan

### Phase 1: Extract Pure And Low-Risk Services

No behavior changes.

- Move delivery completion from `AppState.completeWithText` into `DeliveryServiceLive`.
- Keep `DeliveryPolicyResolver` as-is.
- Wrap `KeychainStore` with `SecretsStoreLive`.
- Wrap `TranscriptArchiveStore` with `TranscriptArchiveClientLive`.
- Add targeted tests for delivery results and archive record construction.

### Phase 2: Settings Snapshot

Still no provider behavior changes.

- Add `AppSettingsSnapshot`.
- Load settings through `SettingsStoreLive`.
- Replace most `didSet { defaults.set(...) }` with `updateSettings` methods that mutate snapshot and call immediate or debounced persistence.
- Keep direct SwiftUI bindings initially by binding through `AppState` properties.
- Move realtime diagnostics persistence into `DiagnosticsStoreLive` or `SettingsStoreLive` depending on final diagnostics shape.

This phase directly addresses hot-path risk from synchronous `UserDefaults` writes.

### Phase 3: Transcription And Improvement Services

Move provider construction and fallback policy out of `AppState`.

- `TranscriptionServiceLive` owns engine selection and `.fastest` fallback behavior.
- `ImprovementServiceLive` owns engine selection and warmup.
- `AppState` still owns phase transitions and partial text updates.
- Preserve existing messages first, then improve diagnostics after tests cover behavior.

### Phase 4: Permissions And Diagnostics

- Add `PermissionsClientLive`.
- Add `DiagnosticsStoreLive`.
- Replace `lastOpenAIRealtimeDiagnostics` with provider-neutral diagnostics.
- Update Settings diagnostics UI.
- Keep the menu short: show one latest actionable diagnostics summary, not a full log.

### Phase 5: Optional Feature Modules

Only after the above has landed and stabilized, consider small feature coordinators:

- `RecordingFeature` for hot-key/start/stop/cancel/latch.
- `TranscriptionFeature` for provider lifecycle and transcript result states.
- `DeliveryFeature` for final text delivery.

This is where Monologue's `TranscriptionFeature` and `NotesFeature` structure is inspirational, but AIR should not jump here first. If services already make the flow readable and testable, stop there.

## Tests

Add tests in the package target or create a broader app-core target once services move out of AppKit-heavy files.

High-value tests:

- Delivery policy and delivery result messages for copy, paste, submit, Accessibility denied, and app-specific suppression.
- Settings snapshot load defaults, save round-trip, and schema migration.
- Debounced settings store coalesces repeated text-field changes.
- Secrets store deletes empty keys and does not export secrets.
- Archive client prepares draft, deletes draft, saves record, truncates index rows, and decodes older records.
- Transcription service `.fastest` fallback matrix:
  - no OpenAI key -> Parakeet.cpp Recommended
  - realtime starts and returns valid text -> realtime result
  - realtime returns suspicious short text -> OpenAI API fallback
  - realtime finalize fails -> OpenAI API fallback
- Improvement service selects provider and preserves streaming cumulative-update contract.
- `AppState` flow tests with fakes:
  - start -> stop -> transcribe -> improve -> deliver
  - cancel during starting deletes draft
  - improve failure shows raw transcript and still delivers raw text
  - auto-improve threshold chooses raw/manual/automatic correctly

## Manual Verification

Because AIR is a native macOS utility, keep manual verification concrete:

- Build Debug and Release with `xcodebuild`.
- Launch the app from the built product or installed `/Applications/AutoImproveRecorder.app`, depending on the change.
- Verify hot-key registration and walkie-talkie hold/release behavior.
- Verify microphone permission prompt on a clean permission state if practical.
- Record short and medium dictations using the selected microphone.
- Verify each transcription mode that is configured on this machine:
  - Local Whisper
  - Parakeet.cpp Fast
  - Parakeet.cpp Recommended
  - Fastest with and without OpenAI key
  - OpenAI API if key is configured
  - Apple Speech only if OS/runtime supports it
- Verify Ollama local cleanup with `qwen3.5:0.8b-mlx`.
- Verify delivery into TextEdit, a browser text field, and WhatsApp or another rule-configured app.
- Verify Accessibility disabled behavior falls back to copy/text-ready messaging.
- Verify Settings edits survive relaunch.
- Verify rapid Settings text-field edits do not block recording start.
- Verify transcript archive records are written under Application Support and contain dictionary snapshot, engine name, final text, and audio path.

## Non-Goals

- Do not rewrite the whole app into a reducer architecture.
- Do not move UI files around during the first service extraction.
- Do not introduce screen capture until AIR has a concrete screen-context feature.
- Do not add cloud sync in the first pass.
- Do not copy Monologue naming or structure wholesale.
- Do not change provider prompts, fallback policy, or local model defaults as part of the boundary migration unless a test exposes an existing bug.

## Recommended First Implementation Ticket

Start with delivery and settings, not transcription.

Reason:

- Delivery already has a pure resolver and a small side-effect surface.
- Settings writes are a known hot-path risk and are easier to isolate than provider fallback behavior.
- Transcription is performance-sensitive and has several recent optimizations; move it only after the lower-risk seams prove the pattern.

First ticket:

1. Add `AppEnvironment`.
2. Add `DeliveryService` and move `completeWithText` side effects out of `AppState`.
3. Add `SettingsStore` and `AppSettingsSnapshot` while preserving existing settings behavior.
4. Add tests for delivery and settings snapshot round-trip.
5. Run app build and manual delivery checks.

