import AppKit
import AVFoundation
import Foundation

final class AutoSendRecordingService: AutoSendCaptureService, @unchecked Sendable {
    private let recorder: AudioRecorder
    private let wirelessProvider: @Sendable () -> AutoSendWirelessBridge
    private let transcription: AutoSendParakeetService
    private let stateLock = NSLock()
    private let recorderLock = NSLock()
    private let permissionTimeoutNanoseconds: UInt64
    private let permissionRequest: @Sendable () async -> AutoSendMicrophonePermissionOutcome
    private var currentOperationID: AutoSendOperationID?
    private var currentSource: AutoSendRecordingSource?
    private var terminalCaptureFailure: (AutoSendOperationID, AudioCaptureFailure)?
    private var terminalRecoveryFailure: (AutoSendOperationID, String)?
    private var activeRecordingURL: (AutoSendOperationID, URL)?
    private var preferredMicrophoneID: String
    private var microphoneRecovery = MicrophoneRecovery(retryCooldown: 30)
    private let microphoneUseLock = AutoSendMicrophoneUseLock()
    private let backupRecorder: BackupMicrophoneRecorder
    private let backupMicrophoneEnabled: @Sendable () -> Bool
    private var microphoneWarningHandler: (@Sendable (AutoSendOperationID, AutoSendMicrophoneWarning) -> Void)?
    /// The current recording's backup, from the moment its start is requested. `isRunning`
    /// becomes true when the backup microphone has opened.
    private var activeBackup: (operationID: AutoSendOperationID, microphoneName: String, isRunning: Bool)?
    /// The repeating check that the main microphone is still delivering buffers. It runs only
    /// while recording.
    private var silenceCheckTimer: DispatchSourceTimer?
    /// The stopped recording's backup, held until the workflow asks for it.
    private var stoppedBackup: (
        operationID: AutoSendOperationID,
        stop: BackupMicrophoneStop,
        microphoneName: String,
        primaryWasSilent: Bool
    )?
    /// The newest operation whose main microphone the silence watch reported.
    private var silenceReportedOperationID: AutoSendOperationID?

    init(
        recorder: AudioRecorder = AudioRecorder(),
        backupRecorder: BackupMicrophoneRecorder = BackupMicrophoneRecorder(),
        backupMicrophoneEnabled: @escaping @Sendable () -> Bool = {
            AutoSendSettingsStore.backupMicrophoneRecordingEnabled()
        },
        wirelessProvider: @escaping @Sendable () -> AutoSendWirelessBridge = { .shared },
        transcription: AutoSendParakeetService,
        preferredMicrophoneID: String = "",
        permissionTimeoutNanoseconds: UInt64 = AutoSendMicrophonePermissionRequest.defaultTimeoutNanoseconds,
        permissionRequest: @escaping @Sendable () async -> AutoSendMicrophonePermissionOutcome = {
            await AutoSendRecordingService.requestSystemMicrophonePermission()
        }
    ) {
        self.recorder = recorder
        self.backupRecorder = backupRecorder
        self.backupMicrophoneEnabled = backupMicrophoneEnabled
        self.wirelessProvider = wirelessProvider
        self.transcription = transcription
        self.preferredMicrophoneID = preferredMicrophoneID
        self.permissionTimeoutNanoseconds = permissionTimeoutNanoseconds
        self.permissionRequest = permissionRequest
    }

    func updatePreferredMicrophoneID(_ id: String) {
        stateLock.lock()
        preferredMicrophoneID = id
        stateLock.unlock()
    }

    /// Receives the first silent-microphone report of each recording. It runs on the audio thread.
    func setMicrophoneWarningHandler(
        _ handler: @escaping @Sendable (AutoSendOperationID, AutoSendMicrophoneWarning) -> Void
    ) {
        stateLock.lock()
        microphoneWarningHandler = handler
        stateLock.unlock()
    }

