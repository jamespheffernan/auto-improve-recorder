# Auto Send Recorder installed-app verification

Date: 12 August 2026 (Europe/London)

Status: Completed with permission limits. The fixed Release app is installed and its settings window and bounded permission recovery pass. Microphone and Accessibility permission are not available, so record-stop, paste, and send behavior were not run.

## Scope and safety limits

- Source app: `/Users/jamesheffernan/Library/Developer/Xcode/DerivedData/AutoImproveRecorder-crdesahfmrowqickgikxkwiwwubv/Build/Products/Release/Auto Send Recorder.app`
- Installed app: `/Applications/Auto Send Recorder.app`
- Expected bundle ID: `com.fieldtheory.autosendrecorder`
- No Auto Send Recorder app was present before the first install.
- AutoImproveRecorder was running from `/Applications/AutoImproveRecorder.app` before this check. It was stopped to prevent a hotkey conflict.
- No text was pasted or sent. No real message, email, or form was used.
- No privacy setting or TCC database was changed.

## Release bundle and install

The source Release bundle passed strict signature verification before installation:

```text
valid on disk
satisfies its Designated Requirement
Identifier=com.fieldtheory.autosendrecorder
Signature=adhoc
Code type=ARM64
```

The Info.plist values were correct:

```text
CFBundleDisplayName=Auto Send Recorder
CFBundleIdentifier=com.fieldtheory.autosendrecorder
CFBundleShortVersionString=1.0
LSMinimumSystemVersion=13.0
LSUIElement=true
```

The source and first installed products were byte-identical:

```text
Executable SHA-256: 048a9e4a02915f2bda570b9ee8954028b8cbc2bfdd3fd04a9528fc93082da76c
Info.plist SHA-256: 8a14224147376c321d68b675b7eef044d223d04912565b15d9085f525c99605d
```

`lsappinfo` confirmed that the running process used this path and identity:

```text
bundle ID: com.fieldtheory.autosendrecorder
bundle path: /Applications/Auto Send Recorder.app
executable path: /Applications/Auto Send Recorder.app/Contents/MacOS/Auto Send Recorder
```

The app behaved as an accessory app. It was not frontmost, it was not visible as a normal app, it had no normal window, and it had a menu-bar status item.

## Fixed Release install

The first installed build was preserved before replacement. The temporary backup directory is:

```text
/tmp/auto-send-installed-backup.PLQt69
```

It contains `Auto Send Recorder-first-installed.app` and a second verified copy named `Auto Send Recorder-pre-fix.app`. Both use the first executable hash `048a9e4a...`. This backup is in temporary storage and can be removed after the final result is accepted.

The fixed Release executable was built at `2026-08-12T00:15:52+0100`. It passed strict signature verification. The Release source product and installed product are byte-identical:

```text
Executable SHA-256: 4390cc0f3651d806d8335cfae9f7edc13e3f0d49ef34ddf08ae29e547c8b6fea
Info.plist SHA-256: 8a14224147376c321d68b675b7eef044d223d04912565b15d9085f525c99605d
```

The relevant source hashes at the end of this run were:

```text
AutoSendRecorder Swift and plist manifest: cac1c2beb6b07c898e2621b8855de5e9cb48929d390abc12320c8b1ac8090df8
Xcode project: f82182948ea8ced1b8dd0ed6a2a240f59eacd87d80326372f77a648063f5fe1d
```

## Menu and state checks

The installed menu opened and showed these items:

```text
Start Recording
Ready. Press Control-Option-Shift-Command-R to record.
Send Settings...
Quit Auto Send Recorder
```

After one quit and reopen, the process again used the installed path. The menu returned to the same Ready state. This confirms basic process, status-item, and reopen behavior.

### Finding 1 before the fix: settings did not open

`Send Settings...` did not open a window. The same result occurred with Command-comma. System Events reported `windows=0` after both actions.

