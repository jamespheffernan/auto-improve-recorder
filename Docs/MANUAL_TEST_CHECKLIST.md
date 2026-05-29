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

- Press `Hyper-R` (`Control-Option-Command-Shift-R`).
- Grant microphone permission if prompted.
- Confirm the floating pill appears and shows `Recording`.
- Press `Escape` while recording.
- Confirm the pill disappears, no transcription runs, and clipboard is not changed.
- Press `Hyper-R` again.
- Speak a short sentence.
- Press `Hyper-R` (`Control-Option-Command-Shift-R`) again or click the stop button.
- Confirm the pill changes to transcription/improve state.
- With a TextEdit document focused, record again and confirm the finished text is pasted automatically.

## Transcription

- In `Local Parakeet`, record a short sentence and confirm the app transcribes through the local server mode.
- In `Apple Speech` on a macOS 26+ Apple Intelligence-capable Mac, record a short sentence and confirm either a local transcript appears or the app shows a clear local-availability error.
- In `Fastest`, record a short sentence with a saved OpenAI API key and confirm the result is pasted or copied after the streaming transcript finalizes.
- In `Fastest`, remove the OpenAI API key or disconnect the network, record again, and confirm the app falls back to Parakeet using the saved WAV.
- With no text field focused and `Copy finished text to clipboard` checked, confirm the result is copied after transcription/improve.
- Open Preview from the menu bar and verify Cleaned and Raw transcript are separate views.
- Confirm `~/Library/Application Support/AutoImproveRecorder/TranscriptTruth/` contains a recording folder with `audio.wav` and `record.json`.
- Confirm `record.json` includes `rawTranscript`, `cleanedTranscript`, `finalTranscript`, transcription settings, cleanup settings, and the audio path.
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
