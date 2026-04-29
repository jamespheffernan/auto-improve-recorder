# Auto Improve Recorder

Native macOS menu bar app for:

`global hotkey / record -> transcription -> OpenAI gpt-5.4-mini improve -> clipboard`

## What is built

- Native Swift/SwiftUI/AppKit macOS app target in `AutoImproveRecorder.xcodeproj`.
- Menu bar status item.
- Global hotkey: `Hyper-R` (`Control-Option-Command-Shift-R`).
- Floating recorder pill during recording/transcription/improve.
- Fast path copies the finished transcript/improved text directly to clipboard with no preview window.
- Optional preview window with improved text, raw transcript toggle, copy, paste, and re-run improve from the menu bar.
- Settings window for OpenAI API key, transcription mode, auto-improve mode, word threshold, edit strength, output mode, microphone preference, and Parakeet runtime paths.
- Transcription modes:
  - `Local Parakeet`: local Field Theory Parakeet server mode only.
  - `Fastest`: OpenAI Realtime streaming transcription while recording, with Parakeet fallback from the saved WAV.
- Local Parakeet adapter backed by Field Theory's persistent `parakeet-transcribe.py --server` mode.
- OpenAI Realtime transcription adapter using native `URLSessionWebSocketTask`, PCM16 mono 24 kHz audio chunks, and `gpt-4o-transcribe`.
- OpenAI Responses API improve adapter using model `gpt-5.4-mini`.

## Build

Open the project:

```bash
open AutoImproveRecorder.xcodeproj
```

Or build from the command line:

```bash
xcodebuild -project AutoImproveRecorder.xcodeproj -scheme AutoImproveRecorder -configuration Debug build
```

The target is configured for macOS 13.0+ and is not sandboxed, because it needs local process execution for Parakeet and Accessibility event posting for paste.

## Runtime setup

1. Launch the app from Xcode or from the built `.app`.
2. Open Settings from the menu bar item.
3. Add an OpenAI API key. It is stored in Keychain under service `com.fieldtheory.autoimproverecorder`.
4. Choose a transcription mode:
   - `Local Parakeet` is the default and keeps audio transcription local.
   - `Fastest` streams microphone audio to OpenAI while recording, then finalizes the streaming transcript on stop. If OpenAI streaming cannot start, fails mid-recording, or no API key is saved, the app falls back to Parakeet using the temporary WAV.
5. Confirm Parakeet paths:
   - Runtime path: `~/Library/Application Support/fieldtheory-mac/build-parakeet/venv/bin/python`
   - Script path: `/Applications/Field Theory.app/Contents/Resources/scripts/parakeet-transcribe.py`
   - Cache path: `~/Library/Application Support/fieldtheory-mac/build-parakeet/cache`
6. Grant Microphone permission when prompted.
7. Grant Accessibility permission if you want the Paste button to send `Command-V`. If missing, Paste copies text and shows a single instruction.

The microphone picker is an MVP preference surface. Recording currently uses the macOS system default input through `AVAudioEngine`; wiring a specific selected input device is left as the next native-audio pass.

## Transcription behavior

`Local Parakeet` keeps transcription local. The app starts Field Theory's `parakeet-transcribe.py` in persistent server mode and sends JSON transcription commands over stdin/stdout:

```bash
"~/Library/Application Support/fieldtheory-mac/build-parakeet/venv/bin/python" \
  "/Applications/Field Theory.app/Contents/Resources/scripts/parakeet-transcribe.py" \
  --server \
  --model nemo-parakeet-tdt-0.6b-v2
```

`FIELD_THEORY_PARAKEET_CACHE_DIR` is set to the discovered cache directory so `onnx-asr` uses the installed local model cache.

`Fastest` opens `wss://api.openai.com/v1/realtime?intent=transcription` with the saved OpenAI API key, sends the current transcription-session `session.update` shape (`session.type = transcription`, `audio.input.format = audio/pcm` at 24 kHz, `audio.input.transcription.model = gpt-4o-transcribe`), converts each captured microphone buffer to 16-bit mono PCM at 24 kHz, and streams `input_audio_buffer.append` events while the WAV is still being written. On stop, the app commits/finalizes the streaming buffer, uses the ordered completed transcript events when available, and then runs the same improve/copy flow. If the realtime path returns an error or an empty transcript, Parakeet transcribes the saved WAV.

## Reliability behavior

- Raw transcript is stored separately from improved text in the current session.
- If OpenAI improve fails, the preview falls back to raw transcript and shows the error.
- If OpenAI realtime transcription fails in `Fastest` mode, transcription falls back to local Parakeet using the saved temporary WAV.
- `Escape` cancel stops recording, closes any realtime transcription session, removes the temporary WAV, and does not touch the clipboard.
- If transcription fails, the preview opens with an actionable error.
- Network improve requests use a 45 second request timeout and a 60 second resource timeout.

## Manual test checklist

See [Docs/MANUAL_TEST_CHECKLIST.md](Docs/MANUAL_TEST_CHECKLIST.md).

## Discovery notes

See [Docs/PARAKEET_DISCOVERY.md](Docs/PARAKEET_DISCOVERY.md) for exact Field Theory and Parakeet paths found on this Mac.
