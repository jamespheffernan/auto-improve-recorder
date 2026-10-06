import AppKit
import Foundation
import XCTest
@testable import AutoSendRecorderCore

final class AutoSendWorkflowTests: XCTestCase {
    @MainActor
    func testPhononDefaultAndExplicitParakeetPreferencePersist() {
        let suiteName = "AutoSendRecorderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AutoSendSettingsStore(defaults: defaults)
        XCTAssertEqual(settings.transcriptionModel, .phonon2)
        var observed: AutoSendTranscriptionModel?
        settings.transcriptionModelDidChange = { observed = $0 }
        settings.transcriptionModel = .parakeet
        XCTAssertEqual(observed, .parakeet)
        XCTAssertEqual(AutoSendSettingsStore(defaults: defaults).transcriptionModel, .parakeet)
        settings.transcriptionModel = .phonon2
        XCTAssertEqual(AutoSendSettingsStore(defaults: defaults).transcriptionModel, .phonon2)
    }

    @MainActor
    func testClipboardFallbackReplacesExistingPasteboardText() throws {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("autosend-clipboard-\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("previous text", forType: .string))

        XCTAssertTrue(AutoSendPasteboardWriter.write("wireless test complete", to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "wireless test complete")
    }

    @MainActor
    func testNewSettingsDefaultToWalkieTalkieAndPreserveExplicitToggle() {
        let suiteName = "AutoSendRecorderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = AutoSendSettingsStore(defaults: defaults)
        XCTAssertEqual(initial.triggerMode, .walkieTalkie)

        initial.triggerMode = .toggle
        let reloaded = AutoSendSettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.triggerMode, .toggle)
    }

    @MainActor
    func testMenuBarIconStyleDefaultsToAutomaticAndPersistsWhiteSelection() {
        let suiteName = "AutoSendRecorderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = AutoSendSettingsStore(defaults: defaults)
        XCTAssertEqual(initial.menuBarIconStyle, .automatic)

        initial.menuBarIconStyle = .white
        let reloaded = AutoSendSettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.menuBarIconStyle, .white)
    }

