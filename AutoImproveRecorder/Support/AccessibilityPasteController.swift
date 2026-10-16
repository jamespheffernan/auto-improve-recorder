import ApplicationServices
import AppKit
import OSLog

enum AccessibilityPasteError: LocalizedError {
    case notTrusted
    case eventCreationFailed

    var errorDescription: String? {
        switch self {
        case .notTrusted:
            return "Accessibility permission is not enabled."
        case .eventCreationFailed:
            return "Could not create paste keyboard events."
        }
    }
}

@MainActor
struct PasteAcknowledgementProbe {
    let isSatisfied: @MainActor () -> Bool
}

@MainActor
struct AccessibilityPasteDependencies {
    typealias RestorationOperation = @MainActor @Sendable () -> Void
    typealias RestorationScheduler = (@escaping RestorationOperation) -> Void
    typealias TimingRecorder = (DeliveryTimingSample) -> Void

    var isTrusted: (_ prompt: Bool) -> Bool
    var pasteboard: NSPasteboard
    var postKeyEventPair: (_ descriptor: SendKeyEventDescriptor) -> Bool
    var scheduleRestoration: RestorationScheduler
    var currentContext: () -> DeliveryContext
    var recordTiming: TimingRecorder
    var preparePasteAcknowledgement: (_ insertedText: String) -> PasteAcknowledgementProbe? = { _ in nil }

    static var live: AccessibilityPasteDependencies {
        AccessibilityPasteDependencies(
            isTrusted: AccessibilityPasteController.isTrusted,
            pasteboard: .general,
            postKeyEventPair: AccessibilityPasteController.postLiveKeyEventPair,
            scheduleRestoration: { operation in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: operation)
            },
            currentContext: {
                AccessibilityPasteController.currentDeliveryContext(promptForPermission: false)
            },
            recordTiming: DeliverySignposts.record,
            preparePasteAcknowledgement: AccessibilityPasteController.prepareLivePasteAcknowledgement
        )
    }
}

private enum DeliverySignposts {
    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "recorder.delivery",
        category: "DeliveryTiming"
    )

    static func record(_ sample: DeliveryTimingSample) {
        switch sample.phase {
        case .pasteEvent:
            os_signpost(.event, log: log, name: "PasteEvent", "%{public}llu", sample.elapsedNanoseconds)
        case .settlement:
            os_signpost(.event, log: log, name: "Settlement", "%{public}llu", sample.elapsedNanoseconds)
        case .finalGuard:
            os_signpost(.event, log: log, name: "FinalGuard", "%{public}llu", sample.elapsedNanoseconds)
        case .sendEvent:
            os_signpost(.event, log: log, name: "SendEvent", "%{public}llu", sample.elapsedNanoseconds)
        case .total:
            os_signpost(.event, log: log, name: "DeliveryTotal", "%{public}llu", sample.elapsedNanoseconds)
        }
    }
}

enum AccessibilityPasteController {
    private static let minimumLegacySendSettlementNanoseconds: UInt64 = 80_000_000

    static func isTrusted(prompt: Bool) -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @MainActor
    static func focusedElementAcceptsText(promptForPermission: Bool = false) -> Bool {
        currentDeliveryContext(promptForPermission: promptForPermission).focusedTarget?.acceptsText == true
    }

    @MainActor
    static func focusedTextTargetFrame(promptForPermission: Bool = false) -> CGRect? {
        currentDeliveryContext(promptForPermission: promptForPermission).focusedTarget?.frame
    }

    @MainActor
    static func currentFocusedApp() -> FocusedApp? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = app.bundleIdentifier,
              !bundleIdentifier.isEmpty else {
            return nil
        }

