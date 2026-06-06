#!/usr/bin/env python3
"""Benchmark transcription and improvement models against a shared corpus.

The harness is intentionally provider-light:
- OpenAI transcription uses the official Python SDK.
- OpenAI improvement uses the Responses API.
- Ollama improvement uses the native /api/chat endpoint.
- Local transcription/improvement models can be wrapped with shell commands.

All runs emit JSONL so later analysis can recompute summaries without rerunning
expensive model calls.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import wave
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


DEFAULT_CONFIG = {
    "transcription_providers": [
        {
            "name": "openai-gpt-4o-transcribe",
            "type": "openai_transcription",
            "model": "gpt-4o-transcribe",
            "enabled": False,
        },
        {
            "name": "openai-gpt-4o-transcribe-app-aac",
            "type": "openai_transcription",
            "model": "gpt-4o-transcribe",
            "upload_format": "aac_m4a_24k",
            "enabled": False,
        },
        {
            "name": "openai-gpt-4o-mini-transcribe",
            "type": "openai_transcription",
            "model": "gpt-4o-mini-transcribe",
            "enabled": False,
        },
        {
            "name": "parakeet-field-theory",
            "type": "command_transcription",
            "model": "nemo-parakeet-tdt-0.6b-v2",
            "command": (
                'FIELD_THEORY_PARAKEET_CACHE_DIR="$HOME/Library/Application Support/fieldtheory-mac/build-parakeet/cache" '
                '"$HOME/Library/Application Support/fieldtheory-mac/build-parakeet/venv/bin/python" '
                '"/Applications/Field Theory.app/Contents/Resources/scripts/parakeet-transcribe.py" '
                "--audio {audio} --model nemo-parakeet-tdt-0.6b-v2"
            ),
            "timeout": 180,
        },
        {
            "name": "mlx-whisper-field-theory",
            "type": "command_transcription",
            "model": "mlx-community/whisper-large-v3-turbo",
            "command": (
                '"$HOME/Library/Application Support/fieldtheory-mac/build-mlx-whisper/venv/bin/python" '
                '"/Applications/Field Theory.app/Contents/Resources/scripts/mlx-whisper-transcribe.py" '
                "--audio {audio}"
            ),
            "timeout": 180,
            "enabled": False,
        },
    ],
    "improvement_providers": [
        {
            "name": "openai-gpt-5-mini",
            "type": "openai_responses",
            "model": "gpt-5-mini",
            "enabled": False,
        },
        {
            "name": "ollama-qwen3-4b-instruct",
            "type": "ollama_chat",
            "base_url": "http://127.0.0.1:11434",
            "model": "qwen3:4b-instruct",
            "output_mode": "lightCleanup",
            "modification_strength": 2,
            "temperature": 0.2,
            "max_tokens": 320,
            "keep_alive": "30m",
        },
    ],
}

_OPENAI_CLIENT = None


IMPROVE_INSTRUCTIONS = """You improve dictated text for direct use.

Preserve the speaker's intent, thinking process, uncertainty, constraints, names, numbers, code references, ordering, and domain-specific wording. Do not remove a thought just because it is tentative, self-correcting, or exploratory. Only remove words that are clearly disposable dictation artifacts, such as filler sounds, accidental duplicate words, and abandoned fragments that carry no meaning.

