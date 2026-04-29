# Auto-Improve Recorder — Codex Build Brief

Build a native macOS app that recreates the narrow Field Theory auto-improve loop:

> global hotkey / record → local NVIDIA Parakeet transcription → OpenAI GPT-5.4 mini auto-improve → preview/copy/paste.

## Hard product decisions

- macOS app, native Swift/SwiftUI/AppKit.
- Prioritize speed, accuracy, reliability.
- Transcription v1: **local NVIDIA Parakeet**, specifically the version already installed on disk for Field Theory on this Mac.
- Auto-improve v1: **OpenAI `gpt-5.4-mini`**.
- Do not default to OpenAI/4o transcription.
- Design adapters so transcription/improve engines can be swapped later.
- Build a real app skeleton, not just a document.

## Use your macOS app build capability/plugin

Use your build-macOS-apps capability/plugin/workflow if available. This is explicitly a macOS native app build task, not a web app.

## Required investigation first

1. Locate Field Theory app and any installed/bundled model/runtime files.
   - Search likely locations: `/Applications`, `~/Applications`, `~/Library/Application Support`, `~/Library/Caches`, `~/Library/Containers`, `~/Library/Group Containers`.
   - Look for Field Theory, Parakeet, NVIDIA, NeMo, Hugging Face, ONNX, CoreML, model weights, Python envs, local CLIs.
2. Determine how to invoke the installed Parakeet model:
   - direct binary/CLI
   - Python/HF/NeMo runtime
   - ONNX/CoreML bundle
   - local service
   - inaccessible bundled app resource
3. If direct integration is blocked, create a `ParakeetTranscriber` interface with a clear TODO and a stub/mock implementation, plus a documented path to wire the discovered runtime.

## MVP app requirements

### UI

- Menu bar app.
- Settings window.
- Floating recorder pill/popover.
- Preview window/popover showing:
  - improved text
  - raw transcript toggle
  - copy button
  - paste button if Accessibility permission is available
  - re-run improve button

### Recording

- Use AVAudioEngine or native macOS audio capture.
- Record mic audio to a temporary file suitable for the transcriber.
- Preferred mic setting if reasonably easy; otherwise stub the setting.

### Transcription

- Define protocol/interface, e.g. `TranscriptionEngine`.
- Implement `ParakeetTranscriber` as far as possible based on discovered local runtime.
- Include robust errors and fallback messaging.
- Preserve raw transcript separately.

### Auto-improve

- Define protocol/interface, e.g. `ImproveEngine`.
- Implement `OpenAIImproveEngine` using API key from Keychain/settings.
- Model: `gpt-5.4-mini`.
- Prompt should preserve intent and constraints; remove filler, false starts, repetition; return only improved text.

### Settings

- OpenAI API key.
- Auto-improve off/manual/automatic.
- Threshold default 75 words.
- Modification strength 1–5.
- Output mode:
  - verbatim
  - light cleanup
  - prompt cleanup
  - structured task
- Parakeet model/runtime path, auto-detected if possible.

### Paste/copy

- Copy improved text to clipboard.
- Paste via Accessibility if available.
- If Accessibility is missing, copy and show one clear instruction.

### Reliability

- Never lose raw transcript.
- If improve fails, show raw transcript.
- If transcription fails, show actionable error.
- Timeouts around network improve call.

## Repository expectations

- Create an Xcode project or Swift Package/App structure that can be opened and built.
- Include README with setup/run instructions.
- Include notes about Parakeet discovery and exact paths found.
- Include a small manual test checklist.
- Build or at least run `xcodebuild`/`swift build` verification if possible.

## Notification route for completion

When completely finished or fatally blocked, send exactly one Telegram completion/failure message using:

```bash
openclaw message send \
  --account default \
  --channel telegram \
  --target 'telegram:-1003798689434' \
  --thread-id '10782' \
  --reply-to '10809' \
  --message 'Done: <brief summary, repo path, build status, blockers if any>'
```

Do not use openclaw system event. Do not rely on heartbeat.