    func start(
        operationID: AutoSendOperationID,
        source: AutoSendRecordingSource
    ) async throws {
        guard claim(operationID, source: source) else {
            throw AutoSendRecordingError.operationSuperseded
        }
        if source == .esp32Button {
            let wireless = wirelessProvider()
            do {
                let url = try makeRecordingURL()
                transcription.beginRecording(operationID: operationID, source: source)
                resetCaptureFailure(operationID: operationID)
                try wireless.startCapture(
                    at: url,
                    streamHandler: { [weak self, weak transcription] event in
                        guard let self, self.isCurrent(operationID) else { return }
                        if case .failure(let failure) = event {
                            self.recordTerminalCaptureFailure(failure, operationID: operationID)
                        }
                        transcription?.handleCaptureEvent(event, operationID: operationID)
                    }
                )
                return
            } catch {
                clearIfCurrent(operationID)
                await transcription.cancel(operationID: operationID)
                throw error
            }
        }
        let permission = await AutoSendMicrophonePermissionRequest.resolve(
            timeoutNanoseconds: permissionTimeoutNanoseconds,
            request: permissionRequest
        )
        switch permission {
        case .granted:
            break
        case .denied:
            clearIfCurrent(operationID)
            throw AutoSendRecorderProductError.microphoneDenied
        case .timedOut:
            clearIfCurrent(operationID)
            throw AutoSendRecorderProductError.microphoneRequestTimedOut
        case .cancelled:
            clearIfCurrent(operationID)
            throw AutoSendRecordingError.operationSuperseded
        case .failed(let message):
            clearIfCurrent(operationID)
            throw AutoSendRecorderProductError.microphoneRequestFailed(message)
        }

        guard isCurrent(operationID) else {
            throw AutoSendRecordingError.operationSuperseded
        }

        do {
            try withRecorderLock {
                guard isCurrent(operationID) else {
                    throw AutoSendRecordingError.operationSuperseded
                }
                let url = try makeRecordingURL()
                let devices = AudioInputDeviceDiscovery.inputDevices()
                let resolution = try resolveMicrophone(devices: devices)
                let healthMonitor = healthMonitor(for: resolution, source: source)
                // With the switch off there is no backup and no silence watch.
                let silenceWatch = backupMicrophoneEnabled() ? MicrophoneSilenceWatch() : nil
                let primaryName = BackupMicrophoneChooser.resolvedPrimary(
                    resolution.device,
                    devices: devices
                )?.name ?? resolution.device.name
                setActiveMicrophoneResolution(resolution)
                rememberRecordingURL(url, operationID: operationID)
                microphoneUseLock.start()
                transcription.beginRecording(operationID: operationID, source: source)
                resetCaptureFailure(operationID: operationID)
                _ = try recorder.start(
                    at: url,
                    microphone: resolution.device,
                    bufferSize: AudioRecorder.fastStartBufferSize,
                    streamHandler: { [weak self, weak transcription] event in
                        guard let self, self.isCurrent(operationID) else { return }
                        if case .captured(let captured) = event,
                           let report = silenceWatch?.observePrimary(captured.buffer) {
                            self.reportSilentMicrophone(report, named: primaryName, operationID: operationID)
                        }
                        if case .captured(let captured) = event,
                           let healthEvent = healthMonitor?.observe(captured.buffer) {
                            Task { [weak self] in
                                self?.recoverFromSilentPreferredMicrophone(
                                    healthEvent,
                                    operationID: operationID,
                                    source: source,
                                    silentResolution: resolution
                                )
                            }
                        }
                        if case .failure(let failure) = event {
                            self.recordTerminalCaptureFailure(failure, operationID: operationID)
                        }
                        transcription?.handleCaptureEvent(event, operationID: operationID)
                    }
                )
                // The main recorder is running. The backup is chosen now and opens on its own queue.
                if let silenceWatch {
                    startSilenceChecks(silenceWatch, primaryName: primaryName, operationID: operationID)
                }
                if let silenceWatch,
                   let backupDevice = BackupMicrophoneChooser.chooseBackup(
                       primary: resolution.device,
                       devices: devices,
                       isEnabled: true,
                       preferredName: AutoSendMicrophoneSelection.ankerMicrophoneName
                   ) {
                    startBackup(
                        on: backupDevice,
                        mainRecordingURL: url,
                        silenceWatch: silenceWatch,
                        primaryName: primaryName,
                        operationID: operationID
                    )
                }
            }
        } catch {
            microphoneUseLock.stop()
            clearIfCurrent(operationID)
            await transcription.cancel(operationID: operationID)
            throw error
        }
    }

