import AppKit
import Foundation
import XCTest
@testable import AutoSendRecorderCore

final class AutoSendWorkflowTests: XCTestCase {
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

    func testESP32MicrophoneIsPreferredWhenAvailable() {
        let selectedIndex = AutoSendMicrophoneSelection.preferredDeviceIndex(
            source: .esp32Button,
            availableDevices: [
                ("boya", "BOYA mini 2"),
                ("AppleUSBAudioEngine:Espressif Systems:ESP32S3_DEV:288485910484:4", "TinyUSB UAC1"),
                ("built-in", "Mac mini Microphone")
            ]
        )

        XCTAssertEqual(selectedIndex, 1)
    }

    func testESP32MicrophoneSelectionIsCaseInsensitive() {
        let selectedIndex = AutoSendMicrophoneSelection.preferredDeviceIndex(
            source: .esp32Button,
            availableDevices: [("usb:288485910484:4", "tinyusb uac1")]
        )

        XCTAssertEqual(selectedIndex, 0)
    }

    func testSystemDefaultRemainsWhenESP32MicrophoneIsUnavailable() {
        let selectedIndex = AutoSendMicrophoneSelection.preferredDeviceIndex(
            source: .esp32Button,
            availableDevices: [("boya", "BOYA mini 2"), ("built-in", "Mac mini Microphone")]
        )

        XCTAssertNil(selectedIndex)
    }

    func testSystemDefaultRemainsWhenESP32MicrophoneIdentityIsAmbiguous() {
        let selectedIndex = AutoSendMicrophoneSelection.preferredDeviceIndex(
            source: .esp32Button,
            availableDevices: [
                ("usb:288485910484:4", "TinyUSB UAC1"),
                ("usb:288485910484:5", "TinyUSB UAC1")
            ]
        )

        XCTAssertNil(selectedIndex)
    }

    func testMacHotKeyKeepsTheNormalMicrophone() {
        let selectedIndex = AutoSendMicrophoneSelection.preferredDeviceIndex(
            source: .macHotKey,
            availableDevices: [
                ("usb:288485910484:4", "TinyUSB UAC1"),
                ("built-in", "Mac mini Microphone")
            ]
        )

        XCTAssertNil(selectedIndex)
    }

    func testMacHotKeyUsesSavedMicrophone() {
        let selectedIndex = AutoSendMicrophoneSelection.preferredDeviceIndex(
            source: .macHotKey,
            availableDevices: [
                ("boya", "BOYA mini 2"),
                ("anker", "Anker PowerConf C200")
            ],
            preferredMicrophoneID: "boya"
        )

        XCTAssertEqual(selectedIndex, 0)
    }

    func testSavedMicrophoneMustMatchOneDevice() {
        let selectedIndex = AutoSendMicrophoneSelection.preferredDeviceIndex(
            source: .macHotKey,
            availableDevices: [("anker", "Anker PowerConf C200")],
            preferredMicrophoneID: "boya"
        )

        XCTAssertNil(selectedIndex)
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

    func testLiveFailureUsesIntactOneShotFallback() async throws {
        let oneShot = FakeOneShot(text: "fallback transcript")
        let pipeline = AutoSendParakeetFallbackPipeline(oneShot: oneShot)
        let url = URL(fileURLWithPath: "/tmp/intact.wav")

        let result = try await pipeline.transcribe(
            liveSession: FailingLiveSession(),
            audioURL: url
        )

        XCTAssertEqual(result, "fallback transcript")
        let receivedURL = await oneShot.receivedURL
        XCTAssertEqual(receivedURL, url)
    }

    func testESP32UsesFastResidentTranscriptInsteadOfLiveStream() async throws {
        let fastResident = FakeOneShot(text: "accurate fast transcript")
        let oneShotFallback = FakeOneShot(text: "slow fallback")
        let pipeline = AutoSendSourceAwareTranscriptionPipeline(
            fastWireless: fastResident,
            fallback: AutoSendParakeetFallbackPipeline(oneShot: oneShotFallback)
        )
        let url = URL(fileURLWithPath: "/tmp/wireless.wav")

        let result = try await pipeline.transcribe(
            source: .esp32Button,
            liveSession: SuccessfulLiveSession(text: "inaccurate live transcript"),
            audioURL: url
        )

        XCTAssertEqual(result, "accurate fast transcript")
        let fastURL = await fastResident.receivedURL
        let fallbackURL = await oneShotFallback.receivedURL
        XCTAssertEqual(fastURL, url)
        XCTAssertNil(fallbackURL)
    }

    func testMacHotKeyKeepsLiveStreamingTranscript() async throws {
        let fastResident = FakeOneShot(text: "must not be used")
        let oneShotFallback = FakeOneShot(text: "slow fallback")
        let pipeline = AutoSendSourceAwareTranscriptionPipeline(
            fastWireless: fastResident,
            fallback: AutoSendParakeetFallbackPipeline(oneShot: oneShotFallback)
        )

        let result = try await pipeline.transcribe(
            source: .macHotKey,
            liveSession: SuccessfulLiveSession(text: "live transcript"),
            audioURL: URL(fileURLWithPath: "/tmp/mac.wav")
        )

        XCTAssertEqual(result, "live transcript")
        let fastURL = await fastResident.receivedURL
        let fallbackURL = await oneShotFallback.receivedURL
        XCTAssertNil(fastURL)
        XCTAssertNil(fallbackURL)
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

    func testWorkflowPublishesDeliveringBeforeReady() async {
        let phases = PhaseCollector()
        let workflow = AutoSendWorkflow(environment: AutoSendWorkflowEnvironment(
            capture: FakeCapture(),
            transcription: FakeTranscript(text: "hello"),
            delivery: FakeDelivery(disposition: .sent),
            normalize: { $0 },
            phaseDidChange: { phases.append($0.phase) }
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
            delivery: delivery,
            normalize: { $0 }
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
            delivery: FakeDelivery(disposition: .sent),
            normalize: { $0 }
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
            normalize: { $0 },
            phaseDidChange: { phases.append($0.phase) }
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
            normalize: normalize
        ))
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

private struct FailingLiveSession: AutoSendLiveTranscriptFinalizing {
    func finalize() async throws -> String { throw TestError.live }
    func cancel() {}
}

private struct SuccessfulLiveSession: AutoSendLiveTranscriptFinalizing {
    let text: String

    func finalize() async throws -> String { text }
    func cancel() {}
}

private actor FakeOneShot: AutoSendOneShotTranscribing {
    let text: String
    private(set) var receivedURL: URL?

    init(text: String) {
        self.text = text
    }

    func transcribe(audioURL: URL) async throws -> String {
        receivedURL = audioURL
        return text
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
