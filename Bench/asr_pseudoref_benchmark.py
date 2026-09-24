#!/usr/bin/env python3
"""Freeze and score current ASR output against archived raw pseudo-references.

This benchmark measures behavioral drift. Archived model output is not speech
truth and must never be reported as accuracy.
"""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
import math
import os
import re
import resource
import statistics
import subprocess
import sys
import time
import unicodedata
from pathlib import Path
from typing import Any, Iterable


REPO = Path(__file__).resolve().parents[1]
DEFAULT_ARCHIVE = REPO / ".autoresearch/auto-send-asr-accuracy/archive-corpus.json"
DEFAULT_OUT = REPO / ".autoresearch/asr-pseudoref-benchmark"
MODEL_BASE = Path.home() / "Library/Application Support/AutoImproveRecorder/ParakeetCpp"
MODEL = MODEL_BASE / "models/nemotron-3.5-asr-streaming-0.6b-q8_0.gguf"
RUNTIME = MODEL_BASE / "capi/libparakeet.dylib"
TRANSCRIPT_INDEX = Path.home() / "Library/Application Support/AutoImproveRecorder/TranscriptTruth/index.jsonl"
SEED = "auto-send-pseudoref-v1"
NO_SPEECH_MARKERS = {
    "[blank_audio]",
    "[blank audio]",
    "[silence]",
    "[no speech]",
    "<blank_audio>",
}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def canonical_sha256(value: Any) -> str:
    return sha256_text(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")))


def stable_key(item_id: str) -> str:
    return sha256_text(f"{SEED}:{item_id}")


def duration_band(seconds: float) -> str:
    if seconds <= 5:
        return "short_0_5s"
    if seconds <= 20:
        return "normal_5_20s"
    if seconds <= 30:
        return "medium_20_30s"
    if seconds <= 120:
        return "long_30_120s"
    return "very_long_over_120s"


def is_no_text(text: str) -> bool:
    stripped = text.strip().casefold()
    return not stripped or stripped in NO_SPEECH_MARKERS


def allocate_proportionally(groups: dict[tuple[str, str], list[dict[str, Any]]], total: int) -> dict[tuple[str, str], int]:
    population = sum(len(items) for items in groups.values())
    if population < total:
        raise ValueError(f"need {total} items but only {population} are eligible")
    exact = {key: total * len(items) / population for key, items in groups.items()}
    allocation = {key: min(len(groups[key]), math.floor(value)) for key, value in exact.items()}
    remaining = total - sum(allocation.values())
    order = sorted(
        groups,
        key=lambda key: (-(exact[key] - math.floor(exact[key])), stable_key("|".join(key))),
    )
    while remaining:
        progressed = False
        for key in order:
            if allocation[key] < len(groups[key]):
                allocation[key] += 1
                remaining -= 1
                progressed = True
                if remaining == 0:
                    break
        if not progressed:
            raise ValueError("could not complete proportional allocation")
    return allocation


def prepare(args: argparse.Namespace) -> None:
    archive = json.loads(args.archive.read_text())
    recovered_engines: dict[str, str] = {}
    if TRANSCRIPT_INDEX.is_file():
        for line in TRANSCRIPT_INDEX.read_text().splitlines():
            try:
                index_record = json.loads(line)
                engine = index_record.get("transcriptionEngine")
                if isinstance(engine, str) and engine.strip():
                    recovered_engines[str(index_record.get("id"))] = engine
            except json.JSONDecodeError:
                continue
    candidates: list[dict[str, Any]] = []
    failures: list[dict[str, str]] = []
    for source in archive.get("items", []):
        try:
            item_id = str(source["id"])
            metadata = source.get("metadata") or {}
            audio = Path(source["audio"]).expanduser().resolve()
            record = Path(metadata["source_record"]).expanduser().resolve()
            if not audio.is_file() or not record.is_file():
                raise FileNotFoundError("audio or record is missing")
            record_data = json.loads(record.read_text())
            raw = record_data.get("rawTranscript")
            if not isinstance(raw, str):
                raise ValueError("rawTranscript is not a string")
            duration = float(metadata.get("duration_seconds") or 0)
            if duration <= 0:
                raise ValueError("duration is missing or not positive")
            dictionary = record_data.get("dictionarySnapshot")
            candidates.append(
                {
                    "id": item_id,
                    "audio_path": str(audio),
                    "record_path": str(record),
                    "duration_seconds": duration,
                    "duration_band": duration_band(duration),
                    "archived_engine": metadata.get("transcription_engine") or recovered_engines.get(item_id) or "unknown",
                    "archived_engine_source": "record_manifest" if metadata.get("transcription_engine") else ("append_only_index" if recovered_engines.get(item_id) else "unknown"),
                    "archived_mode": metadata.get("transcription_mode") or "unknown",
                    "created_at": metadata.get("created_at"),
                    "pseudo_reference_kind": "no_text_or_marker" if is_no_text(raw) else "archived_raw_model_output",
                    "pseudo_reference_sha256": sha256_text(raw),
                    "dictionary_snapshot_sha256": sha256_text(dictionary) if isinstance(dictionary, str) and dictionary else None,
                    "audio_sha256": sha256_file(audio),
                    "record_sha256": sha256_file(record),
                }
            )
        except Exception as error:  # preserve an audit trail without aborting inventory
            failures.append({"id": str(source.get("id", "unknown")), "error": str(error)})

    nonempty = [item for item in candidates if item["pseudo_reference_kind"] == "archived_raw_model_output"]
    no_text = [item for item in candidates if item["pseudo_reference_kind"] == "no_text_or_marker"]
    groups: dict[tuple[str, str], list[dict[str, Any]]] = collections.defaultdict(list)
    for item in nonempty:
        groups[(item["archived_engine"], item["duration_band"])].append(item)
    for items in groups.values():
        items.sort(key=lambda item: stable_key(item["id"]))
    allocation = allocate_proportionally(groups, args.nonempty_count)
    selected = [item for key, items in groups.items() for item in items[: allocation[key]]]
    no_text.sort(key=lambda item: stable_key(item["id"]))
    if len(no_text) < args.no_text_count:
        raise SystemExit(f"need {args.no_text_count} no-text candidates; found {len(no_text)}")
    selected.extend(no_text[: args.no_text_count])
    selected.sort(key=lambda item: item["id"])

    args.out.mkdir(parents=True, exist_ok=True)
    manifest = {
        "schema_version": 1,
        "purpose": "Behavioral drift against archived raw model outputs; not speech accuracy",
        "selection_seed": SEED,
        "selection_rule": (
            f"{args.nonempty_count} non-empty raw outputs sampled deterministically in proportion to "
            "eligible archived-engine x duration-band strata, plus "
            f"{args.no_text_count} empty or explicit no-speech-marker outputs"
        ),
        "archive_manifest_path": str(args.archive.resolve()),
        "archive_manifest_sha256": sha256_file(args.archive),
        "append_only_index_path": str(TRANSCRIPT_INDEX),
        "append_only_index_sha256": sha256_file(TRANSCRIPT_INDEX) if TRANSCRIPT_INDEX.is_file() else None,
        "eligible_inventory_count": len(candidates),
        "inventory_failure_count": len(failures),
        "current_model_path": str(MODEL),
        "current_model_sha256": sha256_file(MODEL),
        "current_runtime_path": str(RUNTIME),
        "current_runtime_sha256": sha256_file(RUNTIME),
        "items": selected,
    }
    manifest["selected_items_canonical_sha256"] = canonical_sha256(selected)
    manifest_path = args.out / "input-manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    checks = []
    for item in selected:
        checks.append(f"{item['audio_sha256']}  {item['audio_path']}")
        checks.append(f"{item['record_sha256']}  {item['record_path']}")
    (args.out / "golden_checksums.txt").write_text("\n".join(checks) + "\n")
    (args.out / "inventory-failures.json").write_text(json.dumps(failures, indent=2, sort_keys=True) + "\n")
    print(json.dumps({
        "manifest": str(manifest_path),
        "selected": len(selected),
        "nonempty": args.nonempty_count,
        "no_text": args.no_text_count,
        "duration_bands": dict(collections.Counter(item["duration_band"] for item in selected)),
        "archived_engines": dict(collections.Counter(item["archived_engine"] for item in selected)),
        "audio_seconds": sum(item["duration_seconds"] for item in selected),
        "selected_items_canonical_sha256": manifest["selected_items_canonical_sha256"],
    }, indent=2, sort_keys=True))


def verify_manifest(manifest: dict[str, Any]) -> None:
    if canonical_sha256(manifest["items"]) != manifest["selected_items_canonical_sha256"]:
        raise ValueError("selected-item manifest hash changed")
    if sha256_file(Path(manifest["current_model_path"])) != manifest["current_model_sha256"]:
        raise ValueError("current model hash changed")
    if sha256_file(Path(manifest["current_runtime_path"])) != manifest["current_runtime_sha256"]:
        raise ValueError("current runtime hash changed")
    for item in manifest["items"]:
        if sha256_file(Path(item["audio_path"])) != item["audio_sha256"]:
            raise ValueError(f"audio hash changed: {item['id']}")
        if sha256_file(Path(item["record_path"])) != item["record_sha256"]:
            raise ValueError(f"record hash changed: {item['id']}")
        record = json.loads(Path(item["record_path"]).read_text())
        if sha256_text(record.get("rawTranscript", "")) != item["pseudo_reference_sha256"]:
            raise ValueError(f"pseudo-reference hash changed: {item['id']}")


def choose_smoke(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    wanted = ["short_0_5s", "normal_5_20s", "long_30_120s"]
    selected: list[dict[str, Any]] = []
    for band in wanted:
        match = next((item for item in items if item["duration_band"] == band and item["pseudo_reference_kind"] == "archived_raw_model_output"), None)
        if match:
            selected.append(match)
    return selected


def run_model(args: argparse.Namespace) -> None:
    manifest = json.loads(args.manifest.read_text())
    verify_manifest(manifest)
    items = choose_smoke(manifest["items"]) if args.smoke else manifest["items"]
    if not items:
        raise SystemExit("no items selected")
    build = subprocess.run(
        ["swift", "build", "-c", "release", "--product", "ParakeetLiveBench"],
        cwd=REPO / "Bench",
        text=True,
        capture_output=True,
    )
    if build.returncode:
        sys.stderr.write(build.stdout + build.stderr)
        raise SystemExit(build.returncode)
    binary = REPO / "Bench/.build/release/ParakeetLiveBench"
    if not binary.is_file():
        raise SystemExit(f"built binary missing: {binary}")
    command = [str(binary), *[item["audio_path"] for item in items]]
    started = time.perf_counter()
    usage_before = resource.getrusage(resource.RUSAGE_CHILDREN)
    completed = subprocess.run(command, cwd=REPO, text=True, capture_output=True)
    elapsed = time.perf_counter() - started
    usage_after = resource.getrusage(resource.RUSAGE_CHILDREN)
    run_name = "smoke" if args.smoke else "full"
    (args.out / f"{run_name}.stderr.log").write_text(completed.stderr)
    if completed.returncode:
        (args.out / f"{run_name}.stdout.log").write_text(completed.stdout)
        raise SystemExit(f"model run failed with exit {completed.returncode}; see {run_name}.stderr.log")
    measurements = json.loads(completed.stdout)
    normalizer_source = REPO / "AutoImproveRecorder/Support/TranscriptTextNormalizer.swift"
    normalizer_main = REPO / "Bench/Sources/PseudoRefNormalize/main.swift"
    normalizer_binary = args.out / "pseudo-ref-normalize"
    compile_normalizer = subprocess.run(
        ["swiftc", "-O", str(normalizer_source), str(normalizer_main), "-o", str(normalizer_binary)],
        cwd=REPO,
        text=True,
        capture_output=True,
    )
    if compile_normalizer.returncode:
        sys.stderr.write(compile_normalizer.stdout + compile_normalizer.stderr)
        raise SystemExit(compile_normalizer.returncode)
    normalized = subprocess.run(
        [str(normalizer_binary)],
        input=json.dumps(measurements),
        text=True,
        capture_output=True,
    )
    if normalized.returncode:
        sys.stderr.write(normalized.stdout + normalized.stderr)
        raise SystemExit(normalized.returncode)
    measurements = json.loads(normalized.stdout)
    run = {
        "kind": run_name,
        "command": command,
        "started_at_unix": time.time() - elapsed,
        "wall_seconds": elapsed,
        "child_user_cpu_seconds": usage_after.ru_utime - usage_before.ru_utime,
        "child_system_cpu_seconds": usage_after.ru_stime - usage_before.ru_stime,
        "child_max_rss_raw": usage_after.ru_maxrss,
        "item_count": len(items),
        "measurements": measurements,
    }
    path = args.out / f"{run_name}-current-output.json"
    path.write_text(json.dumps(run, indent=2, sort_keys=True) + "\n")
    print(json.dumps({
        "output": str(path),
        "item_count": len(items),
        "wall_seconds": elapsed,
        "audio_seconds": sum(item["duration_seconds"] for item in items),
        "measurement_count": len(measurements),
        "child_max_rss_raw": usage_after.ru_maxrss,
    }, indent=2, sort_keys=True))


def normalized_words(text: str) -> list[str]:
    text = unicodedata.normalize("NFKC", text).casefold().replace("’", "'")
    return re.findall(r"[\w]+(?:'[\w]+)*", text, flags=re.UNICODE)


def normalized_text(text: str) -> str:
    return " ".join(normalized_words(text))


def alignment(reference: list[str], hypothesis: list[str]) -> dict[str, int]:
    # Each cell is (cost, substitutions, deletions, insertions, matches).
    rows: list[list[tuple[int, int, int, int, int]]] = []
    rows.append([(j, 0, 0, j, 0) for j in range(len(hypothesis) + 1)])
    for i in range(1, len(reference) + 1):
        row = [(i, 0, i, 0, 0)]
        for j in range(1, len(hypothesis) + 1):
            if reference[i - 1] == hypothesis[j - 1]:
                prev = rows[i - 1][j - 1]
                row.append((prev[0], prev[1], prev[2], prev[3], prev[4] + 1))
                continue
            sub = rows[i - 1][j - 1]
            delete = rows[i - 1][j]
            insert = row[j - 1]
            choices = [
                (sub[0] + 1, sub[1] + 1, sub[2], sub[3], sub[4]),
                (delete[0] + 1, delete[1], delete[2] + 1, delete[3], delete[4]),
                (insert[0] + 1, insert[1], insert[2], insert[3] + 1, insert[4]),
            ]
            row.append(min(choices))
        rows.append(row)
    cost, substitutions, deletions, insertions, matches = rows[-1][-1]
    return {"errors": cost, "substitutions": substitutions, "deletions": deletions, "insertions": insertions, "matches": matches}


def quantile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = max(0, math.ceil(fraction * len(ordered)) - 1)
    return ordered[index]


def safe_div(numerator: float, denominator: float) -> float | None:
    return numerator / denominator if denominator else None


def punctuation_sequence_score(reference: str, hypothesis: str) -> tuple[int, int, int]:
    """Compare punctuation order only; word-boundary position is not scored."""
    ref = [char for char in reference if unicodedata.category(char).startswith("P")]
    hyp = [char for char in hypothesis if unicodedata.category(char).startswith("P")]
    matches = alignment(ref, hyp)["matches"]
    return matches, len(ref), len(hyp)


def lcs_matched_pairs(left: list[str], right: list[str]) -> list[tuple[int, int]]:
    table = [[0] * (len(right) + 1) for _ in range(len(left) + 1)]
    for i in range(len(left) - 1, -1, -1):
        for j in range(len(right) - 1, -1, -1):
            if left[i] == right[j]:
                table[i][j] = 1 + table[i + 1][j + 1]
            else:
                table[i][j] = max(table[i + 1][j], table[i][j + 1])
    pairs: list[tuple[int, int]] = []
    i = j = 0
    while i < len(left) and j < len(right):
        if left[i] == right[j]:
            pairs.append((i, j))
            i += 1
            j += 1
        elif table[i + 1][j] >= table[i][j + 1]:
            i += 1
        else:
            j += 1
    return pairs


def dictionary_terms(record: dict[str, Any], reference: str) -> list[str]:
    snapshot = record.get("dictionarySnapshot")
    if not isinstance(snapshot, str) or not snapshot.strip():
        return []
    candidates = [part.strip() for part in re.split(r"[,;\n]", snapshot) if part.strip()]
    reference_norm = normalized_text(reference)
    return [term for term in candidates if normalized_text(term) and normalized_text(term) in reference_norm]


def aggregate(rows: list[dict[str, Any]]) -> dict[str, Any]:
    speech = [row for row in rows if row["pseudo_reference_kind"] == "archived_raw_model_output" and row.get("error") is None]
    no_text = [row for row in rows if row["pseudo_reference_kind"] == "no_text_or_marker" and row.get("error") is None]
    totals = collections.Counter()
    for row in speech:
        for key in ("reference_words", "hypothesis_words", "errors", "substitutions", "deletions", "insertions", "matches", "reference_characters", "character_errors", "punctuation_sequence_matches", "reference_punctuation_sequence_length", "hypothesis_punctuation_sequence_length", "technical_terms_total", "technical_terms_retained"):
            totals[key] += row[key]
    precision = safe_div(totals["matches"], totals["matches"] + totals["insertions"] + totals["substitutions"])
    recall = safe_div(totals["matches"], totals["matches"] + totals["deletions"] + totals["substitutions"])
    punctuation_sequence_precision = safe_div(totals["punctuation_sequence_matches"], totals["hypothesis_punctuation_sequence_length"])
    punctuation_sequence_recall = safe_div(totals["punctuation_sequence_matches"], totals["reference_punctuation_sequence_length"])
    elapsed = [row["model_audio_pipeline_elapsed_milliseconds"] for row in rows if row.get("model_audio_pipeline_elapsed_milliseconds") is not None]
    finalize = [row["finalize_milliseconds"] for row in rows if row.get("finalize_milliseconds") is not None]
    rtf = [row["model_audio_pipeline_realtime_factor"] for row in rows if row.get("model_audio_pipeline_realtime_factor") is not None]
    return {
        "items": len(rows),
        "successful": sum(row.get("error") is None for row in rows),
        "failed": sum(row.get("error") is not None for row in rows),
        "speech_pseudoref_items": len(speech),
        "no_text_or_marker_items": len(no_text),
        "raw_exact_match_rate": safe_div(sum(row["raw_exact_match"] for row in speech), len(speech)),
        "normalized_exact_match_rate": safe_div(sum(row["normalized_exact_match"] for row in speech), len(speech)),
        "micro_wer": safe_div(totals["errors"], totals["reference_words"]),
        "micro_cer": safe_div(totals["character_errors"], totals["reference_characters"]),
        "word_precision": precision,
        "word_recall": recall,
        "word_f1": safe_div(2 * precision * recall, precision + recall) if precision is not None and recall is not None else None,
        "substitutions": totals["substitutions"],
        "deletions": totals["deletions"],
        "insertions": totals["insertions"],
        "case_agreement_on_aligned_words": safe_div(sum(row["case_matches"] for row in speech), sum(row["case_comparable_words"] for row in speech)),
        "punctuation_sequence_precision": punctuation_sequence_precision,
        "punctuation_sequence_recall": punctuation_sequence_recall,
        "punctuation_sequence_f1": safe_div(2 * punctuation_sequence_precision * punctuation_sequence_recall, punctuation_sequence_precision + punctuation_sequence_recall) if punctuation_sequence_precision is not None and punctuation_sequence_recall is not None else None,
        "punctuation_sequence_scope": "Punctuation character order only; word-boundary position is not scored.",
        "technical_term_retention": safe_div(totals["technical_terms_retained"], totals["technical_terms_total"]),
        "technical_terms_total": totals["technical_terms_total"],
        "no_text_false_word_total": sum(row["hypothesis_words"] for row in no_text),
        "no_text_zero_word_rate": safe_div(sum(row["hypothesis_words"] == 0 for row in no_text), len(no_text)),
        "model_audio_pipeline_elapsed_ms_p50": quantile(elapsed, 0.50),
        "model_audio_pipeline_elapsed_ms_p95": quantile(elapsed, 0.95),
        "model_audio_pipeline_elapsed_ms_p99": quantile(elapsed, 0.99),
        "finalize_ms_p50": quantile(finalize, 0.50),
        "finalize_ms_p95": quantile(finalize, 0.95),
        "finalize_ms_p99": quantile(finalize, 0.99),
        "finalize_ms_max": max(finalize) if finalize else None,
        "model_audio_pipeline_realtime_factor_p50": quantile(rtf, 0.50),
        "model_audio_pipeline_realtime_factor_p95": quantile(rtf, 0.95),
        "model_audio_pipeline_realtime_factor_p99": quantile(rtf, 0.99),
        "timing_scope": "Audio file read, conversion, streaming model feed, and finalization. Product spoken-number normalization is excluded.",
    }


def aggregate_text_variant(rows: list[dict[str, Any]], field: str) -> dict[str, Any]:
    speech = [
        row for row in rows
        if row.get("error") is None and row["pseudo_reference_kind"] == "archived_raw_model_output"
    ]
    metrics = [row[field] for row in speech]
    totals = collections.Counter()
    for value in metrics:
        for key in (
            "reference_words", "hypothesis_words", "errors", "substitutions",
            "deletions", "insertions", "reference_characters", "character_errors",
            "technical_terms_total", "technical_terms_retained",
        ):
            totals[key] += value[key]
    return {
        "items": len(metrics),
        "raw_exact_match_rate": safe_div(sum(value["raw_exact_match"] for value in metrics), len(metrics)),
        "normalized_exact_match_rate": safe_div(sum(value["normalized_exact_match"] for value in metrics), len(metrics)),
        "micro_wer": safe_div(totals["errors"], totals["reference_words"]),
        "micro_cer": safe_div(totals["character_errors"], totals["reference_characters"]),
        "substitutions": totals["substitutions"],
        "deletions": totals["deletions"],
        "insertions": totals["insertions"],
        "technical_terms_total": totals["technical_terms_total"],
        "technical_term_retention": safe_div(totals["technical_terms_retained"], totals["technical_terms_total"]),
    }


def score(args: argparse.Namespace) -> None:
    manifest = json.loads(args.manifest.read_text())
    verify_manifest(manifest)
    run = json.loads(args.current_output.read_text())
    measurements = {Path(value["audioPath"]).resolve(): value for value in run["measurements"]}
    rows: list[dict[str, Any]] = []
    for item in manifest["items"]:
        audio = Path(item["audio_path"]).resolve()
        measurement = measurements.get(audio)
        record = json.loads(Path(item["record_path"]).read_text())
        reference = record["rawTranscript"]
        if measurement is None:
            rows.append({**item, "error": "missing current measurement"})
            continue
        hypothesis = measurement["transcript"]
        product_hypothesis = measurement["productNormalizedTranscript"]
        pre_product_metrics = score_text_pair(reference, hypothesis, record)
        product_metrics = score_text_pair(reference, product_hypothesis, record)
        # The main fields are product-path metrics because archived rawTranscript
        # already passed the product normalizer before it was saved.
        hypothesis = product_hypothesis
        ref_words = normalized_words(reference)
        hyp_words = normalized_words(hypothesis)
        word_alignment = alignment(ref_words, hyp_words)
        ref_chars = list(normalized_text(reference).replace(" ", ""))
        hyp_chars = list(normalized_text(hypothesis).replace(" ", ""))
        char_alignment = alignment(ref_chars, hyp_chars)
        punctuation_sequence_matches, reference_punctuation_sequence_length, hypothesis_punctuation_sequence_length = punctuation_sequence_score(reference, hypothesis)
        ref_surface = re.findall(r"[\w]+(?:['’][\w]+)*", unicodedata.normalize("NFKC", reference))
        hyp_surface = re.findall(r"[\w]+(?:['’][\w]+)*", unicodedata.normalize("NFKC", hypothesis))
        case_pairs = lcs_matched_pairs([word.casefold() for word in ref_surface], [word.casefold() for word in hyp_surface])
        case_matches = sum(ref_surface[i] == hyp_surface[j] for i, j in case_pairs)
        case_comparable = len(case_pairs)
        terms = dictionary_terms(record, reference)
        hypothesis_norm = normalized_text(hypothesis)
        retained = sum(normalized_text(term) in hypothesis_norm for term in terms)
        elapsed_ms = float(measurement["elapsedMilliseconds"])
        duration = float(measurement["durationSeconds"])
        rows.append({
            **item,
            "error": None,
            "archived_raw_pseudo_reference": reference,
            "current_pre_product_normalization": measurement["transcript"],
            "current_transcript": product_hypothesis,
            "pre_product_normalization_metrics": pre_product_metrics,
            "product_normalization_metrics": product_metrics,
            "raw_exact_match": reference.strip() == hypothesis.strip(),
            "normalized_exact_match": ref_words == hyp_words,
            "reference_words": len(ref_words),
            "hypothesis_words": len(hyp_words),
            **word_alignment,
            "wer": safe_div(word_alignment["errors"], len(ref_words)),
            "reference_characters": len(ref_chars),
            "character_errors": char_alignment["errors"],
            "cer": safe_div(char_alignment["errors"], len(ref_chars)),
            "case_matches": case_matches,
            "case_comparable_words": case_comparable,
            "punctuation_sequence_matches": punctuation_sequence_matches,
            "reference_punctuation_sequence_length": reference_punctuation_sequence_length,
            "hypothesis_punctuation_sequence_length": hypothesis_punctuation_sequence_length,
            "technical_terms_total": len(terms),
            "technical_terms_retained": retained,
            "model_audio_pipeline_elapsed_milliseconds": elapsed_ms,
            "feed_chunk_count": measurement["feedChunkCount"],
            "feed_milliseconds_total": measurement["feedMillisecondsTotal"],
            "finalize_milliseconds": measurement["finalizeMilliseconds"],
            "model_audio_pipeline_realtime_factor": safe_div(elapsed_ms / 1000, duration),
        })

    args.out.mkdir(parents=True, exist_ok=True)
    per_clip = args.out / "per-clip.jsonl"
    per_clip.write_text("".join(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n" for row in rows))
    summary = {
        "warning": "Agreement with archived model output measures behavioral drift, not speech accuracy.",
        "manifest_path": str(args.manifest.resolve()),
        "manifest_sha256": sha256_file(args.manifest),
        "current_output_path": str(args.current_output.resolve()),
        "current_output_sha256": sha256_file(args.current_output),
        "run": {
            "kind": run["kind"],
            "model_audio_pipeline_wall_seconds": run["wall_seconds"],
            "child_user_cpu_seconds": run["child_user_cpu_seconds"],
            "child_system_cpu_seconds": run["child_system_cpu_seconds"],
            "child_max_rss_raw": run["child_max_rss_raw"],
            "item_count": run["item_count"],
            "timing_scope": "Audio file read, conversion, streaming model feed, and finalization. Product spoken-number normalization is excluded.",
        },
        "overall": aggregate(rows),
        "current_candidate_before_product_normalization": aggregate_text_variant(rows, "pre_product_normalization_metrics"),
        "current_candidate_after_product_normalization": aggregate_text_variant(rows, "product_normalization_metrics"),
        "by_duration_band": {key: aggregate(values) for key, values in grouped(rows, "duration_band").items()},
        "by_archived_engine": {key: aggregate(values) for key, values in grouped(rows, "archived_engine").items()},
        "by_archived_mode": {key: aggregate(values) for key, values in grouped(rows, "archived_mode").items()},
        "by_pseudo_reference_kind": {key: aggregate(values) for key, values in grouped(rows, "pseudo_reference_kind").items()},
    }
    (args.out / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    divergences = sorted(
        [row for row in rows if row.get("error") is None and row["pseudo_reference_kind"] == "archived_raw_model_output"],
        key=lambda row: (row["wer"] if row["wer"] is not None else -1, row["errors"]),
        reverse=True,
    )[:20]
    lines = ["# Largest pseudo-reference divergences", "", "Private local evidence. Archived text is model output, not truth.", ""]
    for index, row in enumerate(divergences, 1):
        lines.extend([
            f"## {index}. {row['id']} (WER {row['wer']:.3f})",
            "",
            f"- Archived raw: {row['archived_raw_pseudo_reference']}",
            f"- Current: {row['current_transcript']}",
            "",
        ])
    (args.out / "top-20-divergences-private.md").write_text("\n".join(lines))
    print(json.dumps(summary["overall"], indent=2, sort_keys=True))


def grouped(rows: Iterable[dict[str, Any]], key: str) -> dict[str, list[dict[str, Any]]]:
    result: dict[str, list[dict[str, Any]]] = collections.defaultdict(list)
    for row in rows:
        result[str(row[key])].append(row)
    return dict(sorted(result.items()))


def score_text_pair(reference: str, hypothesis: str, record: dict[str, Any]) -> dict[str, Any]:
    ref_words = normalized_words(reference)
    hyp_words = normalized_words(hypothesis)
    word_alignment = alignment(ref_words, hyp_words)
    ref_chars = list(normalized_text(reference).replace(" ", ""))
    hyp_chars = list(normalized_text(hypothesis).replace(" ", ""))
    char_alignment = alignment(ref_chars, hyp_chars)
    terms = dictionary_terms(record, reference)
    hyp_norm = normalized_text(hypothesis)
    return {
        "raw_exact_match": reference.strip() == hypothesis.strip(),
        "normalized_exact_match": ref_words == hyp_words,
        "reference_words": len(ref_words),
        "hypothesis_words": len(hyp_words),
        "errors": word_alignment["errors"],
        "wer": safe_div(word_alignment["errors"], len(ref_words)),
        "reference_characters": len(ref_chars),
        "character_errors": char_alignment["errors"],
        "cer": safe_div(char_alignment["errors"], len(ref_chars)),
        "substitutions": word_alignment["substitutions"],
        "deletions": word_alignment["deletions"],
        "insertions": word_alignment["insertions"],
        "technical_terms_total": len(terms),
        "technical_terms_retained": sum(normalized_text(term) in hyp_norm for term in terms),
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    prepare_parser = sub.add_parser("prepare", help="freeze a deterministic pseudo-reference corpus")
    prepare_parser.add_argument("--archive", type=Path, default=DEFAULT_ARCHIVE)
    prepare_parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    prepare_parser.add_argument("--nonempty-count", type=int, default=100)
    prepare_parser.add_argument("--no-text-count", type=int, default=10)
    prepare_parser.set_defaults(func=prepare)
    run_parser = sub.add_parser("run", help="run the current local streaming model")
    run_parser.add_argument("--manifest", type=Path, default=DEFAULT_OUT / "input-manifest.json")
    run_parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    run_parser.add_argument("--smoke", action="store_true")
    run_parser.set_defaults(func=run_model)
    score_parser = sub.add_parser("score", help="score current output as pseudo-reference drift")
    score_parser.add_argument("--manifest", type=Path, default=DEFAULT_OUT / "input-manifest.json")
    score_parser.add_argument("--current-output", type=Path, default=DEFAULT_OUT / "full-current-output.json")
    score_parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    score_parser.set_defaults(func=score)
    return parser


def main() -> None:
    args = build_parser().parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
