---
title: AIR Hotkey Trigger State Machine
status: active
date: 2026-06-04
origin: delegated planning request
---

# AIR Hotkey Trigger State Machine

## Problem Frame

AIR already has working global hotkeys, but trigger behavior is split across `AutoImproveRecorder/Support/HotKeyCenter.swift`, `AutoImproveRecorder/AppState.swift`, `AutoImproveRecorder/Models.swift`, `AutoImproveRecorder/AppDelegate.swift`, and `AutoImproveRecorder/UI/SettingsView.swift`. The current implementation mixes low-level Carbon delivery, app recording phases, and walkie-talkie bookkeeping (`activeWalkieTalkieRecording`, `walkieTalkieRecordingLatched`, `walkieTalkieKeyIsDown`, `isStartingRecording`) in `AppState`.

The next version should make recording intent explicit and testable. The best AIR design is a small pure hotkey intent reducer between keyboard capture and recording side effects. `HotKeyCenter` should report facts. A new trigger controller should decide whether those facts mean start, stop, latch, cancel, discard, or ignore. `AppState` should execute those commands and keep the existing audio/transcription pipeline.

Monologue Hopper strings are useful inspiration for naming and edge-case coverage: `HotKeyProcessor`, `HotKeyTimingPolicy`, `HotKeyFlow`, `pressAndHold`, `doubleTapLock`, buffered stop, minimum duration discard, and cancel hotkey. AIR should not copy Monologue. AIR should use those ideas to build a clearer local model that fits the existing recorder pipeline and menu-bar HUD.

## Scope

In scope:

- Define AIR's desired trigger behavior for hold-to-talk, toggle, latch, cancel, accidental taps, and processing-busy cases.
- Introduce a finite-state model and event vocabulary that can be tested without Carbon or AVFoundation.
- Define timing thresholds and where they live.
- Define the separation between low-level keyboard capture and high-level recording intent.
- Cover repeats, release during startup, double-presses, busy states, app focus changes, and lost release events.
- Define logging, diagnostics, unit tests, and manual verification.

Out of scope for this plan:

- Implementing code in this turn.
- Replacing the audio recorder, transcription engines, dictionary feature, delivery rules, or HUD design.
- Copying Monologue implementation details.

## User-Facing Behavior

Default mode should be `Hold to talk` with smart latch:

- Press the recording hotkey to start opening the microphone.
- Keep holding while speaking.
- Release after a real recording has started to send the recording for transcription and cleanup.
- Tap too quickly by accident and AIR cancels/discards silently with a small non-intrusive status, no transcript, no paste, no clipboard mutation.
- Double-press the recording hotkey within the latch window to enter hands-free latch. In latch, release no longer stops. Press the recording hotkey again to send.
- Press `Esc` while starting, recording, or latched to cancel and discard audio.
- If AIR is transcribing, improving, or delivering, hotkey presses are ignored with a concise status and diagnostic log. They should not start a second recording or cancel in-flight processing.

`Toggle` mode should stay available:

- First press starts.
- Second press sends.
- `Esc` cancels.
- Releases are ignored except to clear key-down bookkeeping.
- Repeated key-down events are ignored.
- Accidental-tap discard should not apply to intentional toggle stop unless the final audio duration is below the global minimum recording duration.

Latch should be a first-class trigger state, not an `AppState` display flag:

- The preferred latch gesture is primary-hotkey double-press because it does not depend on registering Space globally.
- The existing active-only Space latch can be retained as an alternate `latchRequested` event if it feels good in manual testing, but it should route through the same reducer path.
- HUD copy should be derived from trigger state: held recording says release to send; latched recording says press hotkey to send; all active states say `Esc` cancels.

## Proposed Files

New support files:

- `AutoImproveRecorder/Support/RecordingTriggerController.swift`
- `AutoImproveRecorder/Support/RecordingTriggerModels.swift`
- `AutoImproveRecorder/Support/RecordingTriggerDiagnostics.swift` if diagnostics are not small enough to keep with the controller

Existing files to change in a later implementation:

- `AutoImproveRecorder/Support/HotKeyCenter.swift`
- `AutoImproveRecorder/AppState.swift`
- `AutoImproveRecorder/Models.swift`
- `AutoImproveRecorder/AppDelegate.swift`
- `AutoImproveRecorder/UI/SettingsView.swift`
- `AutoImproveRecorder/UI/WindowControllers.swift`
- `AutoImproveRecorder.xcodeproj/project.pbxproj`
- `Package.swift`

Test files to add:

- `Tests/AutoImproveRecorderTriggerCoreTests/RecordingTriggerControllerTests.swift`
- `Tests/AutoImproveRecorderTriggerCoreTests/RecordingTriggerTimingPolicyTests.swift`