    @MainActor
    func testPreferredMicrophoneDefaultsToSystemAndPersistsSelection() {
        let suiteName = "AutoSendRecorderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = AutoSendSettingsStore(defaults: defaults)
        XCTAssertEqual(initial.preferredMicrophoneID, "")
        XCTAssertFalse(initial.hasSavedMicrophonePreference)

        initial.preferredMicrophoneID = "boya-device-id"
        let reloaded = AutoSendSettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.preferredMicrophoneID, "boya-device-id")
        XCTAssertTrue(reloaded.hasSavedMicrophonePreference)
    }

    @MainActor
    func testAccessibilityPromptIsOfferedOnlyOnceUntilExplicitlyReset() {
        let suiteName = "AutoSendRecorderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AutoSendSettingsStore(defaults: defaults)
        XCTAssertTrue(settings.takeAccessibilityPromptOpportunity())
        XCTAssertFalse(settings.takeAccessibilityPromptOpportunity())

        settings.resetAccessibilityPromptOpportunity()
        XCTAssertTrue(settings.takeAccessibilityPromptOpportunity())
    }

    @MainActor
    func testGlobalShortcutsPersistAndRejectUnsafeOrDuplicateAssignments() {
        let suiteName = "AutoSendRecorderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AutoSendSettingsStore(defaults: defaults)
        XCTAssertEqual(settings.recordingShortcut, .defaultRecording)
        XCTAssertEqual(settings.cancelShortcut, .defaultCancel)

        let replacement = AutoSendKeyboardShortcut(
            keyCode: 49,
            keyLabel: "Space",
            modifiers: [.control, .option]
        )
        XCTAssertNil(settings.updateRecordingShortcut(replacement))
        XCTAssertEqual(settings.recordingShortcut.displayName, "⌃⌥Space")

        let duplicateError = settings.updateCancelShortcut(replacement)
        XCTAssertEqual(duplicateError, "Choose a different shortcut for recording and cancelling.")
        XCTAssertEqual(settings.cancelShortcut, .defaultCancel)

        let unsafe = AutoSendKeyboardShortcut(keyCode: 15, keyLabel: "R", modifiers: [.shift])
        XCTAssertNotNil(settings.updateCancelShortcut(unsafe))
        XCTAssertEqual(AutoSendSettingsStore(defaults: defaults).recordingShortcut, replacement)
    }

    @MainActor
    func testOnboardingAndWirelessOptInSurviveRelaunch() {
        let suiteName = "AutoSendRecorderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AutoSendSettingsStore(defaults: defaults)
        XCTAssertFalse(settings.hasCompletedOnboarding)
        XCTAssertFalse(settings.wirelessRecorderEnabled)

        settings.completeOnboarding()
        settings.wirelessRecorderEnabled = true

        let reloaded = AutoSendSettingsStore(defaults: defaults)
        XCTAssertTrue(reloaded.hasCompletedOnboarding)
        XCTAssertTrue(reloaded.wirelessRecorderEnabled)
    }

    func testWalkieTalkiePressStartsAndReleaseStops() {
        var controller = AutoSendRecordingTriggerController()

        XCTAssertEqual(
            controller.handle(.pressed, mode: .walkieTalkie, phase: .idle),
            .start
        )
        XCTAssertEqual(
            controller.handle(.released, mode: .walkieTalkie, phase: .recording),
            .stop
        )
    }

    func testSpaceLatchKeepsWalkieTalkieRecordingActiveAfterRelease() {
        var controller = AutoSendRecordingTriggerController()

        XCTAssertEqual(controller.handle(.pressed, mode: .walkieTalkie, phase: .idle), .start)
        XCTAssertEqual(controller.handle(.latchPressed, mode: .walkieTalkie, phase: .recording), .none)
        XCTAssertEqual(controller.handle(.released, mode: .walkieTalkie, phase: .recording), .none)
        XCTAssertEqual(controller.handle(.pressed, mode: .walkieTalkie, phase: .recording), .stop)
    }

    func testSpaceLatchDuringStartupPreventsReleaseFromStoppingWhenReady() {
        var controller = AutoSendRecordingTriggerController()

        XCTAssertEqual(controller.handle(.pressed, mode: .walkieTalkie, phase: .idle), .start)
        XCTAssertEqual(controller.handle(.released, mode: .walkieTalkie, phase: .starting), .none)
        XCTAssertEqual(controller.handle(.latchPressed, mode: .walkieTalkie, phase: .starting), .none)
        XCTAssertEqual(
            controller.handle(.phaseChanged(.recording), mode: .walkieTalkie, phase: .recording),
            .none
        )
        XCTAssertEqual(controller.handle(.pressed, mode: .walkieTalkie, phase: .recording), .stop)
    }

    func testWirelessButtonStateFilterEmitsOnlyRealEdges() {
        var filter = AutoSendWirelessButtonStateFilter()

        XCTAssertNil(filter.consume(pressed: false))
        XCTAssertEqual(filter.consume(pressed: true), true)
        XCTAssertNil(filter.consume(pressed: true))
        XCTAssertEqual(filter.consume(pressed: false), false)
        XCTAssertNil(filter.consume(pressed: false))

        filter.reset()
        XCTAssertNil(filter.consume(pressed: false))
    }

    func testWorkflowPassesESP32SourceToCapture() async {
        let capture = FakeCapture()
        let workflow = makeWorkflow(
            capture: capture,
            transcript: FakeTranscript(text: "test"),
            delivery: FakeDelivery(disposition: .sent)
        )

        await workflow.start(source: .esp32Button)

        let source = await capture.startedSource
        XCTAssertEqual(source, .esp32Button)
    }

    func testInactiveTriggerCannotControlTheActiveSource() {
        XCTAssertFalse(
            AutoSendRecordingSourceGate.canProcess(
                source: .esp32Button,
                activeSource: .macHotKey
            )
        )
        XCTAssertFalse(
            AutoSendRecordingSourceGate.canProcess(
                source: .macHotKey,
                activeSource: .esp32Button
            )
        )
        XCTAssertTrue(
            AutoSendRecordingSourceGate.canProcess(
                source: .esp32Button,
                activeSource: .esp32Button
            )
        )
    }

    func testClipboardFallbackReportsNoFieldOnlyWhenAccessibilityIsReady() {
        XCTAssertEqual(
            AutoSendClipboardFallback.disposition(
                accessibilityTrusted: true,
                clipboardWriteSucceeded: true,
                statusMessage: "Text ready."
            ),
            .copied("Copied to clipboard. No editable text field was available.")
        )
    }

    func testClipboardFallbackKeepsAccessibilityRecoveryMessage() {
        XCTAssertEqual(
            AutoSendClipboardFallback.disposition(
                accessibilityTrusted: false,
                clipboardWriteSucceeded: true,
                statusMessage: "Enable Accessibility for Auto Send Recorder in System Settings."
            ),
            .permissionRequired(
                "Copied to clipboard. Enable Accessibility for Auto Send Recorder in System Settings."
            )
        )
    }

    func testClipboardFallbackReportsAWriteFailure() {
        XCTAssertEqual(
            AutoSendClipboardFallback.disposition(
                accessibilityTrusted: true,
                clipboardWriteSucceeded: false,
                statusMessage: "Text ready."
            ),
            .pasteFailed("Could not write the transcript to the clipboard.")
        )
    }

    func testWalkieTalkieReleaseDuringStartupStopsWhenRecordingBecomesReady() {
        var controller = AutoSendRecordingTriggerController()

        XCTAssertEqual(
            controller.handle(.pressed, mode: .walkieTalkie, phase: .idle),
            .start
        )
        XCTAssertEqual(
            controller.handle(.released, mode: .walkieTalkie, phase: .starting),
            .none
        )
        XCTAssertEqual(
            controller.handle(.phaseChanged(.recording), mode: .walkieTalkie, phase: .recording),
            .stop
        )
    }

    func testWalkieTalkiePressAfterALostReleaseStopsTheRecording() {
        var controller = AutoSendRecordingTriggerController()

        XCTAssertEqual(controller.handle(.pressed, mode: .walkieTalkie, phase: .idle), .start)
        XCTAssertEqual(
            controller.handle(.phaseChanged(.recording), mode: .walkieTalkie, phase: .recording),
            .none
        )
        // No release arrives. The next press ends the recording.
        XCTAssertEqual(controller.handle(.pressed, mode: .walkieTalkie, phase: .recording), .stop)
        XCTAssertEqual(controller.handle(.released, mode: .walkieTalkie, phase: .transcribing), .none)
        XCTAssertEqual(
            controller.handle(.phaseChanged(.ready), mode: .walkieTalkie, phase: .ready),
            .none
        )

        // The next hold records as usual.
        XCTAssertEqual(controller.handle(.pressed, mode: .walkieTalkie, phase: .ready), .start)
        XCTAssertEqual(controller.handle(.released, mode: .walkieTalkie, phase: .recording), .stop)
    }

    func testWalkieTalkiePressAfterALostReleaseStartsWhenNoRunIsInProgress() {
        var controller = AutoSendRecordingTriggerController()

        // The first press starts nothing that changes the phase, and its release is lost.
        XCTAssertEqual(controller.handle(.pressed, mode: .walkieTalkie, phase: .idle), .start)
        XCTAssertEqual(controller.handle(.pressed, mode: .walkieTalkie, phase: .idle), .start)
        XCTAssertEqual(controller.handle(.released, mode: .walkieTalkie, phase: .recording), .stop)
    }

    func testWalkieTalkiePressAfterALostReleaseWaitsWhileARunIsBusyButNotRecording() {
        var controller = AutoSendRecordingTriggerController()

        XCTAssertEqual(controller.handle(.pressed, mode: .walkieTalkie, phase: .idle), .start)
        for phase in [AutoSendPhase.starting, .transcribing, .delivering] {
            XCTAssertEqual(controller.handle(.pressed, mode: .walkieTalkie, phase: phase), .none, "\(phase)")
        }
    }

    func testToggleModeIgnoresReleaseAndUsesSecondPressToStop() {
        var controller = AutoSendRecordingTriggerController()

        XCTAssertEqual(controller.handle(.pressed, mode: .toggle, phase: .idle), .start)
        XCTAssertEqual(controller.handle(.released, mode: .toggle, phase: .recording), .none)
        XCTAssertEqual(controller.handle(.pressed, mode: .toggle, phase: .recording), .stop)
    }

    func testSuccessNormalizesAndDeliversKnownDestination() async {
        let capture = FakeCapture()
        let transcript = FakeTranscript(text: "  twenty one notes  ")
        let delivery = FakeDelivery(disposition: .sent)
        let workflow = makeWorkflow(
            capture: capture,
            transcript: transcript,
            delivery: delivery,
            normalize: { $0.replacingOccurrences(of: "twenty one", with: "21") }
        )

        await workflow.start()
        await workflow.stop()

        let phase = await workflow.phase
        let lastText = await workflow.lastText
        let disposition = await workflow.lastDeliveryDisposition
        let deliveredText = await delivery.deliveredText
        XCTAssertEqual(phase, .ready)
        XCTAssertEqual(lastText, "21 notes")
        XCTAssertEqual(disposition, .sent)
        XCTAssertEqual(deliveredText, "21 notes")
    }

    func testCaptureStartFailureDoesNotTranscribeOrDeliver() async {
        let capture = FakeCapture(startError: TestError.capture)
        let transcript = FakeTranscript(text: "must not run")
        let delivery = FakeDelivery(disposition: .sendSuppressed("must not run"))
        let workflow = makeWorkflow(capture: capture, transcript: transcript, delivery: delivery)

        await workflow.start()

        guard case .failed = await workflow.phase else {
            return XCTFail("Expected capture failure")
        }
        let transcriptCallCount = await transcript.callCount
        let deliveryCallCount = await delivery.deliverCallCount
        XCTAssertEqual(transcriptCallCount, 0)
        XCTAssertEqual(deliveryCallCount, 0)
    }

    func testInjectedCaptureGapAtStopIsTerminalAndNeverSends() async {
        let capture = FakeCapture(stopError: TestError.captureGap)
        let transcript = FakeTranscript(text: "must not run")
        let delivery = FakeDelivery(disposition: .sent)
        let workflow = makeWorkflow(capture: capture, transcript: transcript, delivery: delivery)

        await workflow.start()
        await workflow.stop()

        guard case .failed = await workflow.phase else {
            return XCTFail("Expected terminal capture-gap failure")
        }
        let transcriptCallCount = await transcript.callCount
        let deliveryCallCount = await delivery.deliverCallCount
        XCTAssertEqual(transcriptCallCount, 0)
        XCTAssertEqual(deliveryCallCount, 0)
    }

    func testArchiveOpenWriteAndFinishFailuresRejectSuccessfulLiveTranscript() async {
        for failure in [TestError.archiveOpen, .archiveWrite, .archiveFinish] {
            let capture = FakeCapture(stopError: failure)
            let transcript = FakeTranscript(text: "successful live transcript")
            let delivery = FakeDelivery(disposition: .sent)
            let workflow = makeWorkflow(capture: capture, transcript: transcript, delivery: delivery)

            await workflow.start()
            await workflow.stop()

            guard case .failed = await workflow.phase else {
                return XCTFail("Expected terminal archive failure for \(failure)")
            }
            let transcriptCallCount = await transcript.callCount
            let deliveryCallCount = await delivery.deliverCallCount
            XCTAssertEqual(transcriptCallCount, 0)
            XCTAssertEqual(deliveryCallCount, 0)
        }
    }

    func testCancelStopsCaptureAndTranscriptionWithoutDelivery() async {
        let capture = FakeCapture()
        let transcript = FakeTranscript(text: "must not run")
        let delivery = FakeDelivery(disposition: .sent)
        let workflow = makeWorkflow(capture: capture, transcript: transcript, delivery: delivery)

        await workflow.start()
        await workflow.cancel()

        let phase = await workflow.phase
        let captureWasCancelled = await capture.wasCancelled
        let transcriptWasCancelled = await transcript.wasCancelled
        let deliveryCallCount = await delivery.deliverCallCount
        XCTAssertEqual(phase, .idle)
        XCTAssertTrue(captureWasCancelled)
        XCTAssertTrue(transcriptWasCancelled)
        XCTAssertEqual(deliveryCallCount, 0)
    }

    func testSafeSendSuppressionIsReported() async {
        let capture = FakeCapture()
        let transcript = FakeTranscript(text: "hello")
        let delivery = FakeDelivery(disposition: .sendSuppressed("unknown destination"))
        let workflow = makeWorkflow(capture: capture, transcript: transcript, delivery: delivery)

        await workflow.start()
        await workflow.stop()

        let phase = await workflow.phase
        let disposition = await workflow.lastDeliveryDisposition
        XCTAssertEqual(phase, .ready)
        XCTAssertEqual(disposition, .sendSuppressed("unknown destination"))
    }

    func testDeliveryDispositionsPreservePermissionNoTargetAndPasteFailure() async {
        let dispositions: [AutoSendDeliveryDisposition] = [
            .permissionRequired("Accessibility required."),
            .noPasteTarget("No editable field."),
            .pasteFailed("Paste event failed.")
        ]

        for expected in dispositions {
            let workflow = makeWorkflow(
                capture: FakeCapture(),
                transcript: FakeTranscript(text: "hello"),
                delivery: FakeDelivery(disposition: expected)
            )
            await workflow.start()
            await workflow.stop()
            let actual = await workflow.lastDeliveryDisposition
            XCTAssertEqual(actual, expected)
        }
    }

    func testArchiveKeepsTheTextOfAPasteFailureOnlyWhenItReachedTheClipboard() async {
        let cases: [(AutoSendDeliveryDisposition, String?)] = [
            (.copiedAfterPasteFailed("Copied to clipboard. Paste failed."), "hello"),
            (.pasteFailed("Could not paste or copy the transcript. Paste failed."), nil)
        ]

        for (disposition, expectedDeliveredText) in cases {
            let archived = EvidenceCollector()
            let workflow = AutoSendWorkflow(environment: AutoSendWorkflowEnvironment(
                capture: FakeCapture(),
                transcription: FakeTranscript(text: "hello"),
                delivery: FakeDelivery(disposition: disposition),
                archive: { archived.append($0) }
            ))
            await workflow.start()
            await workflow.stop()

            XCTAssertEqual(archived.values.map(\.deliveredText), [expectedDeliveredText], "\(disposition)")
            XCTAssertEqual(archived.values.map(\.disposition), [disposition])
        }
    }

    func testWorkflowPublishesDeliveringBeforeReady() async {
        let phases = PhaseCollector()
        let workflow = AutoSendWorkflow(environment: AutoSendWorkflowEnvironment(
            capture: FakeCapture(),
            transcription: FakeTranscript(text: "hello"),
            delivery: FakeDelivery(disposition: .sent),
            runDidChange: { phases.append($0.phase) }
        ))

        await workflow.start()
        await workflow.stop()

        XCTAssertEqual(phases.values, [.starting, .recording, .transcribing, .delivering, .ready])
    }

    func testTypedMicrophoneErrorSetsPermissionFailureKind() async {
        let workflow = makeWorkflow(
            capture: FakeCapture(startError: AutoSendRecorderProductError.microphoneDenied),
            transcript: FakeTranscript(text: "must not run"),
            delivery: FakeDelivery(disposition: .sent)
        )

        await workflow.start()

        let failureKind = await workflow.lastFailureKind
        XCTAssertEqual(failureKind, .microphonePermission)
    }

    func testMicrophonePermissionTimeoutDoesNotWaitForSuspendedRequest() async {
        let request = SuspendedPermissionRequest()
        let startedAt = ContinuousClock.now
        let result = await AutoSendMicrophonePermissionRequest.resolve(
            timeoutNanoseconds: 20_000_000,
            request: { await request.run() }
        )
        request.resume()

        XCTAssertEqual(result, .timedOut)
        XCTAssertLessThan(startedAt.duration(to: .now), .seconds(1))
    }

    func testMicrophonePermissionResultWinsBeforeTimeout() async {
        let result = await AutoSendMicrophonePermissionRequest.resolve(
            timeoutNanoseconds: 1_000_000_000,
            request: { .denied }
        )

        XCTAssertEqual(result, .denied)
    }

    func testTypedMicrophoneTimeoutSetsPermissionFailureKind() async {
        let workflow = makeWorkflow(
            capture: FakeCapture(startError: AutoSendRecorderProductError.microphoneRequestTimedOut),
            transcript: FakeTranscript(text: "must not run"),
            delivery: FakeDelivery(disposition: .sent)
        )

        await workflow.start()

        let failureKind = await workflow.lastFailureKind
        XCTAssertEqual(failureKind, .microphonePermission)
    }

    func testCancelledOldTranscriptionCannotSendAfterNewRecordingStarts() async {
        let operationOne = AutoSendOperationID(rawValue: 1)
        let capture = FakeCapture()
        let transcript = ControlledTranscript()
        let delivery = FakeDelivery(disposition: .sent)
        let workflow = AutoSendWorkflow(environment: AutoSendWorkflowEnvironment(
            capture: capture,
            transcription: transcript,
            delivery: delivery
        ))

        await workflow.start()
        let oldStop = Task { await workflow.stop() }
        await transcript.waitUntilTranscribing(operationID: operationOne)
        await workflow.cancel()
        await workflow.start()
        await transcript.resume(operationID: operationOne, text: "stale text")
        _ = await oldStop.value

        let phase = await workflow.phase
        let deliveryCount = await delivery.deliverCallCount
        XCTAssertEqual(phase, .recording)
        XCTAssertEqual(deliveryCount, 0)
    }

    func testStaleStartCleanupDoesNotCancelNewRecording() async {
        let operationOne = AutoSendOperationID(rawValue: 1)
        let operationTwo = AutoSendOperationID(rawValue: 2)
        let capture = ControlledStartCapture(suspendedOperationID: operationOne)
        let workflow = AutoSendWorkflow(environment: AutoSendWorkflowEnvironment(
            capture: capture,
            transcription: FakeTranscript(text: "hello"),
            delivery: FakeDelivery(disposition: .sent)
        ))

        let staleStart = Task { await workflow.start() }
        await capture.waitUntilStartIsSuspended()
        await workflow.cancel()
        await workflow.start()
        await capture.resumeSuspendedStart()
        await staleStart.value

        let phase = await workflow.phase
        let activeOperation = await capture.activeOperationID
        let cancelledOperations = await capture.cancelledOperationIDs
        XCTAssertEqual(phase, .recording)
        XCTAssertEqual(activeOperation, operationTwo)
        XCTAssertTrue(cancelledOperations.contains(operationOne))
        XCTAssertFalse(cancelledOperations.contains(operationTwo))
    }

    func testCancelDuringDeliveryPreventsSendAndOldStopCannotLeaveIdle() async {
        let delivery = ControlledDelivery()
        let phases = PhaseCollector()
        let workflow = AutoSendWorkflow(environment: AutoSendWorkflowEnvironment(
            capture: FakeCapture(),
            transcription: FakeTranscript(text: "do not send"),
            delivery: delivery,
            runDidChange: { phases.append($0.phase) }
        ))

        await workflow.start()
        let oldStop = Task { await workflow.stop() }
        await delivery.waitUntilDelivering()
        await workflow.cancel()
        let oldStopCompletedCurrentOperation = await oldStop.value

        let phase = await workflow.phase
        let sendCount = await delivery.sendCount
        XCTAssertFalse(oldStopCompletedCurrentOperation)
        XCTAssertEqual(sendCount, 0)
        XCTAssertEqual(phase, .idle)
        XCTAssertEqual(phases.values.last, .idle)
    }

    func testWhatsAppDefaultsToDoNotSendInSeparateDefaultsDomain() async {
        await MainActor.run {
            let suite = "AutoSendRecorderTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            let store = AutoSendSettingsStore(defaults: defaults)

            XCTAssertEqual(AutoSendSettingsStore.defaultsSuiteName, "com.turfterrace.autosendrecorder")
            XCTAssertEqual(store.action(for: "net.whatsapp.WhatsApp"), .doNotSend)
        }
    }

    func testDefaultInitializerReadsChosenPreferencesDomain() async {
        await MainActor.run {
            // Read only: never alter the user's real preferences during tests.
            let expected = AutoSendSettingsStore(defaults: UserDefaults(suiteName: "com.turfterrace.autosendrecorder"))
            let actual = AutoSendSettingsStore()
            XCTAssertEqual(actual.triggerMode, expected.triggerMode)
            XCTAssertEqual(actual.preferredMicrophoneID, expected.preferredMicrophoneID)
            XCTAssertEqual(actual.hasCompletedOnboarding, expected.hasCompletedOnboarding)
            XCTAssertEqual(actual.recordingShortcut, expected.recordingShortcut)
        }
    }

    func testMicrophonePermissionMessageUsesAutoSendRecorderBrand() {
        let message = AutoSendRecorderProductError.microphoneDenied.localizedDescription

        XCTAssertEqual(
            message,
            "Microphone access is required. Enable it for Auto Send Recorder in System Settings."
        )
        XCTAssertFalse(message.contains("Auto Improve Recorder"))
        XCTAssertFalse(message.contains("AutoImproveRecorder"))
    }

    func testMicrophonePermissionTimeoutMessageExplainsRecovery() {
        let message = AutoSendRecorderProductError.microphoneRequestTimedOut.localizedDescription

        XCTAssertEqual(
            message,
            "The microphone permission request did not finish. Quit and reopen Auto Send Recorder, then try again."
        )
    }

    private func makeWorkflow(
        capture: FakeCapture,
        transcript: FakeTranscript,
        delivery: FakeDelivery,
        normalize: @escaping @Sendable (String) -> String = { $0 }
    ) -> AutoSendWorkflow {
        AutoSendWorkflow(environment: AutoSendWorkflowEnvironment(
            capture: capture,
            transcription: transcript,
            delivery: delivery,
            processTranscript: { AutoSendProcessedTranscript(afterRules: $0, final: normalize($0)) }
        ))
    }
}

