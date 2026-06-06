# Manual Test Checklist

## First launch

- Build and run `AutoImproveRecorder` from Xcode.
- Confirm only a menu bar item appears.
- Open Settings from the menu bar item.
- Confirm Parakeet runtime, script, and cache paths are auto-filled.
- Enter an OpenAI API key and close/reopen Settings to confirm it reloads from Keychain.
- Confirm Transcription defaults to `Local Parakeet`.
- Confirm Improvement defaults to `OpenAI`.
- Switch Transcription to `Fastest`, close/reopen Settings, and confirm the choice persists.
- Switch Improvement to `Apple local`, close/reopen Settings, and confirm the choice persists.
- Switch Improvement to `Ollama local`, close/reopen Settings, and confirm the choice persists.
- Confirm the Ollama Base URL defaults to `http://127.0.0.1:11434` and Model defaults to `qwen3:4b-instruct`.

## Recording

- Set Recording Trigger to `Hold to talk`.
- Press and hold `Hyper-R` (`Control-Option-Command-Shift-R`).
- Grant microphone permission if prompted.
- Confirm the floating pill appears and shows `Recording`.
- Speak a short sentence, release the hotkey, and confirm the pill changes to transcription/improve state.
- Quick-tap `Hyper-R` without speaking and confirm the recording is discarded: no paste, no clipboard change, and no transcription runs.
- Press `Hyper-R`, release quickly, then press `Hyper-R` again within the latch window. Confirm recording stays active after release and the HUD says the recording is locked.
- Press `Hyper-R` again while latched and confirm the recording sends.
- Press `Escape` while recording.
- Confirm the pill disappears, no transcription runs, and clipboard is not changed.
- Press `Escape` while the mic is still opening and confirm AIR does not leave the microphone open.
- Switch Recording Trigger to `Toggle`.
- Press `Hyper-R`, release it, and confirm recording continues.
- Press `Hyper-R` again and confirm the recording sends.
- While AIR is transcribing, improving, or delivering, press `Hyper-R` and confirm no second recording starts.
- With a TextEdit document focused, record again and confirm the finished text is pasted automatically.

## Microphone selection

- Open Settings and confirm the Microphone picker lists `System default` plus the current CoreAudio input devices.
- Select `System default`, set the macOS input device to the built-in microphone, record a short sentence, and confirm `record.json` includes `microphonePreferenceID: ""`, `microphoneResolvedName`, and `microphoneUsedFallback: false`.
- Set the macOS default input to the built-in microphone, select `BOYA mini 2` or another external microphone in AIR, record while speaking only into the selected external mic, and confirm the recording/transcript comes from that mic rather than the system default.
- Unplug or disable the selected preferred mic, reopen Settings, and confirm AIR shows an unavailable preferred mic plus a fallback summary.
- With the preferred mic unavailable, record and confirm AIR falls back to another input, shows a fallback status, and archives `microphoneUsedFallback: true` with a `microphoneFallbackReason`.
- With `BOYA mini 2` selected but its transmitter/lav inactive, start recording and confirm AIR recovers from exact digital silence by briefly quarantining BOYA and using the fallback mic.
- Switch macOS default input while Settings is open and confirm the picker/summary refresh without AIR showing microphone use while idle.
- In `Fastest`, select the external mic, record a short sentence, and confirm OpenAI realtime still receives audio buffers and completes or falls back to Parakeet from the saved WAV.

## Transcription

- In `Local Parakeet`, record a short sentence and confirm the app transcribes through the local server mode.
- In `Apple Speech` on a macOS 26+ Apple Intelligence-capable Mac, record a short sentence and confirm either a local transcript appears or the app shows a clear local-availability error.
- In `Fastest`, record a short sentence with a saved OpenAI API key and confirm the result is pasted or copied after the streaming transcript finalizes.
- In `Fastest`, remove the OpenAI API key or disconnect the network, record again, and confirm the app falls back to Parakeet using the saved WAV.
- With no text field focused and `Copy finished text to clipboard` checked, confirm the result is copied after transcription/improve.
- Open Preview from the menu bar and verify Cleaned and Raw transcript are separate views.
- Confirm `~/Library/Application Support/AutoImproveRecorder/TranscriptTruth/` contains a recording folder with `audio.wav` and `record.json`.
- Confirm `record.json` includes `rawTranscript`, `cleanedTranscript`, `finalTranscript`, transcription settings, cleanup settings, microphone metadata, and the audio path.
- If Parakeet fails, confirm the preview shows the failure instead of silently dropping the recording.

## Improve

- Set Auto-improve to `Automatic`.
- Set threshold low, for example `1 words`.
- Record a sentence with filler or repetition.
- Confirm improved text is different from raw when appropriate.
- Disconnect network or remove API key and confirm raw transcript is still shown with an improve error.
- Set Improvement to `Apple local` on a macOS 26+ Apple Intelligence-capable Mac, record a sentence above the threshold, and confirm either improved text appears or the app shows a clear local-availability error.
- Set Improvement to `Ollama local` with Ollama stopped, record a sentence above the threshold, and confirm raw transcript is shown with a clear message to start Ollama.
- Start Ollama without `qwen3:4b-instruct` available, record again, and confirm the improve error includes `ollama pull qwen3:4b-instruct`.
- Run `ollama pull qwen3:4b-instruct`, keep Ollama running, record filler-heavy dictation above the threshold, and confirm improved text is returned while the raw transcript remains available.
- Pair Transcription `Local Parakeet` with Improvement `Ollama local` and confirm the app does not require cloud API keys for the full transcription/improve flow.
- Click `Re-run` after changing Cleanup in Settings.

## Copy and paste

- Open Settings and confirm `Copy finished text to clipboard` is checked by default.
- Uncheck `Copy finished text to clipboard`, focus TextEdit, record, and confirm the finished text is pasted without replacing the previous clipboard contents.
- Click `Copy` and paste manually into TextEdit.
- Click `Paste` without Accessibility permission and confirm it copies text and shows the clear instruction.
- Grant Accessibility permission in System Settings.
- Focus TextEdit, trigger another recording, then click `Paste` and confirm `Command-V` is sent.

## Modes

- `Off`: preview should show the raw transcript.
- `Manual`: preview should show raw transcript until `Re-run` is clicked.
- `Automatic`: transcripts at or above the threshold should improve automatically.
- Cleanup modes should bias the rewrite toward near-verbatim, clean, prompt, or task without hiding the raw transcript.

## iOS

- Build the `AutoImproveRecorderiOS` scheme for an iPhone simulator.
- Launch the app and confirm the main recorder screen renders with Record, Settings, Copy, and Re-run controls.
- Open Settings and confirm the processing mode, OpenAI API key, auto-improve mode, cleanup mode, threshold, and clipboard setting are available.
- With an OpenAI API key saved, record a short phrase, stop, and confirm the transcript appears.
- Record a transcript above the threshold and confirm automatic improve updates the improved text.
- Toggle Raw/Cleaned and confirm the raw transcript is preserved.
- Confirm Copy writes the visible text to the iOS pasteboard.
- Switch Processing to `Apple local` on an iOS 26+ Apple Intelligence-capable device, record, and confirm either a local transcript appears or the app shows a clear local-availability error.
- Switch Processing to `Local transcription + OpenAI improve`, record with an OpenAI API key saved, and confirm transcription stays local while improve still runs through OpenAI.
