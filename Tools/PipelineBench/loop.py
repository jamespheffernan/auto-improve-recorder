#!/usr/bin/env python3
"""Karpathy-style autoresearch loop runner for the AIR pipeline scheduling bench.

For each variant: run the bench, append a JSONL trial entry to
.autoresearch/air-pipeline-scheduling.jsonl, compare to incumbent, decide
keep/revert.

Acceptance rule: keep if final time improves >=10% OR first-result time
improves >=20% with no correctness regressions.
"""
from __future__ import annotations
import datetime
import json
import os
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
LOG = REPO / ".autoresearch" / "air-pipeline-scheduling.jsonl"
LOG.parent.mkdir(exist_ok=True)

VARIANTS = [
    ("baseline",
     "reproduce AppState.processRecording today: serial finalize -> transcribe -> persist -> improve -> finalize"),
    ("defer_persist",
     "run improve and main-thread persistence in parallel; both must complete before finalize"),
    ("defer_persist_fnf",
     "persistence is non-critical to user delivery; fire-and-forget after improve so finalize is unblocked"),
    ("prewarm_improve",
     "open improve URLSession during transcribe so connection is warm by the time raw is ready"),
    ("partial_prewarm_defer",
     "partial first-result mid-transcribe + prewarm improve + deferred persist (combined wins)"),
    ("speculative",
     "speculative improve on partial transcript, validated against final transcript when it arrives"),
]

ORCHESTRATOR_FILE = "Tools/PipelineBench/PipelineOrchestrator.swift"


def run_variant(variant: str) -> list[dict]:
    env = dict(os.environ)
    env["AIR_BENCH_VARIANT"] = variant
    res = subprocess.run(
        [str(REPO / "Tools" / "PipelineBench" / "run.sh")],
        env=env,
        capture_output=True,
        text=True,
        cwd=str(REPO),
        check=False,
    )
    if res.returncode != 0:
        sys.stderr.write(f"[loop] {variant} failed: {res.returncode}\n{res.stderr}")
        sys.exit(res.returncode)
    return json.loads(res.stdout)


def pct(a: float, b: float) -> float:
    if a <= 0:
        return 0.0
    return (a - b) / a


def main() -> None:
    incumbent_first = None
    incumbent_final = None
    summary = []
    for variant, hypothesis in VARIANTS:
        print(f"=== Trial: {variant} ===")
        results = run_variant(variant)
        realistic = next(r for r in results if r["profile"] == "realistic")
        streaming = next(r for r in results if r["profile"] == "streaming")

        raw_or_improved_delivered = (
            realistic["rawDelivered"] or realistic["improvedDelivered"]
        ) and (streaming["rawDelivered"] or streaming["improvedDelivered"])
        improved_delivered_both = realistic["improvedDelivered"] and streaming["improvedDelivered"]
        ordering_ok = realistic["orderingValid"] and streaming["orderingValid"]

        if variant == "baseline":
            incumbent_first = realistic["firstResultMs"]
            incumbent_final = realistic["finalMs"]
            decision = "incumbent"
            rationale = "initial baseline"
            final_delta = 0.0
            first_delta = 0.0
        else:
            final_delta = pct(incumbent_final, realistic["finalMs"])
            first_delta = pct(incumbent_first, realistic["firstResultMs"])
            if not improved_delivered_both or not ordering_ok:
                decision = "revert"
                rationale = "correctness regression: improved text not delivered or ordering invalid"
            elif final_delta >= 0.10:
                decision = "keep"
                rationale = f"final time reduced by {final_delta*100:.1f}%"
                incumbent_first = realistic["firstResultMs"]
                incumbent_final = realistic["finalMs"]
            elif first_delta >= 0.20:
                decision = "keep"
                rationale = f"first-result time reduced by {first_delta*100:.1f}%"
                incumbent_first = realistic["firstResultMs"]
                incumbent_final = realistic["finalMs"]
            else:
                decision = "revert"
                rationale = f"below acceptance threshold (final {final_delta*100:.1f}%, first {first_delta*100:.1f}%)"

        entry = {
            "ts": datetime.datetime.utcnow().isoformat() + "Z",
            "variant": variant,
            "hypothesis": hypothesis,
            "files": [ORCHESTRATOR_FILE],
            "command": f"AIR_BENCH_VARIANT={variant} ./Tools/PipelineBench/run.sh",
            "metrics": {
                "realistic_firstResult_ms": realistic["firstResultMs"],
                "realistic_final_ms": realistic["finalMs"],
                "streaming_firstResult_ms": streaming["firstResultMs"],
                "streaming_final_ms": streaming["finalMs"],
                "delta_final_pct": round(final_delta * 100, 2),
                "delta_first_pct": round(first_delta * 100, 2),
            },
            "guardrails": {
                "raw_or_improved_delivered": raw_or_improved_delivered,
                "improved_delivered_both_profiles": improved_delivered_both,
                "ordering_ok": ordering_ok,
            },
            "decision": decision,
            "rationale": rationale,
            "incumbent_after": {
                "realistic_firstResult_ms": incumbent_first,
                "realistic_final_ms": incumbent_final,
            },
        }
        with LOG.open("a") as f:
            f.write(json.dumps(entry) + "\n")

        summary.append(entry)
        print(
            f"  realistic: tFirst={realistic['firstResultMs']:.0f}ms "
            f"tFinal={realistic['finalMs']:.0f}ms (decision={decision}) -- {rationale}"
        )
        print(
            f"  streaming: tFirst={streaming['firstResultMs']:.0f}ms "
            f"tFinal={streaming['finalMs']:.0f}ms"
        )
        print()

    # Print compact final summary.
    print("=== Loop complete ===")
    print(f"Log: {LOG}")
    print()
    base = summary[0]
    best = min(
        (e for e in summary if e["guardrails"]["improved_delivered_both_profiles"]),
        key=lambda e: e["metrics"]["realistic_final_ms"],
    )
    best_first = min(
        (e for e in summary if e["guardrails"]["improved_delivered_both_profiles"]),
        key=lambda e: e["metrics"]["realistic_firstResult_ms"],
    )
    print(f"Baseline tFirstResult={base['metrics']['realistic_firstResult_ms']:.0f}ms"
          f" tFinal={base['metrics']['realistic_final_ms']:.0f}ms (realistic profile)")
    print(f"Best tFinal: variant={best['variant']} tFinal={best['metrics']['realistic_final_ms']:.0f}ms"
          f" ({best['metrics']['delta_final_pct']:+.1f}% vs baseline)")
    print(f"Best tFirst: variant={best_first['variant']} tFirst={best_first['metrics']['realistic_firstResult_ms']:.0f}ms"
          f" ({best_first['metrics']['delta_first_pct']:+.1f}% vs baseline)")


if __name__ == "__main__":
    main()