        return FocusedApp(
            bundleIdentifier: bundleIdentifier,
            displayName: app.localizedName,
            processIdentifier: app.processIdentifier
        )
    }

    @MainActor
    static func focusedTextTarget(promptForPermission: Bool = false) -> FocusedTextTarget? {
        currentDeliveryContext(promptForPermission: promptForPermission).focusedTarget
    }

    @MainActor
    static func currentDeliveryContext(promptForPermission: Bool = false) -> DeliveryContext {
        let frontmostApp = currentFocusedApp()
        let trusted = isTrusted(prompt: promptForPermission)

        guard trusted, let element = focusedElement() else {
            return DeliveryContext(focusedApp: frontmostApp, focusedTarget: nil, accessibilityTrusted: trusted)
        }

        let acceptsText = elementAcceptsText(element)
        let target = FocusedTextTarget(
            acceptsText: acceptsText,
            frame: acceptsText ? elementFrame(element) : nil,
            identity: acceptsText ? elementIdentity(element) : nil
        )

        return DeliveryContext(focusedApp: frontmostApp, focusedTarget: target, accessibilityTrusted: trusted)
    }

    @MainActor
    static func paste(
        _ request: PasteExecutionRequest
    ) async throws -> PasteExecutionResult {
        try await paste(
            request,
            dependencies: .live
        )
    }

    @MainActor
    static func paste(
        _ request: PasteExecutionRequest,
        dependencies: AccessibilityPasteDependencies
    ) async throws -> PasteExecutionResult {
        let totalStart = DispatchTime.now().uptimeNanoseconds
        var strategy = DeliveryStrategy.legacyClipboardPaste
        var fallback: DeliveryFallback = request.optimizationMode == .legacyOnly
            ? .optimizationDisabled
            : .capabilityUnavailable
        var timing = DeliveryTimingValues.zero

        guard dependencies.isTrusted(true) else {
            throw AccessibilityPasteError.notTrusted
        }

        let acknowledgementProbe = request.optimizationMode == .qualifiedCapabilities && request.sendCommand != nil
            ? dependencies.preparePasteAcknowledgement(request.text)
            : nil
        let pasteboard = dependencies.pasteboard
        let restoration = request.leaveClipboardChanged
            ? nil
            : PasteboardRestorationCoordinator.beginTemporaryWrite(to: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(request.text, forType: .string)
        let transcriptChangeCount = pasteboard.changeCount

        if let restoration {
            PasteboardRestorationCoordinator.didWriteTranscript(
                restoration,
                changeCount: transcriptChangeCount
            )
            dependencies.scheduleRestoration {
                PasteboardRestorationCoordinator.restoreIfCurrent(restoration, on: pasteboard)
            }
        }

        let pasteDescriptor = SendKeyEventDescriptor(virtualKey: 0x09, flags: .maskCommand)
        let pasteEventStart = DispatchTime.now().uptimeNanoseconds
        guard dependencies.postKeyEventPair(pasteDescriptor) else {
            throw AccessibilityPasteError.eventCreationFailed
        }
        timing.pasteEventNanoseconds = elapsed(since: pasteEventStart)
        record(timing.pasteEventNanoseconds, phase: .pasteEvent, strategy: strategy, dependencies: dependencies)

        guard let sendCommand = request.sendCommand else {
            return finish(
                sendExecution: .notRequested,
                strategy: strategy,
                fallback: fallback,
                timing: timing,
                totalStart: totalStart,
                dependencies: dependencies
            )
        }

        let settlementStart = DispatchTime.now().uptimeNanoseconds
        let acknowledgementDeadline = DispatchTime.now().uptimeNanoseconds &+ minimumLegacySendSettlementNanoseconds
        var pasteWasAcknowledged = false
        if let acknowledgementProbe {
            while !Task.isCancelled && DispatchTime.now().uptimeNanoseconds < acknowledgementDeadline {
                if acknowledgementProbe.isSatisfied() {
                    pasteWasAcknowledged = true
                    break
                }
                do {
                    try await Task.sleep(nanoseconds: 250_000)
                } catch {
                    break
                }
            }
        } else {
            let settlementDelay = max(
                request.settlementDelayNanoseconds,
                minimumLegacySendSettlementNanoseconds
            )
            do {
                try await Task.sleep(nanoseconds: settlementDelay)
            } catch {
                timing.settlementNanoseconds = elapsed(since: settlementStart)
                record(timing.settlementNanoseconds, phase: .settlement, strategy: strategy, dependencies: dependencies)
                return finish(
                    sendExecution: .suppressed(.deliveryCancelled),
                    strategy: strategy,
                    fallback: fallback,
                    timing: timing,
                    totalStart: totalStart,
                    dependencies: dependencies
                )
            }
        }
        if pasteWasAcknowledged {
            strategy = .acknowledgedClipboardPaste
            fallback = .notRequired
        }
        if Task.isCancelled {
            timing.settlementNanoseconds = elapsed(since: settlementStart)
            record(timing.settlementNanoseconds, phase: .settlement, strategy: strategy, dependencies: dependencies)
            return finish(
                sendExecution: .suppressed(.deliveryCancelled),
                strategy: strategy,
                fallback: fallback,
                timing: timing,
                totalStart: totalStart,
                dependencies: dependencies
            )
        }
        timing.settlementNanoseconds = elapsed(since: settlementStart)
        record(timing.settlementNanoseconds, phase: .settlement, strategy: strategy, dependencies: dependencies)
        let guardStart = DispatchTime.now().uptimeNanoseconds
        let currentContext = dependencies.currentContext()
        if let reason = DeliverySendGuard.suppressionReason(
            expectedDestination: request.expectedDestination,
            currentContext: currentContext,
            unknownDestinationPolicy: request.unknownDestinationPolicy
        ) {
            timing.finalGuardNanoseconds = elapsed(since: guardStart)
            record(timing.finalGuardNanoseconds, phase: .finalGuard, strategy: strategy, dependencies: dependencies)
            return finish(
                sendExecution: .suppressed(reason),
                strategy: strategy,
                fallback: fallback,
                timing: timing,
                totalStart: totalStart,
                dependencies: dependencies
            )
        }
        timing.finalGuardNanoseconds = elapsed(since: guardStart)
        record(timing.finalGuardNanoseconds, phase: .finalGuard, strategy: strategy, dependencies: dependencies)

        guard !Task.isCancelled else {
            return finish(
                sendExecution: .suppressed(.deliveryCancelled),
                strategy: strategy,
                fallback: fallback,
                timing: timing,
                totalStart: totalStart,
                dependencies: dependencies
            )
        }
        let sendEventStart = DispatchTime.now().uptimeNanoseconds
        guard dependencies.postKeyEventPair(sendCommand.keyEventDescriptor) else {
            timing.sendEventNanoseconds = elapsed(since: sendEventStart)
            record(timing.sendEventNanoseconds, phase: .sendEvent, strategy: strategy, dependencies: dependencies)
            return finish(
                sendExecution: .suppressed(.sendEventFailed),
                strategy: strategy,
                fallback: fallback,
                timing: timing,
                totalStart: totalStart,
                dependencies: dependencies
            )
        }
        timing.sendEventNanoseconds = elapsed(since: sendEventStart)
        record(timing.sendEventNanoseconds, phase: .sendEvent, strategy: strategy, dependencies: dependencies)
        return finish(
            sendExecution: .sent,
            strategy: strategy,
            fallback: fallback,
            timing: timing,
            totalStart: totalStart,
            dependencies: dependencies
        )
    }

    private static func elapsed(since start: UInt64) -> UInt64 {
        DispatchTime.now().uptimeNanoseconds &- start
    }

    @MainActor
    fileprivate static func prepareLivePasteAcknowledgement(
        insertedText: String
    ) -> PasteAcknowledgementProbe? {
        guard let element = focusedElement(),
              let currentText = stringAttribute(kAXValueAttribute, from: element),
              let selection = textRangeAttribute(kAXSelectedTextRangeAttribute, from: element),
              let expected = try? UTF16TextReplacement.replacing(selection, in: currentText, with: insertedText)
        else {
            return nil
        }

        return PasteAcknowledgementProbe {
            guard let focused = focusedElement(),
                  CFEqual(focused, element),
                  stringAttribute(kAXValueAttribute, from: element) == expected.text,
                  textRangeAttribute(kAXSelectedTextRangeAttribute, from: element) == expected.caret
            else {
                return false
            }
            return true
        }
    }

    @MainActor
    private static func record(
        _ elapsedNanoseconds: UInt64,
        phase: DeliveryTimingPhase,
        strategy: DeliveryStrategy,
        dependencies: AccessibilityPasteDependencies
    ) {
        dependencies.recordTiming(
            DeliveryTimingSample(
                phase: phase,
                strategy: strategy,
                elapsedNanoseconds: elapsedNanoseconds
            )
        )
    }

    @MainActor
    private static func finish(
        sendExecution: SendCommandExecution,
        strategy: DeliveryStrategy,
        fallback: DeliveryFallback,
        timing: DeliveryTimingValues,
        totalStart: UInt64,
        dependencies: AccessibilityPasteDependencies
    ) -> PasteExecutionResult {
        var completedTiming = timing
        completedTiming.totalNanoseconds = elapsed(since: totalStart)
        record(
            completedTiming.totalNanoseconds,
            phase: .total,
            strategy: strategy,
            dependencies: dependencies
        )
        return PasteExecutionResult(
            sendExecution: sendExecution,
            strategy: strategy,
            fallback: fallback,
            timing: completedTiming
        )
    }

    @MainActor
    fileprivate static func postLiveKeyEventPair(_ descriptor: SendKeyEventDescriptor) -> Bool {
        guard
            let source = CGEventSource(stateID: .hidSystemState),
            let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: descriptor.virtualKey,
                keyDown: true
            ),
            let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: descriptor.virtualKey,
                keyDown: false
            )
        else {
            return false
        }

        keyDown.flags = descriptor.flags
        keyUp.flags = descriptor.flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private static func elementIdentity(_ element: AXUIElement) -> FocusedTextTargetIdentity {
        var processIdentifier: pid_t = 0
        AXUIElementGetPid(element, &processIdentifier)

        if let identifier = stringAttribute("AXIdentifier", from: element), !identifier.isEmpty {
            return FocusedTextTargetIdentity(
                rawValue: "\(processIdentifier):identifier:\(identifier)",
                accessibilityElement: element,
                allowsElementReplacement: true
            )
        }

        let role = stringAttribute(kAXRoleAttribute, from: element) ?? "unknown"
        let subrole = stringAttribute(kAXSubroleAttribute, from: element) ?? "unknown"
        return FocusedTextTargetIdentity(
            rawValue: "\(processIdentifier):element:\(CFHash(element)):\(role):\(subrole)",
            accessibilityElement: element
        )
    }

    private static func focusedElement() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &value
        )
        if result == .success,
           let value,
           CFGetTypeID(value) == AXUIElementGetTypeID() {
            return (value as! AXUIElement)
        }

        return frontmostApplicationFocusedElement()
    }

    private static func frontmostApplicationFocusedElement() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &value
        )
        guard result == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return (value as! AXUIElement)
    }

    private static func elementAcceptsText(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(kAXRoleAttribute, from: element)
        let subrole = stringAttribute(kAXSubroleAttribute, from: element)

        if subrole == "AXSecureTextField" {
            return false
        }

        let isEditable = boolAttribute(kAXIsEditableAttribute as String, from: element)
        guard AccessibilityEditableGate.allowsText(isEditable: isEditable) else {
            return false
        }

        guard role != kAXButtonRole as String &&
            role != kAXMenuItemRole as String &&
            role != kAXCheckBoxRole as String &&
            role != kAXRadioButtonRole as String &&
            role != kAXSliderRole as String
        else {
            return false
        }

        if role == kAXTextFieldRole as String ||
            role == kAXTextAreaRole as String ||
            role == kAXComboBoxRole as String {
            return true
        }

        guard hasTextEditingAttribute(element) else {
            return false
        }

        var settable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &settable
        )
        return result != .success || settable.boolValue || role == "AXWebArea"
    }

    private static func hasTextEditingAttribute(_ element: AXUIElement) -> Bool {
        var names: CFArray?
        let result = AXUIElementCopyAttributeNames(element, &names)
        guard result == .success, let names = names as? [String] else {
            return false
        }

        let textEditingAttributes: Set<String> = [
            kAXSelectedTextRangeAttribute,
            kAXVisibleCharacterRangeAttribute,
            "AXSelectedTextMarkerRange",
            "AXInsertionPointLineNumber",
            "AXNumberOfCharacters",
            "AXPlaceholderValue"
        ]

        return names.contains { textEditingAttributes.contains($0) }
    }

    private static func elementFrame(_ element: AXUIElement) -> CGRect? {
        guard let position = pointAttribute(kAXPositionAttribute, from: element),
              let size = sizeAttribute(kAXSizeAttribute, from: element),
              size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0 else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else {
            return nil
        }

        return value as? String
    }

    private static func boolAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else {
            return nil
        }

        return value as? Bool
    }

    private static func textRangeAttribute(_ attribute: String, from element: AXUIElement) -> UTF16TextSelection? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetType(value as! AXValue) == .cfRange else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range),
              range.location >= 0,
              range.length >= 0 else {
            return nil
        }
        return UTF16TextSelection(location: range.location, length: range.length)
    }

    private static func pointAttribute(_ attribute: String, from element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetType(value as! AXValue) == .cgPoint else {
            return nil
        }

        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private static func sizeAttribute(_ attribute: String, from element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetType(value as! AXValue) == .cgSize else {
            return nil
        }

        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else {
            return nil
        }
        return size
    }
}