Do not add facts. Do not answer the speaker. Do not make the text more decisive than the transcript. Return only the improved text with no preface, labels, markdown fence, or commentary."""

COMPACT_LOCAL_IMPROVE_INSTRUCTIONS = (
    "You are a dictation cleanup engine. Rewrite only the transcript between "
    "<transcript> tags. Preserve intent, uncertainty, constraints, names, "
    "numbers, code, order, and domain terms. Remove only filler, accidental "
    "repeats, false starts, and obvious transcription errors. Do not add facts "
    "or answer the speaker. Do not copy instructions or tags. Return only the "
    "cleaned transcript."
)

TRANSCRIPT_ONLY_LOCAL_IMPROVE_INSTRUCTIONS = (
    "You are a dictation cleanup engine. The user message is raw dictated "
    "transcript text. Preserve intent, uncertainty, constraints, names, "
    "numbers, code, order, and domain terms. Remove only filler, accidental "
    "repeats, false starts, and obvious transcription errors. Do not add facts "
    "or answer the speaker. Return only the cleaned transcript."
)

OUTPUT_MODES = {
    "verbatim": {
        "label": "Near-verbatim",
        "instruction": "Make the smallest possible edits: punctuation, paragraph breaks, capitalization, and obvious transcription corrections only.",
        "intensity": "1 out of 4: punctuation and transcription fixes only.",
    },
    "lightCleanup": {
        "label": "Clean",
        "instruction": "Default cleanup. Keep the speaker's thinking, uncertainty, caveats, ordering, and substantive asides. Remove only disposable dictation artifacts such as ums, repeated accidental fragments, duplicated words, and obvious speech-to-text mistakes. Do not compress away exploratory reasoning.",
        "intensity": "2 out of 4: conservative cleanup, preserving thought process.",
    },
    "promptCleanup": {
        "label": "Prompt",
        "instruction": "Turn the transcript into a clear prompt or instruction, preserving every explicit request, constraint, example, name, technical detail, and uncertainty.",
        "intensity": "3 out of 4: rewrite into a usable prompt without dropping constraints.",
    },
    "structuredTask": {
        "label": "Task",
        "instruction": "Convert the transcript into a concise structured task with objective, context, constraints, and deliverables when they are present. Preserve unresolved questions instead of inventing answers.",
        "intensity": "4 out of 4: restructure into a task while preserving all stated requirements.",
    },
}

COMPACT_OUTPUT_MODE_INSTRUCTIONS = {
    "verbatim": "Near-verbatim: fix punctuation, capitalization, and obvious transcription errors only.",
    "lightCleanup": "Clean lightly. Keep thinking, uncertainty, caveats, ordering, and substantive asides. Remove disposable dictation artifacts and obvious speech-to-text mistakes.",
    "promptCleanup": "Rewrite as a clear instruction while preserving every request, constraint, example, name, technical detail, and uncertainty.",
    "structuredTask": "Convert to objective, context, constraints, and deliverables when present. Keep unresolved questions.",
}

FILLER_RE = re.compile(
    r"\b(um+|uh+|er+|ah+|like|you know|i mean|sort of|kind of|basically|actually)\b",
    re.IGNORECASE,
)
PASTE_READY_FILLER_RE = re.compile(
    r"\b(um+|uh+|er+|ah+|you know|i mean|sort of|kind of|basically|actually)\b",
    re.IGNORECASE,
)
PASTE_READY_SPEECH_ARTIFACT_RE = re.compile(
    r"\b(wait actually|no sorry|scratch that|start over|what i mean|let me rephrase|new paragraph)\b"
    r"|\bdot\s+[A-Za-z0-9_]+\b|\bslash\s+[A-Za-z0-9_]+\b",
    re.IGNORECASE,
)
PASTE_READY_TRANSFORM_REQUEST_RE = re.compile(
    r"\b(make this into|turn this into|convert this|rewrite this|clean this up|make it sound|"
    r"summari[sz]e|format this|structure this|write (?:\w+\s+){0,3}(email|slack|message|prompt|task))\b",
    re.IGNORECASE,
)


@dataclass
class CorpusItem:
    id: str
    audio: str | None = None
    reference_transcript: str | None = None
    improvement_input: str | None = None
    reference_improved: str | None = None
    metadata: dict[str, Any] | None = None


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        json.dump(value, f, indent=2, sort_keys=True)
        f.write("\n")


def jsonl_records(path: Path) -> Iterable[dict[str, Any]]:
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                yield json.loads(line)


def append_jsonl(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(value, ensure_ascii=False, sort_keys=True))
        f.write("\n")


def load_corpus(path: Path) -> list[CorpusItem]:
    raw = load_json(path)
    items = raw["items"] if isinstance(raw, dict) else raw
    return [CorpusItem(**item) for item in items]


def config_providers(config_path: Path | None, kind: str) -> list[dict[str, Any]]:
    config = DEFAULT_CONFIG if config_path is None else load_json(config_path)
    providers = config[kind]
    return [p for p in providers if p.get("enabled", True)]


def all_config_providers(config_path: Path | None, kind: str) -> list[dict[str, Any]]:
    config = DEFAULT_CONFIG if config_path is None else load_json(config_path)
    return config[kind]


def selected_providers(
    config_path: Path | None,
    kind: str,
    names: list[str] | None,
) -> list[dict[str, Any]]:
    if not names:
        return config_providers(config_path, kind)
    providers = all_config_providers(config_path, kind)
    wanted = set(names)
    selected = [p for p in providers if p["name"] in wanted]
    missing = wanted - {p["name"] for p in selected}
    if missing:
        raise SystemExit(f"Unknown provider(s): {', '.join(sorted(missing))}")
    return selected


def normalize_text(text: str) -> str:
    text = text.lower()
    text = re.sub(r"[^\w\s']", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def levenshtein(a: list[str] | str, b: list[str] | str) -> int:
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, start=1):
        cur = [i]
        for j, cb in enumerate(b, start=1):
            cur.append(
                min(
                    prev[j] + 1,
                    cur[j - 1] + 1,
                    prev[j - 1] + (0 if ca == cb else 1),
                )
            )
        prev = cur
    return prev[-1]


def wer(reference: str | None, hypothesis: str) -> float | None:
    if not reference:
        return None
    ref_words = normalize_text(reference).split()
    hyp_words = normalize_text(hypothesis).split()
    if not ref_words:
        return None
    return levenshtein(ref_words, hyp_words) / len(ref_words)


def cer(reference: str | None, hypothesis: str) -> float | None:
    if not reference:
        return None
    ref = normalize_text(reference).replace(" ", "")
    hyp = normalize_text(hypothesis).replace(" ", "")
    if not ref:
        return None
    return levenshtein(ref, hyp) / len(ref)


def edit_ratio(source: str, output: str) -> float:
    source_norm = normalize_text(source)
    output_norm = normalize_text(output)
    if not source_norm:
        return 0.0
    return levenshtein(source_norm, output_norm) / max(len(source_norm), 1)


def count_fillers(text: str) -> int:
    return len(FILLER_RE.findall(text))


def paste_ready_bypass_text(provider: dict[str, Any], transcript: str) -> str | None:
    if not provider.get("paste_ready_bypass"):
        return None
    if provider.get("output_mode", "lightCleanup") not in ("lightCleanup", "verbatim"):
        return None

    text = re.sub(r"\s+", " ", transcript).strip()
    if not text:
        return None
    words = re.findall(r"[A-Za-z0-9']+", text)
    if not 6 <= len(words) <= 90:
        return None
    if PASTE_READY_TRANSFORM_REQUEST_RE.search(text):
        return None
    if PASTE_READY_FILLER_RE.search(text):
        return None
    if PASTE_READY_SPEECH_ARTIFACT_RE.search(text):
        return None
    lowered = [word.lower() for word in words]
    if any(left == right and len(left) > 2 for left, right in zip(lowered, lowered[1:])):
        return None
    if len(words) > 12 and not re.search(r"[,.!?;:]", text):
        return None
    if not re.search(r"""[.!?]["')\]]*$""", text):
        return None
    if text[:1].islower():
        return None
    return text


