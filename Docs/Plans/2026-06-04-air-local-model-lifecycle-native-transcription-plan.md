---
title: AIR Local Model Lifecycle and Native Local Transcription Plan
status: active
date: 2026-06-04
deepened: 2026-06-04
origin: delegated planning thread
---

# AIR Local Model Lifecycle and Native Local Transcription Plan

## Problem Frame

AIR currently works, but its local model story is split across several surfaces:

- `AutoImproveRecorder/Engines/ParakeetTranscriber.swift` contains three distinct local paths: Field Theory `whisper-server`, Field Theory Python Parakeet server, and AIR-owned `parakeet.cpp` CLI variants.
- `AutoImproveRecorder/Engines/AppleLocalEngines.swift` has a native Apple Speech / Foundation Models path, gated by OS and device availability.
- `AutoImproveRecorder/AppState.swift` stores raw path preferences, prewarms selected engines, snapshots dictionary context at recording start, handles OpenAI realtime fallback, and archives provider metadata.
- `AutoImproveRecorder/UI/SettingsView.swift` exposes low-level path fields and separate transcription / improvement pickers, but not a coherent local-model inventory.
- `Bench/`, `Tools/PipelineBench/`, and `Tools/StreamImproveBench/` already provide the right culture: benchmark changes against app-like corpora and pipeline timing before shipping defaults.

The next version should make local transcription feel native to AIR: clear modes, install/discovery status, cancellable downloads, non-invasive preloading, benchmark-backed defaults, and precise failure states. It should not copy Monologue. Monologue is useful only as inspiration for lifecycle ergonomics: explicit model status, download progress, "already present / loading / loaded / failed" strings, CoreML component awareness, and performance instrumentation.

## Scope

In scope:

- Model inventory for local transcription and local cleanup runtimes.
- User-facing modes: Fast, Recommended, All Local, and experimental realtime/local.
- Runtime discovery and install/download lifecycle.
- Warmup/preload policy that avoids app startup and microphone latency regressions.
- Native Swift/CoreML path evaluation versus current subprocess/server paths.
- Instrumentation and benchmark gates.
- Missing/slow/incompatible/empty-output failure handling.
- Dictionary/hotword context routing where provider support exists.
- Staged implementation plan with tests and manual verification.

Out of scope for this plan:

- Implementing code in this thread.
- Replacing the whole app architecture.
- Shipping Monologue-derived code or internal assets.
- Solving Mac App Store sandboxing. The current app is intentionally unsandboxed because of subprocess and Accessibility behavior.
- Adding diarization as a first user-facing feature. Sortformer-style diarization can remain a future model-inventory category.

## Opinionated Direction

Make `Parakeet.cpp Recommended` the default local transcription mode, keep `Parakeet.cpp Fast` as an explicit speed/quality tradeoff, preserve Apple Speech as "Apple local when available," and demote raw Field Theory path editing to an Advanced section.

Do not make AIR depend on Field Theory for the primary local stack. The current AIR-owned support tree under the user's Application Support directory is the right direction. Field Theory Python/whisper paths should become legacy/discovered compatibility providers, not the visible local model identity.

For native-feeling local transcription, the likely best long-term path is:

1. Short term: harden AIR's `parakeet.cpp` CLI/runtime lifecycle and benchmark it as the product default.
2. Medium term: wrap `parakeet.cpp` behind an AIR-owned persistent broker/server so warm model state survives across recordings without repeated CLI process cost.
3. Long term: evaluate native Swift/CoreML Parakeet/Qwen3-ASR only behind benchmark gates. Do not move to CoreML just because it feels more "native"; move only if it beats the current stack on startup impact, mic latency, transcript latency, accuracy, and failure debuggability.

## Decisions for Implementation

These are no longer open for the first implementation pass.

| Decision | Call | Rationale |
| --- | --- | --- |
| Primary local transcription identity | `Parakeet.cpp Recommended` | AIR already has an AIR-owned support tree and app mode for it. It is the best default from current benchmark evidence and avoids depending on Field Theory as the product identity. |
| `Fastest` naming | Rename UI copy to `Cloud Realtime` while keeping `TranscriptionMode.fastest` internally for migration | The current behavior streams to OpenAI first. Calling it `Fastest` beside `Parakeet.cpp Fast` makes local/cloud boundaries ambiguous. |
| Field Theory Whisper visibility | Move to Advanced / Legacy compatibility | It is useful as a fallback for this machine, but it should not define AIR's native local model story. |
| Field Theory Python Parakeet visibility | Move to Advanced / Legacy compatibility after Parakeet.cpp status exists | The current server path is useful, but it leaks Field Theory paths and should not be the main user-facing Parakeet mode. |
| Apple Speech in All Local | Do not include automatically | Apple Speech availability depends on OS, locale, assets, and device state. It stays a separate selectable Apple local mode with explicit readiness. |
| Parakeet.cpp downloads | Park hosted download URLs/checksums for a later stage | The first slice should discover and explain the existing AIR-owned runtime. Do not block useful status UX on model hosting. |
| Persistent broker | Implement after inventory/status and benchmark baseline | It is the main performance candidate, but implementing it before inventory makes failure states harder to reason about. |
| Native CoreML/Qwen3-ASR | Research spike only after broker and lifecycle layers | The tokenizer/decoder/runtime surface is large. Native is not automatically better than a measured CLI/broker stack. |

Parked decisions:

- Exact hosting location, license flow, and checksums for downloadable `parakeet.cpp` artifacts.
- Whether the persistent broker is a Swift-owned `Process` wrapper around `parakeet-cli`, a small helper binary, or an upstream server mode if `parakeet.cpp` grows one.
- Whether a future native CoreML ASR model should use Parakeet, Qwen3-ASR, or another runtime.

