# Recent local ASR model bake-off

Date: 11 August 2026

Status: Research and test plan only. This document makes no change to the app's default model.

## Finding

The current `nemotron-3.5-asr-streaming-0.6b-q8_0.gguf` model is not stale. NVIDIA released Nemotron 3.5 on 4 June 2026, so it is about two months old. It remains the default until a challenger passes the gates in this plan. NVIDIA recommends its English-only Nemotron checkpoint for English-only transcription, which makes that model the first challenger. [Nemotron 3.5 model card](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b)

The current local harness is the starting line: about 8 ms of work per 80 ms audio feed, 25–30 ms finalization, punctuation and capitalization, and a 2.46 GB peak process footprint on a 120-second run.

## Ranked challengers

| Rank | Candidate | Release and licence | Dictation and live behavior | Context and endpointing | Local Mac path, resource cost, and effort | Official measurements |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Nemotron Speech Streaming English 0.6B | 13 March 2026; NVIDIA Open Model License | English-only, native punctuation and capitalization, true cache-aware streaming at 80–1120 ms | No hotword or end-of-utterance interface is documented | Official 700 MB Q8 file; Metal and native C interface through [NeMo-Speech.cpp](https://github.com/NVIDIA/NeMo-Speech.cpp); medium effort because the app now uses parakeet.cpp | Average normalized word error rate is 8.43% at 80 ms and 6.93% at 1.12 s. NVIDIA recommends it for English-only use. [Model card](https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b) [Files](https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b/tree/main) |
| 2 | Apple DictationTranscriber | Apple system component; no model redistribution licence | Uses the same on-device models as system dictation. `progressiveShortDictation` provides live provisional text, frequent final results, and punctuation. | Up to 100 short contextual phrases, custom vocabulary and pronunciation, and content hints; finalization is built in | Native Speech framework on macOS 26 or later; model size and memory are system-managed; low-to-medium effort | Apple publishes no word error rate, memory, or latency result, so the local bake-off decides. [DictationTranscriber](https://developer.apple.com/documentation/speech/dictationtranscriber) [Presets](https://developer.apple.com/documentation/speech/dictationtranscriber/preset) [Contextual strings](https://developer.apple.com/documentation/speech/analysiscontext/contextualstrings) |
| 3 | Moonshine Medium Streaming | Current release 7 August 2026; MIT for code and English models | 245M parameters, true cached streaming; punctuation and capitalization are not promised and must be tested | Built-in voice detection and phrase completion; no general hotword interface; optional spelling model for codes | Official [Swift package](https://github.com/moonshine-ai/moonshine-swift) and macOS sample; about 291 MB of Q8 model files; ONNX Runtime CPU is the recommended Apple path; medium effort | Open ASR average word error rate is 6.65%. Reported MacBook Pro response time is 74 ms from detected phrase end to final text. The 30 July Q8 update gives 2.17% LibriSpeech test-clean word error rate versus 2.16% for reproduced floating point. [Repository and measurements](https://github.com/moonshine-ai/moonshine) [Releases](https://github.com/moonshine-ai/moonshine/releases) |
| 4 | Qwen3-ASR 0.6B | 29 January 2026; native Transformers support 26 June; Apache 2.0 | Strong written-form examples; the viable Mac C runtime updates in 2-second chunks with cached windows and text rollback | Free-form vocabulary, names, spelling, and domain prompt; external endpoint logic is needed | Pure C [qwen-asr](https://github.com/antirez/qwen-asr) uses Apple Accelerate and NEON, not Metal; 1.75 GiB weights and about 2.7–3.3 GiB peak memory; medium-to-high effort | The current model card reports 6.31% Open ASR average word error rate. Its Mac C runtime reports 9.6 s of compute for 45 s of interactive audio on an M3 Max. [Official model card](https://huggingface.co/Qwen/Qwen3-ASR-0.6B-hf) [Official repository](https://github.com/QwenLM/Qwen3-ASR) |
| 5 | Voxtral Mini 4B Realtime 2602 | 4 February 2026; Apache 2.0 | Native continuous streaming; punctuation and capitalization are not explicitly promised and must be tested; quality setting is 480 ms delay | No open realtime hotword interface; the C runtime can detect silence and flush pending text | [voxtral.c](https://github.com/antirez/voxtral.c) has Metal and a C streaming interface; 8.9 GB weights, about 8.4 GB Metal weight cache, and up to 1.8 GB key-value cache; high effort | English FLEURS word error rate is 4.90% at 480 ms, 6.46% at 160 ms, and 4.05% at 2.4 s. [Official model card](https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602) [Release post](https://mistral.ai/news/voxtral-transcribe-2/) |

Official results use different data sets and normalization rules. They do not establish a winner. Only the fixed local corpus below can compare the models fairly.

## Watchlist and rejects

- [Parakeet Unified English 0.6B](https://huggingface.co/nvidia/parakeet-unified-en-0.6b) reports 5.91% offline and 6.52% at 560 ms. Its current stream repeats left-context work, NVIDIA lists Linux and NVIDIA hardware, and neither parakeet.cpp nor NeMo-Speech.cpp lists this checkpoint. Do not integrate it until a supported local Mac path exists.
- [whisper.cpp](https://github.com/ggml-org/whisper.cpp/releases) reached version 1.9.2 in August 2026 and improved voice detection and Apple packaging. OpenAI has not released new Whisper weights in the target period. Keep the existing Whisper path as a control and fallback.
- Parakeet Realtime EOU 120M remains useful for automatic stopping, but the existing local test produced lower-case, unpunctuated text. It is not an accuracy challenger.

## Fixed 110-clip corpus

Use audio from Transcript Truth. A person must check each reference transcript. Do not use an AI-cleaned transcript as truth.

| Group | Clips | Purpose |
| --- | ---: | --- |
| Short commands, 1–5 seconds | 20 | Stop latency and short-word loss |
| Normal dictation, 5–20 seconds | 30 | Main quality result |
| Long dictation, 30–120 seconds | 15 | Drift, repetition, and memory growth |
| Noise, distance, and British accents | 15 | Real operating conditions |
| Product names and technical terms | 20 | Context and hotword value |
| Silence and non-speech | 10 | Hallucination control |
| **Total** | **110** | |

Run the same PCM audio through every model. Use the same manual-stop boundary for the main comparison. Run a second endpoint test only for engines that provide voice detection or phrase finalization.

## Measurements

- Normalized word error rate.
- Case accuracy and punctuation F1 score.
- Exact product-name and technical-term hit rate, with and without supported context.
- Time to first stable partial text.
- Stop-to-final time at the 50th and 95th percentiles.
- Wrong early endpoint and missed endpoint counts.
- Cold load time, idle resident memory, peak memory, CPU time, GPU time, and energy.
- Missing final words, repeated spans, and hallucinations on silence.
- Blind human preference for raw dictation output.

Record the Apple Silicon model, memory size, macOS build, runtime commit, model hash, quantization, chunk or delay setting, and corpus hash with every result.

## Promotion gates

A default live replacement must meet all safety gates and at least one value gate.

Safety gates:

- No increase in silence hallucinations, missing final words, or repeated phrases.
- No more wrong early endpoints or missed endpoints than the current model.
- The 95th-percentile stop-to-final time must remain at or below 100 ms.
- The model and runtime licences must permit the planned download, cache, and distribution method. Preserve the original licence and notices; a converted file cannot replace the source model's terms.

Value gates:

- At least 10% relative improvement in normalized word error rate, or
- At least 40% lower peak memory with no material quality loss.

Additional gates:

- A context-aware mode must improve the technical-term hit rate by at least 15 percentage points.
- Qwen or Voxtral can qualify only as an optional quality mode. They require at least 15% relative word-error improvement because of their delay and memory cost.
- Apple must retain a tested fallback for unsupported or missing local speech assets.

## Recommended execution order

1. Keep Nemotron 3.5 as the default and freeze its 110-clip baseline.
2. Test English Nemotron through NeMo-Speech.cpp at 80, 160, 320, and 560 ms.
3. Test Apple `progressiveShortDictation`, both without context and with the fixed 100-or-fewer phrase set.
4. Test Moonshine Medium Streaming with its default voice detector and with voice detection disabled for the manual-stop comparison.
5. Test Qwen3-ASR 0.6B as an optional quality pass, with and without the fixed vocabulary prompt.
6. Test Voxtral only on a Mac with enough memory and only if the first four challengers do not meet the value gates.
7. Publish one result table. Change the default only after a challenger passes every required gate.