def audio_duration_seconds(path: Path) -> float | None:
    if path.suffix.lower() == ".wav":
        try:
            with wave.open(str(path), "rb") as wav:
                return wav.getnframes() / float(wav.getframerate())
        except wave.Error:
            pass
    ffprobe = os.environ.get("FFPROBE", "ffprobe")
    try:
        out = subprocess.check_output(
            [
                ffprobe,
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                str(path),
            ],
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=10,
        ).strip()
        return float(out)
    except Exception:
        return None


def read_sidecar_text(path: Path) -> str | None:
    if path.exists():
        text = path.read_text(encoding="utf-8").strip()
        return text or None
    return None


def sidecar_transcript(audio_path: Path) -> str | None:
    for suffix in (".txt", ".transcript.txt", ".raw.txt"):
        text = read_sidecar_text(audio_path.with_suffix(suffix))
        if text:
            return text
    for name in ("meta.json", "result.json", f"{audio_path.stem}.json"):
        candidate = audio_path.parent / name
        if not candidate.exists():
            continue
        try:
            data = load_json(candidate)
        except Exception:
            continue
        for key in ("rawResult", "raw_result", "transcript", "text", "result"):
            value = data.get(key) if isinstance(data, dict) else None
            if isinstance(value, str) and value.strip():
                return value.strip()
    return None


def pick_text(data: dict[str, Any], keys: tuple[str, ...]) -> str | None:
    for key in keys:
        value = data.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


def parse_command_transcript(output: str) -> str:
    text = output.strip()
    if not text:
        return text
    try:
        decoded = json.loads(text)
    except json.JSONDecodeError:
        return text
    if isinstance(decoded, dict):
        if decoded.get("ok") is False:
            raise RuntimeError(str(decoded.get("error") or decoded))
        value = pick_text(decoded, ("text", "transcript", "result", "rawResult", "raw_result"))
        if value:
            return value
    return text


def command_output(command: str, replacements: dict[str, str], timeout: int) -> str:
    formatted = command.format(**{k: shlex.quote(v) for k, v in replacements.items()})
    result = subprocess.run(
        formatted,
        shell=True,
        check=True,
        text=True,
        capture_output=True,
        timeout=timeout,
    )
    return result.stdout.strip()


def filter_records(
    records: list[CorpusItem] | list[tuple[str, str, dict[str, Any]]],
    item_ids: list[str] | None,
    limit: int | None,
) -> Any:
    if item_ids:
        wanted = set(item_ids)
        filtered = []
        for record in records:
            record_id = record.id if isinstance(record, CorpusItem) else record[0]
            if record_id in wanted:
                filtered.append(record)
        records = filtered  # type: ignore[assignment]
    if limit is not None:
        records = records[:limit]  # type: ignore[index]
    return records


def openai_client():
    global _OPENAI_CLIENT
    if _OPENAI_CLIENT is not None:
        return _OPENAI_CLIENT
    try:
        from openai import OpenAI
    except ImportError as exc:
        raise SystemExit("Install the OpenAI SDK first: python3 -m pip install openai") from exc
    _OPENAI_CLIENT = OpenAI()
    return _OPENAI_CLIENT