## User-Facing Modes

Replace the raw transcription picker presentation with mode copy that maps to concrete providers.

### Recommended

Default for local transcription.

- Provider: `ParakeetCppTranscriber(variant: .recommended06B)`.
- Model: `tdt-0.6b-v2-q4_k.gguf`.
- Device: Metal where available.
- Promise: best local default for dictation quality and practical latency.
- Fallback: Apple Speech if explicitly selected by user, not automatic silent fallback; OpenAI only in cloud modes.

Rationale: prior AIR benchmark memory indicates 0.6B Q4_K was the practical default because it avoided empty transcripts and handled real dictation better than 110M, while still finishing in subsecond-ish ranges on read-aloud tests.

### Fast

Explicit speed-first local mode.

- Provider: `ParakeetCppTranscriber(variant: .fast110M)`.
- Model: `tdt_ctc-110m-q4_k.gguf`.
- Device: CPU forced as currently coded.
- Promise: lower resource use and faster first pass.
- Warning: may be less reliable on coding/product dictation and may produce empty/weak transcripts.

This should not be labeled as "best" or "recommended." It is a deliberate tradeoff.

### All Local

A bundled workflow mode, not just one picker combination.

- Transcription: Recommended Parakeet.cpp by default, with Apple Speech alternative when supported.
- Cleanup: `OllamaImproveEngine` with `qwen3.5:0.8b-mlx` by default.
- Dictionary: terms passed to transcription if provider supports context, replacement rules always applied after transcription, dictionary snapshot always archived.
- UI: a single "All Local" status should verify both transcription and cleanup readiness.

The implementation can keep separate `TranscriptionMode` and `ImprovementMode` internally, but Settings should offer a one-click preset because "local audio + local cleanup" is the product concept users care about.

### Realtime / Local Possibilities

Keep this experimental until proven.

Candidate paths:

- Existing `Fastest`: OpenAI realtime while recording, with local fallback. This is cloud realtime, not all-local.
- AIR local broker: a persistent Parakeet.cpp process/server that accepts audio after stop. This is not realtime, but can remove repeated load/probe overhead.
- True streaming local ASR: evaluate only if a native/CoreML or C++ runtime can consume chunks and emit partials without hurting mic capture. Monologue's `Qwen3StreamingManager` and realtime-endpoint strings show the shape to consider, but AIR should benchmark from first principles.

Do not present "Realtime Local" until AIR can show partial text before stop or immediately at stop with measured wins.

## Settings UX Contract

The first implementation should keep the current `TranscriptionMode` and `ImprovementMode` enums for compatibility, but Settings should add a higher-level "Local models" section with status rows and presets. Do not remove the existing picker in the first slice; annotate and supplement it so migration is low-risk.

### Primary Rows

| Row | Title | Subtitle | Primary action | Secondary action |
| --- | --- | --- | --- | --- |
| Recommended | `Recommended local transcription` | `Parakeet.cpp 0.6B, local on this Mac. Best current AIR default.` | `Use Recommended` | `Check` |
| Fast | `Fast local transcription` | `Parakeet.cpp 110M. Lower latency, weaker on difficult dictation.` | `Use Fast` | `Check` |
| All Local | `All Local` | `Recommended transcription plus Ollama qwen3.5:0.8b-mlx cleanup.` | `Use All Local` | `Check all` |
| Apple Speech | `Apple Speech` | `Apple on-device transcription when this Mac, OS, locale, and speech assets support it.` | `Use Apple Speech` | `Check` |
| Cloud Realtime | `Cloud Realtime` | `Streams microphone audio to OpenAI while recording; falls back after failures.` | `Use Cloud Realtime` | `Copy diagnostics` when available |
| Legacy | `Legacy local providers` | `Field Theory Whisper and Python Parakeet paths for compatibility.` | disclosure toggle | `Auto-detect` |

### Status Badges

Use these exact state labels in the plan and tests:

- `Ready`: all required files or external runtime checks pass, and the last light health check succeeded.
- `Installed`: files are present, but a health check has not run in this app session.
- `Needs model`: executable/runtime exists but the selected model file or external model tag is missing.
- `Needs runtime`: model may exist, but the executable/server/runtime is missing.
- `External app required`: Ollama or Field Theory is not running/installed for an external provider.
- `Unavailable`: Apple Speech or Apple Foundation Models are not available on this OS/device/locale.
- `Checking`: a lightweight health check is running.
- `Loading`: a deliberate warmup/load is running after idle or user action.
- `Failed`: the last check failed; show the specific reason.
- `Downloading`: future installer state with percentage and cancel action.

### Exact Copy for Common Failures

- Missing Parakeet.cpp CLI: `Parakeet.cpp runtime is missing. AIR expected bin/parakeet-cli in Application Support. Reinstall the local runtime or choose another transcription mode.`
- Missing Recommended model: `Recommended local transcription needs tdt-0.6b-v2-q4_k.gguf. Install the model or choose Fast.`
- Missing Fast model: `Fast local transcription needs tdt_ctc-110m-q4_k.gguf. Install the model or choose Recommended.`
- Missing Ollama model: `All Local cleanup needs Ollama model qwen3.5:0.8b-mlx. Run ollama pull qwen3.5:0.8b-mlx, then Check all.`
- Ollama not reachable: `Ollama is not reachable at the configured URL. Start Ollama or use a cloud cleanup provider.`
- Apple Speech unsupported OS: `Apple Speech requires macOS 26 or later in this build.`
- Apple Speech unavailable: `Apple Speech is not available for this Mac, user, or speech locale. No audio was sent to the cloud.`
- Cloud Realtime no API key: `Cloud Realtime needs an OpenAI API key. AIR will use Recommended local transcription if it is ready.`