enum AccessibilityEditableGate {
    /// This flag can veto a target. It cannot qualify a target by itself.
    /// Role and readable/settable text evidence remain authoritative.
    static func allowsText(isEditable: Bool?) -> Bool {
        isEditable != false
    }
}

private struct PasteboardRestoration: Sendable {
    let pasteboardName: String
    let token: UUID
}

@MainActor
private enum PasteboardRestorationCoordinator {
    private struct State {
        var originalSnapshot: PasteboardSnapshot
        var latestToken: UUID
        var transcriptChangeCount: Int?
    }

    private static var statesByPasteboardName: [String: State] = [:]

    static func beginTemporaryWrite(to pasteboard: NSPasteboard) -> PasteboardRestoration {
        let pasteboardName = pasteboard.name.rawValue
        let token = UUID()

        if let state = statesByPasteboardName[pasteboardName],
           state.transcriptChangeCount == pasteboard.changeCount {
            statesByPasteboardName[pasteboardName] = State(
                originalSnapshot: state.originalSnapshot,
                latestToken: token,
                transcriptChangeCount: nil
            )
        } else {
            statesByPasteboardName[pasteboardName] = State(
                originalSnapshot: PasteboardSnapshot.capture(from: pasteboard),
                latestToken: token,
                transcriptChangeCount: nil
            )
        }

        return PasteboardRestoration(pasteboardName: pasteboardName, token: token)
    }

