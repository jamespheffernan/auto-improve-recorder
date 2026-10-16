#!/usr/bin/env python3
"""Benchmark sentence-stable cleanup overlap on AIR transcript fixtures.

The harness uses the app's current light-cleanup prompt and local Ollama model.
It never writes transcript text or model output to its result artifacts.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import statistics
import subprocess
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from difflib import SequenceMatcher
from pathlib import Path
from typing import Any, Iterable


INSTRUCTIONS = """You improve dictated text for direct use.

Preserve the speaker's intent, thinking process, uncertainty, constraints, names, numbers, code references, ordering, and domain-specific wording. Do not remove a thought just because it is tentative, self-correcting, or exploratory. Only remove words that are clearly disposable dictation artifacts, such as filler sounds, accidental duplicate words, and abandoned fragments that carry no meaning.

Do not add facts. Do not answer the speaker. Do not make the text more decisive than the transcript. Return only the improved text with no preface, labels, markdown fence, or commentary."""

INPUT_TEMPLATE = """Cleanup level: Clean
Cleanup instruction: Default cleanup. Keep the speaker's thinking, uncertainty, caveats, ordering, and substantive asides. Remove only disposable dictation artifacts such as ums, repeated accidental fragments, duplicated words, and obvious speech-to-text mistakes. Do not compress away exploratory reasoning.
Cleanup intensity: 2 out of 4: conservative cleanup, preserving thought process.
Legacy strength setting: 2 out of 5. Treat this as secondary to the cleanup level above; never use it as permission to drop substantive thoughts.