### Preset Mapping

| Preset action | Internal mutations |
| --- | --- |
| `Use Recommended` | `transcriptionMode = .localParakeetCppRecommended`; leave `improvementMode` unchanged. |
| `Use Fast` | `transcriptionMode = .localParakeetCppFast`; leave `improvementMode` unchanged. |
| `Use All Local` | `transcriptionMode = .localParakeetCppRecommended`; `improvementMode = .ollamaLocal`; `ollamaModel = "qwen3.5:0.8b-mlx"` unless the user has a non-empty explicit Ollama model and confirms changing it in a later UX pass. |
| `Use Apple Speech` | `transcriptionMode = .appleLocal`; leave `improvementMode` unchanged. |
| `Use Cloud Realtime` | `transcriptionMode = .fastest`; leave `improvementMode` unchanged. |

Do not auto-switch a user's mode during discovery. Discovery can recommend a mode, but only explicit user actions should mutate preferences.

## Model Inventory

Add a first-class inventory model rather than scattering paths through AppState and Settings.

Proposed new support units:

- `AutoImproveRecorder/Support/LocalModelInventory.swift`
- `AutoImproveRecorder/Support/LocalModelInstaller.swift`
- `AutoImproveRecorder/Support/LocalRuntimeHealth.swift`
- `AutoImproveRecorder/Support/LocalModelDownloadClient.swift`
- `AutoImproveRecorder/Support/LocalModelManifest.swift`

Proposed data model:

- `LocalModelID`: stable IDs such as `parakeet.cpp.110m.q4k`, `parakeet.cpp.06b-v2.q4k`, `apple.speech`, `ollama.qwen35.08b.mlx`, `field-theory.parakeet.python`, `field-theory.whisper.small-en`.
- `LocalModelKind`: `transcription`, `cleanup`, `runtime`, `compatibility`.
- `LocalModelInstallState`: `notInstalled`, `discovering`, `downloadable`, `downloading(progress)`, `installed`, `loading`, `ready`, `failed(reason)`, `incompatible(reason)`.
- `LocalModelHealth`: executable present, model present, dylibs present, code signature/quarantine state if relevant, last successful load, last failure, measured warmup time, measured transcription time.
- `LocalModelRequirement`: file paths, size, checksum when known, minimum OS, architecture, optional hardware acceleration.

Initial inventory entries:

- `Parakeet.cpp Recommended`: requires `bin/parakeet-cli`, `lib/libggml*.dylib`, `models/tdt-0.6b-v2-q4_k.gguf`.
- `Parakeet.cpp Fast`: requires the same CLI/dylib tree plus `models/tdt_ctc-110m-q4_k.gguf`.
- `Apple Speech`: no download controlled by AIR; readiness comes from `SpeechTranscriber.isAvailable`, supported locale, OS version, and speech assets.
- `Ollama qwen3.5:0.8b-mlx`: external server/model; readiness comes from Ollama `/api/tags` or a light warmup call, not filesystem guesses.
- `Field Theory Parakeet`: compatibility runtime; discovered through current `ParakeetRuntimeDiscovery`.
- `Field Theory Whisper`: compatibility runtime; discovered through existing `/Applications/Field Theory.app` resource paths and model path.

### Concrete Inventory Contract

Implement the first slice as pure value types plus one actor/service. Keep it testable without SwiftUI, AppKit, microphone access, or model loading.

Core files:

- `AutoImproveRecorder/Support/LocalModelInventory.swift`
- `AutoImproveRecorder/Support/LocalRuntimeHealth.swift`
- `AutoImproveRecorder/Support/LocalRuntimeProbe.swift`

Core types:

- `LocalRuntimeProbe`: protocol over filesystem and HTTP checks so unit tests can run without real model files.
- `LocalModelDescriptor`: static model metadata.
- `LocalModelStatus`: current discovered state.
- `LocalModelIssue`: structured issue with severity, user copy, and optional recovery action.
- `LocalModelInventory`: builds descriptors and resolves statuses.

Required descriptor fields:

- `id`
- `displayName`
- `shortLabel`
- `kind`
- `modeBinding`
- `ownership`: `airManaged`, `externalOllama`, `appleSystem`, `legacyFieldTheory`
- `requirements`
- `capabilities`
- `recommendedRecovery`

Required status fields:

- `id`
- `state`
- `issues`
- `lastCheckedAt`
- `detail`
- `canSelect`
- `canWarm`
- `isCloud`
- `isAllLocalCompatible`

Mode bindings:

| Model ID | Binding |
| --- | --- |
| `parakeet.cpp.06b-v2.q4k` | `TranscriptionMode.localParakeetCppRecommended` |
| `parakeet.cpp.110m.q4k` | `TranscriptionMode.localParakeetCppFast` |
| `apple.speech` | `TranscriptionMode.appleLocal` |
| `openai.realtime.gpt-4o-transcribe` | `TranscriptionMode.fastest` |
| `openai.audio.gpt-4o-transcribe` | `TranscriptionMode.openAIAPI` |
| `field-theory.parakeet.python` | `TranscriptionMode.localParakeet` |
| `field-theory.whisper.small-en` | `TranscriptionMode.localWhisper` |
| `ollama.qwen35.08b.mlx` | `ImprovementMode.ollamaLocal` plus `ollamaModel == "qwen3.5:0.8b-mlx"` |

Path contract for AIR-managed Parakeet.cpp:

- Base: `~/Library/Application Support/AutoImproveRecorder/ParakeetCpp`
- CLI: `bin/parakeet-cli`
- Libraries: at least one `lib/libggml*.dylib`
- Fast model: `models/tdt_ctc-110m-q4_k.gguf`
- Recommended model: `models/tdt-0.6b-v2-q4_k.gguf`

The first implementation should not run `parakeet-cli transcribe` during Settings discovery. It may run `parakeet-cli info <model>` only from a user-triggered Check action or utility-priority health check.

## Install, Download, and Discovery Lifecycle

### Discovery

Discovery should be cheap and never load large models.

On Settings open and app launch idle:

- Check AIR-owned Parakeet.cpp tree for required files.
- Check executability of `bin/parakeet-cli`.
- Check dylib colocations with the CLI.
- Run `parakeet-cli info <model>` only on explicit health check or background utility task, not on critical app startup.
- Check Field Theory compatibility paths only if the user has legacy modes selected or opens Advanced.
- Check Ollama with a short HTTP timeout, then model tags.
- Check Apple Speech with availability APIs only.

Discovery results should be persisted as lightweight metadata under AIR's Application Support directory, but source of truth stays filesystem/runtime probes.

### Download / Install

Do not require users to manually copy Parakeet.cpp assets once this feature ships.

Desired flow:

1. Settings shows each local mode with status: Installed, Needs download, External app required, Incompatible, or Ready.
2. User clicks Install for a missing AIR-owned model/runtime.
3. Download runs via `URLSessionDownloadTask` with progress and cancellation.
4. Download writes to a staging directory.
5. Installer verifies size/checksum where known.
6. Installer clears quarantine or explains the issue if execution is blocked.
7. Installer atomically promotes the staging tree into AIR's support directory.
8. Health check runs after install.

If direct model distribution is not legally or operationally ready, the same installer surface can expose "Open setup instructions" and "Re-check" while still using the inventory model. Avoid raw path fields as the primary UI.

### Runtime Ownership

AIR-owned local models should live under AIR's own Application Support runtime tree. Field Theory paths and Ollama model stores remain external runtimes.

The plan should not bundle large weights into the app bundle. Download on demand and keep the app update lightweight.

## Warmup and Preload Policy

Current `AppState.prewarmLocalModels()` does the right thing in spirit: it calls `prewarmRecordingStartResources()`, then detached utility warmups for selected local transcription and Ollama. The next version needs stricter scheduling rules.

Policy:

- Never load local models synchronously during app launch.
- Never block `startRecordingFlow` or microphone permission on model warmup.
- Keep `audioRecorder.prepareForFastStartIfAuthorized()` and archive draft precreation as the only recording-start prewarm on the visible mic path.
- Warm selected models only after app idle, Settings changes, or recording finishes.
- Use a single `LocalModelWarmupCoordinator` so mode changes cancel obsolete warmups.
- Apply memory pressure guardrails: skip or unload optional warm state when system memory is constrained.
- Back off after failed warmup and show status instead of retrying repeatedly.
- Warm cleanup provider only enough to establish readiness. For Ollama, use a low-cost keepalive or tag check first, then model warmup only if selected.

Preload priority:

1. Active selected transcription mode.
2. Active selected local cleanup mode.
3. Fallback provider for the selected mode, only if fallback is local and likely to be used.
4. No speculative loading of unselected models.

This protects app startup and mic latency while still making repeated dictations fast.

### Warmup State Machine

Warmup should be owned by `LocalModelWarmupCoordinator`, not by ad hoc conditionals in `AppState`.

States:

- `idle`
- `scheduled(reason)`
- `checkingInventory`
- `warming(modelID)`
- `warm(modelID, warmedAt)`
- `failed(modelID, issue, nextRetryAfter)`
- `cancelled`

Triggers:

- App launch complete: schedule only `prewarmRecordingStartResources()` immediately; schedule selected local model warmup after idle.
- Settings mode change: cancel obsolete warmup and schedule selected-mode warmup after debounce.
- Recording started: cancel non-critical warmups; do not start new model work.
- Recording stopped: allow selected-mode warmup again after delivery finishes.
- App termination: cancel warmup and terminate broker/server children owned by AIR.

Rules:

- `startRecordingFlow` must not await inventory, health, download, model info, Ollama checks, or model warmup.
- `finishProcessing()` may trigger future warmup after delivery, but it must not wait on it.
- Warmup failure should update status but not open Preview unless the user is actively recording/transcribing.
- Repeated failure backoff starts at 30 seconds and can cap at 10 minutes.
- A user-triggered Check bypasses backoff once.

## Native Swift/CoreML vs CLI/Server Tradeoffs

### Existing external CLI/server strengths

- Already integrated and benchmarked.
- Failure modes are understandable: missing executable, missing model, timeout, stderr.
- Easy to swap models and measure variants.
- Does not require AIR to own tokenizer/decoder complexity.
- `parakeet.cpp` support tree can be copied, checked, and repaired.

### Existing weaknesses

- Subprocess launch and model load can hurt first transcription unless warm state exists.
- CLI process per transcription is not as native-feeling as a persistent engine.
- Path/dylib/quarantine issues are not exposed cleanly in Settings yet.
- Dictionary/hotword support is limited unless the runtime exposes it.
- Advanced path fields leak implementation details.

### Native Swift/CoreML strengths

- Potentially better integration with app lifecycle, progress, cancellation, and memory management.
- Can use `MLModelConfiguration`, Neural Engine/CPU/GPU controls, and structured component loading.
- Easier to present as "AIR local model" if AIR owns model manifests.
- Potential future streaming support.

