# Local Model Research - 2026-05-29

Goal: find faster local models for the recorder's transcription and cleanup
pipeline, benchmark them against the read-aloud ground truth set, and separate
measured results from external model-card claims.

## Short Answer

`qwen3:8b` is not workable for interactive cleanup here. Also, "newer Qwen"
does not mean "better local cleanup model" for this app:

- Hosted/API Qwen has moved past Qwen3.6-Plus: Alibaba announced
  `qwen3.7-max` on 2026-05-21.
- Local Ollama `qwen3.6` exists, but the verified local variants are 27B/35B
  class models, not a fast 0.8B/2B/4B cleanup candidate for this Mac.
- Ollama `qwen3.5` does have small local variants, including MLX tags for
  Apple Silicon. Those were benchmarked. `qwen3.5:0.8b-mlx` is the fastest
  plausible cleanup model, but it is less conservative with dates and code-ish
  words.

The current practical shortlist is:

- Fast local transcription: `whisper.cpp` with `ggml-small.en.bin`, beam size 1.
- Best local transcription quality: MLX Whisper `large-v3-turbo` in resident
  server mode.
- Local cleanup: `qwen3:4b-instruct` for conservative, literal cleanup.
- Fastest plausible local cleanup: `qwen3.5:0.8b-mlx`, but only as an explicit
  speed mode because it sometimes preserves filler or normalizes dates/numbers
  beyond the read script.

The best local interactive stack to test in-app next is:

```text
whispercpp-small-en-fast -> ollama-qwen3-4b-instruct
```

Accuracy-first local stack:

```text
mlx-whisper-large-v3-turbo-server -> ollama-qwen3-4b-instruct
```

## Runtime Best-Practice Audit

The app build now uses the faster local path directly:

- `Local Whisper` starts Field Theory's bundled `whisper-server` and keeps
  the `ggml-small.en.bin` model resident. It uses GPU by default, Flash
  Attention left on, explicit English language selection, no timestamps, beam
  size 1, best-of 1, and 8 threads. This avoids the command-per-record cold
  start penalty.
- `Ollama local` calls Ollama's native `/api/chat` endpoint instead of the
  OpenAI-compatible endpoint, so the app can pass native runtime controls:
  `think: false`, `keep_alive: "30m"`, and `options.num_predict: 320`.
- The app prewarms `whisper-server` and sends a tiny Ollama warmup request on
  launch when the selected modes are `Local Whisper` and `Ollama local`.
- Ollama cleanup uses native streaming responses in the app, so the preview can
  show partial improved text before the full generation finishes.
- The default cleanup model is `qwen3:4b-instruct`, not the default thinking
  `qwen3:4b` tag and not the too-slow `qwen3:8b`.
- The launched app defaults were set to `transcriptionMode=localWhisper`,
  `improvementMode=ollamaLocal`, `ollamaModel=qwen3:4b-instruct`,
  `autoImproveMode=automatic`, and `thresholdWords=35`.
- The benchmark harness now passes optional Ollama provider runtime controls
  through to `/api/chat`: `top_p`, `top_k`, `repeat_penalty`, and `num_ctx`.
  This matters for testing newer model families without pretending all of them
  share the same best sampling/runtime settings.

Verification after launch:

```text
ollama ps -> qwen3:4b-instruct loaded, 100% GPU, keep-alive about 29 minutes
whisper-server -> installed at /Applications/Field Theory.app/Contents/Resources/whisper-server
ggml-small.en.bin -> installed in ~/Library/Application Support/fieldtheory-mac/models/
```

One default-provider Ollama smoke run through the benchmark harness completed
in 5.43s after re-pulling `qwen3:4b-instruct`, with no error. The result obeyed
the cleanup-only contract and returned text without a preface.

## Local Benchmarks

All numbers below are from the 16-item read-aloud corpus in
`.autoresearch/read-aloud.corpus.json`.

### Transcription

