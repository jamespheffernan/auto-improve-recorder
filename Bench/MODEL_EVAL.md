# Model Evaluation Harness

This harness compares transcription providers and improvement providers without
changing the app. It is built around a corpus manifest, provider config, JSONL
run logs, and repeatable summaries.

## Setup

```bash
cd /Users/jamesheffernan/Code/auto-improve-recorder
python3 -m pip install openai
python3 Bench/model_eval.py write-config --out Bench/model_eval.providers.json
```

`Bench/model_eval.providers.json` is local-first: Field Theory Parakeet
transcription and Ollama cleanup providers are available, with OpenAI providers
kept as disabled cloud baselines. The current app default is
`qwen3.5:0.8b-mlx`; older Qwen/Gemma/Llama entries remain in the provider file
as disabled comparison candidates unless they are currently being tested.
Ollama providers expect Ollama to be running and the selected model already
pulled:

```bash
ollama pull qwen3.5:0.8b-mlx
```

The Field Theory Parakeet provider points at the installed runtime on this Mac:

```text
~/Library/Application Support/fieldtheory-mac/build-parakeet/venv/bin/python
/Applications/Field Theory.app/Contents/Resources/scripts/parakeet-transcribe.py
~/Library/Application Support/fieldtheory-mac/build-parakeet/cache
```

OpenAI providers use `OPENAI_API_KEY` when explicitly enabled or selected.

## Current Local Cleanup Result

The current AIR local cleanup default is `qwen3.5:0.8b-mlx`. On June 2, 2026,
the live app preference also matched that default:

```bash
defaults read com.fieldtheory.autoimproverecorder ollamaModel
defaults read com.fieldtheory.autoimproverecorder improvementMode
```

The small-model bake-off did not find a better Parakeet-style text improvement
replacement. Prior local runs showed `qwen3.5:0.8b-mlx` as the fastest good
cleanup model, while `qwen3:4b-instruct` and `qwen3.5:4b-mlx` were meaningfully
slower and several small GGUF models either over-edited, echoed reasoning, or
expanded the transcript.

Prompt-shape experiments also did not justify changing app behavior:

- Current app prompt: `.autoresearch/qwen35-mlx-no-prefix-repeat3-read-aloud.csv`
  reported mean `599 ms`, p50 `593 ms`, mean edit ratio `0.084`, and mean
  reference WER `0.146` across 48 runs.
- Current app prompt without `/no_think`: mean `602 ms`, p50 `601 ms`, mean
  edit ratio `0.096`, and mean reference WER `0.147` across 48 runs, so no
  stable speed or quality win.
- Transcript-only prompt without `/no_think`: a 16-run screen showed mean
  `843 ms` and substantial over-editing, even though some short over-edited
  outputs completed quickly.
- Compact/tagged prompt variants leaked prompt scaffolding on some samples and
  were slower or lower quality than the current prompt.

Output-cap experiments found one safe optimization. Keep the app on
`qwen3.5:0.8b-mlx` with the existing prompt shape, but use a bounded adaptive
Ollama `num_predict` cap instead of always requesting 320 output tokens. On a
48-run same-prompt comparison, `.autoresearch/qwen35-mlx-adaptive-cap-repeat3-read-aloud.csv`
showed adaptive-cap-320 improved mean latency from `986 ms` to `878 ms`, p50
from `904 ms` to `785 ms`, and p95 from `1403 ms` to `1292 ms`, with no
truncation or prompt scaffolding leaks in the corpus screen. Treat this as a
tail-latency improvement, not a model-quality change.