Raw transcript:
{transcript}"""

CRITICAL_TERMS: dict[str, tuple[str, ...]] = {
    "swift-inspection-prompt": ("AppState dot swift", "ImproveEngine dot swift", "OllamaImproveEngine dot swift"),
    "model-comparison": ("Parakeet", "MLX Whisper", "Apple Speech", "OpenAI", "word error rate", "character error rate", "real-time factor"),
    "structured-task": ("raw audio private", "exact read transcripts", "JSONL", "CSV"),
    "proper-nouns": ("Mira Patel", "Nikhil Rao", "Ana Gomez", "Auto Improve Recorder", "Field Theory", "Transcript Truth"),
    "numbers-and-date": ("Friday", "May twenty ninth twenty twenty six", "two thirty", "twenty clips", "five runs", "four hundred milliseconds"),
    "code-review-note": ("audio dot wav", "record dot json", "JSON"),
    "sequence-instructions": ("First", "then", "then", "If any step fails"),
    "privacy-constraints": ("Do not send audio to the cloud", "only after", "private evaluation folder"),
    "spoken-correction": ("BOYA mini", "AirPods Max", "Anker PowerConf C200"),
}

SENTENCE_END_RE = re.compile(r"[.!?]+(?:[\"'\u2019\u201d)\]]+)?(?=\s+|$)")
CORRECTION_START_RE = re.compile(
    r"^\s*(?:wait|actually|no[, ]|no sorry|sorry|scratch that|rather|instead|what i mean)",
    re.IGNORECASE,
)
CONSTRAINT_RE = re.compile(r"\b(?:must|never|only|do not|don't|keep|preserve|if|before|after|then)\b", re.IGNORECASE)
CODE_TOKEN_RE = re.compile(r"\b(?:[A-Za-z_][A-Za-z0-9_]*\.(?:swift|json|wav|py|rs)|[A-Z][A-Za-z0-9]+[A-Z][A-Za-z0-9]*)\b")
NUMBER_RE = re.compile(r"\b\d+(?:[.:/-]\d+)*%?\b")


@dataclass(frozen=True)
class Fixture:
    fixture_id: str
    source: str
    transcript: str
    duration_s: float
    reference: str | None
    dictionary_terms: tuple[str, ...] = ()


@dataclass(frozen=True)
class ProviderResult:
    output: str
    elapsed_ms: float
    prompt_tokens: int
    output_tokens: int


def percentile(values: list[float], fraction: float) -> float:
    if not values:
        return math.nan
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    low = math.floor(position)
    high = math.ceil(position)
    if low == high:
        return ordered[low]
    return ordered[low] + (ordered[high] - ordered[low]) * (position - low)


def normalize(text: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"[^\w\s']", " ", text.lower())).strip()


def words(text: str) -> list[str]:
    return normalize(text).split()


def levenshtein(left: list[str], right: list[str]) -> int:
    previous = list(range(len(right) + 1))
    for row, lhs in enumerate(left, start=1):
        current = [row]
        for column, rhs in enumerate(right, start=1):
            current.append(min(previous[column] + 1, current[-1] + 1, previous[column - 1] + (lhs != rhs)))
        previous = current
    return previous[-1]


def wer(reference: str | None, output: str) -> float | None:
    if not reference:
        return None
    reference_words = words(reference)
    return levenshtein(reference_words, words(output)) / max(1, len(reference_words))


def audio_duration(path: Path) -> float | None:
    try:
        raw = subprocess.check_output(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", str(path)],
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=10,
        ).strip()
        return float(raw)
    except (OSError, subprocess.SubprocessError, ValueError):
        return None


def sentence_units(text: str) -> list[str]:
    units: list[str] = []
    start = 0
    for match in SENTENCE_END_RE.finditer(text):
        end = match.end()
        unit = text[start:end].strip()
        if unit:
            units.append(unit)
        start = end
    tail = text[start:].strip()
    if tail:
        units.append(tail)
    return units


def balanced_chunks(units: list[str], max_prefix_calls: int, min_prefix_words: int) -> list[str]:
    """Keep the last sentence unstable and split earlier sentences into at most N chunks."""
    if len(units) < 2:
        return []
    prefix_units = units[:-1]
    if sum(len(words(unit)) for unit in prefix_units) < min_prefix_words:
        return []
    chunk_count = min(max_prefix_calls, len(prefix_units))
    target = max(min_prefix_words, math.ceil(sum(len(words(unit)) for unit in prefix_units) / chunk_count))
    chunks: list[str] = []
    current: list[str] = []
    current_words = 0
    for index, unit in enumerate(prefix_units):
        current.append(unit)
        current_words += len(words(unit))
        remaining_units = len(prefix_units) - index - 1
        if current_words >= target and remaining_units >= (chunk_count - len(chunks) - 1):
            chunks.append(" ".join(current))
            current = []
            current_words = 0
    if current:
        if chunks and len(chunks) >= chunk_count:
            chunks[-1] += " " + " ".join(current)
        else:
            chunks.append(" ".join(current))
    return chunks


def protected_terms(fixture: Fixture) -> tuple[str, ...]:
    found = set(CRITICAL_TERMS.get(fixture.fixture_id, ()))
    transcript_normalized = normalize(fixture.transcript)
    found.update(term for term in fixture.dictionary_terms if normalize(term) in transcript_normalized)
    found.update(NUMBER_RE.findall(fixture.transcript))
    found.update(CODE_TOKEN_RE.findall(fixture.transcript))
    return tuple(sorted((term for term in found if term.strip()), key=str.casefold))


def preservation(terms: tuple[str, ...], output: str) -> tuple[int, int, list[str]]:
    output_folded = normalize(output)
    missing = [term for term in terms if normalize(term) not in output_folded]
    return len(terms) - len(missing), len(terms), missing


def content_recall(source: str, output: str) -> float:
    disposable = {
        "a", "an", "the", "and", "or", "but", "to", "of", "in", "on", "for", "with",
        "um", "uh", "er", "ah", "hey", "okay", "like", "just", "really", "basically",
    }
    source_terms = {word for word in words(source) if len(word) > 2 and word not in disposable}
    output_terms = set(words(output))
    return len(source_terms & output_terms) / max(1, len(source_terms))


def has_bad_seam(outputs: list[str]) -> bool:
    for left, right in zip(outputs, outputs[1:]):
        left_words = words(left)
        right_words = words(right)
        overlap = 0
        for size in range(1, min(6, len(left_words), len(right_words)) + 1):
            if left_words[-size:] == right_words[:size]:
                overlap = size
        if overlap >= 2:
            return True
        if not re.search(r"[.!?;:]\s*$", left):
            return True
    return False


class OllamaProvider:
    def __init__(self, base_url: str, model: str, timeout: int) -> None:
        self.url = base_url.rstrip("/") + "/api/chat"
        self.model = model
        self.timeout = timeout

    def improve(self, transcript: str) -> ProviderResult:
        payload = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": INSTRUCTIONS},
                {"role": "user", "content": "/no_think\n\n" + INPUT_TEMPLATE.format(transcript=transcript)},
            ],
            "think": False,
            "stream": False,
            "keep_alive": "30m",
            "options": {"temperature": 0.2, "num_predict": 320},
        }
        request = urllib.request.Request(
            self.url,
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        started = time.perf_counter()
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                decoded = json.loads(response.read())
        except urllib.error.URLError as error:
            raise RuntimeError(f"Ollama unavailable at {self.url}: {error}") from error
        elapsed_ms = (time.perf_counter() - started) * 1000
        output = str(decoded.get("message", {}).get("content", "")).strip()
        if not output:
            raise RuntimeError(f"Empty Ollama output for model {self.model}")
        return ProviderResult(
            output=output,
            elapsed_ms=elapsed_ms,
            prompt_tokens=int(decoded.get("prompt_eval_count") or 0),
            output_tokens=int(decoded.get("eval_count") or 0),
        )


def load_read_aloud(path: Path) -> list[Fixture]:
    raw = json.loads(path.read_text())
    fixtures: list[Fixture] = []
    audio_root = path.parent.parent / ".autoresearch" / "read-aloud-corpus"
    for item in raw["items"]:
        fixture_id = item["id"]
        duration = audio_duration(audio_root / fixture_id / "audio.wav")
        if duration is None:
            continue
        fixtures.append(Fixture(fixture_id, "read-aloud", item["read_transcript"], duration, item.get("reference_improved")))
    return fixtures


def load_transcript_truth(root: Path, limit: int) -> list[Fixture]:
    candidates: list[tuple[str, Fixture]] = []
    for record_path in root.glob("*/record.json"):
        try:
            record = json.loads(record_path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        transcript = str(record.get("rawTranscript") or "").strip()
        if len(transcript) < 160 or len(sentence_units(transcript)) < 3:
            continue
        audio_path = Path(str(record.get("audioPath") or record_path.parent / "audio.wav")).expanduser()
        if not audio_path.exists():
            audio_path = record_path.parent / "audio.wav"
        duration = audio_duration(audio_path)
        if duration is None or duration < 8:
            continue
        dictionary = tuple(term.strip() for term in str(record.get("dictionarySnapshot") or "").split(",") if term.strip())
        fixture = Fixture(
            str(record.get("id") or record_path.parent.name),
            "transcript-truth",
            transcript,
            duration,
            str(record.get("cleanedTranscript") or "").strip() or None,
            dictionary,
        )
        candidates.append((str(record.get("createdAt") or ""), fixture))
    candidates.sort(key=lambda pair: pair[0], reverse=True)
    return [fixture for _, fixture in candidates[:limit]]


def tail_after_prefix(transcript: str, chunks: list[str]) -> str:
    prefix_chars = sum(len(chunk) for chunk in chunks) + max(0, len(chunks) - 1)
    # Find by the exact joined prefix so punctuation and spaces remain stable.
    joined = " ".join(chunks)
    if transcript.startswith(joined):
        return transcript[len(joined):].strip()
    return transcript[prefix_chars:].strip()


def finish_timeline(fixture: Fixture, chunks: list[str], calls: list[ProviderResult], stability_s: float) -> tuple[float, float]:
    cursor_s = 0.0
    consumed_chars = 0
    first_finish_s: float | None = None
    for chunk, call in zip(chunks, calls[:-1]):
        consumed_chars += len(chunk) + (1 if consumed_chars else 0)
        stable_at = fixture.duration_s * min(1.0, consumed_chars / max(1, len(fixture.transcript))) + stability_s
        cursor_s = max(cursor_s, stable_at) + call.elapsed_ms / 1000
        if first_finish_s is None:
            first_finish_s = cursor_s
    cursor_s = max(cursor_s, fixture.duration_s) + calls[-1].elapsed_ms / 1000
    first_after_stop_ms = max(0.0, ((first_finish_s or cursor_s) - fixture.duration_s) * 1000)
    final_after_stop_ms = max(0.0, (cursor_s - fixture.duration_s) * 1000)
    return first_after_stop_ms, final_after_stop_ms


def benchmark_fixture(
    fixture: Fixture,
    provider: OllamaProvider,
    max_prefix_calls: int,
    min_prefix_words: int,
    stability_s: float,
) -> dict[str, Any]:
    baseline = provider.improve(fixture.transcript)
    units = sentence_units(fixture.transcript)
    chunks = balanced_chunks(units, max_prefix_calls, min_prefix_words)
    tail = tail_after_prefix(fixture.transcript, chunks) if chunks else ""
    preflight_reason: str | None = None
    if not chunks or not tail:
        preflight_reason = "no_stable_prefix"
    elif CORRECTION_START_RE.search(tail):
        preflight_reason = "cross_boundary_correction"

    if preflight_reason:
        return {
            "id": fixture.fixture_id,
            "source": fixture.source,
            "eligible": False,
            "decision": "whole_fallback_preflight",
            "fallback_reason": preflight_reason,
            "duration_ms": fixture.duration_s * 1000,
            "baseline_final_ms": baseline.elapsed_ms,
            "overlap_first_useful_ms": baseline.elapsed_ms,
            "overlap_final_ms": baseline.elapsed_ms,
            "latency_reduction_percent": 0.0,
            "runtime_calls": 1,
            "baseline_calls": 1,
            "runtime_prompt_tokens": baseline.prompt_tokens,
            "runtime_output_tokens": baseline.output_tokens,
            "baseline_prompt_tokens": baseline.prompt_tokens,
            "baseline_output_tokens": baseline.output_tokens,
            "protected_found": 0,
            "protected_total": 0,
            "constraint_cues_input": len(CONSTRAINT_RE.findall(fixture.transcript)),
            "constraint_cues_output": len(CONSTRAINT_RE.findall(baseline.output)),
            "seam_failure": False,
            "whole_similarity": 1.0,
            "baseline_reference_wer": wer(fixture.reference, baseline.output),
            "overlap_reference_wer": wer(fixture.reference, baseline.output),
        }

    segment_inputs = chunks + [tail]
    segment_calls = [provider.improve(part) for part in segment_inputs]
    segment_outputs = [call.output for call in segment_calls]
    joined_output = " ".join(segment_outputs)
    terms = protected_terms(fixture)
    found, total, missing = preservation(terms, joined_output)
    seam_failure = has_bad_seam(segment_outputs)
    constraint_input = len(CONSTRAINT_RE.findall(fixture.transcript))
    constraint_output = len(CONSTRAINT_RE.findall(joined_output))
    length_ratio = len(normalize(joined_output)) / max(1, len(normalize(fixture.transcript)))
    segment_content_recalls = [content_recall(source, output) for source, output in zip(segment_inputs, segment_outputs)]
    segment_source_similarities = [
        SequenceMatcher(None, normalize(source), normalize(output)).ratio()
        for source, output in zip(segment_inputs, segment_outputs)
    ]
    runtime_valid = (
        not missing
        and not seam_failure
        and constraint_output >= constraint_input
        and 0.75 <= length_ratio <= 1.35
        and min(segment_content_recalls) >= 0.75
        and min(segment_source_similarities) >= 0.85
    )
    first_ms, segmented_final_ms = finish_timeline(fixture, chunks, segment_calls, stability_s)

    if runtime_valid:
        decision = "segmented"
        final_ms = segmented_final_ms
        runtime_calls = len(segment_calls)
        runtime_prompt_tokens = sum(call.prompt_tokens for call in segment_calls)
        runtime_output_tokens = sum(call.output_tokens for call in segment_calls)
        delivered_output = joined_output
        fallback_reason = None
    else:
        decision = "whole_fallback_validation"
        final_ms = segmented_final_ms + baseline.elapsed_ms
        runtime_calls = len(segment_calls) + 1
        runtime_prompt_tokens = sum(call.prompt_tokens for call in segment_calls) + baseline.prompt_tokens
        runtime_output_tokens = sum(call.output_tokens for call in segment_calls) + baseline.output_tokens
        delivered_output = baseline.output
        fallback_reason = "missing_protected_term" if missing else "seam_or_structure"

    return {
        "id": fixture.fixture_id,
        "source": fixture.source,
        "eligible": True,
        "decision": decision,
        "fallback_reason": fallback_reason,
        "duration_ms": fixture.duration_s * 1000,
        "prefix_chunks": len(chunks),
        "baseline_final_ms": baseline.elapsed_ms,
        "overlap_first_useful_ms": first_ms,
        "overlap_final_ms": final_ms,
        "latency_reduction_percent": 100 * (baseline.elapsed_ms - final_ms) / baseline.elapsed_ms,
        "runtime_calls": runtime_calls,
        "baseline_calls": 1,
        "runtime_prompt_tokens": runtime_prompt_tokens,
        "runtime_output_tokens": runtime_output_tokens,
        "baseline_prompt_tokens": baseline.prompt_tokens,
        "baseline_output_tokens": baseline.output_tokens,
        "protected_found": found,
        "protected_total": total,
        "missing_protected_count": len(missing),
        "minimum_segment_content_recall": min(segment_content_recalls),
        "minimum_segment_source_similarity": min(segment_source_similarities),
        "constraint_cues_input": constraint_input,
        "constraint_cues_output": len(CONSTRAINT_RE.findall(delivered_output)),
        "seam_failure": seam_failure,
        "whole_similarity": SequenceMatcher(None, normalize(baseline.output), normalize(joined_output)).ratio(),
        "baseline_reference_wer": wer(fixture.reference, baseline.output),
        "overlap_reference_wer": wer(fixture.reference, delivered_output),
    }


def safe_mean(values: Iterable[float | int]) -> float:
    materialized = list(values)
    return statistics.mean(materialized) if materialized else math.nan


def summarize(records: list[dict[str, Any]], model: str, args: argparse.Namespace) -> dict[str, Any]:
    eligible = [record for record in records if record["eligible"]]
    segmented = [record for record in eligible if record["decision"] == "segmented"]
    reductions = [record["latency_reduction_percent"] for record in records]
    similarities = [record["whole_similarity"] for record in segmented]
    equivalence_rate = safe_mean(float(similarity >= 0.85) for similarity in similarities)
    reference_deltas = [
        record["overlap_reference_wer"] - record["baseline_reference_wer"]
        for record in segmented
        if record["baseline_reference_wer"] is not None and record["overlap_reference_wer"] is not None
    ]
    protected_found = sum(record["protected_found"] for record in eligible)
    protected_total = sum(record["protected_total"] for record in eligible)
    delivered_protected_found = sum(record["protected_found"] for record in segmented)
    delivered_protected_total = sum(record["protected_total"] for record in segmented)
    median_reduction = statistics.median(reductions)
    eligible_median_reduction = statistics.median([record["latency_reduction_percent"] for record in eligible]) if eligible else math.nan
    p95_final = percentile([record["overlap_final_ms"] for record in records], 0.95)
    baseline_p95 = percentile([record["baseline_final_ms"] for record in records], 0.95)
    summary = {
        "model": model,
        "fixtures": len(records),
        "read_aloud_fixtures": sum(record["source"] == "read-aloud" for record in records),
        "transcript_truth_fixtures": sum(record["source"] == "transcript-truth" for record in records),
        "eligible_fixtures": len(eligible),
        "segmented_deliveries": len(segmented),
        "fallbacks": len(records) - len(segmented),
        "median_stop_to_final_reduction_percent": median_reduction,
        "eligible_median_reduction_percent": eligible_median_reduction,
        "baseline_final_p50_ms": statistics.median(record["baseline_final_ms"] for record in records),
        "overlap_final_p50_ms": statistics.median(record["overlap_final_ms"] for record in records),
        "baseline_final_p95_ms": baseline_p95,
        "overlap_final_p95_ms": p95_final,
        "first_useful_p50_ms": statistics.median(record["overlap_first_useful_ms"] for record in records),
        "runtime_calls_total": sum(record["runtime_calls"] for record in records),
        "baseline_calls_total": len(records),
        "runtime_tokens_total": sum(record["runtime_prompt_tokens"] + record["runtime_output_tokens"] for record in records),
        "baseline_tokens_total": sum(record["baseline_prompt_tokens"] + record["baseline_output_tokens"] for record in records),
        "protected_preservation_rate": protected_found / protected_total if protected_total else 1.0,
        "segmented_delivery_protected_preservation_rate": delivered_protected_found / delivered_protected_total if delivered_protected_total else 1.0,
        "protected_terms": protected_total,
        "seam_failures": sum(bool(record["seam_failure"]) for record in eligible),
        "median_whole_output_similarity": statistics.median(similarities) if similarities else math.nan,
        "whole_output_equivalence_rate_at_0_85": equivalence_rate,
        "max_reference_wer_regression": max(reference_deltas, default=0.0),
        "acceptance_gate": {
            "beats_prior_6_9_percent": eligible_median_reduction > 6.9,
            "protected_preservation_at_least_99_percent": (delivered_protected_found / delivered_protected_total if delivered_protected_total else 1.0) >= 0.99,
            "zero_seam_failures": not any(record["seam_failure"] and record["decision"] == "segmented" for record in eligible),
            "whole_output_equivalence_at_least_95_percent": bool(similarities) and equivalence_rate >= 0.95,
            "reference_wer_regression_at_most_0_05": max(reference_deltas, default=0.0) <= 0.05,
        },
        "settings": {
            "max_prefix_calls": args.max_prefix_calls,
            "min_prefix_words": args.min_prefix_words,
            "stability_ms": args.stability_ms,
            "transcript_truth_limit": args.transcript_truth_limit,
        },
    }
    summary["accepted"] = all(summary["acceptance_gate"].values())
    return summary


def write_jsonl(path: Path, records: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record, sort_keys=True) + "\n")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--read-aloud", type=Path, default=Path("Bench/read_aloud_items.json"))
    parser.add_argument("--transcript-truth-root", type=Path, required=True)
    parser.add_argument("--transcript-truth-limit", type=int, default=8)
    parser.add_argument("--model", default="qwen3.5:0.8b-mlx")
    parser.add_argument("--base-url", default="http://127.0.0.1:11434")
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--max-prefix-calls", type=int, default=2)
    parser.add_argument("--min-prefix-words", type=int, default=12)
    parser.add_argument("--stability-ms", type=int, default=750)
    parser.add_argument("--limit", type=int)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--summary", type=Path, required=True)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    fixtures = load_read_aloud(args.read_aloud) + load_transcript_truth(args.transcript_truth_root.expanduser(), args.transcript_truth_limit)
    if args.limit is not None:
        fixtures = fixtures[: args.limit]
    if not fixtures:
        raise SystemExit("No fixtures found")
    provider = OllamaProvider(args.base_url, args.model, args.timeout)
    provider.improve("Warm-up sentence.")
    records: list[dict[str, Any]] = []
    for index, fixture in enumerate(fixtures, start=1):
        print(f"[{index}/{len(fixtures)}] {fixture.source}:{fixture.fixture_id}", flush=True)
        records.append(
            benchmark_fixture(
                fixture,
                provider,
                max(1, args.max_prefix_calls),
                max(1, args.min_prefix_words),
                max(0, args.stability_ms) / 1000,
            )
        )
    summary = summarize(records, args.model, args)
    write_jsonl(args.output, records)
    args.summary.parent.mkdir(parents=True, exist_ok=True)
    args.summary.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    print(json.dumps(summary, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
