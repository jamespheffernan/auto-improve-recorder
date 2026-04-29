# Auto Improve Recorder

Native macOS menu bar app skeleton for:

`global hotkey / record -> local NVIDIA Parakeet transcription -> OpenAI gpt-5.4-mini improve -> preview/copy/paste`

## What is built

- Native Swift/SwiftUI/AppKit macOS app target in `AutoImproveRecorder.xcodeproj`.
- Menu bar status item.
- Global hotkey: `Hyper-R` (`Control-Option-Command-Shift-R`).
- Floating recorder pill during recording/transcription/improve.
- Fast path copies the finished transcript/improved text directly to clipboard with no preview window.
- Optional preview window with improved text, raw transcript toggle, copy, paste, and re-run improve from the menu bar.
- Settings window for OpenAI API key, auto-improve mode, word threshold, edit strength, output mode, microphone preference, and Parakeet runtime paths.
- Local Parakeet adapter that invokes Field Theory's installed Parakeet runtime instead of OpenAI transcription.
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
4. Confirm Parakeet paths:
   - Runtime path: `~/Library/Application Support/fieldtheory-mac/build-parakeet/venv/bin/python`
   - Script path: `/Applications/Field Theory.app/Contents/Resources/scripts/parakeet-transcribe.py`
   - Cache path: `~/Library/Application Support/fieldtheory-mac/build-parakeet/cache`
5. Grant Microphone permission when prompted.
6. Grant Accessibility permission if you want the Paste button to send `Command-V`. If missing, Paste copies text and shows a single instruction.

The microphone picker is an MVP preference surface. Recording currently uses the macOS system default input through `AVAudioEngine`; wiring a specific selected input device is left as the next native-audio pass.

## Parakeet integration

The current adapter runs Field Theory's `parakeet-transcribe.py` directly for each recording:

```bash
"~/Library/Application Support/fieldtheory-mac/build-parakeet/venv/bin/python" \
  "/Applications/Field Theory.app/Contents/Resources/scripts/parakeet-transcribe.py" \
  --audio /path/to/recording.wav \
  --model nemo-parakeet-tdt-0.6b-v2
```

`FIELD_THEORY_PARAKEET_CACHE_DIR` is set to the discovered cache directory so `onnx-asr` uses the installed local model cache.

Field Theory's script also supports `--server`. The next speed pass should keep that process warm and send JSON transcription commands over stdin/stdout instead of loading the model per recording.

## Reliability behavior

- Raw transcript is stored separately from improved text in the current session.
- If OpenAI improve fails, the preview falls back to raw transcript and shows the error.
- If transcription fails, the preview opens with an actionable error.
- Network improve requests use a 45 second request timeout and a 60 second resource timeout.

## Manual test checklist

See [Docs/MANUAL_TEST_CHECKLIST.md](Docs/MANUAL_TEST_CHECKLIST.md).

## Discovery notes

See [Docs/PARAKEET_DISCOVERY.md](Docs/PARAKEET_DISCOVERY.md) for exact Field Theory and Parakeet paths found on this Mac.
