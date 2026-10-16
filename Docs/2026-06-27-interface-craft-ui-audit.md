# AutoImproveRecorder Interface Craft UI Audit

## Items to review

- [ ] Make the edge glow/readout the primary recording and processing surface, and demote the 390px pill to a fallback or transient compact HUD.
- [ ] Rework the Processing settings pane around "choose a preset first, customize only if needed" instead of giving presets and custom engines equal weight.
- [ ] Turn readiness, diagnostics, and local model status into actionable rows with next steps, not just dots, badges, and copy actions.
- [ ] Redesign Preview as a post-capture workspace with clearer raw-vs-cleaned comparison, delivery state, and error recovery.
- [ ] Create a small state playground for recording, processing, delivery, failure, permissions, and model readiness before more UI changes.

## Context

AutoImproveRecorder is a macOS menu bar dictation utility. The target user is mid-writing, usually inside another app, and wants fast capture, clear waiting feedback, and confidence that text landed in the right place.

The emotional context is interruption-sensitive. The interface has to communicate "I am listening", "I am working", "I am done", and "I need help" without feeling like a separate app taking over the user's task.

## Evidence reviewed

- Current SwiftUI settings structure in `AutoImproveRecorder/UI/SettingsView.swift`.
- Current recorder pill in `AutoImproveRecorder/UI/RecorderPillView.swift`.
- Current post-capture preview in `AutoImproveRecorder/UI/PreviewView.swift`.
- Current glow/readout implementation in `AutoImproveRecorder/UI/WindowControllers.swift`.
- Existing waiting UX prototype notes in `Design/WaitingUXPrototype/NOTES.md`.
- Installed app process at `/Applications/AutoImproveRecorder.app`. The app was running, but its status menu exposed no accessible menu items during this pass, so this audit relies on source and design prototype evidence rather than a live settings screenshot.

## First Impressions

The app has the hard product pieces: explicit recording states, a processing rail, a readiness model, local model inventory, permission checks, diagnostics, and a waiting UX prototype. The UI problem is not missing state. The problem is that important state gets scattered across a pill, edge glow, preview, footer badges, local model rows, and menu items. The strongest direction is already present in the prototype: feedback should stay attached to the user's work area, while settings should act like a calm control room.

## Visual Design

**The pill competes with the glow layer** - `RecorderPillView` renders a fixed 390px capsule with material, border, shadow, status glyph, one-line transcript/status text, action button, and optional rail. The edge glow/readout separately renders full-screen colored bands, a status capsule, stage rail, and target-field highlight. The two systems both try to own recording feedback. The pill should become a compact fallback or menu-bar-adjacent readout once the glow/readout is active.

Relevant code: `RecorderPillView.swift:7`, `RecorderPillView.swift:40`, `WindowControllers.swift` glow/readout implementation.

**Color semantics are too dependent on raw hue** - Recording, transcribing, improving, delivering, success, idle, and failure map directly to red, orange, teal, blue, green, green, and yellow in the pill. In the glow layer, failure is red/orange while recording is also red. Green means both idle and success. This gives fast color feedback, but it weakens semantic clarity for users with color differences or peripheral vision. Keep the colors, but pair every state with shape, position, and wording: recording can pulse waveform/timer, processing can show stage rail, failure can use a warning triangle plus stable recovery copy.

Relevant code: `RecorderPillView.swift:172`, `WindowControllers.swift` `glowColor`.

**Settings uses too many equal-weight rows** - The settings window has a strong sidebar shell, but the content area uses repeated 13px row titles, 12px subtitles, dividers, and controls across every section. In Processing, the highest-impact decision is the preset, yet the preset rows, custom engine pickers, and auto-improve controls sit in the same visual rhythm. Make the chosen preset a larger selected summary at the top, then tuck custom engine controls behind a disclosure.

Relevant code: `SettingsView.swift:17`, `SettingsView.swift:218`, `SettingsView.swift:368`.

**Footer status is visually too small for the job** - Readiness footer badges are 11px text plus 7px dots, while the live status message is a one-line truncated tail. This is fine for passive state, but not for blocked paste, missing Accessibility permission, failed local runtime, or provider errors. Promote blocking state into an action strip with a clear primary button. Keep the tiny footer for all-green state only.

Relevant code: `SettingsView.swift:695`, `SettingsView.swift:715`, `SettingsView.swift:730`.

## Interface Design

**We are missing a single focusing mechanism for the live workflow.** The app has menu item state, pill state, edge glow state, preview state, and settings footer state. The user should always know which surface matters now. A clear hierarchy would be: edge glow/readout during recording and processing, preview only after capture or failure, settings only for configuration and repair.

