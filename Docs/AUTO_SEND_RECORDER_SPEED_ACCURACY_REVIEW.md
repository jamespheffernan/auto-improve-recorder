# Auto Send Recorder: speed, accuracy, and experience

Date: 12 August 2026

Status: Built, verified, and installed with permission limits. This is not a claim that Auto Send Recorder is the fastest or most accurate product in its market.

## Outcome

Auto Send Recorder is a separate macOS target. Current source uses bundle ID `com.turfterrace.autosendrecorder` and its own preferences domain. The previously tested app at `/Applications/Auto Send Recorder.app` has not been replaced or reverified for this identity; the measurements below remain historical evidence. Its target has no Auto Improve engine and no cloud transcription or improvement provider path. It uses the installed local Parakeet.cpp runtime shared with AIR.

The product now has these behaviors:

- It records, transcribes locally, pastes, and sends without an improvement pass.
- A known app without a rule uses Enter. A rule can use Enter, Command-Enter, or Do not send. WhatsApp starts with Do not send.
- An unknown destination never sends. Before a send, the app checks the bundle ID, process ID, focused field identity, and editable state again.
- The Interface Craft HUD gives an immediate recording state, hides very short delivery states, shows a short success result, supports Reduce Motion, and does no model or delivery work.
- Cancel stops active work and keeps the saved recording. A new operation cannot accept late output from an old operation.
- A temporary pasteboard write is restored only if no other app changed the pasteboard. This prevents the app from overwriting newer clipboard content.
- A capture or archive failure is terminal. The app does not send a partial transcript. Normal recordings use `~/Library/Application Support/Auto Send Recorder/Recordings`.

Key implementation links: [workflow](../AutoSendRecorder/AutoSendCore.swift), [delivery adapter](../AutoSendRecorder/AutoSendDeliveryAdapter.swift), [recording service](../AutoSendRecorder/AutoSendRecordingService.swift), [settings](../AutoSendRecorder/AutoSendSettingsView.swift), and [HUD](../AutoSendRecorder/UI/AutoSendHUD.swift).

## Verification result

The final combined Swift run passed 157 tests. One optional private-corpus test had the expected skip. The focused Auto Send suite passed 22 of 22 tests. Debug and Release builds passed for Auto Send Recorder and AutoImproveRecorder. The target manifest tests also check that improvement engines and OpenAI, Anthropic, Gemini, and Ollama provider tokens are absent from the Auto Send source set.

The fixed Release product is installed. Its source and installed executable hashes match. The installed process used the expected bundle ID and `/Applications` path. The settings command opened an on-screen 520 by 442 window in the installed app. Core Graphics proved the window state; the automation capture was black, so this is not a visual-content comparison.

The installed app also recovered from an unanswered microphone request after 12 seconds and returned to a typed, usable state. In Ready and permission-wait checks, CPU was 0.0% and resident memory was approximately 1.98 GB after the local model warm-up.

Microphone and Accessibility permission are still unavailable. A physical hotkey test and a full record-stop-paste cycle in TextEdit therefore still need user action. No real message, email, or form was used. See the [installed-app verification](AUTO_SEND_RECORDER_INSTALLED_VERIFICATION.md).

## Measured speed facts

The local live-model proof produced the exact expected 25-word transcript. Average model work was 8.51 ms for each 80 ms audio feed. Finalization took 30.10 ms, and the short-run peak footprint was 2.107 GB. This is a model-harness result, not full product latency. See the [AIR-1 live warm-up proof](../.autoresearch/air-1-live-warmup-proof/README.md).

The Auto Send orchestration benchmark ran 30 Release trials with 5,000 iterations per trial:

| Path | p50 | p95 | p99 |
| --- | ---: | ---: | ---: |
| Baseline | 0.003715 ms | 0.003866 ms | 0.004065 ms |
| Per-app command hook | 0.003824 ms | 0.003932 ms | 0.004172 ms |

The per-app rule cost is too small to matter at product scale. The current 80 ms paste-to-send settlement delay is much larger. A composed value of about 110.824 ms is only a planning estimate: 30.82 ms model finalization, about 0.004 ms synthetic orchestration, and 80 ms settlement. It excludes real focus changes, paste behavior, archive I/O, capture, and app response. See the [orchestration verdict](../.autoresearch/auto-send-recorder-baseline/VERDICT.md).

