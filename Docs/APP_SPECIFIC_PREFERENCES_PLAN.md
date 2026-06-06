# App-Specific Preferences Proposal
Date: 2026-05-31
## Goal
Add app-specific completion behavior to AutoImproveRecorder, starting with:

- WhatsApp should paste but not auto-submit.
  
- The implementation should become a general rule system for per-app preferences, not a one-off WhatsApp conditional.
  

The feature should affect only delivery behavior after transcription and cleanup are complete. It should not change recording, transcription, improvement, or the final text selection logic.
## Grounded Current State
Current completion behavior is global:

- `AppState.completeWithText(_:)` decides paste, clipboard, and auto-submit behavior.
  
- `autoSubmitDetectedTextFields` is a single global boolean.
  
- `copyFinishedTextToClipboard` is a single global boolean.
  
- `AccessibilityPasteController.paste(...)` accepts `submitAfterPaste`.
  
- `AccessibilityPasteController` can already inspect the focused accessibility element, focused text target frame, and frontmost application indirectly.
  
- Settings currently exposes completion toggles in one global "Completion" section.
  

Local WhatsApp install:

- `/Applications/WhatsApp.app`
  
- Bundle identifier: `net.whatsapp.WhatsApp`
  
## Proposed Model
Introduce a delivery policy layer:

```swift
struct DeliveryContext {
    let focusedApp: FocusedApp?
    let focusedTarget: FocusedTextTarget?
}

struct FocusedApp: Equatable, Codable {
    let bundleIdentifier: String
    let localizedName: String
}

struct DeliveryPolicy: Equatable, Codable {
    var pasteBehavior: PasteBehavior
    var submitBehavior: SubmitBehavior
    var clipboardBehavior: ClipboardBehavior
}
```

Policy resolution should be explicit:

```text
defaults -> matching app rule -> delivery decision
```

The app should never ask `autoSubmitDetectedTextFields` directly during delivery once this lands. It should ask a resolver:

```swift
let context = AccessibilityPasteController.currentDeliveryContext(promptForPermission: true)
let policy = deliveryPolicyStore.resolve(context: context, defaults: globalCompletionSettings)
```
## Policy Fields
Recommended first version:

```swift
enum SubmitBehavior: String, Codable, CaseIterable {
    case followGlobal
    case never
    case always
}

enum ClipboardBehavior: String, Codable, CaseIterable {
    case followGlobal
    case copy
    case doNotCopy
}

enum PasteBehavior: String, Codable, CaseIterable {
    case followGlobal
    case pasteIfPossible
    case copyOnly
}
```

For WhatsApp, create a seeded rule:

```text
App: net.whatsapp.WhatsApp
Submit: never
Clipboard: follow global
Paste: follow global
```

That preserves the user's current paste/copy preference while preventing accidental sends.
## Data Storage
Use `UserDefaults` with JSON-encoded rules for v1:

```swift
struct AppDeliveryRule: Identifiable, Equatable, Codable {
    var id: String { bundleIdentifier }
    var bundleIdentifier: String
    var appName: String
    var enabled: Bool
    var submitBehavior: SubmitBehavior
    var clipboardBehavior: ClipboardBehavior
    var pasteBehavior: PasteBehavior
}
```

Key:

```text
appDeliveryRules.v1
```

Seed logic:

- On launch, if no stored rules exist, create the WhatsApp rule.
  
- If stored rules exist, do not overwrite them.
  
- Keep this migration idempotent.
  

This is enough for a local macOS app and avoids premature file/database complexity.
## Detection Surface
Add a public context API to `AccessibilityPasteController`:

```swift
static func currentDeliveryContext(promptForPermission: Bool) -> DeliveryContext
```

Implementation should collect:

- `NSWorkspace.shared.frontmostApplication?.bundleIdentifier`
  
- `NSWorkspace.shared.frontmostApplication?.localizedName`
  
- Focused element accepts text: existing AX logic
  
- Focused target frame: existing AX logic
  

Important: app identity should come from `NSWorkspace.shared.frontmostApplication`, not from the AX element alone. The AX element is for "can paste here"; the frontmost app is for "which policy applies."
## Delivery Flow
Current flow:

```text
finishProcessing()
  -> completeWithText(text)
      -> focusedElementAcceptsText()
      -> AccessibilityPasteController.paste(... submitAfterPaste: autoSubmitDetectedTextFields)
```

Proposed flow:

```text
finishProcessing()
  -> completeWithText(text)
      -> context = currentDeliveryContext(promptForPermission: true)
      -> policy = DeliveryPolicyResolver.resolve(context, global settings, app rules)
      -> if policy.pasteBehavior allows paste and focused target accepts text:
             paste(text, leaveClipboardChanged: policy.copy, submitAfterPaste: policy.submit)
         else if policy.copy:
             copyToPasteboard(text)
         else:
             show "Text ready"
```

The user-visible status should say the actual outcome:

- `Pasted.`
  
- `Pasted and copied to clipboard.`
  
- `Pasted. Auto-submit disabled for WhatsApp.`
  
- `Copied to clipboard.`
  
- `Text ready.`
  
## Settings UI
Keep v1 small but extensible.

Add a new section under Completion:

```text
App Rules
  WhatsApp
    [enabled] Paste, but never submit

  Current focused app:
    Add rule for <App Name>
```

Rule editor fields:

- App name
  
- Bundle identifier
  
- Enabled toggle
  
- Paste behavior picker
  
- Submit behavior picker
  
- Clipboard behavior picker
  

For v1, a simple table/list in `SettingsView` is enough. Avoid a separate window until there are enough rules to justify it.
## Implementation Steps
1. Add domain models in a new file:
  
  - `AutoImproveRecorder/Support/AppDeliveryRules.swift`
    
  - `FocusedApp`
    
  - `DeliveryContext`
    
  - `AppDeliveryRule`
    
  - policy enums
    
  - resolver
    
2. Extend `AccessibilityPasteController`:
  
  - expose focused app info
    
  - expose focused text target context
    
  - avoid duplicating AX checks
    
3. Add AppState storage:
  
  - `@Published var appDeliveryRules: [AppDeliveryRule]`
    
  - load/save JSON to `UserDefaults`
    
  - seed WhatsApp rule on first launch
    
4. Refactor delivery:
  
  - update `completeWithText(_:)`
    
  - remove direct `autoSubmitDetectedTextFields` decision from paste execution
    
  - compute policy once per completion
    
5. Add Settings UI:
  
  - App Rules section
    
  - default WhatsApp rule visible and editable
    
  - "Add current app" button
    
6. Add focused tests:
  
  - resolver tests for global-only behavior
    
  - WhatsApp rule disables submit
    
  - disabled rule falls back to global behavior
    
  - copy-only rule does not call paste
    
7. Manual QA:
  
  - WhatsApp: paste into message field, verify no Return/send is fired
    
  - Messages or Notes: verify current global auto-submit behavior still works
    
  - No focused text field: verify clipboard fallback still works
    
  - Accessibility disabled: verify status message remains useful
    
## Recommendation
Build this in two commits:

1. Policy engine + WhatsApp default, wired into delivery, no settings editor except maybe the existing global toggle still visible.
  
2. Settings UI for viewing/editing app rules and adding the current focused app.
  

That gets the safety fix in quickly while keeping the extensible preference system clean.
## Open Questions
1. Should WhatsApp disable submit only for the native Mac app, or also for WhatsApp Web in browsers?
  
2. Should app rules be able to override cleanup mode later, or should v1 stay strictly completion/delivery behavior?
  
3. Should "Add current app" capture only bundle ID, or also the current focused element role/subrole for future per-field rules?