**We are missing progressive disclosure in Processing.** The pane says "Use a tested pipeline without manually pairing engines", then immediately shows six local/cloud rows plus custom transcription and cleanup pickers. This asks the user to understand the implementation matrix. The first screen should ask for intent: fastest cloud, recommended local, all local, live/resident. Engine pairing belongs in an advanced drawer.

Relevant code: `SettingsView.swift:373`, `SettingsView.swift:390`, `SettingsView.swift:770`.

**We are missing actionable readiness.** Permissions show as "Ready", "Denied", or "Not requested"; diagnostics show latest text and "Copy details". This helps debugging, but it does not always tell the user what to do next. For denied Accessibility, the row should lead with "Open System Settings" or "Prompt Accessibility". For a missing local model, the row should explain the exact install/check action before showing the diagnostic detail.

Relevant code: `SettingsView.swift:634`, `SettingsView.swift:751`, `SettingsView.swift:869`.

**We are missing a recovery-first preview.** Preview is a fixed 560x420 window with a segmented raw/cleaned picker, one message area, one text editor, and Copy/Paste/Re-run actions. That is enough for happy-path inspection. It is thin for failed cleanup, partial transcript, paste failure, or dictionary-induced correction. Treat Preview as the recovery workspace: show raw and cleaned differences when both exist, explain why cleanup is unavailable, and make the next action obvious.

Relevant code: `PreviewView.swift:25`, `PreviewView.swift:40`, `PreviewView.swift:55`, `PreviewView.swift:66`.

**We are missing a state playground for the real app states.** The prototype already asks the right questions about recording obviousness, command hints, and paste/submit legibility. The shipped SwiftUI state set is richer than the prototype. Build a small native or web playground that can switch through idle, starting, recording, latched, transcribing, improving, delivering, pasted, submitted, copied, ready, failed, permission-denied, and model-unavailable states.

Relevant evidence: `Design/WaitingUXPrototype/NOTES.md:1`.

## Consistency & Conventions

**The settings sidebar follows macOS expectations, but the content behaves more like a dense admin panel.** The 188px sidebar, divider, scroll content, and 900x680 window are a sound frame. Inside the panes, settings groups use a two-column pattern with 145px labels and fixed-width controls. That structure is orderly, but it makes explanatory copy and controls compete. Favor macOS preference-pane conventions: summary, primary control, secondary detail, then advanced options.

Relevant code: `SettingsView.swift:11`, `SettingsView.swift:28`, `SettingsView.swift:218`.

**Similar status concepts render differently across the app.** The pill uses colored circles and symbols. The settings footer uses dot badges. Local models use dot plus capsule badge. Permissions use capsule badge only. Diagnostics use plain text. These should share one status row vocabulary: icon, title, state badge, short consequence, next action.

Relevant code: `RecorderPillView.swift:56`, `SettingsView.swift:730`, `SettingsView.swift:751`, `SettingsView.swift:889`.

**Buttons mix command weight.** "Use Recommended", "Check", "Check all", "Copy diagnostics", "Prompt Accessibility", "Restore defaults", and icon-only refresh buttons all sit near each other without a strict primary/secondary/destructive vocabulary. Give each row one primary next action, then move refresh/copy/debug actions behind menus or secondary buttons.

Relevant code: `SettingsView.swift:377`, `SettingsView.swift:654`, `SettingsView.swift:920`.

## User Context

The user is likely focused, impatient, and already inside another writing surface. When recording starts, the app should feel present but not like a new window. When processing takes time, it should make the wait feel bounded. When something fails, it should give one concrete repair step before exposing diagnostics.

Uncommon care here would be state-specific reassurance tied to the user's document: a subtle target-field highlight before paste, a short "Text landed" confirmation after delivery, a clear "Copied instead because Accessibility is not ready" fallback, and a preview that preserves both raw and cleaned text without making the user hunt for the difference.

## Top Opportunities

1. Make the glow/readout the primary live workflow and retire the pill from the center of the screen except as a fallback.
2. Collapse Processing around four user intents: fastest cloud, recommended local, all local, and live/resident.
3. Replace footer dots and local model badges with actionable readiness rows that say what is blocked and what to do next.
4. Turn Preview into the recovery and verification surface, with side-by-side or inline raw/cleaned comparison and clearer failure actions.
5. Build a state playground for the shipped states before changing the visual layer, so every permission, runtime, and delivery edge case gets designed.

## Suggested First Implementation Pass

1. Add a `WorkflowSurfacePriority` note or small design doc that defines which surface owns each state: menu, glow/readout, pill, preview, settings.
2. Update Processing settings to show one selected preset summary and an "Advanced engine pairing" disclosure.
3. Create a shared `StatusActionRow` for permissions, local models, diagnostics, and footer-blocking state.
4. Extend the existing waiting UX prototype or add a SwiftUI debug view for all `ProcessingVisualState` and readiness combinations.
5. Only after those state decisions, tune color, spacing, and animation values.
