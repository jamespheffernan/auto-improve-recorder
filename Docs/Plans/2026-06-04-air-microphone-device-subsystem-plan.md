# AIR Microphone Device Subsystem Plan

Date: 2026-06-04

Scope: planning only. No app code was changed for this pass.

## Current Repo Findings

- `SettingsView` exposes a `Microphone` picker bound to `AppState.preferredMicrophoneID`.
- `AppState.preferredMicrophoneID` is persisted in `UserDefaults` under `preferredMicrophoneID`, and `availableMicrophones` is refreshed manually through `AudioInputDeviceDiscovery.inputDevices()`.
- `AudioInputDeviceDiscovery` currently returns `System default` plus `AVCaptureDevice` audio devices by `uniqueID` and `localizedName`.
- `AudioRecorder.start(...)` ignores `preferredMicrophoneID`. It always uses `engine.inputNode`, reads `input.outputFormat(forBus: 0)`, installs the tap, writes the WAV, and feeds the realtime sink from that same tap.
- `README.md` accurately documents this as an MVP preference surface: recording currently uses the macOS system default input.
- The macOS recording-start path already has useful latency instrumentation in the `RecordingStartup` logger and does not intentionally warm the macOS microphone while idle. Keep that boundary.

Monologue's Hopper artifacts suggest useful concepts: preferences, a resolver, retry cooldown, quarantine, device-change recovery, and clear user-facing microphone state. AIR should use those ideas only as product inspiration, not copy Monologue's structure or UX.

## User-Facing Behavior

AIR should make microphone choice operational, not decorative.

1. Settings should show:
   - `System default`
   - connected input devices by readable name
   - a saved preferred device even when currently disconnected, marked unavailable
   - the currently resolved recording device, for example `Using BOYA mini 2` or `Using system default: MacBook Pro Microphone`

2. Recording should resolve the microphone at the moment the hotkey starts:
   - If `System default` is selected, use the current default input device.
   - If a preferred device is connected and input-capable, record from it even when the system default is different.
   - If the preferred device is gone, not input-capable, or in cooldown, fall back to the best available input and show a short status message such as `BOYA mini 2 unavailable; using MacBook Pro Microphone.`
   - If no usable input exists, fail before transcription with `No usable microphone is available.`

3. AIR should not hold a selected microphone open while idle. Device discovery, preference resolution, and UI refresh must not open the audio stream.

4. AIR should not silently keep recording from the wrong device. A selected mic that fails should produce an in-app status, a log line, and archive metadata for the recording.

5. AIR should avoid aggressive mid-dictation switching. Prefer:
   - switch before the first real buffer when startup resolution fails;
   - switch during an active recording only if the current device disappears, the engine fails, or the stream is exact digital silence long enough to indicate a dead transmitter/device rather than a quiet user.

## Internal Model

Add small, testable model types before touching `AudioRecorder`.

```swift
struct MicrophoneDevice: Identifiable, Hashable {
    var id: String              // stable CoreAudio UID, compatible with saved AVCapture uniqueID where possible
    var name: String
    var coreAudioDeviceID: AudioObjectID?
    var transportType: String?
    var isConnected: Bool
    var isInputCapable: Bool
    var isSystemDefault: Bool
}

struct MicrophonePreferences: Codable, Equatable {
    var mode: Mode
    var preferredIDs: [String]  // v1 can persist one ID; keep array to support priority order later

    enum Mode: String, Codable {
        case systemDefault
        case preferred
    }
}

struct MicrophoneResolution: Equatable {
    var requestedID: String?
    var device: MicrophoneDevice
    var usedFallback: Bool
    var reason: MicrophoneResolutionReason
}
```

Keep `preferredMicrophoneID` as a compatibility shim at first. Internally, map `""` to `.systemDefault`; map non-empty values to `.preferred([id])`.

Core services:

- `AudioInputDeviceDiscovery`: evolve from `AVCaptureDevice`-only listing to a CoreAudio-backed inventory that includes `AudioObjectID`, UID, input channel capability, default-input status, display name, and transport metadata when available.
- `MicrophoneResolver`: pure resolver that takes preferences, current devices, quarantined IDs, and current time; returns `MicrophoneResolution` or a no-device error.
- `MicrophoneDeviceObserver`: CoreAudio property listener for `kAudioHardwarePropertyDevices` and `kAudioHardwarePropertyDefaultInputDevice`, debounced onto the main actor.
- `MicrophoneHealthMonitor`: only active while recording. Reads tap buffers already flowing through `AudioRecorder`; tracks first-buffer timing, exact-zero buffers, RMS, and silence duration.
- `MicrophoneDiagnostics`: small value captured at start and saved/logged with each recording.

