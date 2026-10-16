# Auto Send Recorder verification status

The current source identity is `com.turfterrace.autosendrecorder` for Debug and Release. The preferences initializer and self-app comparisons use the same identity.

The installed app has not been replaced or reverified for this identity. Earlier permissions, signing output and UI checks do not prove that the new identity works. Unchanged captured output remains in [the historical verification record](History/ASR_INSTALLED_VERIFICATION_PRE_IDENTITY_CHANGE.md).

The new preferences domain starts with defaults. No old settings or privacy grants are migrated. During the separately approved private-candidate stage, verify app-specific Microphone and Accessibility access, onboarding, shortcuts, app rules and a real record-stop-paste cycle. Test Bluetooth only when enabled. Do not grant terminal microphone access as a substitute.

ASR continues to use the existing Parakeet.cpp runtime shared with AIR. See [runtime wiring](PARAKEET_DISCOVERY.md). Identity cleanup does not install, sign, notarise or publish an app.