The first checked build called `showSettingsWindow:`. It was replaced with an explicit, retained AppKit window controller.

### Fixed result: settings opens

The fixed installed Release app opened an on-screen layer-zero window. `CGWindowList` independently reported:

```text
window number: 81895
title: Auto Send Recorder Settings
on screen: true
size: 520 x 442
position: 700, 186
```

AppKit logs also recorded the `showSettings` menu action and the new window order. System Events still returned zero windows, and the captured screen stayed black because this automation session cannot capture the visible desktop. The Core Graphics window result proves that the installed process created and showed the settings window. It does not provide a visual content check.

Evidence:

- `.autoresearch/auto-send-installed-verification/post-fix-settings-window.png`
- `.autoresearch/auto-send-installed-verification/post-fix-settings-window-visible.png`

### Finding 2 before the fix: first microphone request remained pending

The Start Recording menu action changed the menu to:

```text
Starting Recording
Listening...
```

It did not reach the Recording state because macOS started a first-use microphone permission request. Unified logs show:

```text
2026-08-12 00:08:39.951 +0100
service=kTCCServiceMicrophone
msgID=675.7

2026-08-12 00:08:39.954 +0100
AUTHREQ_PROMPTING
subject=com.fieldtheory.autosendrecorder
binary_path=/Applications/Auto Send Recorder.app/Contents/MacOS/Auto Send Recorder
```

No permission result followed. The screen image showed a black desktop and the orange microphone privacy dot, but no visible permission window. System Events also found no window in Auto Send Recorder, UserNotificationCenter, or NotificationCenter. The prompt was not accepted or denied.

Evidence:

- `.autoresearch/auto-send-installed-verification/pre-fix-microphone-prompt.png`
- `.autoresearch/auto-send-installed-verification/pre-fix-process.sample.txt`

Because permission remained pending, this run did not test record-stop, transcription, paste, or per-app send behavior. The app was terminated by its exact PID after its normal AppleEvent quit waited behind the pending system request.

Synthetic Hyper-R and Hyper-Escape events did not activate the registered Carbon hotkeys in this automation session. This is an automation limit, not proof of a product hotkey fault. A physical-key check is still required.

### Fixed result: permission wait is bounded

The fixed installed app issued one microphone request. At one second, the menu showed `Starting Recording` and `Listening...`. Unified logs showed `AUTHREQ_PROMPTING` for request `9508.7`. No permission choice was selected.

At 13 seconds, the menu had returned to `Start Recording` and showed this typed recovery message:

```text
The microphone permission request did not finish. Quit and reopen Auto Send Recorder, then try again.
```

The 12-second timeout therefore works in the installed Release app. The captured screen remained black and did not show a system prompt. The TCC log is the authoritative prompt record for this run.

Evidence:

- `.autoresearch/auto-send-installed-verification/post-fix-microphone-prompt.png`
- `.autoresearch/auto-send-installed-verification/post-fix-microphone-timeout.png`

TCC also reported `authValue=0` for the app's Accessibility preflight. Thus, the app could not safely paste into TextEdit or the local fixture. No paste or send test was attempted.

## Energy sanity check

These values are not latency results.

The pending-permission state had 15 one-second samples at `0.0%` CPU and approximately `1,985 MB` resident memory. A three-second process sample showed six sleeping threads and no audio-engine or archive thread. The model warm-up had already loaded the Parakeet and GGML libraries.

After quit and reopen, the Ready state had 15 one-second samples at `0.0%` CPU and approximately `1,969 MB` resident memory. The process had six sleeping threads.

After the fixed build recovered from the microphone timeout, 15 one-second samples were `0.0%` CPU and approximately `1,980 MB` resident memory. The process had nine sleeping threads. This memory includes the warmed Parakeet and GGML runtime.

No capture-buffer, backlog, dropped-buffer, capture-failure, or archive-failure event was found. Audio capture did not start because microphone permission was pending.

## Data separation and integrity

