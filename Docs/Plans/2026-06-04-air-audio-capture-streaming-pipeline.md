# AIR Audio Capture and Streaming Pipeline Plan

Date: 2026-06-04

## Scope

Design AIR's own microphone capture, archive, realtime streaming, and offline fallback pipeline. This is a planning document only; no app code should be changed as part of this pass.

The plan is based on the current AIR repo surfaces:

- `AutoImproveRecorder/Recording/AudioRecorder.swift`
- `AutoImproveRecorder/Engines/OpenAIRealtimeTranscriber.swift`
- `AutoImproveRecorder/AppState.swift`
- `AutoImproveRecorder/Support/TranscriptArchiveStore.swift`
- `Tools/OpenAIRealtimeProbe.swift`
- `Tools/PipelineBench/*`
- `Tools/StreamImproveBench/*`
- `Bench/MODEL_EVAL.md` and the transcription harness

Monologue/Hopper artifacts were used only for inspiration: the useful ideas are converted PCM chunking, pending byte accumulation, `AVAudioConverter` reuse, async stream yielding, and keeping microphone streaming separate from capture-session/system-audio work. AIR should not copy Monologue code or shape its product architecture around Monologue internals.

## Current State

AIR's current capture path is compact and already has several good latency decisions:

- `AudioRecorder` owns an `AVAudioEngine`, installs an input tap, and starts with `AudioRecorder.fastStartBufferSize` of 256 frames.
- It opens the archive `AVAudioFile` on `AudioRecorder.fileOpenQueue` so file creation does not block the visible `Opening microphone` path.
- While the file is opening, it stores up to 16 copied `AVAudioPCMBuffer`s in `pendingBuffers`.
- It calls a synchronous `streamHandler` from the tap callback, currently feeding `OpenAIRealtimeAudioSink`.
- `AppState` creates an archive draft before starting capture, then uses the archive WAV as the offline fallback source for OpenAI API, Whisper, Apple Speech, Parakeet, and Parakeet.cpp.
- `OpenAIRealtimeAudioSink` buffers up to 15 seconds of copied tap buffers while the realtime WebSocket starts, then replays them into `OpenAIRealtimeTranscriber`.
- `OpenAIRealtimeTranscriber` converts each tap buffer to 24 kHz mono interleaved PCM16 and serializes WebSocket sends through task chains.

The weak points are also clear:

- `preferredMicrophoneID` is stored and shown in Settings, but `AudioRecorder` currently records from `AVAudioEngine.inputNode` without an explicit selected-device binding.
- File-write failures are logged but not surfaced to the session, so AIR can believe it has an offline fallback when the archive is incomplete or missing.
- The realtime path has two queues with unclear ownership: `OpenAIRealtimeAudioSink.pendingBuffers` stores pre-conversion `AVAudioPCMBuffer`s, and `OpenAIRealtimeTranscriber.appendChain/sendChain` serializes converted data. This makes backpressure and lag hard to reason about.
- Realtime conversion happens per buffer at the transcriber boundary, so AppState is moving raw audio objects around even though OpenAI only wants one canonical stream format.
- Dropped pending buffers are trimmed silently in `OpenAIRealtimeAudioSink`.
- Archive writing, realtime conversion, realtime send lag, and fallback choice do not share one diagnostic record.

## Recommendation

Introduce a small typed audio pipeline between the tap and the consumers:

1. `MicrophoneCaptureSource` owns the selected microphone and produces typed `CapturedAudioBuffer` events.
2. `AudioCaptureFanout` receives copied buffers from the tap without blocking it.
3. `ArchiveAudioWriter` writes the durable WAV archive and reports success/failure.
4. `RealtimePCMChunker` converts to OpenAI's required 24 kHz mono PCM16 format and emits fixed-size `RealtimeAudioChunk`s.
5. `OpenAIRealtimeTranscriber` consumes `RealtimeAudioChunk`s through a bounded async stream instead of receiving arbitrary `AVAudioPCMBuffer`s.

Keep the archive WAV as the offline source of truth. Realtime is a fast path, not the only path. If realtime lags, drops, or fails, AIR should finish against the archive with the current fallback logic. If the archive fails but realtime succeeds, AIR can still return the realtime transcript, but the session record must say the archive failed and offline fallback was unavailable.

