# Manual Test Checklist

## First launch

- Build and run `AutoImproveRecorder` from Xcode.
- Confirm only a menu bar item appears.
- Open Settings from the menu bar item.
- Confirm Parakeet runtime, script, and cache paths are auto-filled.
- Enter an OpenAI API key and close/reopen Settings to confirm it reloads from Keychain.

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

## Transcription

- Confirm the result is copied to the clipboard after transcription/improve.
- Open Preview from the menu bar and verify the raw transcript is preserved.
- If Parakeet fails, confirm the preview shows the failure instead of silently dropping the recording.

## Improve

- Set Auto-improve to `Automatic`.
- Set threshold low, for example `1 words`.
- Record a sentence with filler or repetition.
- Confirm improved text is different from raw when appropriate.
- Disconnect network or remove API key and confirm raw transcript is still shown with an improve error.
- Click `Re-run` after changing Output or Strength in Settings.

## Copy and paste

- Click `Copy` and paste manually into TextEdit.
- Click `Paste` without Accessibility permission and confirm it copies text and shows the clear instruction.
- Grant Accessibility permission in System Settings.
- Focus TextEdit, trigger another recording, then click `Paste` and confirm `Command-V` is sent.

## Modes

- `Off`: preview should show the raw transcript.
- `Manual`: preview should show raw transcript until `Re-run` is clicked.
- `Automatic`: transcripts at or above the threshold should improve automatically.
- Output modes should bias the rewrite toward verbatim, light cleanup, prompt cleanup, or structured task.