/// The run snapshot the workflow publishes, and the one mapping from it to what the user sees.
final class AutoSendRunSnapshotTests: XCTestCase {
    func testEverySnapshotOfASentRunIsCompleteAndInOrder() async {
        let snapshots = SnapshotCollector()
        let workflow = AutoSendWorkflow(environment: AutoSendWorkflowEnvironment(
            capture: FakeCapture(),
            transcription: FakeTranscript(text: "hello"),
            delivery: FakeDelivery(disposition: .sent),
            runDidChange: { snapshots.append($0) }
        ))

        await workflow.start()
        await workflow.stop()

        let published = snapshots.values
        XCTAssertEqual(published.map(\.sequence), [1, 2, 3, 4, 5])
        XCTAssertEqual(published.map(\.phase), [.starting, .recording, .transcribing, .delivering, .ready])
        XCTAssertEqual(published.map(\.lastText), ["", "", "", "hello", "hello"])
        XCTAssertEqual(published.map(\.deliveryDisposition), [nil, nil, nil, nil, .sent])
        let current = await workflow.snapshot
        XCTAssertEqual(current, published.last)
    }

    func testStartingSnapshotCarriesNothingFromThePreviousRun() async {
        let snapshots = SnapshotCollector()
        let workflow = AutoSendWorkflow(environment: AutoSendWorkflowEnvironment(
            capture: FakeCapture(),
            transcription: FakeTranscript(text: "first run"),
            delivery: FakeDelivery(disposition: .sent),
            runDidChange: { snapshots.append($0) }
        ))
        await workflow.start()
        await workflow.stop()

        await workflow.start()

        let starting = snapshots.values.last { $0.phase == .starting }
        XCTAssertEqual(starting?.lastText, "")
        XCTAssertNil(starting?.deliveryDisposition)
        XCTAssertNil(starting?.failureKind)
        XCTAssertEqual(starting?.wasCancelled, false)
    }