A larger optimization is the paste-ready bypass. For `Clean` and
`Near-verbatim` modes, the Ollama engine can return the transcript immediately
when the text already looks paste-ready: punctuated, terminally punctuated,
not too short or too long, no obvious filler/false-start artifacts, no spoken
file-extension artifacts such as `dot swift`, and no explicit transformation
request such as "make this into a task" or "clean this up". In
`.autoresearch/qwen35-mlx-bypass-repeat3-read-aloud.csv`, the bypass skipped
27 of 48 repeated read-aloud runs. Mean latency dropped from `775 ms` to
`345 ms`, p50 dropped from `777 ms` to `0.10 ms`, and p95 dropped from
`1042 ms` to `946 ms`. Mean reference WER improved from `0.130` to `0.106`
because paste-ready transcripts were not unnecessarily over-edited.

Use compact prompt styles only as benchmark experiments until a run beats the
current app prompt on both latency and preservation.

## Local-First Quick Run

Use archived app recordings for a realistic first pass. This builds a corpus
from `~/Library/Application Support/AutoImproveRecorder/TranscriptTruth/`, using
the archived raw transcript as the improvement input. It does not treat the app's
own raw transcript as ground-truth transcription accuracy.

```bash
python3 Bench/model_eval.py make-transcript-truth-corpus \
  --min-raw-chars 40 \
  --require-improvement-input \
  --out .autoresearch/transcript-truth.corpus.json
```

Run a small local transcription screen:

```bash
python3 Bench/model_eval.py transcribe \
  --corpus .autoresearch/transcript-truth.corpus.json \
  --config Bench/model_eval.providers.json \
  --provider parakeet-field-theory \
  --limit 3 \
  --runs 1 \
  --out .autoresearch/local-transcription-smoke.jsonl
```

Run local cleanup on the same real transcripts:

```bash
python3 Bench/model_eval.py improve \
  --corpus .autoresearch/transcript-truth.corpus.json \
  --config Bench/model_eval.providers.json \
  --provider ollama-qwen3.5-0.8b-mlx \
  --limit 3 \
  --runs 1 \
  --out .autoresearch/local-improvement-smoke.jsonl
```

Summarize both:

```bash
python3 Bench/model_eval.py summarize \
  .autoresearch/local-transcription-smoke.jsonl \
  .autoresearch/local-improvement-smoke.jsonl \
  --csv .autoresearch/local-model-smoke-summary.csv
```

For true transcription accuracy, hand-correct transcripts into
`reference_transcript` fields or add `.txt` / `.transcript.txt` sidecars next to
audio files before running WER/CER comparisons. Without that, transcription runs
are latency, stability, and qualitative-output evidence only.

If you want a rough regression check against the app's archived raw transcript,
add `--use-app-raw-as-reference` when building the TranscriptTruth corpus. Treat
those WER/CER numbers as pseudo-reference drift, not model accuracy.

## Read-Aloud Ground Truth Run

For a cleaner efficacy test, record yourself reading a fixed script. The exact
script becomes `reference_transcript`, and the expected cleaned version becomes
`reference_improved`.

Prepare the prompts and corpus manifest:

```bash
python3 Bench/read_aloud.py prepare
```

List microphone devices:

```bash
python3 Bench/read_aloud.py devices
```

On this machine, the last observed audio devices included:

```text
[1] AirPods Max
[4] BOYA mini 2
[5] Anker PowerConf C200
[6] Jimmy's iPhone 14 Microphone
```

Record the first five clips with the BOYA mic:

```bash
python3 Bench/read_aloud.py record --device 4 --limit 5
```

Check progress:

```bash
python3 Bench/read_aloud.py status
```

Run local transcription against the grounded read-aloud corpus:

```bash
python3 Bench/model_eval.py transcribe \
  --corpus .autoresearch/read-aloud.corpus.json \
  --config Bench/model_eval.providers.json \
  --provider parakeet-field-theory \
  --runs 1 \
  --out .autoresearch/read-aloud-transcription.jsonl
```

Run local cleanup against the exact read transcript:

```bash
python3 Bench/model_eval.py improve \
  --corpus .autoresearch/read-aloud.corpus.json \
  --config Bench/model_eval.providers.json \
  --provider ollama-qwen3.5-0.8b-mlx \
  --runs 1 \
  --out .autoresearch/read-aloud-improvement.jsonl
```