    func stop(operationID: AutoSendOperationID) async throws -> URL {
        if source(for: operationID) == .esp32Button {
            let url = try wirelessProvider().stopCapture()
            clearIfCurrent(operationID)
            return url
        }
        let result = try withRecorderLock {
            guard isCurrent(operationID) else {
                throw AutoSendRecordingError.operationSuperseded
            }
            let result = recorder.stopWithResult()
            microphoneUseLock.stop()
            clearIfCurrent(operationID)
            return result
        }
        // The main recorder has stopped. The backup stops on its own queue.
        beginBackupStop(operationID: operationID)
        let rememberedURL = takeRecordingURL(operationID: operationID)
        guard let url = result.audioURL ?? rememberedURL else {
            throw AutoSendRecordingError.noActiveRecording
        }
        if let recoveryFailure = takeRecoveryFailure(operationID: operationID) {
            await transcription.cancel(operationID: operationID)
            throw AutoSendRecordingError.captureFailed(
                audioURL: url,
                message: recoveryFailure
            )
        }
        let captureFailure = takeCaptureFailure(operationID: operationID)
        if let archiveFailure = result.archiveFailureMessage {
            await transcription.cancel(operationID: operationID)
            throw AutoSendRecordingError.archiveFailed(
                audioURL: url,
                message: archiveFailure
            )
        }
        if let captureFailure {
            await transcription.cancel(operationID: operationID)
            throw AutoSendRecordingError.captureFailed(
                audioURL: url,
                message: captureFailure.localizedDescription
            )
        }
        return url
    }

    func cancel(operationID: AutoSendOperationID) async {
        if source(for: operationID) == .esp32Button {
            clearIfCurrent(operationID)
            wirelessProvider().cancelCapture()
            resetCaptureFailure(operationID: operationID)
            return
        }
        withRecorderLock {
            guard isCurrent(operationID) else { return }
            clearIfCurrent(operationID)
            _ = recorder.stop()
            microphoneUseLock.stop()
            resetCaptureFailure(operationID: operationID)
            clearRecordingURL(operationID: operationID)
            resetRecoveryFailure(operationID: operationID)
        }
        discardBackup(operationID: operationID)
    }

    func backupRecording(
        operationID: AutoSendOperationID,
        mainTextIsUnusable: Bool
    ) async -> AutoSendBackupRecording? {
        stateLock.lock()
        guard let stopped = stoppedBackup, stopped.operationID == operationID else {
            stateLock.unlock()
            return nil
        }
        stoppedBackup = nil
        stateLock.unlock()
        // A usable main text with no silence report needs no backup: delete it without waiting.
        guard mainTextIsUnusable || stopped.primaryWasSilent else {
            stopped.stop.discard()
            return nil
        }
        guard let url = stopped.stop.wait() else { return nil }
        return AutoSendBackupRecording(
            audioURL: url,
            microphoneName: stopped.microphoneName,
            primaryWasSilent: stopped.primaryWasSilent
        )
    }