## Driving Recording

The key change is to pass a resolved microphone into `AudioRecorder.start`.

Current:

```swift
audioRecorder.start(at: archiveDraft.audioURL, bufferSize: ..., streamHandler: ...)
```

Target shape:

```swift
let resolution = microphoneResolver.resolve(...)
audioRecorder.start(
    at: archiveDraft.audioURL,
    microphone: resolution.device,
    bufferSize: AudioRecorder.fastStartBufferSize,
    streamHandler: ...,
    onFirstBuffer: ...
)
```

On macOS, `AudioRecorder` should set the input node's underlying I/O unit device before reading the format and installing the tap. The local SDK exposes the relevant path:

- `AVAudioNode.AUAudioUnit`
- macOS `AUAudioUnit.setDeviceID(_:error:)`
- older fallback: `AVAudioIONode.audioUnit` plus `kAudioOutputUnitProperty_CurrentDevice`

Order matters:

1. Stop the engine if running.
2. Remove any existing tap.
3. Resolve/set the target device on `engine.inputNode`.
4. Read `input.outputFormat(forBus: 0)` after the device is set.
5. Validate sample rate/channel count.
6. Install the tap.
7. Open the WAV asynchronously as the current code does.
8. `engine.prepare()` and `engine.start()`.

This preserves the current WAV archive, realtime OpenAI sink, first-buffer callback, and fast-start buffer size. It also avoids a larger `AVCaptureSession` rewrite.

## Fallback And Recovery

Resolution-time fallback:

- Preferred missing: use system default or first input-capable device.
- Preferred present but not input-capable: fallback and mark reason `preferredNotInputCapable`.
- Preferred quarantined: fallback until cooldown expires.
- No fallback: fail with a clear `AudioRecorderError.noUsableMicrophone`.

Start-time fallback:

- If setting the preferred device or starting the engine fails, quarantine that microphone ID for a short cooldown, for example 10 seconds, and retry once with the next resolver result.
- If the fallback also fails, surface the original preferred failure plus fallback failure in diagnostics.
- Do not loop indefinitely on hotkey start.

Active-recording recovery:

- If CoreAudio reports the active device disappeared, try `switchToResolvedMicrophone` against the same active recording URL and stream handler. Log the gap.
- If switching fails, stop recording and show a failure rather than creating a misleading transcript from partial or wrong-device audio.
- If the preferred device comes back while recording from fallback, do not switch mid-dictation. Use it on the next recording.

Silence/mute handling:

- Treat exact digital silence differently from ordinary quiet audio.
- If the active selected device produces exact-zero buffers for about 1.0-1.5 seconds at the start, quarantine it briefly and switch to fallback.
- If audio is merely low RMS, do not auto-switch. Show a warning/status such as `No input level detected from BOYA mini 2` and keep recording unless the user stops.
- Add a manual `Test microphone` button later if this remains a common failure mode.

Busy device handling:

- A busy or refused device should become a cooldown/quarantine event with reason `startFailed`.
- The cooldown should be in memory only. Do not permanently mark devices bad across launches.

## Device Change Observation

Register a CoreAudio listener at app startup or first settings open:

- `kAudioHardwarePropertyDevices`
- `kAudioHardwarePropertyDefaultInputDevice`

Behavior:

- Debounce changes for roughly 250 ms.
- Refresh `availableMicrophones` on the main actor.
- Preserve saved preferred IDs even if not currently connected.
- If idle, just update Settings/menu status.
- If starting/recording and the active device disappeared, invoke active-recording recovery.
- If recording on fallback and the preferred device appears, record a log line but do not switch until next recording.

## Startup Latency Constraints

The hotkey path should stay close to the current behavior.

- No microphone probing while idle.
- No opening candidate devices serially on hotkey start.
- Maintain an in-memory device cache from CoreAudio observation so resolution is O(number of devices) with no I/O.
- Device selection must happen before format lookup; do not do extra format conversions unless the selected device requires it.
- Keep the existing background WAV open queue and prepared archive draft.
- Extend existing `RecordingStartup` logs with `resolve`, `setDevice`, and `firstBuffer` phases.
- Target budget: resolver plus device set should usually add less than 30 ms; any event over 100 ms should be logged as a startup warning.