def encode_aac_m4a_ffmpeg(audio_path: Path, bitrate: int = 24_000) -> Path:
    ffmpeg = os.environ.get("FFMPEG", "ffmpeg")
    with tempfile.NamedTemporaryFile(suffix=".m4a", delete=False) as f:
        out = Path(f.name)
    try:
        subprocess.run(
            [
                ffmpeg,
                "-y",
                "-v",
                "error",
                "-i",
                str(audio_path),
                "-ac",
                "1",
                "-ar",
                "16000",
                "-c:a",
                "aac",
                "-b:a",
                str(bitrate),
                str(out),
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=30,
        )
        return out
    except Exception:
        out.unlink(missing_ok=True)
        raise


def transcribe_openai(provider: dict[str, Any], audio_path: Path) -> str:
    client = openai_client()
    upload_path = audio_path
    cleanup_path: Path | None = None
    if provider.get("upload_format") == "aac_m4a_24k":
        upload_path = encode_aac_m4a_ffmpeg(audio_path, bitrate=int(provider.get("aac_bitrate", 24_000)))
        cleanup_path = upload_path
    try:
        with upload_path.open("rb") as f:
            result = client.audio.transcriptions.create(
                model=provider.get("model", "gpt-4o-transcribe"),
                file=f,
                response_format=provider.get("response_format", "text"),
            )
    finally:
        if cleanup_path is not None:
            cleanup_path.unlink(missing_ok=True)
    if isinstance(result, str):
        return result.strip()
    text = getattr(result, "text", None)
    if text:
        return text.strip()
    return str(result).strip()


def improve_openai(provider: dict[str, Any], transcript: str) -> str:
    client = openai_client()
    instructions, input_text = improve_prompt(provider, transcript)
    response = client.responses.create(
        model=provider.get("model", "gpt-5-mini"),
        instructions=instructions,
        input=input_text,
    )
    return response.output_text.strip()


def improve_prompt(provider: dict[str, Any], transcript: str) -> tuple[str, str]:
    if provider.get("prompt_style") == "compact_local":
        return compact_local_improve_prompt(provider, transcript)
    if provider.get("prompt_style") == "transcript_only_local":
        return transcript_only_local_improve_prompt(provider, transcript)

    mode_key = provider.get("output_mode", "lightCleanup")
    mode = OUTPUT_MODES.get(mode_key, OUTPUT_MODES["lightCleanup"])
    strength = min(max(int(provider.get("modification_strength", 2)), 1), 5)
    input_text = f"""Cleanup level: {mode["label"]}
Cleanup instruction: {mode["instruction"]}
Cleanup intensity: {mode["intensity"]}
Legacy strength setting: {strength} out of 5. Treat this as secondary to the cleanup level above; never use it as permission to drop substantive thoughts.

Raw transcript:
{transcript}"""
    return provider.get("instructions", IMPROVE_INSTRUCTIONS), input_text


def compact_local_improve_prompt(provider: dict[str, Any], transcript: str) -> tuple[str, str]:
    mode_key = provider.get("output_mode", "lightCleanup")
    mode_instruction = COMPACT_OUTPUT_MODE_INSTRUCTIONS.get(mode_key, COMPACT_OUTPUT_MODE_INSTRUCTIONS["lightCleanup"])
    strength = min(max(int(provider.get("modification_strength", 2)), 1), 5)
    input_text = f"""Mode: {mode_instruction}
Strength: {strength}/5.

<transcript>
{transcript}
</transcript>"""
    return provider.get("instructions", COMPACT_LOCAL_IMPROVE_INSTRUCTIONS), input_text


def transcript_only_local_improve_prompt(provider: dict[str, Any], transcript: str) -> tuple[str, str]:
    mode_key = provider.get("output_mode", "lightCleanup")
    mode_instruction = COMPACT_OUTPUT_MODE_INSTRUCTIONS.get(mode_key, COMPACT_OUTPUT_MODE_INSTRUCTIONS["lightCleanup"])
    strength = min(max(int(provider.get("modification_strength", 2)), 1), 5)
    instructions = provider.get(
        "instructions",
        f"{TRANSCRIPT_ONLY_LOCAL_IMPROVE_INSTRUCTIONS} Mode: {mode_instruction} Strength: {strength}/5.",
    )
    return instructions, transcript


def adaptive_ollama_max_tokens(provider: dict[str, Any], transcript: str) -> int | None:
    if not provider.get("adaptive_max_tokens"):
        return provider.get("max_tokens")

    mode_key = provider.get("output_mode", "lightCleanup")
    estimated_input_tokens = max(24, len(transcript) // 4)
    ratio = {
        "verbatim": 1.15,
        "lightCleanup": 1.0,
        "promptCleanup": 1.05,
        "structuredTask": 0.8,
    }.get(mode_key, 1.0)
    minimum = int(provider.get("adaptive_min_tokens", 96))
    maximum = int(provider.get("adaptive_max_token_cap", 512))
    return min(maximum, max(minimum, int(estimated_input_tokens * ratio) + 48))


def improve_ollama(provider: dict[str, Any], transcript: str) -> str:
    bypass_text = paste_ready_bypass_text(provider, transcript)
    if bypass_text is not None:
        return bypass_text

    base = provider.get("base_url", "http://127.0.0.1:11434").rstrip("/")
    url = f"{base}/api/chat"
    instructions, input_text = improve_prompt(provider, transcript)
    user_content = input_text
    if provider.get("no_think_prefix", True):
        user_content = "/no_think\n\n" + user_content
    payload = {
        "model": provider.get("model", "qwen3:4b-instruct"),
        "messages": [
            {"role": "system", "content": instructions},
            {"role": "user", "content": user_content},
        ],
        "think": False,
        "keep_alive": provider.get("keep_alive", "30m"),
        "options": {
            "temperature": provider.get("temperature", 0.2),
        },
        "stream": False,
    }
    max_tokens = adaptive_ollama_max_tokens(provider, transcript)
    if max_tokens is not None:
        payload["options"]["num_predict"] = int(max_tokens)
    for option_key in ("top_p", "top_k", "repeat_penalty", "num_ctx"):
        if provider.get(option_key) is not None:
            payload["options"][option_key] = provider[option_key]
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=int(provider.get("timeout", 120))) as resp:
            raw = resp.read()
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Ollama unavailable at {url}: {exc}") from exc
    decoded = json.loads(raw)
    if isinstance(decoded.get("message"), dict):
        return str(decoded["message"].get("content", "")).strip()
    return decoded["choices"][0]["message"]["content"].strip()


def improve_command(provider: dict[str, Any], transcript: str) -> str:
    with tempfile.NamedTemporaryFile("w", suffix=".txt", encoding="utf-8", delete=False) as f:
        f.write(transcript)
        transcript_path = f.name
    try:
        return command_output(
            provider["command"],
            {"transcript_file": transcript_path, "transcript": transcript},
            int(provider.get("timeout", 120)),
        )
    finally:
        Path(transcript_path).unlink(missing_ok=True)


def judge_openai(model: str, input_text: str, output_text: str, reference: str | None) -> dict[str, Any]:
    client = openai_client()
    prompt = {
        "input_transcript": input_text,
        "candidate_output": output_text,
        "reference_output": reference,
        "rubric": {
            "intent_preservation": "1-5, whether the output preserves the speaker's meaning and constraints",
            "clarity": "1-5, whether the result is readable and direct",
            "concision": "1-5, whether it removes filler without over-compressing",
            "ready_to_use": "1-5, whether the result could be pasted as final text",
        },
    }
    response = client.responses.create(
        model=model,
        instructions=(
            "Score an improved transcript. Return strict JSON with integer keys "
            "intent_preservation, clarity, concision, ready_to_use, overall, and a "
            "short rationale string. Penalize invented facts, dropped constraints, "
            "and style changes that alter intent."
        ),
        input=json.dumps(prompt, ensure_ascii=False),
    )
    text = response.output_text.strip()
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        parsed = {"raw_judge_output": text}
    return parsed


def make_corpus(args: argparse.Namespace) -> None:
    audio_dir = Path(args.audio_dir).expanduser().resolve()
    exts = {".wav", ".m4a", ".mp3", ".aac", ".flac", ".ogg", ".opus"}
    items: list[dict[str, Any]] = []
    for audio in sorted(p for p in audio_dir.rglob("*") if p.suffix.lower() in exts):
        reference = sidecar_transcript(audio)
        items.append(
            {
                "id": re.sub(r"[^a-zA-Z0-9_.-]+", "-", audio.relative_to(audio_dir).with_suffix("").as_posix()),
                "audio": str(audio),
                "reference_transcript": reference,
                "improvement_input": reference,
                "metadata": {
                    "duration_seconds": audio_duration_seconds(audio),
                    "source_root": str(audio_dir),
                },
            }
        )
    write_json(Path(args.out), {"items": items})
    print(f"Wrote {len(items)} corpus items to {args.out}")


def make_transcript_truth_corpus(args: argparse.Namespace) -> None:
    root = Path(args.root).expanduser()
    if not root.exists():
        raise SystemExit(f"TranscriptTruth root does not exist: {root}")

    min_raw_chars = max(args.min_raw_chars, 0)
    items: list[dict[str, Any]] = []
    for record_path in sorted(root.glob("*/record.json")):
        try:
            record = load_json(record_path)
        except Exception as exc:
            print(f"Skipping unreadable record {record_path}: {exc}", file=sys.stderr)
            continue
        if not isinstance(record, dict):
            continue

        audio_value = record.get("audioPath")
        audio_path = Path(audio_value).expanduser() if isinstance(audio_value, str) and audio_value else record_path.parent / "audio.wav"
        if not audio_path.exists():
            audio_path = record_path.parent / "audio.wav"
        if not audio_path.exists():
            continue

        raw_transcript = pick_text(record, ("rawTranscript", "raw_transcript", "transcript", "text"))
        if raw_transcript and len(raw_transcript) < min_raw_chars:
            continue
        if not raw_transcript and args.require_improvement_input:
            continue

        reference_transcript = pick_text(
            record,
            ("referenceTranscript", "reference_transcript", "correctedTranscript", "corrected_transcript"),
        )
        reference_is_app_raw = False
        if reference_transcript is None and args.use_app_raw_as_reference:
            reference_transcript = raw_transcript
            reference_is_app_raw = raw_transcript is not None
        reference_improved = pick_text(
            record,
            ("referenceImproved", "reference_improved", "correctedImproved", "corrected_improved"),
        )
        app_cleaned = pick_text(record, ("cleanedTranscript", "cleaned_transcript"))
        app_final = pick_text(record, ("finalTranscript", "final_transcript"))

        record_id = str(record.get("id") or record_path.parent.name)
        items.append(
            {
                "id": record_id,
                "audio": str(audio_path),
                "reference_transcript": reference_transcript,
                "improvement_input": raw_transcript,
                "reference_improved": reference_improved,
                "metadata": {
                    "app_cleaned_transcript": app_cleaned,
                    "app_final_transcript": app_final,
                    "auto_improve_mode": record.get("autoImproveMode"),
                    "cleanup_mode": record.get("cleanupMode"),
                    "created_at": record.get("createdAt"),
                    "duration_seconds": audio_duration_seconds(audio_path),
                    "improvement_mode": record.get("improvementMode"),
                    "raw_chars": len(raw_transcript or ""),
                    "reference_is_app_raw": reference_is_app_raw,
                    "source_record": str(record_path),
                    "transcription_engine": record.get("transcriptionEngine"),
                    "transcription_mode": record.get("transcriptionMode"),
                },
            }
        )

    write_json(Path(args.out), {"items": items})
    print(f"Wrote {len(items)} TranscriptTruth corpus items to {args.out}")


def write_default_config(args: argparse.Namespace) -> None:
    write_json(Path(args.out), DEFAULT_CONFIG)
    print(f"Wrote provider config to {args.out}")


def run_transcription(args: argparse.Namespace) -> None:
    corpus = filter_records(load_corpus(Path(args.corpus)), args.item, args.limit)
    providers = selected_providers(
        Path(args.config) if args.config else None,
        "transcription_providers",
        args.provider,
    )
    out = Path(args.out)
    if out.exists() and not args.append:
        out.unlink()

    for item in corpus:
        if not item.audio:
            continue
        audio = Path(item.audio).expanduser()
        duration = audio_duration_seconds(audio)
        for provider in providers:
            for run_index in range(args.runs):
                started = time.perf_counter()
                error = None
                text = ""
                try:
                    if provider["type"] == "openai_transcription":
                        text = transcribe_openai(provider, audio)
                    elif provider["type"] == "command_transcription":
                        text = parse_command_transcript(
                            command_output(
                                provider["command"],
                                {"audio": str(audio)},
                                int(provider.get("timeout", args.timeout)),
                            )
                        )
                    else:
                        raise ValueError(f"Unsupported transcription provider type: {provider['type']}")
                except Exception as exc:
                    error = repr(exc)
                elapsed = time.perf_counter() - started
                append_jsonl(
                    out,
                    {
                        "kind": "transcription",
                        "timestamp": dt.datetime.now(dt.timezone.utc).isoformat(),
                        "item_id": item.id,
                        "provider": provider["name"],
                        "provider_type": provider["type"],
                        "model": provider.get("model"),
                        "run_index": run_index,
                        "audio": str(audio),
                        "duration_seconds": duration,
                        "reference_transcript": item.reference_transcript,
                        "reference_improved": item.reference_improved,
                        "metadata": item.metadata,
                        "elapsed_ms": elapsed * 1000.0,
                        "realtime_factor": elapsed / duration if duration else None,
                        "text": text,
                        "wer": wer(item.reference_transcript, text),
                        "cer": cer(item.reference_transcript, text),
                        "error": error,
                    },
                )
                print(f"{item.id} {provider['name']} run={run_index} {elapsed:.2f}s")


def transcript_inputs_from_results(path: Path) -> list[tuple[str, str, dict[str, Any]]]:
    inputs: list[tuple[str, str, dict[str, Any]]] = []
    for record in jsonl_records(path):
        if record.get("kind") != "transcription" or record.get("error"):
            continue
        text = str(record.get("text", "")).strip()
        if text:
            source = f"{record.get('item_id')}::{record.get('provider')}::run{record.get('run_index')}"
            inputs.append((source, text, record))
    return inputs


def corpus_improvement_inputs(corpus: list[CorpusItem]) -> list[tuple[str, str, dict[str, Any]]]:
    inputs: list[tuple[str, str, dict[str, Any]]] = []
    for item in corpus:
        text = item.improvement_input or item.reference_transcript
        if text:
            inputs.append((item.id, text, {"item_id": item.id, "reference_improved": item.reference_improved}))
    return inputs


def run_improvement(args: argparse.Namespace) -> None:
    providers = selected_providers(
        Path(args.config) if args.config else None,
        "improvement_providers",
        args.provider,
    )
    if args.transcription_results:
        inputs = transcript_inputs_from_results(Path(args.transcription_results))
    else:
        inputs = corpus_improvement_inputs(load_corpus(Path(args.corpus)))
    inputs = filter_records(inputs, args.item, args.limit)
    if not inputs:
        raise SystemExit("No improvement inputs found.")

    out = Path(args.out)
    if out.exists() and not args.append:
        out.unlink()

    for input_id, transcript, source in inputs:
        reference = source.get("reference_improved")
        for provider in providers:
            for run_index in range(args.runs):
                started = time.perf_counter()
                error = None
                output = ""
                try:
                    if provider["type"] == "openai_responses":
                        output = improve_openai(provider, transcript)
                    elif provider["type"] == "ollama_chat":
                        output = improve_ollama(provider, transcript)
                    elif provider["type"] == "command_improvement":
                        output = improve_command(provider, transcript)
                    else:
                        raise ValueError(f"Unsupported improvement provider type: {provider['type']}")
                except Exception as exc:
                    error = repr(exc)
                elapsed = time.perf_counter() - started
                append_jsonl(
                    out,
                    {
                        "kind": "improvement",
                        "timestamp": dt.datetime.now(dt.timezone.utc).isoformat(),
                        "input_id": input_id,
                        "source": source,
                        "provider": provider["name"],
                        "provider_type": provider["type"],
                        "model": provider.get("model"),
                        "run_index": run_index,
                        "elapsed_ms": elapsed * 1000.0,
                        "input_chars": len(transcript),
                        "output_chars": len(output),
                        "length_ratio": len(output) / len(transcript) if transcript else None,
                        "edit_ratio": edit_ratio(transcript, output),
                        "input_fillers": count_fillers(transcript),
                        "output_fillers": count_fillers(output),
                        "reference_wer": wer(reference, output),
                        "reference_cer": cer(reference, output),
                        "input": transcript,
                        "output": output,
                        "error": error,
                    },
                )
                print(f"{input_id} {provider['name']} run={run_index} {elapsed:.2f}s")


def pctl(values: list[float], p: float) -> float | None:
    if not values:
        return None
    values = sorted(values)
    if len(values) == 1:
        return values[0]
    pos = p * (len(values) - 1)
    lo = int(pos)
    hi = min(lo + 1, len(values) - 1)
    frac = pos - lo
    return values[lo] + (values[hi] - values[lo]) * frac


def summarize(args: argparse.Namespace) -> None:
    groups: dict[tuple[str, str], list[dict[str, Any]]] = {}
    for result_path in args.results:
        for record in jsonl_records(Path(result_path)):
            key = (record.get("kind", "unknown"), record.get("provider", "unknown"))
            groups.setdefault(key, []).append(record)

    rows: list[dict[str, Any]] = []
    for (kind, provider), records in sorted(groups.items()):
        ok = [r for r in records if not r.get("error")]
        times = [float(r["elapsed_ms"]) for r in ok if r.get("elapsed_ms") is not None]
        row = {
            "kind": kind,
            "provider": provider,
            "runs": len(records),
            "successes": len(ok),
            "failures": len(records) - len(ok),
            "elapsed_p50_ms": pctl(times, 0.50),
            "elapsed_p95_ms": pctl(times, 0.95),
            "elapsed_mean_ms": sum(times) / len(times) if times else None,
        }
        for metric in (
            "wer",
            "cer",
            "reference_wer",
            "reference_cer",
            "realtime_factor",
            "edit_ratio",
            "length_ratio",
            "judge_overall",
            "judge_intent_preservation",
            "judge_clarity",
            "judge_concision",
            "judge_ready_to_use",
        ):
            values = [float(r[metric]) for r in ok if r.get(metric) is not None]
            if values:
                row[f"{metric}_mean"] = sum(values) / len(values)
                row[f"{metric}_p50"] = pctl(values, 0.50)
        rows.append(row)

    print(json.dumps(rows, indent=2, sort_keys=True))
    if args.csv:
        keys = sorted({key for row in rows for key in row})
        with Path(args.csv).open("w", encoding="utf-8", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=keys)
            writer.writeheader()
            writer.writerows(rows)
        print(f"Wrote CSV summary to {args.csv}")


def run_judge(args: argparse.Namespace) -> None:
    out = Path(args.out)
    if out.exists() and not args.append:
        out.unlink()

    limit = args.limit
    judged = 0
    for path in args.results:
        for record in jsonl_records(Path(path)):
            if record.get("kind") != "improvement" or record.get("error"):
                continue
            if limit is not None and judged >= limit:
                return
            source = record.get("source") if isinstance(record.get("source"), dict) else {}
            reference = source.get("reference_improved") if isinstance(source, dict) else None
            started = time.perf_counter()
            error = None
            scores: dict[str, Any] = {}
            try:
                scores = judge_openai(
                    args.model,
                    str(record.get("input", "")),
                    str(record.get("output", "")),
                    reference,
                )
            except Exception as exc:
                error = repr(exc)
            elapsed = time.perf_counter() - started
            judged_record = {
                "kind": "improvement_judge",
                "timestamp": dt.datetime.now(dt.timezone.utc).isoformat(),
                "judge_model": args.model,
                "provider": record.get("provider"),
                "model": record.get("model"),
                "input_id": record.get("input_id"),
                "run_index": record.get("run_index"),
                "elapsed_ms": elapsed * 1000.0,
                "scores": scores,
                "judge_overall": scores.get("overall") if isinstance(scores, dict) else None,
                "judge_intent_preservation": scores.get("intent_preservation") if isinstance(scores, dict) else None,
                "judge_clarity": scores.get("clarity") if isinstance(scores, dict) else None,
                "judge_concision": scores.get("concision") if isinstance(scores, dict) else None,
                "judge_ready_to_use": scores.get("ready_to_use") if isinstance(scores, dict) else None,
                "error": error,
            }
            append_jsonl(out, judged_record)
            judged += 1
            print(f"judged {record.get('input_id')} {record.get('provider')} {elapsed:.2f}s")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(required=True)

    p = sub.add_parser("write-config", help="write an editable provider config")
    p.add_argument("--out", default="Bench/model_eval.providers.json")
    p.set_defaults(func=write_default_config)

    p = sub.add_parser("make-corpus", help="build a corpus manifest from an audio directory")
    p.add_argument("--audio-dir", required=True)
    p.add_argument("--out", default="Bench/model_eval.corpus.json")
    p.set_defaults(func=make_corpus)

    p = sub.add_parser("make-transcript-truth-corpus", help="build a corpus from archived app recordings")
    p.add_argument(
        "--root",
        default="~/Library/Application Support/AutoImproveRecorder/TranscriptTruth",
        help="TranscriptTruth archive root",
    )
    p.add_argument("--out", default=".autoresearch/transcript-truth.corpus.json")
    p.add_argument("--min-raw-chars", type=int, default=0)
    p.add_argument("--require-improvement-input", action="store_true")
    p.add_argument(
        "--use-app-raw-as-reference",
        action="store_true",
        help="use archived rawTranscript as a pseudo-reference when no corrected transcript exists",
    )
    p.set_defaults(func=make_transcript_truth_corpus)

    p = sub.add_parser("transcribe", help="run transcription providers over a corpus")
    p.add_argument("--corpus", required=True)
    p.add_argument("--config")
    p.add_argument("--provider", action="append", help="provider name; repeat to select several")
    p.add_argument("--item", action="append", help="corpus item id; repeat to select several")
    p.add_argument("--limit", type=int, help="maximum selected corpus items to run")
    p.add_argument("--runs", type=int, default=1)
    p.add_argument("--timeout", type=int, default=180)
    p.add_argument("--out", default=".autoresearch/model-eval-transcription.jsonl")
    p.add_argument("--append", action="store_true")
    p.set_defaults(func=run_transcription)

    p = sub.add_parser("improve", help="run improvement providers over fixed transcripts")
    p.add_argument("--corpus", help="corpus manifest; used unless --transcription-results is supplied")
    p.add_argument("--transcription-results", help="feed successful transcription outputs into improvement providers")
    p.add_argument("--config")
    p.add_argument("--provider", action="append", help="provider name; repeat to select several")
    p.add_argument("--item", action="append", help="corpus item id or transcription-result input id; repeat to select several")
    p.add_argument("--limit", type=int, help="maximum selected inputs to run")
    p.add_argument("--runs", type=int, default=1)
    p.add_argument("--out", default=".autoresearch/model-eval-improvement.jsonl")
    p.add_argument("--append", action="store_true")
    p.set_defaults(func=run_improvement)

    p = sub.add_parser("summarize", help="summarize one or more result JSONL files")
    p.add_argument("results", nargs="+")
    p.add_argument("--csv")
    p.set_defaults(func=summarize)

    p = sub.add_parser("judge", help="LLM-judge improvement outputs with a fixed rubric")
    p.add_argument("results", nargs="+", help="improvement JSONL files")
    p.add_argument("--model", default="gpt-5.2")
    p.add_argument("--out", default=".autoresearch/model-eval-judged.jsonl")
    p.add_argument("--append", action="store_true")
    p.add_argument("--limit", type=int)
    p.set_defaults(func=run_judge)
    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    if getattr(args, "func", None) == run_improvement and not args.transcription_results and not args.corpus:
        parser.error("improve requires --corpus or --transcription-results")
    args.func(args)


if __name__ == "__main__":
    main()