Run full-pipeline cleanup from Parakeet output:

```bash
python3 Bench/model_eval.py improve \
  --transcription-results .autoresearch/read-aloud-transcription.jsonl \
  --config Bench/model_eval.providers.json \
  --provider ollama-qwen3.5-0.8b-mlx \
  --runs 1 \
  --out .autoresearch/read-aloud-pipeline-improvement.jsonl
```

Summarize:

```bash
python3 Bench/model_eval.py summarize \
  .autoresearch/read-aloud-transcription.jsonl \
  .autoresearch/read-aloud-improvement.jsonl \
  .autoresearch/read-aloud-pipeline-improvement.jsonl \
  --csv .autoresearch/read-aloud-summary.csv
```

## Build A Corpus

Use real dictation audio when measuring accuracy. If a `.txt`,
`.transcript.txt`, `.raw.txt`, `meta.json`, or `result.json` sidecar exists next
to an audio file, the harness will use it as the reference transcript.

```bash
python3 Bench/model_eval.py make-corpus \
  --audio-dir /path/to/recordings \
  --out Bench/model_eval.corpus.json
```

The manifest can also be edited by hand. Important fields:

- `audio`: audio file fed to every transcription provider.
- `reference_transcript`: ground truth for WER/CER.
- `improvement_input`: fixed transcript fed to every improvement provider.
- `reference_improved`: optional target output for WER/CER on improvements.

## Transcription Benchmarks

```bash
python3 Bench/model_eval.py transcribe \
  --corpus Bench/model_eval.corpus.json \
  --config Bench/model_eval.providers.json \
  --runs 3 \
  --out .autoresearch/model-eval-transcription.jsonl
```

Each row records elapsed time, real-time factor, transcript text, WER, CER, and
errors. Select providers by repeating `--provider`:

```bash
python3 Bench/model_eval.py transcribe \
  --corpus Bench/model_eval.corpus.json \
  --config Bench/model_eval.providers.json \
  --provider openai-gpt-4o-transcribe \
  --provider parakeet-field-theory
```

## Improvement Benchmarks

Feed the exact same transcript into every improvement model:

```bash
python3 Bench/model_eval.py improve \
  --corpus Bench/model_eval.corpus.json \
  --config Bench/model_eval.providers.json \
  --runs 3 \
  --out .autoresearch/model-eval-improvement.jsonl
```

Or feed every successful transcription output into each improvement model to
measure full pipeline behavior:

```bash
python3 Bench/model_eval.py improve \
  --transcription-results .autoresearch/model-eval-transcription.jsonl \
  --config Bench/model_eval.providers.json \
  --runs 1 \
  --out .autoresearch/model-eval-pipeline-improvement.jsonl
```

Improvement rows record elapsed time, output text, output length ratio, edit
ratio, filler counts before/after, and optional reference WER/CER.

For qualitative scoring, run a separate judge pass over the improvement JSONL.
This keeps model outputs immutable and makes the judge model/rubric explicit:

```bash
python3 Bench/model_eval.py judge \
  .autoresearch/model-eval-improvement.jsonl \
  --model gpt-5.2 \
  --out .autoresearch/model-eval-judged.jsonl
```

The judge writes 1-5 scores for intent preservation, clarity, concision,
ready-to-use quality, and overall quality. Treat this as a calibrated review
aid, not ground truth; keep a small hand-checked reference set in the corpus for
decisions that affect the app default.

## Summaries

```bash
python3 Bench/model_eval.py summarize \
  .autoresearch/model-eval-transcription.jsonl \
  .autoresearch/model-eval-improvement.jsonl \
  .autoresearch/model-eval-judged.jsonl \
  --csv .autoresearch/model-eval-summary.csv
```

Use the JSONL files as the durable evidence. The CSV is just a quick comparison
view for p50/p95 latency and mean quality metrics.
