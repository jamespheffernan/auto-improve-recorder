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
  - `Phonon-2 (Default)`: resident English transcription on this Mac, shared by ASR and AIR.
  - `Local Whisper`: legacy local `whisper-server` with `ggml-small.en.bin` and low-latency decoding flags.
  - `Local Parakeet`: legacy local Python Parakeet server mode only (AIR compatibility).
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
- Local live transcription contract with the measured parakeet.cpp C-API and Nemotron model as the current provider.
- OpenAI Realtime transcription adapter using native `URLSessionWebSocketTask`, PCM16 mono 24 kHz audio chunks, and `gpt-4o-transcribe`.
- Shared Apple local adapter using `SpeechAnalyzer`/`SpeechTranscriber` for transcription and Foundation Models for cleanup.

## Auto Send Recorder

The `AutoSendRecorder` target builds the separate **Auto Send Recorder** menu bar app with identity `com.turfterrace.autosendrecorder`. See [runtime wiring](Docs/PARAKEET_DISCOVERY.md) and [current verification status](Docs/AUTO_SEND_RECORDER_INSTALLED_VERIFICATION.md). The new identity starts a new preferences domain; existing settings and privacy grants do not migrate automatically. On first launch, its three-step setup guide:

1. checks the selected local transcription runtime;
2. explains and requests Microphone and Accessibility access; and
3. provides a local practice field for the first dictation.

The guide is skippable and can be reopened from **Setup Guide…** in the menu bar. Bluetooth stays off until the user enables **Wireless recorder** in the guide or Settings.

Open **Settings…** to change the global **Record and send** and **Cancel** shortcuts. Both require Control, Option, or Command, cannot be identical, and persist across launches. Existing installs keep `Hyper-R` and `Hyper-Escape` until changed.

ASR Settings now offers **Phonon-2 (Default)** and **Parakeet**. A recording keeps the model selected when it starts. Phonon-2 transcribes the saved recording after stop; Parakeet retains its existing live and wireless paths.

The 1.1 website release includes the universal Parakeet speech engine. Its **Install speech models** action downloads and SHA-256 verifies three models (1.75 GB). Setup needs 4 GB of free space. That installer does not install Phonon-2. Its runtime lives at `~/Library/Application Support/AutoSendRecorder/Runtime/20260918`; the shared AIR Parakeet runtime remains a fallback. Source builds need the `SpeechRuntime` resource supplied by `Tools/AutoSendRelease/build-runtime.sh` and `package-archive.sh` to offer Parakeet installation.

### Phonon-2 runtime

On Apple silicon, install the pinned runtime once for both apps. Run this from the repository with `uv` and Python 3.12 available:

```bash
python3 Tools/PhononRuntime/install.py "/Volumes/4TB Private/Offloaded/Agent Work/Phonon2-0.2.3"
```

The installer keeps dependencies, caches, and models on the external volume. It verifies the upstream model archive and every extracted file, runs a load/decode check, and links the completed runtime at `~/Library/Application Support/AutoImproveRecorder/Phonon2`. Keep that volume mounted while using this model. The app does not download models during recording.

Each app starts a private worker, warms the model, and reuses it between recordings. Requests pass over pipes; no network server runs. Cancellation, an incomplete transcript, or an engine failure keeps the recording and prevents delivery. Existing AIR model preferences remain saved; new preferences default to Phonon-2. Select Phonon-2 in AIR Settings to change an existing installation.

