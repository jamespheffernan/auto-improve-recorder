# Auto Send Recorder fast delivery: permission-ready foundation

Date: 12 August 2026

## Outcome

The low-level delivery design and its disabled production foundation are ready. The current product still uses the known-safe clipboard paste path and waits at least 80 ms before it sends Enter or Command-Enter.

No faster delivery path is enabled. No speed improvement is claimed yet. A valid live target could not be obtained from this macOS session, so promotion remains blocked on one Accessibility permission and a live qualification run.

## What is complete

- Delivery now uses structured request and result values instead of positional callback arguments.
- Both AIR and Auto Send Recorder default explicitly to `legacyOnly`.
- The legacy path still performs one Command-V, waits at least 80 ms when a send key is requested, checks the destination again, and then sends Enter or Command-Enter.
- A failed send-key event after a successful paste is reported as a send failure. It is not reported as a paste failure, and the text is not copied or pasted a second time.
- The code has typed strategy, fallback, and timing values. Timing records contain phase, strategy, and elapsed time only. They do not contain transcript text.
- The code has a strict, technical capability record format. It has no production persistence, learning, or loading path.
- A capability can qualify only after at least 10,000 operations, zero errors, and at least 25% lower median latency than the legacy path.
- Capability matching includes the exact application identity and version, macOS build, control role, subrole, stable non-empty Accessibility identifier, schema version, implementation version, and intended delivery strategy.
- UTF-16 replacement logic covers emoji, composed characters, CJK text, and multiline text.
- The obsolete literal `AXEditable` probe was replaced with the SDK constant `kAXIsEditableAttribute`. Readable and settable checks remain authoritative.

## Fast path prepared for the live gate

The first candidate is an acknowledged Command-V path:

1. Capture the destination process and focused text element.
2. Read the original value and UTF-16 selection.
3. Compute the exact expected value and caret.
4. Register Accessibility notifications before posting Command-V to the captured process.
5. Use notifications only as wake-up signals. Verify the full value, caret, process, focus, destination, and cancellation state.
6. Send immediately if the exact mutation is proved.
7. If proof does not arrive, wait only until the existing 80 ms deadline and use the existing destination guard. Never paste twice.

A direct Accessibility value-write path is a later candidate for qualified native plain-text fields only. It must never run for secure, rich-text, web, Electron, terminal, canvas, or unknown controls without separate application-version evidence. If a direct mutation becomes ambiguous, the operation must stop without a clipboard fallback because a fallback could duplicate text.

## Permission-independent live work

The trusted delivery controller was tested against its native AppKit fixture. The controller reported that Accessibility trust was active, but macOS returned the application object for the window and focused-element queries. System-wide and application-root point hit tests also failed to expose either native text control. The run stopped before it changed text or measured latency.

A second bounded probe launched a new, unsaved TextEdit document. Every Accessibility query returned `kAXErrorCannotComplete` (`-25204`). No editor was exposed. No text was changed, no send action ran, and no file was saved.

These results block measurement. They do not prove that the candidate is slow or unsafe, and they do not support a speed claim.

Evidence:

- `.autoresearch/asr-fast-delivery/final-blocked-proof/`
- `.autoresearch/asr-fast-delivery/textedit-probe-20260812T010/`

## Required user action

Grant Accessibility permission to `/Applications/Auto Send Recorder.app` in System Settings. Microphone permission is not required for the delivery-only gate.

Then run:

```bash
cd /Users/jamesheffernan/GitHub/auto-improve-recorder
DELIVERY_FIXTURE_ITERATIONS=40 Bench/DeliveryFixture/run_delivery_fixture.sh .autoresearch/asr-fast-delivery/live-gate
```

If target discovery works, the next gate is a 10,000-operation application-version qualification run. Promotion requires:

- zero wrong insertions;
- zero wrong sends;
- zero duplicate pastes;
- exact Unicode and selection behavior;
- correct cancellation and focus-change suppression;
- at least 25% lower median mutation-to-send latency than the 80 ms legacy path.

Any failure keeps `legacyOnly` active.

## Claim boundary

The fixed 80 ms settlement is the main known delivery delay. Removing it could reduce the earlier planning estimate from about 111 ms toward roughly 35–45 ms on a supported field. That is a planning estimate, not measured end-to-end application latency. The product must not claim this reduction until the live gate passes.