### Native Swift/CoreML risks

- Tokenizers and decoder stacks are not trivial. Monologue's static strings show many tokenizer and Qwen3-ASR components because this is a real subsystem, not a thin wrapper.
- CoreML conversion can improve UX while regressing accuracy or startup time.
- ANE/GPU memory pressure can hurt the recorder and the rest of the Mac.
- Debuggability may get worse than a CLI with JSON/stderr unless AIR builds strong instrumentation.

Decision: implement a benchmarked persistent AIR local broker before attempting a native CoreML ASR rewrite. Start a CoreML spike only after the lifecycle/inventory layer exists, because the same inventory, health, warmup, and benchmark gates will be needed either way.

## Performance Instrumentation and Gates

Add explicit timing fields to archive records and bench outputs before changing defaults.

Proposed new metrics:

- `recordingStartRequestedAt`
- `microphoneFirstBufferMs`
- `transcriptionQueuedAt`
- `modelWarmState`: cold, warm, unknown
- `modelLoadMs`
- `transcriptionWallMs`
- `realTimeFactor`
- `transcriptCharCount`
- `emptyTranscript`
- `fallbackUsed`
- `improveWallMs`
- `deliveryWallMs`
- `endToEndStopToDeliveredMs`

Implementation surfaces:

- `AutoImproveRecorder/Support/LocalPerformanceMonitor.swift`
- `AutoImproveRecorder/Support/TranscriptArchiveStore.swift`
- `Bench/model_eval.py`
- `Bench/model_eval.providers.json`
- `Bench/MODEL_EVAL.md`
- `Tools/PipelineBench/PipelineOrchestrator.swift`

Benchmark gates before changing the default:

- Debug and Release builds pass.
- Local model inventory unit tests pass.
- `Parakeet.cpp Recommended` must beat or match existing local default on empty-output rate and real-dictation quality.
- `Parakeet.cpp Fast` must be clearly labeled if it has a higher empty-output rate.
- Warm selected model must not increase mic first-buffer p95 by more than 50 ms.
- App launch to idle must not synchronously load models.
- Stop-to-transcript p95 for Recommended should stay under the current benchmark baseline on read-aloud and archived corpora.
- Empty transcript fallback/error path must be exercised manually.

Use `Bench/model_eval.py make-transcript-truth-corpus` for realistic archived runs, and use read-aloud ground truth for actual WER/CER. Do not treat archived raw transcript as ground truth unless the run is explicitly labeled pseudo-reference drift.

### Exact Benchmark Gates for First Three Stages

Stage 1 inventory/status does not need live model benchmarks because it must not change transcription behavior. Its gates are:

- Unit tests for descriptor mapping and fake filesystem/HTTP probes.
- A manual Settings check with no model files, partial model files, and installed model files.
- `git diff` confirms no transcription behavior changes outside planned status wiring.

Stage 2 Settings preset gates:

- Existing selected modes round-trip through `UserDefaults`.
- `Use All Local` sets Recommended + Ollama `qwen3.5:0.8b-mlx`.
- Cloud Realtime copy is shown for `.fastest`.
- Legacy Field Theory settings remain available and unchanged.

Stage 3 warmup coordinator gates:

- Hotkey-to-first-buffer p95 on 10 local manual runs is not worse than baseline by more than 50 ms.
- App launch does not spawn `parakeet-cli`, `whisper-server`, Python Parakeet, or Ollama warmup before idle scheduling.
- Mode changes cancel obsolete warmups in tests.
- Recording start cancels non-critical warmups in tests.

Persistent broker gates before promotion:

- 10 repeated 5s fixture runs and 10 repeated 30s fixture runs show lower stop-to-transcript p50 and p95 than CLI-per-call Recommended.
- Empty transcript rate is not worse than CLI-per-call Recommended.
- Broker restart after child crash is covered by test and manual run.
- Broker memory footprint is recorded after cold load, after 10 runs, and after idle.

Commands to preserve in the implementation PR description:

```bash
python3 Bench/model_eval.py make-transcript-truth-corpus \
  --min-raw-chars 40 \
  --require-improvement-input \
  --out .autoresearch/transcript-truth.corpus.json

python3 Bench/model_eval.py transcribe \
  --corpus .autoresearch/transcript-truth.corpus.json \
  --config Bench/model_eval.providers.json \
  --provider parakeet-field-theory \
  --limit 3 \
  --runs 1 \
  --out .autoresearch/local-transcription-smoke.jsonl

python3 Bench/model_eval.py improve \
  --corpus .autoresearch/transcript-truth.corpus.json \
  --config Bench/model_eval.providers.json \
  --provider ollama-qwen3.5-0.8b-mlx \
  --limit 3 \
  --runs 1 \
  --out .autoresearch/local-improvement-smoke.jsonl
```

Add Parakeet.cpp provider entries to `Bench/model_eval.providers.json` before using the harness to gate Parakeet.cpp. Do not keep gating Recommended through the Field Theory provider once the AIR-owned runtime is the product default.

## Failure Handling

Every local model mode should separate "not installed," "installed but cannot run," "runs but slow," and "runs but bad output."

Missing model:

- Settings row: Needs download / Install.
- Recording path: fail early with actionable message if the selected model is missing and no allowed fallback exists.
- Do not silently switch to cloud in local modes.

Missing executable or dylibs:

- Settings row: Runtime incomplete.
- Health detail: which file is missing.
- Offer Re-check and repair/install flow.

Incompatible runtime:

- Capture architecture, minimum OS, executable launch failure, and model format mismatch separately.
- For Apple Speech, show OS/device/locale availability rather than file errors.