The current SwiftPM package only exposes dictionary/archive support. Future implementation should either add a second testable support target for trigger core or broaden the existing support package with exclusions for AppKit/Carbon/AVFoundation-only files. The trigger reducer itself should depend only on Foundation.

## Event Vocabulary

Low-level capture events from `HotKeyCenter`:

- `recordHotKeyDown(receivedAt: Date, eventID: UInt64, isRepeat: Bool)`
- `recordHotKeyUp(receivedAt: Date, eventID: UInt64)`
- `cancelHotKeyDown(receivedAt: Date)`
- `latchHotKeyDown(receivedAt: Date)`
- `flagsOrFocusInvalidated(receivedAt: Date, reason: TriggerInvalidationReason)`

Recorder lifecycle events from `AppState`:

- `startAccepted(startID: UUID, requestedAt: Date)`
- `startFailed(startID: UUID, error: String)`
- `recordingBegan(startID: UUID, recordingID: UUID, audioURL: URL, beganAt: Date)`
- `stopAccepted(recordingID: UUID, requestedAt: Date)`
- `processingBegan(recordingID: UUID)`
- `processingFinished(recordingID: UUID)`
- `processingFailed(recordingID: UUID, error: String)`
- `cancelCompleted(reason: TriggerCancelReason)`

Timer events owned by the trigger controller:

- `startupReleaseGraceElapsed(token: UUID, now: Date)`
- `doublePressWindowElapsed(token: UUID, now: Date)`
- `lostReleaseWatchdogElapsed(token: UUID, now: Date)`
- `minimumDurationElapsed(token: UUID, now: Date)`

Commands emitted by the reducer:

- `requestStart(source: TriggerStartSource, requestedAt: Date)`
- `requestStop(reason: TriggerStopReason, requestedAt: Date, shouldTranscribe: Bool)`
- `requestCancel(reason: TriggerCancelReason)`
- `enterLatch`
- `exitLatch`
- `scheduleTimer(kind: TriggerTimerKind, token: UUID, firesAt: Date)`
- `cancelTimer(kind: TriggerTimerKind, token: UUID?)`
- `showStatus(String)`
- `log(TriggerDiagnosticEvent)`
- `ignore(reason: TriggerIgnoreReason)`

This command layer is the seam: tests assert commands; `AppState` maps commands to `startRecording`, `stopRecording`, `cancelRecording`, visual updates, and timer scheduling.

## Finite-State Model

Use a trigger-specific state separate from `RecorderPhase`.

States:

- `idle(clean: Bool)`
- `starting(startID: UUID?, startedFrom: TriggerStartSource, keyDown: Bool, pressedAt: Date, releasedDuringStartupAt: Date?)`
- `recordingHeld(recordingID: UUID, pressedAt: Date, beganAt: Date, keyDown: Bool)`
- `recordingLatched(recordingID: UUID, beganAt: Date, latchSource: TriggerLatchSource)`
- `pendingBufferedStop(recordingID: UUID, beganAt: Date, releasedAt: Date, pendingStopToken: UUID)`
- `stopping(recordingID: UUID, stopReason: TriggerStopReason)`
- `processingBusy(recordingID: UUID?)`
- `suppressedUntilRelease(reason: TriggerSuppressReason)`

Core transitions:

- `idle` + non-repeat record down in hold mode -> `starting`, emit `requestStart`.
- `starting` + record up before `recordingBegan` -> remember `releasedDuringStartupAt`; do not call stop yet because no audio URL exists.
- `starting` + `recordingBegan` + key still down -> `recordingHeld`.
- `starting` + `recordingBegan` + release already seen -> classify elapsed time. If below accidental tap threshold or minimum recording duration, emit cancel/discard. Otherwise emit stop immediately or after a short startup-release grace.
- `recordingHeld` + record up -> if held duration is below quick-tap threshold, enter `pendingBufferedStop` for the double-press window; otherwise emit stop.
- `pendingBufferedStop` + record down within double-press window -> `recordingLatched`, cancel pending stop, emit `enterLatch`.
- `pendingBufferedStop` + timer elapsed -> emit stop if duration is sufficient; emit cancel/discard if below minimum duration.
- `recordingHeld` + latch hotkey -> `recordingLatched`.
- `recordingLatched` + record down -> emit stop.
- Any active starting/recording/latch state + cancel hotkey -> emit cancel/discard.
- `stopping` + processing began -> `processingBusy`.
- `processingBusy` + processing finished/failed -> `idle(clean: true)`.
- Any state + lost release watchdog -> if the physical key appears up or the app can no longer trust key state, emit stop/cancel according to current duration and state.

`clean` means all keys involved in a previous trigger have fully released. If AIR sees a non-matching chord or missed release while active, it can move to `suppressedUntilRelease` so a later repeat does not unexpectedly stop or latch.

## Timing Policy

