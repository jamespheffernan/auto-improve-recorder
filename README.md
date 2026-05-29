# Auto Improve Recorder

Native macOS menu bar app for:

`global hotkey / record -> transcription -> improve -> paste or clipboard`

## What is built

- Native Swift/SwiftUI/AppKit macOS app target in `AutoImproveRecorder.xcodeproj`.
- Native SwiftUI iOS app target, `AutoImproveRecorderiOS`, sharing the OpenAI transcription/improve engines and adding an optional Apple on-device processing path where the platform allows it.
- Menu bar status item.
- Global hotkey: `Hyper-R` (`Control-Option-Command-Shift-R`).
- Floating recorder pill during recording/transcription/improve.
- Fast path pastes the finished transcript/improved text into the focused text field when available, or copies it to the clipboard with no preview window.
- Optional preview window with explicit cleaned/raw transcript switch, copy, paste, and re-run improve from the menu bar.
- Settings window for OpenAI, Gemini, and Anthropic API keys, transcription mode, improvement provider, auto-improve mode, word threshold, cleanup level, completion clipboard behavior, microphone preference, and Parakeet runtime paths.
- Transcription modes:
  - `Local Whisper`: local Field Theory `whisper-server` with `ggml-small.en.bin` and low-latency decoding flags.
  - `Local Parakeet`: local Field Theory Parakeet server mode only.
  - `Apple Speech`: Apple on-device speech transcription where supported.
  - `OpenAI API`: OpenAI file transcription after recording.
  - `Fastest`: OpenAI Realtime streaming transcription while recording, with Parakeet fallback from the saved WAV.
- Improvement modes:
  - `OpenAI`: OpenAI Responses API cleanup using model `gpt-5-mini`.
  - `Gemini Flash`: Google Gemini cleanup using model `gemini-2.5-flash`.
  - `Claude Haiku`: Anthropic cleanup using model `claude-haiku-4-5-20251001`.
  - `Apple local`: Foundation Models cleanup using the on-device Apple Intelligence model where supported.
  - `Ollama local`: local Ollama cleanup using model `qwen3:4b-instruct`.
    `qwen3.5:0.8b-mlx` or `qwen3.5:0.8b` can be typed into the model field as
    faster experimental modes, but they are less conservative than the default.
- Local Parakeet adapter backed by Field Theory's persistent `parakeet-transcribe.py --server` mode.
- OpenAI Realtime transcription adapter using native `URLSessionWebSocketTask`, PCM16 mono 24 kHz audio chunks, and `gpt-4o-transcribe`.
- Shared Apple local adapter using `SpeechAnalyzer`/`SpeechTranscriber` for transcription and Foundation Models for cleanup.

## Build

Open the project:

```bash
open AutoImproveRecorder.xcodeproj
```

Or build from the command line:

```bash
xcodebuild -project AutoImproveRecorder.xcodeproj -scheme AutoImproveRecorder -configuration Debug build
```

The target is configured for macOS 13.0+ and is not sandboxed, because it needs local process execution for Parakeet and Accessibility event posting for paste. Apple local transcription and improvement require macOS 26+, supported speech assets, and Apple Intelligence availability on the Mac.

Build the iOS target for the simulator:

```bash
xcodebuild -project AutoImproveRecorder.xcodeproj \
  -scheme AutoImproveRecorderiOS \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The iOS target is configured for iOS 17.0+. It starts with a touch-first record/transcribe/improve workflow. The default processing mode uses OpenAI API transcription and the shared Responses API improve engine. The optional Apple local mode uses iOS 26+ `SpeechAnalyzer`/`SpeechTranscriber` for on-device transcription and Foundation Models for on-device cleanup when Apple Intelligence is available. Local Parakeet, global hotkeys, and automatic paste are macOS-only for now.

## Runtime setup

### macOS

1. Launch the app from Xcode or from the built `.app`.
2. Open Settings from the menu bar item.
3. Add an OpenAI API key. It is stored in Keychain under service `com.fieldtheory.autoimproverecorder`.
4. Choose a transcription mode:
   - `Local Whisper` is the default and keeps audio transcription local.
   - `Local Parakeet` keeps audio transcription local through the Field Theory Parakeet runtime.
   - `Apple Speech` keeps audio transcription local through Apple's Speech framework when supported on this Mac.
   - `OpenAI API` sends the saved recording to OpenAI after recording.
   - `Fastest` streams microphone audio to OpenAI while recording, then finalizes the streaming transcript on stop. If OpenAI streaming cannot start, fails mid-recording, or no API key is saved, the app falls back to Parakeet using the temporary WAV.
5. Choose an improvement mode:
   - `OpenAI` uses the OpenAI API key for cleanup.
   - `Gemini Flash` uses the Gemini API key for cleanup.
   - `Claude Haiku` uses the Anthropic API key for cleanup.
   - `Apple local` uses the on-device Foundation Models framework. Paired with `Apple Speech` or `Local Parakeet`, this keeps the whole flow on the Mac.
   - `Ollama local` sends transcript text to a local Ollama server. Paired with `Local Whisper` or `Local Parakeet`, this keeps the whole flow on the Mac.
6. Confirm Parakeet paths if using `Local Parakeet`:
   - Runtime path: `~/Library/Application Support/fieldtheory-mac/build-parakeet/venv/bin/python`
   - Script path: `/Applications/Field Theory.app/Contents/Resources/scripts/parakeet-transcribe.py`
   - Cache path: `~/Library/Application Support/fieldtheory-mac/build-parakeet/cache`
7. For Ollama local cleanup, start Ollama and run `ollama pull qwen3:4b-instruct`. The default local endpoint is `http://127.0.0.1:11434`. For the experimental speed mode, also run `ollama pull qwen3.5:0.8b-mlx` or `ollama pull qwen3.5:0.8b` and set the model field to that tag.
8. Grant Microphone permission when prompted.
9. Grant Speech Recognition permission if prompted by Apple Speech.
10. Grant Accessibility permission if you want automatic paste into focused text fields or the Paste button to send `Command-V`. If missing, the app falls back to the clipboard when clipboard copying is enabled.