    static func didWriteTranscript(_ restoration: PasteboardRestoration, changeCount: Int) {
        guard var state = statesByPasteboardName[restoration.pasteboardName],
              state.latestToken == restoration.token else {
            return
        }

        state.transcriptChangeCount = changeCount
        statesByPasteboardName[restoration.pasteboardName] = state
    }

    static func restoreIfCurrent(_ restoration: PasteboardRestoration, on pasteboard: NSPasteboard) {
        guard let state = statesByPasteboardName[restoration.pasteboardName],
              state.latestToken == restoration.token else {
            return
        }

        defer {
            statesByPasteboardName.removeValue(forKey: restoration.pasteboardName)
        }

        guard state.transcriptChangeCount == pasteboard.changeCount else {
            return
        }

        state.originalSnapshot.restore(to: pasteboard)
    }
}

private struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = pasteboard.pasteboardItems?.map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { result, type in
                result[type] = item.data(forType: type)
            }
        } ?? []

        return PasteboardSnapshot(items: items)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let pasteboardItems = items.map { itemData in
            let item = NSPasteboardItem()
            for (type, data) in itemData {
                item.setData(data, forType: type)
            }
            return item
        }

        if !pasteboardItems.isEmpty {
            pasteboard.writeObjects(pasteboardItems)
        }
    }
}