Add `RecordingTriggerTimingPolicy` as a value type with defaults and test injection:

- `accidentalTapThreshold`: 0.22 seconds. A press/release shorter than this in hold mode is treated as accidental unless it becomes part of a double-press latch.
- `doublePressLatchWindow`: 0.32 seconds. A second primary-hotkey down inside this window after a quick release latches the recording.
- `startupReleaseGrace`: 0.12 seconds. If release arrives while the recorder is still starting, give the start path a tiny window to produce an audio URL before deciding stop/cancel.
- `minimumRecordingDuration`: 0.70 seconds for transcription. Anything shorter is discarded without transcription; this protects against microphone-open blips and key slips.
- `lostReleaseWatchdog`: 45 seconds for held mode. If a held recording runs this long with no latch and no release, log loudly and either auto-latch or show an urgent HUD state. Opinionated default: auto-latch at watchdog rather than stop, because stopping and pasting a long accidental capture is worse than leaving the user in visible control.
- `repeatDebounce`: 0.05 seconds. Repeated down events for the same hotkey while the key is already down are ignored.

Configurability:

- Store the policy defaults in `RecordingTriggerTimingPolicy.default`.
- Allow test code to inject arbitrary values.
- Persist user-facing trigger options in `UserDefaults`: trigger mode, smart latch enabled, accidental tap guard enabled.
- Keep raw timing controls out of the normal Settings UI initially. If needed, add an `Advanced Trigger Timing` disclosure in `SettingsView` with reset-to-defaults, but do not make casual users tune milliseconds to get reliable behavior.
- Add a debug-only diagnostics export that includes the effective policy.

## Separation of Responsibilities

`HotKeyCenter` should only:

- Register and unregister Carbon hotkeys.
- Convert Carbon events into typed `HotKeyCenter.Event` values.
- Preserve `receivedAt` and hotkey identity.
- Filter obvious Carbon repeat/noise if available, but still mark `isRepeat`.
- Avoid knowing whether AIR is starting, recording, latched, or processing.

`RecordingTriggerController` should:

- Own the trigger state machine.
- Classify press, release, latch, cancel, and timer events.
- Emit commands, never start audio itself.
- Have deterministic tests with a fake clock.

`AppState` should:

- Keep `RecorderPhase` as the audio/transcription/delivery pipeline phase.
- Translate reducer commands into existing `startRecording`, `stopRecording`, and `cancelRecording` side effects.
- Feed lifecycle events back into the trigger controller when start/record/stop/process outcomes occur.
- Publish display values such as `walkieTalkieIsLatchedForDisplay` from trigger state, eventually renaming it to something mode-neutral like `recordingIsLatchedForDisplay`.

`AppDelegate` should:

- Wire `HotKeyCenter` events to `AppState.handleHotKeyEvent`.
- Stop knowing about latch behavior directly.
- Keep menu item behavior as an app-level toggle action, routed through the same trigger controller where possible.

`SettingsView` and `Models` should:

- Expand `RecordingTriggerMode` if needed to distinguish `holdToTalk`, `toggle`, and `holdWithSmartLatch`.
- Keep labels plain: `Hold to talk`, `Toggle`, `Hold + double-press latch`.
- Show the selected recording hotkey and a short latch hint without implementation prose.

## Edge Cases

Repeats:

- Ignore repeat down events when already key-down in `starting`, `recordingHeld`, or `pendingBufferedStop`.
- Log repeats at debug level only.

Release during startup:

- Record the release time in `starting`.
- When `recordingBegan` arrives, classify based on the original press duration and effective recording duration.
- If the release was very quick, cancel/discard without transcribing.
- If the user held long enough but startup was slow, stop immediately after the audio URL exists.

Double-presses:

- A quick release does not immediately stop. It starts a buffered stop timer.
- A second press before that timer fires enters latch.
- If the second press arrives after the timer, it should start a new recording only after the previous stop has moved into processing/idle rules; it should not race stop/start.

Processing-busy states:

- During `.transcribing`, `.improving`, and `.delivering`, hotkey down emits `ignore(processingBusy)`.
- Do not let `Esc` cancel processing unless AIR later adds explicit cancellation for transcription/improvement tasks.
- Show a short status such as `Still finishing the last recording.`

App focus changes:

- Global hotkeys are focus-independent, so normal app activation changes should not stop a recording.
- If Settings hotkey capture is active, disable or suppress global recording hotkeys to avoid self-triggering.
- If Accessibility paste focus changes during recording, leave recording alone; delivery already resolves focused target at paste time.

Lost release events:

- Start a watchdog when entering held recording.
- If the key-up never arrives, the HUD must not remain ambiguous forever.
- On watchdog, move held recording into latched state with a status like `Recording latched after long hold.` and log `lostReleaseWatchdog`.
- When any later key-up arrives, clear dirty key state but do not stop the latched recording.