| Provider | Mean WER | Median WER | Mean latency | Median latency | P95 latency | Median RTF |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `mlx-whisper-large-v3-turbo-server` | 5.05% | 2.75% | 1.18s | 1.17s | 1.26s | 0.094 |
| `parakeet-field-theory` | 6.38% | 5.64% | 2.19s | 1.84s | 3.60s | 0.157 |
| `whispercpp-small-en-fast` | 7.35% | 5.56% | 0.76s | 0.77s | 0.87s | 0.061 |
| `moonshine-medium-streaming` | 10.47% | 8.06% | 1.25s | 1.23s | 1.63s | 0.100 |
| `moonshine-small-streaming` | 19.87% | 17.29% | 1.01s | 0.96s | 1.40s | 0.084 |
| `moonshine-tiny-streaming` | 33.29% | 33.78% | 0.65s | 0.68s | 0.94s | 0.052 |
| `parakeet-field-theory-v3` | 4.50% | 0.00% | 27.29s | 8.11s | 60.50s | 0.596 |

Interpretation: MLX Whisper `large-v3-turbo` resident server is now the local
quality winner on the grounded corpus, with better mean WER than Parakeet and
much lower latency. `whisper.cpp` small.en fast is still the speed winner.
Moonshine does not fit this use case: medium is slower and less accurate than
MLX Whisper, while small/tiny trade too much accuracy for speed.
The Parakeet v3 smoke used only three items and a command-per-record harness,
not the app's persistent server mode. It loaded and transcribed, but the first
v3 item paid a large initialization/download cost and the steady items were
still around 7-8s in that harness, so v3 is not a drop-in speed win yet.

### Cleanup

Full 16-item finalist run:

| Provider | Reference WER | Median latency | P95 latency | Mean edit ratio | Notes |
| --- | ---: | ---: | ---: | ---: | --- |
| `ollama-qwen3-4b-instruct` | 8.35% mean / 4.51% median | 1.90s | 2.41s | 0.7% | Best literal preservation. Often leaves already-clean input unchanged. |
| `ollama-llama3.2-3b` | 19.73% mean / 11.43% median | 1.53s | 2.10s | 11.6% | Faster, but more likely to rewrite dates, numbers, and structure. |
| `ollama-qwen3-8b` | not completed | roughly 24-52s on successes | timeout on one item | n/a | Too slow for the app's interaction loop. |

Expanded current-model cleanup pass:

| Provider | Scope | Mean latency | Median latency | P95 latency | Reference WER | Mean edit ratio | Decision |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| `ollama-qwen3-4b-instruct` | 16 items | 2.20s | 1.95s | 3.40s | 8.35% | 0.7% | Keep as default. Best literal preservation. |
| `ollama-qwen3.5-0.8b` | 16 items | 1.55s | 1.57s | 1.95s | 10.31% | 2.2% | Candidate speed mode. Faster, but weaker on conservative cleanup. |
| `ollama-qwen3.5-0.8b-mlx` | 16 items | 0.91s | 0.87s | 1.29s | 9.87% | 5.3% | Fastest candidate. More aggressive; use only as explicit speed mode. |
| `ollama-qwen3.5-2b` | 16 items | 2.36s | 2.36s | 2.82s | 10.03% | 2.4% | Slower than default with no quality win. |
| `ollama-qwen3.5-4b-mlx` | 16 items | 2.59s | 2.67s | 3.29s | 7.32% | 0.1% | Accurate/conservative, but not faster than default and can under-clean structured prompts. |
| `ollama-qwen3.5-4b` | 5 items | 8.52s | 5.14s | 19.38s | 15.79% | 1.6% | Too slow here. |
| `ollama-gemma4-e2b` | 5 items | 13.86s | 12.73s | 17.14s | 14.41% | 0.3% | Too slow for interactive cleanup. |
| `ollama-granite4-350m` | 5 items | 2.70s | 2.94s | 3.09s | 141.76% | 121.8% | Rewrites destructively. Reject. |
| `ollama-granite4-1b` | 5 items | 8.23s | 7.63s | 10.76s | 123.76% | 109.6% | Rewrites destructively and is slow. Reject. |

Manual inspection of the 16-item Qwen comparison explains the recommendation.
The regular `qwen3.5:0.8b` is meaningfully faster, but it left the leading
"Um" in one filler-heavy command, converted "Friday May twenty ninth twenty
twenty six at two thirty" into "Friday, May 29, 2026, at 2:30 PM", and failed
to normalize `audio dot wav` / `record dot json` where `qwen3:4b-instruct`
produced `audio.wav` / `record.json`. The MLX `qwen3.5:0.8b-mlx` tag removed
filler better and was faster again, but it still over-normalized the date and
turned "record dot json" into "recording .json". Those are exactly the kinds of
details this app needs to preserve or handle predictably.

