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
    private var activeMicrophoneResolution: MicrophoneResolution?
    private var activeMicrophoneHealthMonitor: MicrophoneHealthMonitor?
    private var quarantinedMicrophoneIDs: [String: Date] = [:]
    private var microphoneRecoveryInProgress = false
    private let microphoneRetryCooldown: TimeInterval = 30
    private let microphoneUseLock = AutoSendMicrophoneUseLock()

    init(
        recorder: AudioRecorder = AudioRecorder(),
        wirelessProvider: @escaping @Sendable () -> AutoSendWirelessBridge = { .shared },
        transcription: AutoSendParakeetService,
        preferredMicrophoneID: String = "",
        permissionTimeoutNanoseconds: UInt64 = AutoSendMicrophonePermissionRequest.defaultTimeoutNanoseconds,
        permissionRequest: @escaping @Sendable () async -> AutoSendMicrophonePermissionOutcome = {
            await AutoSendRecordingService.requestSystemMicrophonePermission()
        }
    ) {
        self.recorder = recorder
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
                let resolution = try resolveMicrophone()
                let healthMonitor = healthMonitor(for: resolution, source: source)
                activeMicrophoneResolution = resolution
                activeMicrophoneHealthMonitor = healthMonitor
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
            activeMicrophoneResolution = nil
            activeMicrophoneHealthMonitor = nil
            microphoneRecoveryInProgress = false
        }
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

    private func resolveMicrophone() throws -> MicrophoneResolution {
        let devices = AudioInputDeviceDiscovery.inputDevices()
        stateLock.lock()
        let preferredID = preferredMicrophoneID
        let quarantined = quarantinedMicrophoneIDs
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
        return try MicrophoneResolver.resolve(
            preferences: preferences,
            devices: orderedDevices,
            quarantinedUntil: quarantined,
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
        guard source == .macHotKey,
              !resolution.usedFallback,
              !resolution.device.id.isEmpty else { return nil }
        if resolution.device.name.compare(
            AutoSendMicrophoneSelection.boyaMicrophoneName,
            options: .caseInsensitive
        ) == .orderedSame {
            return nil
        }
        stateLock.lock()
        let selectedID = preferredMicrophoneID
        stateLock.unlock()
        guard selectedID == resolution.device.id else { return nil }
        return MicrophoneHealthMonitor(configuration: .startupFallback)
    }

    private func recoverFromSilentPreferredMicrophone(
        _ event: MicrophoneHealthEvent,
        operationID: AutoSendOperationID,
        source: AutoSendRecordingSource,
        silentResolution: MicrophoneResolution
    ) {
        stateLock.lock()
        guard currentOperationID == operationID,
              !microphoneRecoveryInProgress,
              activeMicrophoneResolution == silentResolution else {
            stateLock.unlock()
            return
        }
        microphoneRecoveryInProgress = true
        let expiresAt = Date().addingTimeInterval(microphoneRetryCooldown)
        quarantinedMicrophoneIDs[silentResolution.device.id] = expiresAt
        stateLock.unlock()

        defer {
            stateLock.lock()
            microphoneRecoveryInProgress = false
            stateLock.unlock()
        }

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
                guard fallback.device.id != silentResolution.device.id else {
                    throw MicrophoneResolverError.noUsableMicrophone
                }
                transcription.beginRecording(operationID: operationID, source: source)
                resetCaptureFailure(operationID: operationID)
                activeMicrophoneResolution = fallback
                activeMicrophoneHealthMonitor = nil
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