The shared audio path also removed repeated work. In the 120-second Parakeet harness, raw copies fell from 45,000 to 22,500, stream-buffer allocations fell from 22,500 to zero, conversion-buffer allocations fell from 22,500 to one, and temporary Float arrays fell from 24,000 to zero. Archive, OpenAI conversion, Parakeet input, and transcript digests stayed equal. CPU results varied, so this is not a guaranteed CPU-speed claim. See the [AIR-4 implementation verdict](../.autoresearch/air-4-audio-implementation/AIR-4_IMPLEMENTATION.md).

## Blocked speed gate

A direct text-insertion experiment did not pass its live two-process gate. macOS did not expose both fixture targets through Accessibility, so it produced zero live operations and no latency values. The product keeps the known-safe Command-V path and the 80 ms settlement delay before Enter or Command-Enter.

Do not remove that fallback on an estimate. A new path must pass 10,000 same-Mac live operations with zero wrong-field writes, duplicate sends, missing text, clipboard damage, or send-after-cancel events. See the [delivery fixture verdict](../.autoresearch/auto-send-delivery-fixture/verdict.md).

## Accuracy state and model choices

The current `nemotron-3.5-asr-streaming-0.6b-q8_0.gguf` model remains the default. NVIDIA released Nemotron 3.5 on 4 June 2026, so it is current rather than stale. The installed model is 983,696,512 bytes and runs through the local `parakeet.cpp` C API and Metal backend.

There is no valid local accuracy result yet. The archive has 715 records with audio, but it has 0 trustworthy human-corrected spoken references. The planned corpus therefore needs 110 human-listened and corrected references. A model output cannot be its own truth. No word-error, punctuation, jargon, or market-accuracy claim is valid before this work. See the [accuracy audit](../.autoresearch/auto-send-asr-accuracy/AUDIT.md) and [curation guide](../.autoresearch/auto-send-asr-accuracy/CURATION.md).

The recent challenger order is:

1. NVIDIA English Nemotron Speech Streaming 0.6B for an English-specific local test.
2. Apple DictationTranscriber for a system-managed, context-aware test.
3. Moonshine Medium Streaming, released 7 August 2026, for its small model and built-in phrase completion.
4. Qwen3-ASR 0.6B as an optional quality mode because it has more memory and delay.
5. Voxtral Mini 4B Realtime only as a high-memory experiment.

No challenger was downloaded or promoted. The fixed local bake-off must decide. See the [model bake-off](RECENT_ASR_MODEL_BAKEOFF.md).

## Competitor benchmark standard

A speed-leadership claim needs a same-Mac test. Use the same microphone or fixed PCM, the same 110 verified clips, the same manual stop point, and the same target text field for Auto Send Recorder and each competitor. Record cold and warm results for time to first visible state, time to first stable text, stop-to-final, stop-to-paste, and stop-to-send at p50 and p95. Also record word error rate, missed final words, duplicates, wrong sends, silence hallucinations, CPU, energy, and peak memory. Keep product versions, settings, model hashes, macOS build, and raw runs with the result.

Until that test passes, the correct statement is: Auto Send Recorder has a short local path and strong measured components. It is not proven to lead the market.

## Later trigger backlog

These are ideas only. None is implemented.

1. Mouse side-button hold: fast and one-handed; risk of driver conflicts and accidental starts.
2. USB or Bluetooth foot pedal: hands-free and clear; risk of extra hardware, reconnect failures, and device-specific mapping.
3. Menu-bar press-and-hold: easy to discover and needs no setup; pointer travel makes it slower than a hardware control.
4. AirPods stem or media control: useful away from the keyboard; media ownership, Bluetooth delay, and limited event access can make it unreliable.
5. Spoken end phrase: useful when hands are busy; false matches, continuous listening, and removal of the end phrase need strict tests.

## Integrity caveat

AutoImproveRecorder dictionary files stayed byte-identical during installed-app verification. Its preference file was rewritten when AutoImproveRecorder quit and again when it reopened. The strict byte-preservation gate therefore failed. The evidence is consistent with normal serialization or flushing, but it does not prove that all logical values stayed equal because there was no canonical before-value export. This is an integrity caveat, not proven data loss. No preference file was restored.

## Items to review

- [ ] Grant Microphone and Accessibility permission, then run one safe physical-hotkey and TextEdit record-stop-paste gate.
- [ ] Curate and human-check the 110 audio clips.
- [ ] Approve model downloads and the local bake-off later.
- [ ] Approve a same-Mac competitor benchmark.
- [ ] Keep the safe 80 ms fallback until a replacement passes the 10,000-operation gate.
- [ ] Choose the next trigger prototype.