Cancel:

- `Esc` cancels `starting`, `recordingHeld`, `recordingLatched`, and `pendingBufferedStop`.
- Cancel should unregister active-only cancel/latch hotkeys, stop audio if any, delete active archive drafts, clear realtime buffers, hide the HUD, and prewarm the next draft, matching the intent of current `cancelRecording`.

Minimum duration discard:

- Stop paths should ask the trigger controller whether the recording is long enough to transcribe.
- For below-minimum audio, stop and delete the draft without entering `.transcribing`.
- The user-facing status should be quiet: `Recording discarded.`
- Diagnostics should include duration, threshold, trigger mode, and reason.

## Logging and Diagnostics

Use `OSLog` categories:

- `HotKeyCapture` for Carbon registration and event delivery.
- `RecordingTrigger` for reducer transitions and command decisions.
- `RecordingStartup` for existing microphone-open timings.

Every trigger transition log should include:

- previous state
- event
- next state
- command summary
- trigger mode
- key-down status
- press duration when available
- recording duration when available
- active start/recording IDs when available

Add an in-memory ring buffer, for example the last 100 trigger diagnostic events, exposed through Settings or copied with a diagnostics button. This should be redacted and local only. It is for debugging user reports like "I released but it kept recording" or "I double-tapped and it stopped."

## Focused Tests

`RecordingTriggerControllerTests` should cover:

- Hold mode starts on first press.
- Repeated key-down while starting is ignored.
- Release during startup is remembered and stops after `recordingBegan`.
- Quick press/release below accidental threshold cancels/discards and does not transcribe.
- Hold longer than threshold then release stops and transcribes.
- Quick release then second press within double-press window enters latch.
- Buffered stop commits when no second press arrives.
- Latched recording ignores release and stops on next primary hotkey press.
- Space latch, if retained, routes through the same latch transition.
- `Esc` cancels starting, held recording, pending buffered stop, and latched recording.
- Toggle mode ignores releases and stops on second press.
- Processing-busy ignores primary hotkey and does not emit start/stop/cancel.
- Lost release watchdog moves held recording to latched state.
- Start failure resets to idle and emits a diagnostic.
- Minimum duration discard wins over normal stop.

`RecordingTriggerTimingPolicyTests` should cover:

- Default thresholds match documented values.
- Boundary behavior at exactly threshold, just below, and just above.
- Injected policy values affect classification deterministically.
- Effective policy can be encoded into diagnostics without requiring AppKit.

Existing dictionary tests should stay untouched. Trigger tests should run with `swift test` once the package target is wired.

## Manual Verification

Add a section to `Docs/MANUAL_TEST_CHECKLIST.md` after implementation:

- In hold mode, press and hold hotkey, speak, release, confirm transcription starts.
- Quick tap the hotkey, confirm no paste, no clipboard change, and no archive record is kept except any intentionally retained diagnostic.
- Press, quick release, press again within the latch window, release, confirm recording stays active and HUD says latched.
- Press hotkey again while latched, confirm recording sends.
- Press `Esc` while starting and while recording, confirm audio is discarded and no transcription runs.
- In toggle mode, press to start, release, confirm recording continues; press again, confirm send.
- While transcribing/improving/delivering, press hotkey, confirm no second recording starts and status explains AIR is finishing.
- Trigger a release-during-startup case by using a cold microphone path; confirm AIR does not leave the microphone open.
- Leave hold mode recording active past the watchdog; confirm it visibly latches rather than silently stopping.
- Change the recording hotkey in Settings and confirm global capture does not fire while the recorder control is listening for a shortcut.

## Sequencing

1. Add the pure trigger models, timing policy, reducer, diagnostics, and tests.
2. Wire `Package.swift` so trigger tests can run without AppKit/Carbon.
3. Adapt `HotKeyCenter` to emit typed events while preserving existing registration behavior.
4. Route `AppDelegate` hotkey callbacks through `AppState.handleHotKeyEvent`.
5. Move walkie-talkie booleans out of `AppState` into trigger state or derived display state.
6. Feed recorder lifecycle events from `startRecordingFlow`, `stopRecording`, `cancelRecording`, and processing completion back into the trigger controller.
7. Update Settings labels and optional smart-latch preference.
8. Update HUD copy in `WindowControllers` to reflect held vs latched state.
9. Add manual verification checklist items and run live installed-app checks.

## Main Design Decision

Do not keep adding booleans to `AppState`. The correct AIR shape is a pure, reducer-style trigger controller with explicit states and timing policy. `AppState` already has enough responsibility: microphone startup, archive drafts, realtime fallback, transcription, cleanup, paste, menu updates, and HUD state. Pulling trigger intent into a small testable support unit is the highest-leverage change because it makes the hard edge cases reviewable before audio or UI side effects happen.