Before the first recording action, the Auto Send support directory did not exist. It still did not exist after the pending permission request, so no recording file was created. The Auto Send preferences domain was initially absent.

AutoImproveRecorder dictionary files remained byte-identical:

```text
Dictionary/dictionary.json
6543464bc3a9c9b9da6f3256b0b1c9961638c34e3c4ad3b34d31516c83109d5e

Dictionary/replacement-rules.json
afeb9c112183191d75aeb6cac485ec64e2c6546b455698ff35884d33f7497b25
```

The AutoImproveRecorder preferences file was rewritten when AutoImproveRecorder quit. Its size stayed at 12,029 bytes, but the strict hash changed:

```text
Before: e64a18daa4db62716e083590b9a72fab4088582bef1c8d9ce171ac19a48762cb
After:  c590e715d1b49259822efe0a519649dc15e1b47a4ef5fc3909fdcff61f3491de
```

The exported preferences hash also changed. This can be a quit-time serialization or flush change, but the available evidence cannot prove that all logical values stayed identical because no canonical before-value export was retained. The strict unchanged-preferences gate therefore fails for this run. No attempt was made to restore the file.

After AutoImproveRecorder was restored to its original running state, its final preferences hashes were:

```text
Binary plist: b304fa6b6cf770bf54271be396079bd2675475fa8ce8486c1f35cd7d7c584ad1
Exported plist: 3fa42a83311a719b11e06d4e2785e31c940f3d00ecfaf9d0f17d03a6df50d5f6
```

The second change occurred at relaunch. It confirms that strict preference-byte preservation did not pass. The dictionary content hashes remained unchanged throughout.

During the concurrent settings-window fix, a Debug app with the same Auto Send bundle ID wrote one Auto Send preference:

```text
NSWindow Frame AutoSendRecorderSettingsWindow
```

Unified logs identify the writer path as `/private/tmp/asr-settings-window-debug/.../Auto Send Recorder.app`. The same value remained after fixed Release verification. Its preference file hash was `a833883984645dad355edebc5d7bbf31cc9336b1a7ef9d6f1dba91136d869aa5`.

The `~/Library/Application Support/Auto Send Recorder` directory was still absent at the end of the run. This is correct for this permission-gated check: recording never started and no WAV file was created. The recording-path gate remains untested.

## Commands used

The main read-only checks used `codesign --verify --deep --strict`, `codesign -dv`, `plutil -p`, `shasum -a 256`, `lsappinfo`, `mdls`, `ps`, `top`, `sample`, `/usr/bin/log show`, `defaults read`, and System Events accessibility queries.

The only app-state changes were:

- graceful stop of the running AutoImproveRecorder app;
- first install of the new, separate Auto Send Recorder app in `/Applications`;
- preservation and replacement of the first Auto Send build with the fixed Release build;
- launch, one reopen, one exact-PID termination after the first TCC wait, and final status-menu quit of Auto Send Recorder;
- relaunch of the same installed AutoImproveRecorder bundle to restore its original running state.

Final process state:

```text
AutoImproveRecorder: running from /Applications/AutoImproveRecorder.app
Auto Send Recorder: installed, not running
```

## Required follow-up

- [x] Install the fixed Release product and confirm that Send Settings opens an on-screen settings window.
- [x] Confirm that the fixed installed product hash matches its Release source product.
- [x] Capture the first microphone request without accepting or denying it; the screen remained black, but TCC logged `AUTHREQ_PROMPTING`.
- [x] Confirm that a pending microphone request returns from Starting with a typed recovery after 12 seconds.
- [ ] If permission is already available later, use only TextEdit or the disposable fixture, with sending disabled, for one short record-stop-paste check.
- [ ] Test the physical recording and cancel hotkeys.
- [ ] Confirm the `Auto Send Recorder/Recordings` support path after an authorized recording.
- [x] Restore AutoImproveRecorder to its original running state.