The microphone picker is an MVP preference surface. Recording currently uses the macOS system default input through `AVAudioEngine`; wiring a specific selected input device is left as the next native-audio pass.

### iOS

1. Select the `AutoImproveRecorderiOS` scheme in Xcode.
2. Launch on an iPhone simulator or device.
3. Open Settings and choose a Processing mode:
   - `OpenAI`: OpenAI transcription and OpenAI improve.
   - `Apple local`: Apple on-device transcription and Apple Foundation Models cleanup. Requires iOS 26+, compatible on-device speech assets, and Apple Intelligence availability.
   - `Local transcription + cloud improve`: Apple on-device transcription, then the selected cleanup provider.
4. Add the relevant API key if using a mode that calls a cloud provider.
5. Tap Record, grant microphone permission, then tap Stop.
6. The app transcribes, optionally improves the transcript, and copies the finished text when that setting is enabled.

## Transcription behavior

`Local Parakeet` keeps transcription local. The app starts Field Theory's `parakeet-transcribe.py` in persistent server mode and sends JSON transcription commands over stdin/stdout:

```bash
"~/Library/Application Support/fieldtheory-mac/build-parakeet/venv/bin/python" \
  "/Applications/Field Theory.app/Contents/Resources/scripts/parakeet-transcribe.py" \
  --server \
  --model nemo-parakeet-tdt-0.6b-v2
```

`FIELD_THEORY_PARAKEET_CACHE_DIR` is set to the discovered cache directory so `onnx-asr` uses the installed local model cache.

`Apple Speech` uses Apple's on-device speech APIs when available on the current OS, hardware, locale, and installed speech assets. If it is unavailable, the app shows a local-availability error rather than sending audio elsewhere.

`Fastest` opens `wss://api.openai.com/v1/realtime?intent=transcription` with the saved OpenAI API key, sends the current transcription-session `session.update` shape (`session.type = transcription`, `audio.input.format = audio/pcm` at 24 kHz, `audio.input.transcription.model = gpt-4o-transcribe`), converts each captured microphone buffer to 16-bit mono PCM at 24 kHz, and streams `input_audio_buffer.append` events while the WAV is still being written. On stop, the app commits/finalizes the streaming buffer, uses the ordered completed transcript events when available, and then runs the same improve/copy flow. If the realtime path returns an error or an empty transcript, Parakeet transcribes the saved WAV.

## Reliability behavior

- Raw transcript is stored separately from cleaned text in the current session; the preview can show the unedited transcript even when cleanup is unavailable or fails.
- Each completed macOS recording is archived under `~/Library/Application Support/AutoImproveRecorder/TranscriptTruth/` with `audio.wav` plus `record.json` containing the raw transcript, cleaned transcript, final visible transcript, provider/settings metadata, and any failure message.
- If OpenAI improve fails, the preview falls back to raw transcript and shows the error.
- If OpenAI realtime transcription fails in `Fastest` mode, transcription falls back to local Parakeet using the saved temporary WAV.
- `Escape` cancel stops recording, closes any realtime transcription session, removes the temporary WAV, and does not touch the clipboard.
- If transcription fails, the preview opens with an actionable error.
- Network improve requests use a 45 second request timeout and a 60 second resource timeout.

## Manual test checklist

See [Docs/MANUAL_TEST_CHECKLIST.md](Docs/MANUAL_TEST_CHECKLIST.md).

## Discovery notes

See [Docs/PARAKEET_DISCOVERY.md](Docs/PARAKEET_DISCOVERY.md) for exact Field Theory and Parakeet paths found on this Mac.