    func testCancelledRunIsShownAsCancelledUntilTheNextRunStarts() async {
        let workflow = AutoSendWorkflow(environment: AutoSendWorkflowEnvironment(
            capture: FakeCapture(),
            transcription: FakeTranscript(text: "unused"),
            delivery: FakeDelivery(disposition: .sent)
        ))
        await workflow.start()

        await workflow.cancel()

        let cancelled = await workflow.snapshot
        XCTAssertEqual(cancelled.phase, .idle)
        XCTAssertEqual(
            present(cancelled),
            AutoSendRunPresentation(
                experienceState: .cancelled,
                statusMessage: "Cancelled. Saved recordings were not deleted."
            )
        )

        await workflow.start()

        let restarted = await workflow.snapshot
        XCTAssertFalse(restarted.wasCancelled)
        XCTAssertEqual(present(restarted).experienceState, .recording)
    }

    func testMicrophonePermissionFailureIsShownAsPermissionNeeded() async {
        let workflow = AutoSendWorkflow(environment: AutoSendWorkflowEnvironment(
            capture: FakeCapture(startError: AutoSendRecorderProductError.microphoneDenied),
            transcription: FakeTranscript(text: "must not run"),
            delivery: FakeDelivery(disposition: .sent)
        ))

        await workflow.start()

        let failed = await workflow.snapshot
        let message = AutoSendRecorderProductError.microphoneDenied.localizedDescription
        XCTAssertEqual(
            present(failed),
            AutoSendRunPresentation(experienceState: .permissionNeeded(message), statusMessage: message)
        )
    }

