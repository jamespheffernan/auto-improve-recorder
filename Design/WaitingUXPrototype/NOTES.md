# LAIR Waiting UX Prototype

Question: which waiting/recording feedback direction should replace or reduce the current pill while preserving clear recording state, timer/waveform feedback, release-to-send, Space latch, and Escape cancel?

Run:

```bash
python3 -m http.server 5177 --directory Design/WaitingUXPrototype
```

Open:

```text
http://127.0.0.1:5177/?variant=D
```

Variants:

- `A` Edge instrument: keeps the feedback married to the screen-edge glow, with a bottom-edge instrument strip for waveform, timer, and command hints.
- `B` Field-attached: puts the status directly on the focused field, with a ring and compact status capsule.
- `C` Micro HUD: tiny ambient HUD near the work area, with edge glow doing most of the emotional/status work.
- `D` Glow readout: hybrid direction. The edge glow is the primary state layer, and the micro HUD is a small readout connected to the bottom edge by a light tether.

Prototype controls:

- Hold the red button to record; release sends.
- Click `Space: latch`, or press Space when the textarea is not focused, to test persistent recording.
- Press Escape to cancel.
- Use left/right arrows or the floating switcher to change variants.

Review prompt:

- Does the UI make recording obvious without feeling like a separate app window?
- Does the timer/waveform feel useful or noisy?
- Do the command hints help, or should they appear only on first use / hover / settings?
- Is the paste/submit moment legible enough without becoming theatrical?