[Phonon-2](https://huggingface.co/FermionResearch/Phonon-2) is English-only. The weights use CC-BY-4.0 and derive from NVIDIA Parakeet TDT 0.6B v3. See [third-party notices](Tools/PhononRuntime/THIRD-PARTY-NOTICES.txt).

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
3. Add an OpenAI API key. AIR stores it in its existing Keychain service, defined in `AutoImproveRecorder/Support/KeychainStore.swift`. ASR does not use this credential store.
4. Choose a transcription mode:
   - New installs select `Phonon-2 (Default)`. Install its runtime as described above. Existing explicit model choices remain saved.
   - `Local Whisper` is an explicit compatibility mode and keeps audio transcription local.
   - `Parakeet.cpp Fast` keeps audio transcription local through AIR's 110M Parakeet.cpp runtime.
   - `Parakeet Live` keeps Nemotron 0.6B resident and transcribes during recording when the runtime, fallback, and memory gates pass.
   - `Parakeet.cpp Recommended` remains the explicit one-shot local mode and the saved-WAV fallback for live failures.
   - `Apple Speech` keeps audio transcription local through Apple's Speech framework when supported on this Mac.
   - `OpenAI API` sends the saved recording to OpenAI after recording.
   - `Fastest` streams microphone audio to OpenAI while recording, then finalizes the streaming transcript on stop. If OpenAI streaming cannot start, fails mid-recording, or no API key is saved, the app falls back to Parakeet.cpp Recommended using the temporary WAV.
5. Choose an improvement mode:
   - `OpenAI` uses the OpenAI API key for cleanup.
   - `Gemini Flash` uses the Gemini API key for cleanup.
   - `Claude Haiku` uses the Anthropic API key for cleanup.
   - `Apple local` uses the on-device Foundation Models framework. Paired with `Apple Speech` or Parakeet.cpp, this keeps the whole flow on the Mac.
   - `Ollama local` sends transcript text to a local Ollama server. Paired with `Local Whisper` or Parakeet.cpp, this keeps the whole flow on the Mac.
6. Confirm AIR's Parakeet.cpp runtime exists under `~/Library/Application Support/AutoImproveRecorder/ParakeetCpp` if using a Parakeet.cpp mode:
   - CLI: `bin/parakeet-cli`
   - Fast model: `models/tdt_ctc-110m-q4_k.gguf`
   - Recommended model: `models/tdt-0.6b-v2-q4_k.gguf`
7. For Ollama local cleanup, start Ollama and run `ollama pull qwen3:4b-instruct`. The default local endpoint is `http://127.0.0.1:11434`. For the experimental speed mode, also run `ollama pull qwen3.5:0.8b-mlx` or `ollama pull qwen3.5:0.8b` and set the model field to that tag.
8. Choose a microphone:
   - `System default` follows the current macOS default input at recording start.
   - A named input, such as `BOYA mini 2`, is resolved through CoreAudio and passed into `AVAudioEngine` before AIR reads the input format or installs the tap.
   - If the preferred input is missing, disconnected, busy at start, or exact-silent during startup, AIR quarantines it briefly and records from the best available fallback input.
9. Grant Microphone permission when prompted.
10. Grant Speech Recognition permission if prompted by Apple Speech.
11. Grant Accessibility permission if you want automatic paste into focused text fields or the Paste button to send `Command-V`. If missing, the app falls back to the clipboard when clipboard copying is enabled.

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

`Parakeet Live`, `Parakeet.cpp Fast`, and `Parakeet.cpp Recommended` keep transcription local. Live mode uses the resident C API and Nemotron streaming model. The one-shot modes run AIR's installed `parakeet-cli` against model files under `~/Library/Application Support/AutoImproveRecorder/ParakeetCpp`:

```bash
"~/Library/Application Support/AutoImproveRecorder/ParakeetCpp/bin/parakeet-cli" \
  transcribe \
  --model "~/Library/Application Support/AutoImproveRecorder/ParakeetCpp/models/tdt-0.6b-v2-q4_k.gguf" \
  --input recording.wav \
  --json
```

`Apple Speech` uses Apple's on-device speech APIs when available on the current OS, hardware, locale, and installed speech assets. If it is unavailable, the app shows a local-availability error rather than sending audio elsewhere.

`Fastest` opens `wss://api.openai.com/v1/realtime?intent=transcription` with the saved OpenAI API key, sends the current transcription-session `session.update` shape (`session.type = transcription`, `audio.input.format = audio/pcm` at 24 kHz, `audio.input.transcription.model = gpt-4o-transcribe`), converts each captured microphone buffer to 16-bit mono PCM at 24 kHz, and streams `input_audio_buffer.append` events while the WAV is still being written. On stop, the app commits/finalizes the streaming buffer, uses the ordered completed transcript events when available, and then runs the same improve/copy flow. If the realtime path returns an error or an empty transcript, Parakeet.cpp Recommended transcribes the saved WAV.

## Reliability behavior

- Raw transcript is stored separately from cleaned text in the current session; the preview can show the unedited transcript even when cleanup is unavailable or fails.
- Each completed macOS recording is archived under `~/Library/Application Support/AutoImproveRecorder/TranscriptTruth/` with `audio.wav` plus `record.json` containing the raw transcript, cleaned transcript, final visible transcript, provider/settings metadata, microphone preference/resolution metadata, and any failure message.
- The microphone inventory is observed with CoreAudio property listeners. AIR refreshes the picker when devices/default input change, but it does not hold the microphone open while idle.
- If OpenAI improve fails, the preview falls back to raw transcript and shows the error.
- If OpenAI realtime transcription fails in `Fastest` mode, transcription falls back to local Parakeet using the saved temporary WAV.
- `Escape` cancel stops recording, closes any realtime transcription session, removes the temporary WAV, and does not touch the clipboard.
- If transcription fails, the preview opens with an actionable error.
- Network improve requests use a 45 second request timeout and a 60 second resource timeout.

## Manual test checklist

See [Docs/MANUAL_TEST_CHECKLIST.md](Docs/MANUAL_TEST_CHECKLIST.md).

## Discovery notes

See [Docs/PARAKEET_DISCOVERY.md](Docs/PARAKEET_DISCOVERY.md) for current ASR runtime wiring and a separate link to historical discovery evidence. AIR/iOS sections above describe those targets, not ASR requirements.