    private func startBackup(
        on device: MicrophoneDevice,
        mainRecordingURL: URL,
        silenceWatch: MicrophoneSilenceWatch,
        primaryName: String,
        operationID: AutoSendOperationID
    ) {
        stateLock.lock()
        activeBackup = (operationID, device.name, false)
        stateLock.unlock()
        backupRecorder.start(
            at: BackupMicrophoneRecorder.backupURL(forMainRecording: mainRecordingURL),
            microphone: device,
            onBuffer: { [weak self] buffer in
                // The backup's buffers show when the main microphone has stopped delivering any.
                if let report = silenceWatch.observeBackup(buffer) {
                    self?.reportSilentMicrophone(report, named: primaryName, operationID: operationID)
                }
            },
            onResult: { [weak self] started in
                guard let self else { return }
                var skippedRecovery: (silence: SkippedMicrophoneSilence, source: AutoSendRecordingSource)?
                self.stateLock.lock()
                if self.activeBackup?.operationID == operationID {
                    if started {
                        self.activeBackup?.isRunning = true
                        silenceWatch.backupStarted()
                    } else {
                        self.activeBackup = nil
                        if self.currentOperationID == operationID,
                           let source = self.currentSource,
                           let silence = self.microphoneRecovery.backupFailedToOpen() {
                            skippedRecovery = (silence, source)
                        }
                    }
                }
                self.stateLock.unlock()
                // A startup recovery that was skipped because of this backup runs now.
                if let skippedRecovery {
                    Task { [weak self] in
                        self?.recoverFromSilentPreferredMicrophone(
                            skippedRecovery.silence.event,
                            operationID: operationID,
                            source: skippedRecovery.source,
                            silentResolution: skippedRecovery.silence.resolution
                        )
                    }
                }
            }
        )
    }

