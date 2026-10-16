# Auto Send two-process delivery fixture

This fixture measures delivery into a separate AppKit process. It is the required gate before a direct-insertion path can replace the current Command-V plus 80 ms path.

## Run

From the repository root:

```bash
DELIVERY_FIXTURE_ITERATIONS=40 Bench/DeliveryFixture/run_delivery_fixture.sh .autoresearch/asr-fast-delivery/live-gate
```

To probe a new disposable TextEdit document without changing its text:

```bash
DELIVERY_FIXTURE_TEXTEDIT_PROBE=1 Bench/DeliveryFixture/run_delivery_fixture.sh .autoresearch/asr-fast-delivery/textedit-probe
```

The probe stops without touching TextEdit when TextEdit is already running. It closes the empty document without saving.

If `ax-diagnostics.txt` says `AXIsProcessTrusted=false`, add the exact controller binary shown by the script to **System Settings > Privacy & Security > Accessibility**, and run the same command again. A blocked run still compiles both processes and writes unit goldens, but it does not support promotion.

The default evidence directory is `.autoresearch/asr-fast-delivery/live-gate/`. It contains:

- `fixture-events.ndjson`: target-process values and Enter or Command-Enter events.
- `ax-diagnostics.txt`: controller trust, application attributes, and a bounded hierarchy dump.
- `operations.ndjson`: one timestamped controller result per measured operation.
- `summary.json`: p50, p95, p99, maximum latency, invariant failures, and the promotion gate.
- `unit-goldens.json`: UTF-16 replacement and clipboard change-count guard checks.
- `golden_checksums.txt`: SHA-256 proof for the unit goldens.

## Strategies

| Strategy | Mechanism | Main risk | Opportunity score |
|---|---|---|---:|
| Command-V + 80 ms | Current fixed settlement delay | Always pays 80 ms before send | 5.0 |
| Ordered Command-V + send | PID-targeted events with no delay | Send can overtake paste | 5.0 |
| Verified Command-V + send | Poll AX value and selection before send | Some controls do not expose readable state | 4.0 |
| Qualified AX replacement | Replace the full AXValue only for a writable native plain field | Narrow compatibility; must preserve UTF-16 selection semantics | 4.0 |

Score is impact times confidence divided by effort. All four experiments score at least 2.0.

## Promotion gate

Promotion requires all of these results in a live two-process run:

- No text loss or duplication.
- No cross-target delivery.
- No double-send.
- Exactly one Enter and exactly one Command-Enter for their fixtures.
- Suppression after focus or PID changes.
- Clipboard restoration only when its injected `changeCount` is still current.
- At least 25% lower median latency than the 80 ms baseline.

The qualified AX path applies only when the target is a native `AXTextField`, official `AXIsEditable` is true, its `AXValue` is writable, and its UTF-16 selection is readable. An ambiguous direct write fails without an automatic paste fallback.

## Behavior proof

- Ordering preserved: yes for the baseline and verified-paste paths; the zero-delay path must prove ordering in the fixture.
- Selection behavior: checked for empty, end, middle, and replacement selections using UTF-16 offsets.
- Unicode behavior: checked for emoji, composed accents, CJK, smart punctuation, newlines, and a 32 KB value.
- Send behavior: target process logs Enter and Command-Enter independently.
- Clipboard behavior: all pasteboard item data is captured; restoration is conditional on the injected change count.
- Golden outputs: `unit-goldens.json` is written before the live permission gate.

Keep a strategy only when `summary.json` says `PASS`. Reject it when any behavior invariant fails, even when it is faster.