## Proposed Types and Ownership

Add these under `AutoImproveRecorder/Recording/` in a later implementation pass:

- `AudioCaptureSource`: protocol for things that can start/stop audio capture.
- `MicrophoneCaptureSource`: v1 implementation for microphone capture only.
- `CapturedAudioBuffer`: immutable copied audio payload plus timing and format metadata.
- `AudioCaptureFanout`: nonblocking fanout from capture source to archive/realtime consumers.
- `ArchiveAudioWriter`: async file writer with explicit state.
- `RealtimePCMChunker`: `AVAudioConverter` plus pending byte buffer and fixed chunk emission.
- `RealtimeAudioChunk`: sequence number, capture time range, PCM format, and bytes.
- `AudioCaptureDiagnostics`: counters and timings accumulated across the session.

Sketch:

```swift
struct CapturedAudioBuffer {
    let sequence: UInt64
    let capturedAtHostTime: UInt64
    let receivedAt: Date
    let format: AVAudioFormat
    let frameLength: AVAudioFrameCount
    let buffer: AVAudioPCMBuffer
}

struct RealtimeAudioChunk {
    let sequence: UInt64
    let firstCaptureSequence: UInt64
    let lastCaptureSequence: UInt64
    let producedAt: Date
    let format: RealtimeAudioFormat // pcm16Mono24k
    let data: Data
}
```

The typed abstraction should live below `AppState` and above provider-specific transcribers. `AppState` should ask for a `RecordingSessionHandle`, not manage raw realtime buffering itself. This lets system-audio capture arrive later as another `AudioCaptureSource` without changing AppState's stop/transcribe/improve orchestration.

## Selected Input Device

V1 should make selected microphone behavior real. The current UI stores `preferredMicrophoneID` values from `AVCaptureDevice.uniqueID`; the recorder does not use them.

Implementation should keep the low-latency `AVAudioEngine` path if selected-device binding can be made reliable on macOS by resolving the selected device to a CoreAudio device and binding the input audio unit before engine start. The implementation spike should have a hard acceptance test: select BOYA, record with MacBook mic muted or physically separated, and confirm the BOYA signal is the one in the archive.

If reliable `AVAudioEngine` device binding is not achieved quickly, put an `AVCaptureSession`-backed microphone source behind the same `AudioCaptureSource` protocol for explicit device capture. That is more invasive, but it matches the existing `AVCaptureDevice.uniqueID` UI and prevents fake microphone selection.

The plan should not set the system default input device as a side effect. AIR should record from the selected input, not mutate the user's global audio routing.

## Buffer and Chunk Architecture

The tap callback should do the minimum work:

1. Mark first-buffer timing.
2. Copy the buffer into a `CapturedAudioBuffer`.
3. Offer it to `AudioCaptureFanout`.
4. Return.

No file open, file write, WebSocket send, JSON/base64 encoding, or `AVAudioConverter` work should run in the tap callback.

Fanout should use bounded queues with explicit policies:

- Archive queue: target 3 seconds, hard cap 5 seconds. If full, mark archive failed and stop archive writes for this session. Do not block the tap and do not silently write a partial file as if it were complete.
- Realtime preconnect queue: target 2 seconds, hard cap 5 seconds of converted chunks. If full before the socket is ready, drop oldest realtime chunks, increment diagnostics, and mark realtime degraded so stop-time fallback prefers the archive.
- Realtime send queue: target under 500 ms lag, hard cap 2 seconds. If lag exceeds cap, drop oldest unsent realtime chunks and mark realtime degraded. The archive keeps recording.

Use fixed-size realtime chunks after conversion. The current `Tools/OpenAIRealtimeProbe.swift` uses 4,800-byte appends, which equals 100 ms of 24 kHz mono PCM16 audio. That is a good AIR default:

- `chunkByteCount = 4_800`
- `maxPendingRealtimeBytes = 4_800 * 50` for a 5 second hard cap
- flush a final short chunk on stop before commit

This mirrors the useful Monologue pattern conceptually: maintain `pendingData`, append converted PCM bytes, emit when `pendingData.count >= chunkByteCount`, and preserve tail bytes until stop.