Slow model/load:

- If cold load exceeds threshold, surface "first run is still loading" once.
- Persist last load time and warn if the mode is repeatedly too slow.
- Do not keep retrying in a tight loop.

Empty transcript:

- Treat as a first-class failure, as current `TranscriptionEngineError.emptyLocalTranscript(provider:)` already does.
- Record provider, audio duration, RMS/silence hint if available, and model variant.
- For `Fast` mode, recommend trying Recommended in the error copy.
- For all-local mode, do not call cleanup on empty text.

Fallback rules:

- Local modes should fallback only to local providers unless the user has selected a cloud/realtime mode.
- `Fastest` can keep its current cloud-first behavior, but the UI should call it cloud realtime, not local.
- Every fallback should archive `fallbackUsed` and original failure.

## Dictionary and Hotword Context

AIR's current split is right:

- `UserDictionaryStore.currentSnapshotString` captures dictionary entries.
- `AppState.startRecordingFlow` snapshots that string at recording start.
- `TranscriptionContext.transcriptionPrompt` converts it into provider prompt text.
- `OpenAIAudioTranscriber` passes the prompt to OpenAI transcription.
- `OpenAIRealtimeTranscriber` receives the dictionary snapshot in its initializer.
- `UserDictionaryStore.applyReplacementRules` runs after raw transcription.
- `TranscriptArchiveRecord` persists `dictionarySnapshot`.

The next version should make provider support explicit:

- OpenAI file transcription: pass `context.transcriptionPrompt`.
- OpenAI realtime: include dictionary context in session instructions/input transcription prompt if supported by current API shape.
- Parakeet.cpp: add support only if the CLI exposes hotword/context flags. If not, mark `supportsHotwords = false` and rely on replacement rules.
- Field Theory Parakeet Python: inspect script support before claiming hotword support.
- Apple Speech: only pass custom vocabulary if Apple's APIs expose a supported mechanism on the target OS. Otherwise mark unsupported.
- Ollama cleanup: include dictionary snapshot in improve prompt, as existing improve engines already receive it.

Add `TranscriptionEngineCapabilities` or a model inventory capability field:

- `supportsPromptContext`
- `supportsHotwords`
- `supportsReplacementRulesOnly`
- `supportsStreamingPartial`
- `supportsWarmup`

Settings can then say "Dictionary terms are used as transcription context for this mode" or "Dictionary terms are applied as post-transcription replacements for this mode" without overclaiming.

### Provider Capability Matrix

Truth table for the first implementation:

| Provider | Prompt context | Native hotwords | Replacement rules | Streaming partial | Warmup | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| OpenAI file transcription | yes | no | yes | no | no | `OpenAIAudioTranscriber` already passes `context.transcriptionPrompt`. |
| OpenAI realtime | likely, verify current session shape before claiming in UI | no | yes | yes | connection startup only | UI copy should say dictionary support is used only after API shape is verified. |
| Parakeet.cpp Fast | no until CLI flag verified | no until CLI flag verified | yes | no | `info` only today | Do not claim hotword support. |
| Parakeet.cpp Recommended | no until CLI flag verified | no until CLI flag verified | yes | no | `info` only today | Default local mode still benefits from replacement rules. |
| Field Theory Python Parakeet | unknown | unknown | yes | no | persistent server | Inspect script before claiming dictionary context. |
| Field Theory Whisper | no in current wrapper | no | yes | no | persistent server | Could support prompts only if `whisper-server` endpoint accepts one; do not claim now. |
| Apple Speech | no in current wrapper | unknown on macOS 26 APIs | yes | result stream internal only | no explicit warmup | Check SDK docs before exposing vocabulary copy. |
| Ollama cleanup | yes for cleanup prompt | n/a | n/a | yes for improve stream | yes | Receives dictionary snapshot through improve engines. |

Settings dictionary line should be generated from capabilities:

- If transcription provider supports prompt/hotwords: `Dictionary terms guide transcription for this mode; replacement rules still run after transcription.`
- If transcription provider does not support prompt/hotwords but replacement rules exist: `Dictionary replacement rules run after transcription. This mode does not currently bias recognition.`
- If support is unknown: `Dictionary replacements run after transcription. Recognition bias has not been verified for this mode.`

## Implementation Units

### Unit 0: First Slice - Read-Only Inventory and Honest Settings Status

Files:

- `AutoImproveRecorder/Support/LocalModelInventory.swift`
- `AutoImproveRecorder/Support/LocalRuntimeHealth.swift`
- `AutoImproveRecorder/Support/LocalRuntimeProbe.swift`
- `AutoImproveRecorder/AppState.swift`
- `AutoImproveRecorder/UI/SettingsView.swift`
- `Tests/AutoImproveRecorderLocalModelTests/LocalModelInventoryTests.swift`
- `Tests/AutoImproveRecorderLocalModelTests/LocalModelModeTests.swift`
- `AutoImproveRecorder.xcodeproj/project.pbxproj`

Goal:

- Add read-only model inventory/status and exact Settings copy around existing modes.
- Add preset actions for Recommended, Fast, All Local, Apple Speech, and Cloud Realtime.
- Do not implement downloads, broker, native CoreML, or behavior-changing transcription rewrites.

Why this is the smallest valuable slice:

- It immediately fixes the current user confusion between Local Whisper, Field Theory Parakeet, Parakeet.cpp Fast/Recommended, All Local, Apple Speech, and cloud realtime.
- It gives future installer/warmup/broker work a typed status layer.
- It can be unit-tested without real models and manually verified against the existing installed runtime.

Acceptance:

- Settings shows the six primary rows and status badges.
- `Use Recommended`, `Use Fast`, `Use All Local`, `Use Apple Speech`, and `Use Cloud Realtime` mutate preferences as specified.
- No model is loaded as part of opening Settings.
- Existing transcription and improvement behavior is unchanged unless the user clicks a preset action.

### Unit 1: Local Model Inventory

Files:

- `AutoImproveRecorder/Support/LocalModelInventory.swift`
- `AutoImproveRecorder/Support/LocalRuntimeHealth.swift`
- `Tests/AutoImproveRecorderLocalModelTests/LocalModelInventoryTests.swift`

Responsibilities:

- Define model IDs, mode mapping, install states, health details, and capabilities.
- Discover AIR-owned Parakeet.cpp files.
- Discover Apple Speech availability without heavy work.
- Discover Ollama readiness through a short HTTP probe.
- Represent Field Theory providers as compatibility entries.

Test scenarios:

- Missing Parakeet.cpp tree returns `notInstalled`.
- CLI present but model missing returns runtime/model-specific incomplete state.
- CLI and required model present returns installed without calling heavy warmup.
- Apple Speech unavailable reason is rendered without pretending a download exists.
- Ollama tag response with and without `qwen3.5:0.8b-mlx` maps correctly.

### Unit 2: Installer and Download Progress

Files:

- `AutoImproveRecorder/Support/LocalModelInstaller.swift`
- `AutoImproveRecorder/Support/LocalModelDownloadClient.swift`
- `Tests/AutoImproveRecorderLocalModelTests/LocalModelInstallerTests.swift`

Responsibilities:

- Download to staging.
- Emit progress.
- Support cancellation.
- Verify file sizes/checksums when known.
- Promote atomically.
- Surface repairable errors.

Test scenarios:

- Progress moves from 0 to 1 and final state is installed.
- Cancelled download removes staging files.
- Failed checksum does not promote.
- Existing model reports already installed.
- Missing runtime dependency reports a specific file.

### Unit 3: Warmup Coordinator

Files:

- `AutoImproveRecorder/Support/LocalModelWarmupCoordinator.swift`
- `AutoImproveRecorder/AppState.swift`
- `Tests/AutoImproveRecorderLocalModelTests/LocalModelWarmupCoordinatorTests.swift`

Responsibilities:

- Replace scattered warmup decisions with cancellable selected-mode warmup.
- Preserve `prewarmRecordingStartResources()` as the only mic-start path.
- Debounce Settings changes.
- Back off after repeated failures.
- Track cold/warm status for performance records.

Test scenarios:

- Mode change cancels obsolete warmup.
- Warmup does not run synchronously from `startRecordingFlow`.
- Failed warmup is recorded and not retried immediately.
- Selected Recommended warms Recommended only.
- All Local warms transcription plus cleanup, not unrelated models.

### Unit 4: Settings Model Status UI

Files:

- `AutoImproveRecorder/UI/SettingsView.swift`
- `AutoImproveRecorder/AppState.swift`
- `AutoImproveRecorder/Models.swift`
- `Tests/AutoImproveRecorderLocalModelTests/LocalModelModeTests.swift`

Responsibilities:

- Show Fast, Recommended, All Local, Apple Speech, OpenAI API, and cloud realtime copy clearly.
- Add install/check/repair actions.
- Move raw Parakeet path fields into Advanced compatibility.
- Show dictionary capability per selected mode.

Test scenarios:

- All Local preset maps to Recommended Parakeet.cpp plus Ollama local.
- Cloud realtime mode is not described as all-local.
- Missing model state disables selection or records actionable warning.
- Advanced Field Theory paths still round-trip saved defaults.

### Unit 5: Persistent AIR Local Broker Spike

Files:

- `AutoImproveRecorder/Engines/ParakeetTranscriber.swift`
- `AutoImproveRecorder/Support/LocalParakeetBroker.swift`
- `Bench/model_eval.providers.json`
- `Bench/MODEL_EVAL.md`
- `Tests/AutoImproveRecorderLocalModelTests/LocalParakeetBrokerTests.swift`

Responsibilities:

- Evaluate a persistent process/server abstraction for AIR-owned Parakeet.cpp.
- Keep JSON command/response boundaries similar to existing `ParakeetServer`.
- Preserve CLI fallback while benchmarking.
- Record model load time separately from transcription time.

Test scenarios:

- Broker starts once for repeated transcriptions.
- Broker restarts when model variant changes.
- Broker returns empty transcript as provider-specific empty error.
- Broker timeout kills/restarts the child process.
- CLI fallback still works when broker is disabled.

### Unit 6: Performance Monitor and Archive Metrics

Files:

- `AutoImproveRecorder/Support/LocalPerformanceMonitor.swift`
- `AutoImproveRecorder/Support/TranscriptArchiveStore.swift`
- `AutoImproveRecorder/AppState.swift`
- `Bench/model_eval.py`
- `Tests/AutoImproveRecorderLocalModelTests/LocalPerformanceMonitorTests.swift`

Responsibilities:

- Capture model lifecycle and pipeline timings.
- Persist timing fields in archive records.
- Summarize cold versus warm runs.
- Extend benchmark logs to include lifecycle state.

Test scenarios:

- Stop-to-transcript timing is recorded.
- Empty transcript records provider and audio path metadata.
- Warm and cold runs are distinguishable.
- Archive save remains backward-compatible with older records.

### Unit 7: Native/CoreML Research Spike

Files:

- `Bench/LOCAL_MODEL_RESEARCH_2026-05-29.md`
- `Docs/Plans/2026-06-04-air-local-model-lifecycle-native-transcription-plan.md`
- future spike files only after approval