    func testOtherFailuresAreShownAsFailedWithTheirMessage() {
        var snapshot = AutoSendRunSnapshot()
        snapshot.phase = .failed("capture failed")
        snapshot.failureKind = .recording

        XCTAssertEqual(
            present(snapshot),
            AutoSendRunPresentation(experienceState: .failed("capture failed"), statusMessage: "capture failed")
        )
    }

    func testEachDeliveryDispositionHasOnePresentation() {
        let cases: [(AutoSendDeliveryDisposition?, AutoSendExperienceState, String)] = [
            (.sent, .sent, "Pasted and sent."),
            (.pastedWithoutSending, .pastedWithoutSend, "Pasted. Sending is off for this app."),
            (.sendSuppressed("Send held back."), .suppressed, "Send held back."),
            (.noPasteTarget("No text field."), .noTarget("No text field."), "No text field."),
            (.copied("Copied to clipboard."), .pastedWithoutSend, "Copied to clipboard."),
            (.permissionRequired("Allow access."), .permissionNeeded("Allow access."), "Allow access."),
            (.pasteFailed("Paste failed."), .failed("Paste failed."), "Paste failed."),
            (
                .copiedAfterPasteFailed("Copied to clipboard. Paste failed."),
                .failed("Copied to clipboard. Paste failed."),
                "Copied to clipboard. Paste failed."
            ),
            (nil, .pastedWithoutSend, "Transcript ready.")
        ]

        for (disposition, experienceState, statusMessage) in cases {
            var snapshot = AutoSendRunSnapshot()
            snapshot.phase = .ready
            snapshot.deliveryDisposition = disposition
            XCTAssertEqual(
                present(snapshot),
                AutoSendRunPresentation(experienceState: experienceState, statusMessage: statusMessage),
                "\(String(describing: disposition))"
            )
        }
    }