## Backpressure and Failure Handling

Backpressure should never block capture. AIR's user experience is better when the archive or realtime path is marked degraded than when the microphone tap stalls.

Rules:

- Archive write failure is terminal for the archive consumer only. Continue realtime capture if active.
- Archive open failure should be visible immediately in diagnostics, but not necessarily in the HUD while recording unless realtime is unavailable too.
- Realtime conversion failure is terminal for realtime for that recording. Continue archive, and use offline fallback on stop.
- Realtime send failure is terminal for realtime. Continue archive.
- Realtime queue drops make realtime untrusted. It may still be useful for partial display later, but final transcription should fall back to the archive.
- If both archive and realtime are unavailable, stop should fail with a direct message: recording audio could not be saved or streamed.

At stop, `AppState.processRecording` should receive a resolved `RecordingCaptureResult`:

```swift
struct RecordingCaptureResult {
    let audioURL: URL?
    let archiveStatus: ArchiveStatus
    let realtimeTranscriber: OpenAIRealtimeTranscriber?
    let realtimeStatus: RealtimeCaptureStatus
    let diagnostics: AudioCaptureDiagnostics
}
```

This removes the current implicit assumption that a returned URL means the archive is valid.

## Conversion Policy

Archive:

- Write the original microphone capture format to `audio.wav` where possible.
- Preserve sample rate and channel count for offline engines; they already read the saved file.
- If the input format changes mid-session, close the archive as failed rather than writing an invalid WAV.

Realtime:

- Convert every capture buffer to 24 kHz mono interleaved PCM16.
- Reuse one `AVAudioConverter` per input format.
- Recreate the converter when input format changes and increment `converterRecreateCount`.
- Downmix to mono through `AVAudioConverter`; do not hand-roll channel averaging unless tests show converter behavior is wrong.
- Emit little-endian PCM16 bytes directly from the converted buffer.
- Accumulate bytes into 4,800-byte chunks and flush any tail chunk on stop.

OpenAI's realtime transcription docs currently require `audio/pcm` at 24 kHz mono for PCM input and use `input_audio_buffer.append` plus delta/completed transcription events. AIR's existing `OpenAIRealtimeTranscriber` is aligned with that format; the change is to move conversion and chunking into a reusable typed component.

Offline OpenAI API fallback should keep the existing AAC/M4A pre-upload optimization in `OpenAIAudioTranscriber`. That is a separate upload path and should not constrain realtime chunking.

## Keeping Tap-to-First-Buffer Latency Low

Protect the current good decisions:

- Keep the pre-created archive draft in `AppState`.
- Keep 256-frame capture buffers for recording start unless measurement shows CPU pressure.
- Keep archive file creation off the visible start path.
- Do not wait for OpenAI realtime startup before showing recording UI.
- Start the realtime WebSocket task in parallel immediately after permission/device resolution when mode is `.fastest`.
- Move realtime conversion and JSON/base64 work out of the tap path.
- Keep first-buffer instrumentation from `AudioRecorder` and add first-chunk/first-send timings.

Target metrics for manual verification:

- hotkey/tap to `phase = .recording`: no regression from current behavior
- hotkey/tap to first audio buffer: p50 under 100 ms on BOYA and built-in mic
- first buffer to first realtime chunk produced: under 150 ms
- first realtime chunk produced to first WebSocket send: under 250 ms when socket is ready

## Future System Audio Capture

Do not add system-audio capture code to the microphone recorder.

The source boundary should be:

```swift
enum AudioCaptureSourceKind {
    case microphone
    case systemAudio
}
```

V1 ships only `.microphone`. A later `SystemAudioTapSource` can produce the same `CapturedAudioBuffer` shape and feed the same fanout, archive writer, chunker, and diagnostics. Permissions, entitlements, screen/audio capture prompts, and source-specific errors stay inside the system-audio source.

Do not mix microphone and system audio in v1. If AIR later needs combined meeting capture, add a separate `MixedAudioCaptureSource` that composes two sources and owns clock alignment. Keep that out of the dictation microphone path.

## Diagnostics

Add one session-level diagnostic object and persist it with the archive record in a later schema extension.

Minimum fields:

- `sourceKind`
- `requestedDeviceID`
- `resolvedDeviceName`
- `inputSampleRate`
- `inputChannelCount`
- `tapBufferFrames`
- `startRequestedAt`
- `engineStartedAt`
- `firstBufferAt`
- `archiveOpenMs`
- `archiveWriteCount`
- `archiveBytesWritten`
- `archiveQueueMaxDepth`
- `archiveFailure`
- `converterRecreateCount`
- `conversionFailure`
- `chunkByteCount`
- `realtimeChunksProduced`
- `realtimeChunksSent`
- `realtimeChunksDropped`
- `realtimePendingBytesMax`
- `realtimeSocketReadyMs`
- `realtimeSendLagMaxMs`
- `realtimeFailure`
- `fallbackReason`

Expose diagnostics through the existing "copy OpenAI realtime diagnostics" style surface, but rename or broaden it when capture diagnostics include archive and converter failures. The current `OpenAIRealtimeDiagnostics` should become one part of the larger capture/transcription diagnostic packet.

## Focused Tests

Unit tests:

- `RealtimePCMChunker` converts 48 kHz stereo float buffers to 24 kHz mono PCM16.
- `RealtimePCMChunker` emits exact 4,800-byte chunks and flushes a final short tail on finish.
- `RealtimePCMChunker` recreates its converter on input format change and records the event.
- `BoundedAudioQueue` drops oldest realtime chunks after its cap and reports the count.
- `ArchiveAudioWriter` reports open failure, write failure, successful close, and byte counts.
- `AudioCaptureFanout` continues archive writes when realtime fails.
- `AudioCaptureFanout` continues realtime when archive fails.

Integration/tool tests:

- Extend `Tools/OpenAIRealtimeProbe.swift` to feed chunks generated by `RealtimePCMChunker` from `Bench/Fixtures/*.wav`, not hand-sliced bytes.
- Add `Tools/AudioPipelineBench` with a synthetic tap producer that can simulate 5 seconds, 2 minutes, and 10 minutes of 48 kHz mono/stereo input at real-time and faster-than-real-time rates.
- Extend `Tools/PipelineBench` with capture-result states: realtime success, realtime degraded, archive failed, both failed.
- Use `Bench/model_eval.py make-transcript-truth-corpus` on real `TranscriptTruth` recordings to verify offline fallback still works after archive writer changes.

Manual verification:

- Select BOYA, record, and confirm archive audio is BOYA, not the system default mic.
- Select System default and confirm behavior matches today's default route.
- Unplug the selected mic before start and confirm AIR explains the device issue and falls back only if the user selected System default.
- Record in `.fastest` with network available; confirm realtime finalizes and diagnostics show no drops.
- Record in `.fastest` with network disabled after start; confirm archive fallback transcribes successfully.
- Force archive open/write failure with a debug-only bad archive URL; confirm realtime can still finish and the record says archive failed.
- Run a 5-minute recording; confirm no unbounded memory growth, no archive queue drops, and realtime queue behavior is explicit.

## Implementation Sequence

1. Add diagnostics and test-only chunker/queue primitives without touching AppState behavior.
2. Move OpenAI realtime conversion from `OpenAIRealtimeTranscriber` into `RealtimePCMChunker`, preserving the current `appendAudioBuffer` API through a compatibility shim.
3. Replace `OpenAIRealtimeAudioSink` with typed chunk buffering and bounded drop diagnostics.
4. Move archive writing out of `AudioRecorder` into `ArchiveAudioWriter`, keeping the returned `audioURL` behavior until the new result type is wired.
5. Introduce `RecordingCaptureResult` and update `AppState.stopRecording/processRecording` to choose realtime vs archive based on explicit statuses.
6. Make selected microphone capture real and verify on hardware.
7. Only after v1 microphone capture is stable, add the empty `AudioCaptureSourceKind.systemAudio` placeholder and documentation. Do not implement `SystemAudioTapSource` in the microphone refactor.

## Non-Goals

- No system-audio capture in this implementation.
- No speculative improvement pipeline changes.
- No change to local Parakeet/Whisper transcription engines except consuming the same archive path.
- No new external dependencies.
- No Monologue code reuse.