The MLX `qwen3.5:4b-mlx` tag is interesting but not a speed replacement. It was
fairly conservative and had the best reference WER in the expanded run, but it
often did almost no cleanup and was slower than `qwen3:4b-instruct` on median
latency.

Small-model shootout on three representative items:

| Provider | Result |
| --- | --- |
| `qwen3:4b-instruct` | Viable. Similar sample quality to `llama3.2:3b`, more literal. |
| `llama3.2:3b` | Viable. Fastest plausible model, but somewhat over-eager. |
| `llama3.2:1b` | Not worth using; inconsistent and once copied `/no_think` into output. |
| `gemma3:1b` | Fast but too compressive/destructive. |
| `qwen3:0.6b` | Too destructive. |
| `qwen3:1.7b` | Wrong behavior in this setup; thinking/default tag produced bad/blank output. |
| `qwen3:4b` | Wrong tag for this use; use `qwen3:4b-instruct` instead. |
| `phi4-mini` | Too slow and too rewrite-heavy for this cleanup task. |

## Cloud Comparison

I did not run a live OpenAI benchmark because `OPENAI_API_KEY` is not set in
this shell. The harness has disabled OpenAI providers ready for explicit
selection once a key is present.

Practical comparison:

- OpenAI cloud (`gpt-4o-transcribe` / `gpt-4o-mini-transcribe`) is the likely
  robustness baseline for noisy audio, accents, and general ASR quality.
- For this app's local paste loop, cloud may still feel slower or more variable
  because every clip has upload, network, queue, and response overhead.
- Local wins on privacy, offline behavior, and predictable sub-second to
  low-single-second latency for these short clips.
- We should only claim cloud latency after measuring it from this Mac with the
  same corpus.

Benchmark command when a key is available:

```bash
OPENAI_API_KEY=... python3 Bench/model_eval.py transcribe \
  --corpus .autoresearch/read-aloud.corpus.json \
  --config Bench/model_eval.providers.json \
  --provider openai-gpt-4o-transcribe \
  --provider openai-gpt-4o-mini-transcribe \
  --runs 1 \
  --out .autoresearch/read-aloud-openai-transcription.jsonl
```

## Research Notes

- NVIDIA Parakeet TDT 0.6B v2 is a 600M-parameter ASR model with punctuation,
  capitalization, timestamps, 6.05 average WER on the Hugging Face Open-ASR
  leaderboard, and very high reported batch throughput.
- NVIDIA's newer Parakeet options have expanded. `parakeet-unified-en-0.6b`
  was published on Hugging Face on 2026-04-07 and is explicitly designed for
  English offline and streaming ASR; NVIDIA says latency can be as low as
  160ms in its intended streaming use case.
- NVIDIA's current NeMo speech model selector points to Parakeet-TDT 0.6B V3
  for fast offline ASR, Canary-Qwen 2.5B for best English accuracy, and
  Nemotron-Speech-Streaming for real-time streaming. These are the right next
  local ASR candidates to test if we want to beat the current Parakeet path.
- Qwen3-ASR-0.6B is also current and relevant: the Hugging Face model card says
  Qwen3-ASR-0.6B and 1.7B support language identification and ASR for 30
  languages plus 22 Chinese dialects. It is worth testing, but the local Apple
  tooling path is less mature than `whisper.cpp` or NVIDIA NeMo today.
- OpenAI's current speech-to-text docs position `gpt-4o-transcribe` and
  `gpt-4o-mini-transcribe` as newer transcription models with lower WER than
  original Whisper, and they support prompting for transcription style/context.
- `whisper.cpp` remains the simplest fast local CPU/GPU path already present on
  this machine through Field Theory's bundled `whisper-server` / `whisper-cli`.
- MLX Whisper `large-v3-turbo` resident server has now been tested and is the
  local quality winner on this corpus: 1.18s mean latency and 5.05% mean WER.
- Moonshine medium/small/tiny streaming were tested and rejected for this use
  case. The best Moonshine quality result, medium-streaming, was 1.25s mean
  latency and 10.47% mean WER, worse than MLX Whisper on both accuracy and
  latency. The small and tiny variants were faster but too inaccurate; the
  Moonshine venv/cache was removed after testing.
- For cleanup, avoid default thinking Qwen3 tags unless the harness explicitly
  disables reasoning and limits output. The instruct/non-thinking Qwen3 tags are
  better suited to short cleanup.