    func testBusyPhasesHaveFixedPresentations() {
        let cases: [(AutoSendPhase, AutoSendExperienceState, String)] = [
            (.starting, .starting, "Listening..."),
            (.transcribing, .finalizing, "Finishing and sending..."),
            (.delivering, .delivering, "Pasting transcript...")
        ]

        for (phase, experienceState, statusMessage) in cases {
            var snapshot = AutoSendRunSnapshot()
            snapshot.phase = phase
            XCTAssertEqual(
                present(snapshot),
                AutoSendRunPresentation(experienceState: experienceState, statusMessage: statusMessage)
            )
        }
    }

    func testIdleAndRecordingMessagesFollowTheTriggerModeAndLatch() {
        var snapshot = AutoSendRunSnapshot()

        XCTAssertEqual(
            present(snapshot, triggerMode: .walkieTalkie).statusMessage,
            "Ready. Hold Hyper-R to record and release to send, or press Space to lock it."
        )
        XCTAssertEqual(
            present(snapshot, triggerMode: .toggle).statusMessage,
            "Ready. Press Hyper-R to start, then press again to send."
        )

        snapshot.phase = .recording
        XCTAssertEqual(
            present(snapshot, triggerMode: .walkieTalkie).statusMessage,
            "Recording. Release Hyper-R to send, or press Space to lock it."
        )
        XCTAssertEqual(
            present(snapshot, triggerMode: .walkieTalkie, isLatched: true).statusMessage,
            "Recording locked. Press Hyper-R to send."
        )
        XCTAssertEqual(
            present(snapshot, triggerMode: .toggle, isLatched: true).statusMessage,
            "Recording. Press Hyper-R again to send."
        )
    }

