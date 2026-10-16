# AutoImproveRecorder Waiting UX Prototype

Purpose: compare waiting and delivery feedback directions while checking the shipped app states against the same edge glow, stage rail, command hint, and readout copy rules.

Run:

```bash
python3 -m http.server 5177 --directory Design/WaitingUXPrototype
```

Open:

```text
http://127.0.0.1:5177/?variant=B&state=recording
```

The prototype also works by opening `index.html` directly. The local server keeps variant and state URLs easy to share.

Variants:

- `A` Edge instrument: bottom-edge instrument strip for waveform, timer, stage rail, and command hints.
- `B` Field-attached: status and rail attached to the focused field.
- `C` Micro HUD: small work-area HUD with ambient command hints.
- `D` Glow readout: edge glow as the primary layer with a small tethered readout.

State playground:

- Use the left panel to jump through `idle`, `starting`, `recording`, `latched`, `transcribing`, `improving`, `delivering`, `pasted`, `submitted`, `copied`, `ready`, `done`, `failed`, `permission-denied`, and `model-unavailable`.
- Use `Play flow` to run the happy path from startup through ready.
- Add `state=<key>` to the URL to deep-link to a state, for example `?variant=A&state=model-unavailable`.

Tuning panel:

- The dial kit is focused on the waveform-to-stage transition only, grouped `Tempo`, `Wave in`, `Handoff`, and `Landing`. Everything else (HUD chrome, pill geometry, colors, opacity, glow, visibility) is pinned to the Subtle values in `fixedTuning` so it stays out of the way.
- Hover or keyboard-focus any dial to get a floating description of exactly what it changes; the copy lives on each control's `description` in `app.js`.
- The visible status track is one shared pill series: it animates as a waveform while `recording` or `latched`, then uses the same pills as the stage bar for every other active state.
- The waveform-to-stage handoff peaks at the incoming active stage pill first; `Active overshoot`, `Neighbor overshoot`, `Settle duration`, and `Pill stagger` tune that settle, and `Wave height`/`Wave cycle`/`Wave stagger` shape the waveform energy that hands off.
- `Settle bounce` controls follow-through on that handoff: the pill carries the wave's height in, overshoots, then rings out (dip under rest, small re-overshoot, settle) instead of stopping dead. Set it to `0` for a clean single decel; raise it for a springier, more "alive" landing.
- Completed/current stage pills keep subtle motion after the handoff; tune it with `Active height`, `Stage breathing`, and `Breathing cycle`.
- `Subtle` and `Loud` presets now vary only the transition feel: `Subtle` is the refined default; `Loud` is the punchier, springier upper bound. The pinned look is unaffected by the preset.
- Use `Copy values` to copy the current tuning JSON for implementation notes or follow-up work.

Prototype controls:

- Hold the red button to record; release sends.
- Click `Space: latch`, or press Space when the textarea is not focused, to test persistent recording.
- Press Escape to cancel.
- Use left/right arrows or the floating switcher to change variants.

Inspect:

- Does each state make the active surface clear: glow/readout, field attachment, micro HUD, or idle quiet?
- Do command hints change correctly between capture, wait, delivery, recovery, permission, and model states?
- Does the stage rail mark the right phase without relying on color alone?
- Do `pasted`, `submitted`, and `copied` feel distinct enough after delivery?
- Do `failed`, `permission-denied`, and `model-unavailable` lead with recovery copy instead of generic error status?

Lightweight check:

```bash
node --check Design/WaitingUXPrototype/app.js
```