Responsibilities:

- Evaluate native Parakeet/Qwen3-ASR/CoreML candidates against the same gates.
- Document tokenizer/runtime complexity before any implementation.
- Compare against `Parakeet.cpp Recommended`, not against a strawman.

Exit criteria:

- A native candidate must prove better measured behavior or materially better lifecycle control.
- If not, continue with CLI/broker stack.

## Staged Implementation Plan

### Stage 0: Baseline and Diff Guard

- Re-run current local transcription and cleanup smoke benchmarks.
- Capture current Settings defaults and installed runtime health.
- Add no app code except optional benchmark provider config entries if needed.
- Output: baseline CSV/JSONL under `.autoresearch/`, notes in `Bench/MODEL_EVAL.md`, and current defaults from `defaults read`.

### Stage 1: First Slice - Inventory Status and Presets

- Add inventory and health types.
- Wire read-only status into `AppState`.
- Add Settings rows, exact copy, status badges, and preset actions.
- Add unit tests for discovery and mode mapping.
- Add no downloads, broker, or native ASR.
- Completion condition: a user can open Settings and understand exactly which local stack is ready and which action fixes missing pieces.

### Stage 2: Failure-State Hardening

- Make selected-mode preflight errors use inventory issues where possible.
- Keep local modes local: no silent cloud fallback from Recommended, Fast, Apple Speech, or All Local.
- Add archive fields for `fallbackUsed`, `originalFailure`, and `localModelID` if they are not already present.
- Add manual failure checklist entries for missing CLI, missing model, missing Ollama model, Ollama down, Apple Speech unavailable, and empty transcript.

### Stage 3: Warmup Coordinator

- Replace `AppState.prewarmLocalModels()` model-specific branching with `LocalModelWarmupCoordinator`.
- Preserve `prewarmRecordingStartResources()` as the only hotkey/mic-start prewarm.
- Add cancellation/backoff tests.
- Gate with hotkey-to-first-buffer measurements.

### Stage 4: Installer Skeleton

- Add installer interface and local staging logic.
- If hosted model URLs/checksums are not ready, expose `Open setup instructions` and `Re-check` only.
- If URLs/checksums are ready, add cancellable download and verification.
- Do not bundle large models in the app bundle.

### Stage 5: Persistent Broker Benchmark

- Implement broker behind a feature flag or provider variant.
- Add bench provider entries.
- Compare repeated cold/warm recordings.
- Promote only if it improves repeated stop-to-transcript timing without hurting reliability.

### Stage 6: Failure and Archive Metrics

- Add structured failure states.
- Extend transcript archive metadata.
- Add manual failure fixtures: missing model, missing CLI, timeout, empty transcript.

### Stage 7: Native/CoreML Spike

- Only after Stages 1-6 are stable.
- Evaluate CoreML candidates as replacements or optional variants.
- Gate on benchmarks, not subjective native feel.

## First Implementation Slice Checklist

An implementer can start with this exact checklist:

1. Add `LocalModelID`, `LocalModelDescriptor`, `LocalModelStatus`, `LocalModelIssue`, `LocalModelCapabilities`, and `LocalRuntimeProbe`.
2. Add fake-probe unit tests for no files, partial Parakeet.cpp install, full Parakeet.cpp install, Ollama reachable with/without model tag, and Apple unavailable.
3. Add `AppState.localModelStatuses` and `refreshLocalModelStatuses()` with no model loading.
4. Add Settings rows and copy from `Settings UX Contract`.
5. Add preset action methods on `AppState` so UI does not mutate multiple settings inline.
6. Move existing raw Parakeet path fields under a `Legacy local providers` disclosure, keeping the current bindings.
7. Verify opening Settings does not spawn or warm local models.
8. Run unit tests and a manual Settings pass.

## Manual Verification

Run through these after implementation stages, not during this planning thread:

- Fresh install with no AIR Parakeet.cpp support tree: Settings shows missing models and no crash.
- Install/copy runtime tree: Settings flips to installed/ready after Re-check.
- Select Recommended: record 5s, 30s, 120s fixtures and real dictation; archive records provider and timing.
- Select Fast: verify faster/less-reliable copy is clear; empty transcript error recommends Recommended.
- Select All Local: disconnect network, verify Parakeet.cpp plus Ollama path still works when Ollama model is present. If Ollama pulls or tag checks need network, do that before disconnecting.
- Stop Ollama: All Local reports cleanup runtime missing and preserves raw transcript.
- Remove model file: actionable missing model error.
- Break CLI executable bit: actionable runtime error.
- Add dictionary term: verify OpenAI prompt-capable paths receive context; local paths honestly report if they do not support hotwords; replacement rules still apply.
- App launch: no model load on launch.
- Hotkey recording: first audio buffer timing does not regress.
- Cancel recording: no lingering warmup blocks or child process leaks.

## Deferred Decisions Register

These are deliberately parked so Stage 1 can ship:

- Hosted Parakeet.cpp artifact URLs, checksums, and license presentation.
- Whether AIR should delete or migrate old Field Theory path preferences after several releases.
- Whether the persistent broker should be app-managed Swift `Process`, helper binary, or upstream server mode.
- Whether to add true local streaming ASR after broker benchmarking.
- Which native CoreML model family to spike first.

## Review Checklist

- Does the Settings mode language make cloud/local boundaries impossible to misunderstand?
- Does every install state have an actionable next step?
- Does warmup avoid app launch and mic-start critical paths?
- Are local default changes benchmark-backed?
- Are dictionary claims provider-specific and honest?
- Does the archive capture enough detail to diagnose missing, slow, or empty local runs later?
