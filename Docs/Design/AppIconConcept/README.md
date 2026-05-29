# App Icon Concept: Waveform to Text

This design pack keeps the editable source for the current app icon and menu bar icon.

## Visual Direction

The icon uses three app signals in a stripped-back mark:

- A central microphone for recording.
- A live waveform entering from the left.
- Two text lines on the right, showing speech becoming improved text.

The app icon uses a flat deep teal field, an ivory microphone, and a mint signal line. There are no gradients, shadows, glows, or background arcs. The menu bar icon is a monochrome template-safe waveform/text cue.

## Files

- `app-icon-waveform-to-text.svg`: 1024 x 1024 editable app icon source.
- `menu-bar-waveform-template.svg`: 44 x 44 editable menu bar template icon source.

## Export Notes

For the macOS app icon, export `app-icon-waveform-to-text.svg` to PNG sizes required by `AppIcon.appiconset`.

For the menu bar icon, export `menu-bar-waveform-template.svg` as a black template PDF or PNG, then mark the image as a template image in code or asset settings. The white interior strokes are cutout guides in the source; if the export pipeline does not preserve them as transparency, convert the white strokes to transparent paths before final production export.