- Qwen3.7-Max is the newest Qwen model found in this pass, but it is a hosted
  proprietary/API model, not a local speed candidate. Qwen3.6 local on Ollama is
  27B/35B class, so it is also not a speed candidate for this recorder loop.
- Current local cleanup candidates tested in this expanded pass: Qwen3.5
  0.8B/2B/4B, Qwen3.5 MLX 0.8B/4B, Gemma 4 E2B, Granite 4 350M, Granite 4 1B,
  plus earlier Qwen3, Llama 3.2, Gemma 3, and Phi-4 mini candidates.

## Files Produced

- `.autoresearch/read-aloud-transcription-compare.csv`
- `.autoresearch/read-aloud-local-llm-shootout-with-qwen-instruct.csv`
- `.autoresearch/read-aloud-local-cleanup-finalists.csv`
- `.autoresearch/read-aloud-whispercpp-small-fast.jsonl`
- `.autoresearch/mlx-whisper-large-v3-turbo-server-transcription.csv`
- `.autoresearch/mlx-whisper-large-v3-turbo-server-transcription.jsonl`
- `.autoresearch/moonshine-medium-streaming-transcription.csv`
- `.autoresearch/moonshine-medium-streaming-transcription.jsonl`
- `.autoresearch/moonshine-small-streaming-transcription.csv`
- `.autoresearch/moonshine-small-streaming-transcription.jsonl`
- `.autoresearch/moonshine-tiny-streaming-transcription.csv`
- `.autoresearch/moonshine-tiny-streaming-transcription.jsonl`
- `.autoresearch/read-aloud-local-cleanup-finalists.jsonl`
- `.autoresearch/qwen35-cleanup-full.csv`
- `.autoresearch/qwen35-cleanup-full.jsonl`
- `.autoresearch/current-local-cleanup-shootout-limit5.csv`
- `.autoresearch/current-local-cleanup-shootout-limit5.jsonl`
- `.autoresearch/current-local-cleanup-full.csv`
- `.autoresearch/current-local-cleanup-full.jsonl`
- `.autoresearch/qwen35-mlx-cleanup-full.csv`
- `.autoresearch/qwen35-mlx-cleanup-full.jsonl`
- `.autoresearch/parakeet-v3-smoke.csv`
- `.autoresearch/parakeet-v3-smoke.jsonl`

## Sources Checked

- Alibaba Cloud Qwen3.7-Max announcement:
  https://www.alibabacloud.com/blog/qwen3-7-the-agent-frontier_603154
- Alibaba Cloud Qwen3.6-Plus announcement:
  https://www.alibabacloud.com/blog/alibaba-unveils-qwen3-6-plus-to-accelerate-agentic-ai-deployment-for-enterprises-and-alibaba%E2%80%99s-ai-applications_603005
- Ollama Qwen3.6:
  https://ollama.com/library/qwen3.6
- Ollama Qwen3.5:
  https://registry.ollama.com/library/qwen3.5
- Ollama Gemma 4:
  https://ollama.com/library/gemma4
- Ollama Granite 4:
  https://ollama.com/library/granite4
- NVIDIA Parakeet TDT 0.6B v2 model card:
  https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2
- NVIDIA Parakeet Unified EN 0.6B model card:
  https://huggingface.co/nvidia/parakeet-unified-en-0.6b
- NVIDIA NeMo-Speech model selector:
  https://docs.nvidia.com/nemo/speech/nightly/starthere/choosing_a_model.html
- Qwen3-ASR 0.6B model card:
  https://huggingface.co/Qwen/Qwen3-ASR-0.6B
- OpenAI speech-to-text docs:
  https://platform.openai.com/docs/guides/speech-to-text
- `whisper.cpp`:
  https://github.com/ggml-org/whisper.cpp
- OpenAI Whisper large-v3-turbo model card:
  https://huggingface.co/openai/whisper-large-v3-turbo
- MLX Whisper examples:
  https://github.com/ml-explore/mlx-examples/tree/main/whisper
- WhisperKit:
  https://github.com/argmaxinc/WhisperKit
- Ollama Qwen3 tags:
  https://ollama.com/library/qwen3/tags
- Ollama Llama 3.2:
  https://ollama.com/library/llama3.2
- Ollama Gemma 3:
  https://ollama.com/library/gemma3
- Ollama Phi-4 mini:
  https://ollama.com/library/phi4-mini