    private func takeActiveBackup(
        operationID: AutoSendOperationID
    ) -> (microphoneName: String, primaryWasSilent: Bool)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let backup = activeBackup, backup.operationID == operationID else { return nil }
        activeBackup = nil
        return (backup.microphoneName, silenceReportedOperationID == operationID)
    }

    private func beginBackupStop(operationID: AutoSendOperationID) {
        guard let backup = takeActiveBackup(operationID: operationID) else { return }
        let stop = backupRecorder.stop()
        stateLock.lock()
        stoppedBackup = (operationID, stop, backup.microphoneName, backup.primaryWasSilent)
        stateLock.unlock()
    }

    /// Deletes the backup of a cancelled recording, whether it is still running or already stopped.
    private func discardBackup(operationID: AutoSendOperationID) {
        if takeActiveBackup(operationID: operationID) != nil {
            backupRecorder.stop().discard()
        }
        stateLock.lock()
        let stopped = stoppedBackup?.operationID == operationID ? stoppedBackup : nil
        if stopped != nil {
            stoppedBackup = nil
        }
        stateLock.unlock()
        stopped?.stop.discard()
    }

    /// Checks once a second that the main microphone is still delivering buffers. The first
    /// check, made here, marks when the recording started. `stopSilenceChecks` ends it.
    private func startSilenceChecks(
        _ silenceWatch: MicrophoneSilenceWatch,
        primaryName: String,
        operationID: AutoSendOperationID
    ) {
        _ = silenceWatch.checkPrimaryDelivery(now: Date())
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.isCurrent(operationID) else { return }
            if let report = silenceWatch.checkPrimaryDelivery(now: Date()) {
                self.reportSilentMicrophone(report, named: primaryName, operationID: operationID)
            }
        }
        stateLock.lock()
        silenceCheckTimer?.cancel()
        silenceCheckTimer = timer
        stateLock.unlock()
        timer.resume()
    }

    private func stopSilenceChecks() {
        stateLock.lock()
        silenceCheckTimer?.cancel()
        silenceCheckTimer = nil
        stateLock.unlock()
    }

    private func reportSilentMicrophone(
        _ report: MicrophoneSilenceReport,
        named primaryName: String,
        operationID: AutoSendOperationID
    ) {
        stateLock.lock()
        guard currentOperationID == operationID, silenceReportedOperationID != operationID else {
            stateLock.unlock()
            return
        }
        silenceReportedOperationID = operationID
        let backupName = activeBackup?.operationID == operationID && activeBackup?.isRunning == true
            ? activeBackup?.microphoneName
            : nil
        let handler = microphoneWarningHandler
        stateLock.unlock()
        NSLog(
            "Auto Send Recorder: silent microphone report (%@) for %@; backup microphone: %@.",
            report.kind.rawValue,
            primaryName,
            backupName ?? "none"
        )
        handler?(
            operationID,
            AutoSendMicrophoneWarning(microphoneName: primaryName, backupMicrophoneName: backupName)
        )
    }

    private func claim(
        _ operationID: AutoSendOperationID,
        source: AutoSendRecordingSource
    ) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard currentOperationID == nil else { return false }
        currentOperationID = operationID
        currentSource = source
        return true
    }

    private func source(for operationID: AutoSendOperationID) -> AutoSendRecordingSource? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard currentOperationID == operationID else { return nil }
        return currentSource
    }

    private func isCurrent(_ operationID: AutoSendOperationID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return currentOperationID == operationID
    }

    private func clearIfCurrent(_ operationID: AutoSendOperationID) {
        stateLock.lock()
        if currentOperationID == operationID {
            currentOperationID = nil
            currentSource = nil
            microphoneRecovery.recordingEnded()
            silenceCheckTimer?.cancel()
            silenceCheckTimer = nil
        }
        stateLock.unlock()
    }

    private func setActiveMicrophoneResolution(_ resolution: MicrophoneResolution) {
        stateLock.lock()
        microphoneRecovery.recordingStarted(on: resolution)
        stateLock.unlock()
    }

    private func recordTerminalCaptureFailure(
        _ failure: AudioCaptureFailure,
        operationID: AutoSendOperationID
    ) {
        stateLock.lock()
        if terminalCaptureFailure == nil, currentOperationID == operationID {
            terminalCaptureFailure = (operationID, failure)
        }
        stateLock.unlock()
    }

    private func resetCaptureFailure(operationID: AutoSendOperationID) {
        stateLock.lock()
        if terminalCaptureFailure?.0 == operationID {
            terminalCaptureFailure = nil
        }
        stateLock.unlock()
    }

    private func recordRecoveryFailure(_ message: String, operationID: AutoSendOperationID) {
        stateLock.lock()
        if terminalRecoveryFailure == nil, currentOperationID == operationID {
            terminalRecoveryFailure = (operationID, message)
        }
        stateLock.unlock()
    }

    private func resetRecoveryFailure(operationID: AutoSendOperationID) {
        stateLock.lock()
        if terminalRecoveryFailure?.0 == operationID {
            terminalRecoveryFailure = nil
        }
        stateLock.unlock()
    }

    private func takeRecoveryFailure(operationID: AutoSendOperationID) -> String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard terminalRecoveryFailure?.0 == operationID else { return nil }
        let message = terminalRecoveryFailure?.1
        terminalRecoveryFailure = nil
        return message
    }

    private func rememberRecordingURL(_ url: URL, operationID: AutoSendOperationID) {
        stateLock.lock()
        if currentOperationID == operationID {
            activeRecordingURL = (operationID, url)
        }
        stateLock.unlock()
    }

    private func takeRecordingURL(operationID: AutoSendOperationID) -> URL? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard activeRecordingURL?.0 == operationID else { return nil }
        let url = activeRecordingURL?.1
        activeRecordingURL = nil
        return url
    }

    private func clearRecordingURL(operationID: AutoSendOperationID) {
        stateLock.lock()
        if activeRecordingURL?.0 == operationID {
            activeRecordingURL = nil
        }
        stateLock.unlock()
    }

    private func takeCaptureFailure(operationID: AutoSendOperationID) -> AudioCaptureFailure? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard terminalCaptureFailure?.0 == operationID else { return nil }
        let failure = terminalCaptureFailure?.1
        terminalCaptureFailure = nil
        return failure
    }

    private func withRecorderLock<T>(_ body: () throws -> T) rethrows -> T {
        recorderLock.lock()
        defer { recorderLock.unlock() }
        return try body()
    }

    private func makeRecordingURL() throws -> URL {
        let baseURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let recordingsURL = baseURL
            .appendingPathComponent("Auto Send Recorder", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(
            at: recordingsURL,
            withIntermediateDirectories: true
        )
        return recordingsURL
            .appendingPathComponent("recording-\(UUID().uuidString)")
            .appendingPathExtension("wav")
    }

    private func resolveMicrophone(
        devices: [MicrophoneDevice] = AudioInputDeviceDiscovery.inputDevices()
    ) throws -> MicrophoneResolution {
        stateLock.lock()
        let preferredID = preferredMicrophoneID
        let recovery = microphoneRecovery
        stateLock.unlock()
        let preferences = MicrophonePreferences.fromPreferredMicrophoneID(preferredID)
        if let automaticRoute = automaticBoyaRoute(
            devices: devices,
            preferredMicrophoneID: preferredID
        ) {
            return automaticRoute
        }
        let orderedDevices = devicesWithAnkerFallbackPriority(
            devices,
            preferredMicrophoneID: preferredID
        )
        return try recovery.resolve(
            preferences: preferences,
            devices: orderedDevices,
            now: Date()
        )
    }

    private func automaticBoyaRoute(
        devices: [MicrophoneDevice],
        preferredMicrophoneID: String
    ) -> MicrophoneResolution? {
        guard let preferred = devices.first(where: { $0.id == preferredMicrophoneID }),
              preferred.name.compare(
                  AutoSendMicrophoneSelection.boyaMicrophoneName,
                  options: .caseInsensitive
              ) == .orderedSame else {
            return nil
        }

        let concreteDefault = devices.first {
            !$0.isSystemDefaultPlaceholder &&
                $0.isSystemDefault &&
                $0.isConnected &&
                $0.isInputCapable
        }
        let anker = devices.first {
            $0.name.compare(
                AutoSendMicrophoneSelection.ankerMicrophoneName,
                options: .caseInsensitive
            ) == .orderedSame &&
                $0.isConnected &&
                $0.isInputCapable
        }
        guard let route = concreteDefault ?? anker else { return nil }
        let isPreferred = route.id == preferredMicrophoneID
        return MicrophoneResolution(
            requestedID: preferredMicrophoneID,
            device: route,
            usedFallback: !isPreferred,
            reason: isPreferred ? .preferredAvailable : .preferredQuarantined
        )
    }

    private func devicesWithAnkerFallbackPriority(
        _ devices: [MicrophoneDevice],
        preferredMicrophoneID: String
    ) -> [MicrophoneDevice] {
        guard let preferred = devices.first(where: { $0.id == preferredMicrophoneID }),
              preferred.name.compare(
                  AutoSendMicrophoneSelection.boyaMicrophoneName,
                  options: .caseInsensitive
              ) == .orderedSame,
              let ankerID = devices.first(where: {
                  $0.name.compare(
                      AutoSendMicrophoneSelection.ankerMicrophoneName,
                      options: .caseInsensitive
                  ) == .orderedSame
              })?.id else {
            return devices
        }
        return devices.map { device in
            guard !device.isSystemDefaultPlaceholder else { return device }
            var prioritized = device
            prioritized.isSystemDefault = device.id == ankerID
            return prioritized
        }
    }

    private func healthMonitor(
        for resolution: MicrophoneResolution,
        source: AutoSendRecordingSource
    ) -> MicrophoneHealthMonitor? {
        guard source == .macHotKey else { return nil }
        if resolution.device.name.compare(
            AutoSendMicrophoneSelection.boyaMicrophoneName,
            options: .caseInsensitive
        ) == .orderedSame {
            return nil
        }
        stateLock.lock()
        let selectedID = preferredMicrophoneID
        stateLock.unlock()
        guard MicrophoneRecovery.shouldMonitor(
            resolution,
            preferredMicrophoneID: selectedID
        ) else { return nil }
        return MicrophoneHealthMonitor(configuration: .startupFallback)
    }

    private func recoverFromSilentPreferredMicrophone(
        _ event: MicrophoneHealthEvent,
        operationID: AutoSendOperationID,
        source: AutoSendRecordingSource,
        silentResolution: MicrophoneResolution
    ) {
        stateLock.lock()
        // A recording with a backup keeps its main microphone; the backup holds the audio. The
        // event is kept, and the recovery runs if that backup then fails to open.
        if currentOperationID == operationID, activeBackup?.operationID == operationID {
            microphoneRecovery.silentMicrophoneSkippedForBackup(event, on: silentResolution)
            stateLock.unlock()
            return
        }
        guard currentOperationID == operationID,
              case .recover = microphoneRecovery.silentMicrophoneReported(
                  event,
                  on: silentResolution,
                  recheckingPreferredMicrophoneID: nil,
                  now: Date()
              ) else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        defer {
            stateLock.lock()
            microphoneRecovery.recoveryFinished()
            stateLock.unlock()
        }
        // The recorder that restarts below does not feed the silence watch, so its checks end here.
        stopSilenceChecks()

        withRecorderLock {
            guard isCurrent(operationID) else { return }
            let oldResult = recorder.stopWithResult()
            guard let url = oldResult.audioURL else {
                recordRecoveryFailure(
                    "The preferred microphone produced digital silence, but its recording could not be restarted.",
                    operationID: operationID
                )
                return
            }

            do {
                let fallback = try resolveMicrophone()
                guard case .restart = MicrophoneRecovery.restartCommand(
                    replacing: silentResolution,
                    with: fallback
                ) else {
                    throw MicrophoneResolverError.noUsableMicrophone
                }
                transcription.beginRecording(operationID: operationID, source: source)
                resetCaptureFailure(operationID: operationID)
                setActiveMicrophoneResolution(fallback)
                _ = try recorder.start(
                    at: url,
                    microphone: fallback.device,
                    bufferSize: AudioRecorder.fastStartBufferSize,
                    streamHandler: { [weak self, weak transcription] captureEvent in
                        guard let self, self.isCurrent(operationID) else { return }
                        if case .failure(let failure) = captureEvent {
                            self.recordTerminalCaptureFailure(failure, operationID: operationID)
                        }
                        transcription?.handleCaptureEvent(captureEvent, operationID: operationID)
                    }
                )
                let observedMS = Int(event.observedDuration * 1_000)
                NSLog(
                    "Auto Send Recorder: %@ produced exact digital silence for %d ms across %d buffers; using %@.",
                    silentResolution.device.name,
                    observedMS,
                    event.silentBufferCount,
                    fallback.device.name
                )
            } catch {
                recordRecoveryFailure(
                    "The preferred microphone produced digital silence and no fallback could start: \(error.localizedDescription)",
                    operationID: operationID
                )
            }
        }
    }

    private static func requestSystemMicrophonePermission() async -> AutoSendMicrophonePermissionOutcome {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            await MainActor.run {
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }

        do {
            try await AudioRecorder.requestMicrophonePermission()
            return .granted
        } catch AudioRecorderError.microphoneDenied {
            return .denied
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

private final class AutoSendMicrophoneUseLock: @unchecked Sendable {
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private let url = URL(fileURLWithPath: "/tmp/autoimproverecorder-mic-active.lock")

    func start() {
        lock.lock()
        defer { lock.unlock() }
        write()
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            self?.refresh()
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        lock.lock()
        let timer = timer
        self.timer = nil
        timer?.cancel()
        try? FileManager.default.removeItem(at: url)
        lock.unlock()
    }

    private func write() {
        let body = "pid=\(ProcessInfo.processInfo.processIdentifier)\nupdatedAt=\(Date().timeIntervalSince1970)\n"
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }

    private func refresh() {
        lock.lock()
        defer { lock.unlock() }
        guard timer != nil else { return }
        write()
    }
}

enum AutoSendRecordingError: LocalizedError {
    case noActiveRecording
    case operationSuperseded
    case captureFailed(audioURL: URL, message: String)
    case archiveFailed(audioURL: URL, message: String)

    var errorDescription: String? {
        switch self {
        case .noActiveRecording:
            return "No active recording was available."
        case .operationSuperseded:
            return "This recording operation is no longer active."
        case .captureFailed(let audioURL, let message):
            return "Audio capture failed: \(message) The incomplete recording was kept at \(audioURL.path) and was not sent."
        case .archiveFailed(let audioURL, let message):
            return "Audio archive failed: \(message) The live transcript was discarded and was not sent. Archive path: \(audioURL.path)."
        }
    }
}