    func testStartAndStopAreAcceptedInTheSamePhasesTheWorkflowAcceptsThem() {
        let phases: [AutoSendPhase] = [
            .idle, .starting, .recording, .transcribing, .delivering, .ready, .failed("x")
        ]

        XCTAssertEqual(phases.filter(\.acceptsStart), [.idle, .ready, .failed("x")])
        XCTAssertEqual(phases.filter(\.acceptsStop), [.recording])
    }

    private func present(
        _ snapshot: AutoSendRunSnapshot,
        triggerMode: AutoSendTriggerMode = .walkieTalkie,
        isLatched: Bool = false
    ) -> AutoSendRunPresentation {
        snapshot.presentation(triggerMode: triggerMode, shortcutName: "Hyper-R", isLatched: isLatched)
    }
}

private final class SnapshotCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [AutoSendRunSnapshot] = []

    var values: [AutoSendRunSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }

    func append(_ snapshot: AutoSendRunSnapshot) {
        lock.lock()
        storedValues.append(snapshot)
        lock.unlock()
    }
}

private enum TestError: LocalizedError {
    case capture
    case captureGap
    case archiveOpen
    case archiveWrite
    case archiveFinish
    case live

    var errorDescription: String? {
        switch self {
        case .capture: return "capture failed"
        case .captureGap: return "capture gap; audio kept"
        case .archiveOpen: return "archive open failed; live transcript discarded"
        case .archiveWrite: return "archive write failed; live transcript discarded"
        case .archiveFinish: return "archive finish failed; live transcript discarded"
        case .live: return "live failed"
        }
    }
}

private actor FakeCapture: AutoSendCaptureService {
    let startError: Error?
    let stopError: Error?
    private(set) var wasCancelled = false
    private(set) var startedSource: AutoSendRecordingSource?

    init(startError: Error? = nil, stopError: Error? = nil) {
        self.startError = startError
        self.stopError = stopError
    }

    func start(
        operationID: AutoSendOperationID,
        source: AutoSendRecordingSource
    ) async throws {
        startedSource = source
        if let startError { throw startError }
    }

    func stop(operationID: AutoSendOperationID) async throws -> URL {
        if let stopError { throw stopError }
        return URL(fileURLWithPath: "/tmp/kept.wav")
    }

    func cancel(operationID: AutoSendOperationID) async {
        wasCancelled = true
    }
}

