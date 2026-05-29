# App Icon

## Current direction — "AIR" monogram (A-wave)

The shipping mark is a bold, flat-geometric capital **A** (for **A**uto **I**mprove **R**ecorder —
also the *air* voice travels through) whose crossbar is a tangerine **soundwave**. The wave is the
only colored element, so the brand color carries meaning (voice) and doubles as the universal
"record" signal.

Palette:

- Field: `#1B1714` (espresso ink)
- Glyph: `#F2ECDD` (bone)
- Accent: `#FF7A33` (tangerine)

Previews: `icon-air-macos-1024.png` (squircle, native macOS look) and `icon-air-ios-1024.png`
(full-bleed, system-masked) in `Design/`.

### Regenerating

Masters and the renderer live in `Design/_render/`:

- `icon-macos.svg` — rounded-rect tile inset with transparent margins (macOS).
- `icon-ios.svg` — full-bleed field, glyph scaled up (iOS, system masks corners).
- `build-icons.sh` — renders every size into both `AppIcon.appiconset`s and rebuilds
  `AutoImproveRecorder/AppIcon.icns` via `iconutil`.

```bash
cd Design/_render
npm install          # @resvg/resvg-js, one time
bash build-icons.sh
```

## Earlier explorations (superseded)

Mic + waveform marks, kept for reference:

- `concept-a-waveform-text.png`: previous shipping icon. Flat microphone, waveform, two text lines.
- `concept-b-orbital-mic.png`: compact microphone variant.
- `concept-c-text-wave.png`: variant emphasizing the transcript/text output.
