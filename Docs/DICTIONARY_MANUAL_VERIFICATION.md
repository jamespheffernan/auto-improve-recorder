# Dictionary Manual Verification

1. Build and install `/Applications/AutoImproveRecorder.app`.
2. Relaunch the installed app and open Settings.
3. Add a dictionary term, then confirm it appears at the top of the Dictionary list.
4. Select text in another app and run Services > Add to Auto Improve Recorder Dictionary, then confirm the term appears in Settings.
5. Add a replacement rule such as `air app -> AIR app`.
6. Record a short dictation containing the custom term.
7. Confirm the final pasted or copied output preserves the dictionary term.
8. Confirm the replacement rule applies before paste.
9. Open the latest archive record under `~/Library/Application Support/AutoImproveRecorder/TranscriptTruth/` and confirm `dictionarySnapshot` contains the active terms.
10. Run Superwhisper import from Settings with no source present and confirm the app shows a clear non-fatal status message.

## Non-Hardware Fallback

If the selected microphone/output devices are in use and cannot be taken over, do not fake the live recording step. Use a file-based audio check only as supporting evidence:

1. Generate a local audio file with `say -o /tmp/air-dictionary.aiff "Monologue dictionary verification."`.
2. Convert it to WAV with `ffmpeg -y -i /tmp/air-dictionary.aiff -ar 16000 -ac 1 /tmp/air-dictionary.wav`.
3. Run the installed Parakeet runtime against the WAV and confirm the custom term is transcribed.
4. Treat this as verification of transcription/runtime behavior, not as a replacement for the live installed-app recording check.