private actor FakeTranscript: AutoSendTranscriptService {
    let text: String
    private(set) var callCount = 0
    private(set) var wasCancelled = false

    init(text: String) {
        self.text = text
    }

    func transcribe(audioURL: URL, operationID: AutoSendOperationID) async throws -> String {
        callCount += 1
        return text
    }

    func cancel(operationID: AutoSendOperationID) async {
        wasCancelled = true
    }
}

private actor FakeDelivery: AutoSendDeliveryService {
    let disposition: AutoSendDeliveryDisposition
    private(set) var deliveredText: String?
    private(set) var deliverCallCount = 0

    init(disposition: AutoSendDeliveryDisposition) {
        self.disposition = disposition
    }

    func deliver(text: String) async throws -> AutoSendDeliveryDisposition {
        deliverCallCount += 1
        deliveredText = text
        return disposition
    }
}

private final class EvidenceCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [AutoSendTranscriptEvidence] = []

    var values: [AutoSendTranscriptEvidence] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }

    func append(_ evidence: AutoSendTranscriptEvidence) {
        lock.lock()
        storedValues.append(evidence)
        lock.unlock()
    }
}

private final class PhaseCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [AutoSendPhase] = []

    var values: [AutoSendPhase] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }

    func append(_ phase: AutoSendPhase) {
        lock.lock()
        storedValues.append(phase)
        lock.unlock()
    }
}

private actor ControlledTranscript: AutoSendTranscriptService {
    private var started: Set<AutoSendOperationID> = []
    private var startWaiters: [AutoSendOperationID: CheckedContinuation<Void, Never>] = [:]
    private var transcriptContinuations: [AutoSendOperationID: CheckedContinuation<String, Never>] = [:]

    func transcribe(audioURL: URL, operationID: AutoSendOperationID) async throws -> String {
        started.insert(operationID)
        startWaiters.removeValue(forKey: operationID)?.resume()
        return await withCheckedContinuation { continuation in
            transcriptContinuations[operationID] = continuation
        }
    }

    func cancel(operationID: AutoSendOperationID) async {
        // Deliberately non-cooperative. The workflow generation must reject its late result.
    }

    func waitUntilTranscribing(operationID: AutoSendOperationID) async {
        if started.contains(operationID) { return }
        await withCheckedContinuation { continuation in
            startWaiters[operationID] = continuation
        }
    }

    func resume(operationID: AutoSendOperationID, text: String) {
        transcriptContinuations.removeValue(forKey: operationID)?.resume(returning: text)
    }
}

private actor ControlledStartCapture: AutoSendCaptureService {
    let suspendedOperationID: AutoSendOperationID
    private(set) var activeOperationID: AutoSendOperationID?
    private(set) var cancelledOperationIDs: [AutoSendOperationID] = []
    private var startIsSuspended = false
    private var suspensionWaiter: CheckedContinuation<Void, Never>?
    private var startContinuation: CheckedContinuation<Void, Never>?

    init(suspendedOperationID: AutoSendOperationID) {
        self.suspendedOperationID = suspendedOperationID
    }

    func start(
        operationID: AutoSendOperationID,
        source: AutoSendRecordingSource
    ) async throws {
        if operationID == suspendedOperationID {
            startIsSuspended = true
            suspensionWaiter?.resume()
            suspensionWaiter = nil
            await withCheckedContinuation { continuation in
                startContinuation = continuation
            }
        }
        if activeOperationID == nil {
            activeOperationID = operationID
        }
    }

    func stop(operationID: AutoSendOperationID) async throws -> URL {
        if activeOperationID == operationID {
            activeOperationID = nil
        }
        return URL(fileURLWithPath: "/tmp/kept.wav")
    }

    func cancel(operationID: AutoSendOperationID) async {
        cancelledOperationIDs.append(operationID)
        if activeOperationID == operationID {
            activeOperationID = nil
        }
    }

    func waitUntilStartIsSuspended() async {
        if startIsSuspended { return }
        await withCheckedContinuation { continuation in
            suspensionWaiter = continuation
        }
    }

    func resumeSuspendedStart() {
        startContinuation?.resume()
        startContinuation = nil
    }
}

private actor ControlledDelivery: AutoSendDeliveryService {
    private var delivering = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var sendCount = 0

    func deliver(text: String) async throws -> AutoSendDeliveryDisposition {
        delivering = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        do {
            try await Task.sleep(nanoseconds: 10_000_000_000)
        } catch {
            return .sendSuppressed("Delivery was cancelled.")
        }
        sendCount += 1
        return .sent
    }

    func waitUntilDelivering() async {
        if delivering { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private final class SuspendedPermissionRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AutoSendMicrophonePermissionOutcome, Never>?

    func run() async -> AutoSendMicrophonePermissionOutcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resume() {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: .granted)
    }
}