## Logging, Diagnostics, And Archive Metadata

Add an `OSLog` category:

```swift
Logger(subsystem: "com.fieldtheory.autoimproverecorder", category: "MicrophoneDevice")
```

Log these fields:

- saved preference mode and ID
- resolved device ID/name
- CoreAudio `AudioObjectID`
- system default ID/name
- fallback reason
- quarantine/cooldown reason and expiry
- device-change events
- set-device duration
- first-buffer duration
- exact-silence duration and RMS samples during startup

Add a copyable diagnostics section in Settings after implementation:

- available devices
- saved preference
- active/resolved device
- last fallback reason
- last start failure

Extend `TranscriptArchiveRecord` later with:

- `microphonePreferenceID`
- `microphoneResolvedID`
- `microphoneResolvedName`
- `microphoneUsedFallback`
- `microphoneFallbackReason`

Manual log command:

```bash
log stream --predicate 'subsystem == "com.fieldtheory.autoimproverecorder" && (category == "RecordingStartup" || category == "MicrophoneDevice")' --style compact
```

## Implementation Stages

### Stage 1: Pure Model And Resolver

- Add `MicrophonePreferences`, `MicrophoneDevice`, `MicrophoneResolution`, and `MicrophoneResolver`.
- Keep existing `preferredMicrophoneID` persistence working.
- Add package tests for resolver behavior:
  - system default selected
  - preferred connected
  - preferred missing falls back
  - preferred quarantined falls back until cooldown
  - no input-capable devices fails
  - disconnected saved device remains representable

### Stage 2: CoreAudio Discovery And Observation

- Upgrade `AudioInputDeviceDiscovery` to return CoreAudio-backed devices.
- Keep names stable and readable, using `AVCaptureDevice` only as a supplementary name source if useful.
- Add `MicrophoneDeviceObserver` and debounce refresh into `AppState`.
- Update Settings to show unavailable saved preference and current resolved device.

### Stage 3: Recorder Device Selection

- Add `microphone: MicrophoneDevice?` to `AudioRecorder.start` on macOS.
- Set the `AVAudioInputNode` device before `outputFormat(forBus:)`.
- Return or log the actual active device.
- Do not change iOS behavior except to keep signatures compiling behind `#if os(macOS)`.
- Build with `xcodebuild -project AutoImproveRecorder.xcodeproj -scheme AutoImproveRecorder -configuration Debug build`.

### Stage 4: Fallback And Quarantine

- Add in-memory quarantine state to `AppState` or a small `MicrophoneRecoveryController`.
- On set/start failure, retry once with fallback.
- Log and surface fallback status.
- Add active startup exact-silence detection using the existing tap buffers.

### Stage 5: Active Device Recovery

- Implement switch during active recording only for device disappearance or exact digital silence.
- Preserve the current archive URL and realtime sink.
- If switch fails, fail loudly and archive partial diagnostics.

### Stage 6: Documentation And Manual Verification

- Update `README.md` to remove the MVP caveat only after Stage 3 passes manual testing.
- Update `Docs/MANUAL_TEST_CHECKLIST.md` with microphone-specific cases.
- Add a short `Docs/DICTIONARY_MANUAL_VERIFICATION.md`-style microphone verification note if needed.

## Manual Verification Matrix

Use a real installed app or Xcode run, not just unit tests.

- Select `System default`, set macOS input to MacBook mic, record, confirm log says system default and archive metadata matches.
- Select BOYA or another external mic while macOS default is MacBook mic, record, confirm audio comes from the selected external mic.
- Disconnect the preferred external mic, press hotkey, confirm fallback status and successful recording.
- Reconnect preferred mic, record again, confirm AIR uses it on the next recording.
- Start with preferred mic producing exact digital silence, confirm fallback only after the startup silence threshold.
- Simulate busy/start failure if possible, confirm one retry and no infinite loop.
- Change macOS default while AIR is idle; Settings updates without opening the mic.
- Change devices during an active recording; confirm either a logged switch or a clear failure.
- Run `Fastest` mode and confirm the realtime sink still receives buffers after device selection.

## Non-Goals For This Pass

- Do not implement code in this planning step.
- Do not copy Monologue internals.
- Do not add always-on microphone monitoring.
- Do not prioritize a drag-reordered microphone list until AIR has a proven single-preferred-device implementation.
- Do not update README's MVP caveat until recording actually uses the selected device.
