import AVFoundation
import Foundation
import OSLog

#if os(macOS)
import AudioToolbox
#endif

private let audioRecorderStartupLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "recorder.audio",
    category: "RecordingStartup"
)

private let microphoneDeviceLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "recorder.audio",
    category: "MicrophoneDevice"
)

enum AudioRecorderError: LocalizedError {
    case microphoneDenied
    case inputUnavailable
    case inputDeviceUnavailable(String, String)
    case fileUnavailable
    case engineStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            #if os(iOS)
            return "Microphone access is required. Enable it for Auto Improve Recorder in Settings."
            #else
            return "Microphone access is required. Enable it for AutoImproveRecorder in System Settings."
            #endif
        case .inputUnavailable:
            return "No microphone input is available."
        case .inputDeviceUnavailable(let name, let message):
            return "Could not use \(name). \(message)"
        case .fileUnavailable:
            return "Could not create a temporary recording file."
        case .engineStartFailed(let message):
            return "Could not start microphone recording. \(message)"
        }
    }
}

final class AudioRecorder {
    typealias AudioBufferHandler = (AudioCaptureEvent) -> Void
    typealias ArchiveWriterFactory = (URL, AVAudioFormat) -> ArchiveAudioWriter

    fileprivate static let fileOpenQueue = DispatchQueue(label: "recorder.audio.fileopen", qos: .userInitiated)
    static let fastStartBufferSize: AVAudioFrameCount = 256
    private static let pendingArchiveBufferDuration: TimeInterval = 3.0

    private let engine = AVAudioEngine()
    private let capturedBufferFactory: CapturedAudioBufferFactory
    private let archiveWriterFactory: ArchiveWriterFactory
    fileprivate let stateLock = NSLock()
    fileprivate var archiveWriter: ArchiveAudioWriter?
    fileprivate var archiveStatus: ArchiveStatus = .unavailable
    fileprivate var archiveDiagnostics = AudioCaptureDiagnostics()
    fileprivate var currentURL: URL?
    fileprivate var pendingBuffers: [CapturedAudioBuffer] = []
    fileprivate var pendingArchiveBufferedFrames: AVAudioFrameCount = 0
    fileprivate var pendingArchiveFrameCapacity: AVAudioFrameCount = 0
    fileprivate var droppedPendingArchiveBuffers = 0
    fileprivate var nextCapturedAudioSequence: UInt64 = 0
    fileprivate var captureFailure: AudioCaptureFailure?
    fileprivate var halPrimed = false
    private var observedFirstBuffer = false
    private var tapInstalled = false
    private var installedBufferSize: AVAudioFrameCount?
    private var installedFormat: AVAudioFormat?
    private var activeStreamHandler: AudioBufferHandler?
    private var activeOnFirstBuffer: (() -> Void)?
    #if os(macOS)
    private var inputCapture: HALInputCapture?
    #endif
    #if os(iOS)
    private var audioSessionConfigured = false
    private var audioSessionActive = false
    #endif

    init(
        capturedBufferFactory: CapturedAudioBufferFactory = CapturedAudioBufferFactory(),
        archiveWriterFactory: @escaping ArchiveWriterFactory = { url, format in
            ArchiveAudioWriter(url: url, format: format)
        }
    ) {
        self.capturedBufferFactory = capturedBufferFactory
        self.archiveWriterFactory = archiveWriterFactory
    }

    static func makeRecordingURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("auto-improve-\(UUID().uuidString)")
            .appendingPathExtension("wav")
    }

    static var hasMicrophonePermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMicrophonePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
            if !granted {
                throw AudioRecorderError.microphoneDenied
            }
        case .denied, .restricted:
            throw AudioRecorderError.microphoneDenied
        @unknown default:
            throw AudioRecorderError.microphoneDenied
        }
    }

    func start(
        at url: URL = AudioRecorder.makeRecordingURL(),
        microphone: AudioInputDevice? = nil,
        bufferSize: AVAudioFrameCount = 1024,
        streamHandler: AudioBufferHandler? = nil,
        onFirstBuffer: (() -> Void)? = nil
    ) throws -> URL {
        let tStart = Date()
        #if os(iOS)
        try configureAudioSession()
        #endif
        let tSession = Date()

        #if os(macOS)
        let capture = try openInputCapture(microphone, bufferSize: bufferSize)
        let tDevice = Date()
        let format = capture.format
        #else
        let input = engine.inputNode
        let tDevice = Date()
        let format = input.outputFormat(forBus: 0)
        #endif
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioRecorderError.inputUnavailable
        }
        let tFormat = Date()

        #if !os(macOS)
        let shouldStartEngine = try prepareEngine(bufferSize: bufferSize, format: format)
        #endif
        let tPrepEng = Date()

        stateLock.lock()
        archiveWriter = nil  // Pending: filled by background open task.
        archiveStatus = .writing
        archiveDiagnostics = AudioCaptureDiagnostics(
            inputSampleRate: format.sampleRate,
            inputChannelCount: format.channelCount,
            tapBufferFrames: bufferSize,
            startRequestedAt: tStart
        )
        currentURL = url
        pendingBuffers.removeAll(keepingCapacity: true)
        pendingArchiveBufferedFrames = 0
        pendingArchiveFrameCapacity = Self.pendingArchiveFrameCapacity(
            sampleRate: format.sampleRate,
            bufferSize: bufferSize
        )
        droppedPendingArchiveBuffers = 0
        nextCapturedAudioSequence = 0
        captureFailure = nil
        observedFirstBuffer = false
        activeStreamHandler = streamHandler
        activeOnFirstBuffer = onFirstBuffer
        stateLock.unlock()

        // Open the archive writer on a background queue so the engine start path is
        // not blocked on file IO. The tap buffers early audio until the writer is ready.
        AudioRecorder.fileOpenQueue.async { [weak self] in
            guard let self else { return }
            let writer = self.archiveWriterFactory(url, format)
            writer.open()
            self.stateLock.lock()
            if self.currentURL == url {
                self.archiveWriter = writer
                self.archiveStatus = writer.status
                self.archiveDiagnostics = writer.diagnostics
                self.applyCaptureFailureLocked()
                let pending = self.pendingBuffers
                self.pendingBuffers = []
                self.pendingArchiveBufferedFrames = 0
                self.stateLock.unlock()
                if case .writing = writer.status {
                    for captured in pending {
                        writer.append(captured)
                    }
                    self.updateArchiveState(from: writer)
                } else if case .failed(let message) = writer.status {
                    NSLog("AudioRecorder file open failed: \(message)")
                }
            } else {
                self.stateLock.unlock()
            }
        }

        do {
            #if os(macOS)
            let tPrepare = Date()
            try capture.start()
            inputCapture = capture
            #else
            engine.prepare()
            let tPrepare = Date()
            if shouldStartEngine {
                try engine.start()
            }
            #endif
            let tEngStart = Date()
            let sessionMS = String(format: "%.2f", tSession.timeIntervalSince(tStart) * 1000)
            let deviceMS = String(format: "%.2f", tDevice.timeIntervalSince(tSession) * 1000)
            let formatMS = String(format: "%.2f", tFormat.timeIntervalSince(tDevice) * 1000)
            let prepEngineMS = String(format: "%.2f", tPrepEng.timeIntervalSince(tFormat) * 1000)
            let prepareMS = String(format: "%.2f", tPrepare.timeIntervalSince(tPrepEng) * 1000)
            let engineStartMS = String(format: "%.2f", tEngStart.timeIntervalSince(tPrepare) * 1000)
            let totalMS = String(format: "%.2f", tEngStart.timeIntervalSince(tStart) * 1000)
            audioRecorderStartupLogger.info(
                "AudioRecorder phase session=\(sessionMS, privacy: .public)ms setDevice=\(deviceMS, privacy: .public)ms format=\(formatMS, privacy: .public)ms prepEngine=\(prepEngineMS, privacy: .public)ms prepare=\(prepareMS, privacy: .public)ms engineStart=\(engineStartMS, privacy: .public)ms total=\(totalMS, privacy: .public)ms"
            )
        } catch {
            clearActiveRecordingState()
            #if os(macOS)
            capture.stop()
            #else
            if engine.isRunning {
                engine.stop()
            }
            removeInputTap()
            #endif
            throw AudioRecorderError.engineStartFailed(error.localizedDescription)
        }
        return url
    }

    #if os(macOS)
    /// Opens the microphone's own capture unit. It never opens the system default input, unless
    /// that is the microphone.
    private func openInputCapture(_ microphone: AudioInputDevice?, bufferSize: AVAudioFrameCount) throws -> HALInputCapture {
        let deviceID: AudioObjectID
        let deviceName: String
        let selectedDeviceID: String

        if let microphone, !microphone.isSystemDefaultPlaceholder {
            guard let coreAudioDeviceID = microphone.coreAudioDeviceID else {
                throw AudioRecorderError.inputDeviceUnavailable(
                    microphone.name,
                    "The selected microphone does not have a CoreAudio device ID."
                )
            }
            deviceID = coreAudioDeviceID
            deviceName = microphone.name
            selectedDeviceID = microphone.id
        } else {
            guard let defaultDeviceID = AudioInputDeviceDiscovery.defaultInputDeviceID() else {
                throw AudioRecorderError.inputUnavailable
            }
            deviceID = defaultDeviceID
            deviceName = "System default"
            selectedDeviceID = ""
        }

        inputCapture?.stop()
        inputCapture = nil

        let startedAt = Date()
        let capture: HALInputCapture
        do {
            capture = try HALInputCapture(deviceID: deviceID, chunkFrames: bufferSize) { [weak self] buffer in
                self?.handleAudioBuffer(buffer)
            }
        } catch {
            throw AudioRecorderError.inputDeviceUnavailable(
                deviceName,
                error.localizedDescription
            )
        }

        let elapsedMS = Date().timeIntervalSince(startedAt) * 1000
        microphoneDeviceLogger.info(
            "Selected microphone id=\(selectedDeviceID, privacy: .public) name=\(deviceName, privacy: .public) coreAudioDeviceID=\(deviceID, privacy: .public) setDevice=\(String(format: "%.2f", elapsedMS), privacy: .public)ms"
        )
        return capture
    }
    #endif

    func prepareForFastStartIfAuthorized() {
        #if os(iOS)
        guard Self.hasMicrophonePermission else { return }
        do {
            try configureAudioSession()

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { return }

            let shouldStartEngine = try prepareEngine(bufferSize: Self.fastStartBufferSize, format: format)
            engine.prepare()

            if shouldStartEngine {
                try engine.start()
                // Wait briefly for the first audio buffer to flow so the HAL is fully primed.
                // This trades a few ms of prewarm for a much faster perceived first-buffer time
                // when the user actually taps record.
                let warmStart = Date()
                while Date().timeIntervalSince(warmStart) < 0.15 {
                    stateLock.lock()
                    let primed = halPrimed
                    stateLock.unlock()
                    if primed { break }
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
        } catch {
            NSLog("AudioRecorder prewarm failed: \(error.localizedDescription)")
        }
        #endif
    }

    private static func tapFailureMessage(format: AVAudioFormat, input: AVAudioInputNode) -> String {
        let hardware = input.inputFormat(forBus: 0)
        return "The microphone runs at \(Int(hardware.sampleRate)) Hz but the recording asked for \(Int(format.sampleRate)) Hz."
    }

    private func prepareEngine(bufferSize: AVAudioFrameCount, format: AVAudioFormat) throws -> Bool {
        let input = engine.inputNode

        if tapInstalled,
           installedBufferSize == bufferSize,
           installedFormat?.isEqual(format) == true {
            return !engine.isRunning
        }

        if engine.isRunning {
            engine.stop()
        }

        removeInputTap()

        // A tap whose format does not match the input hardware raises an Objective-C exception
        // that ends the app. Report it as an error instead.
        let tapBlock: AVAudioNodeTapBlock = { [weak self] buffer, _ in
            self?.handleAudioBuffer(buffer)
        }
        if #available(macOS 27.0, iOS 27.0, *) {
            do {
                try input.__installTap(onBus: 0, bufferSize: bufferSize, format: format, error: (), block: tapBlock)
            } catch {
                throw AudioRecorderError.engineStartFailed(Self.tapFailureMessage(format: format, input: input))
            }
        } else {
            guard format.sampleRate == input.inputFormat(forBus: 0).sampleRate else {
                throw AudioRecorderError.engineStartFailed(Self.tapFailureMessage(format: format, input: input))
            }
            input.installTap(onBus: 0, bufferSize: bufferSize, format: format, block: tapBlock)
        }
        tapInstalled = true
        installedBufferSize = bufferSize
        installedFormat = format
        return true
    }

    private func removeInputTap() {
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
        installedBufferSize = nil
        installedFormat = nil
    }

    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        stateLock.lock()
        // Mark HAL as primed regardless of recording state.
        halPrimed = true
        guard let activeURL = currentURL else {
            // No active recording (likely a prewarm flow).
            stateLock.unlock()
            return
        }
        let writer = archiveWriter
        let streamHandler = activeStreamHandler
        let onFirstBuffer = observedFirstBuffer ? nil : activeOnFirstBuffer
        let isFirstBuffer = !observedFirstBuffer
        observedFirstBuffer = true
        let sequence = nextCapturedAudioSequence
        nextCapturedAudioSequence += 1
        let captureEvent = capturedBufferFactory.capture(sequence: sequence, buffer: buffer)

        switch captureEvent {
        case .captured(let captured):
            if writer == nil {
                if pendingArchiveBufferedFrames + captured.frameLength <= pendingArchiveFrameCapacity {
                    pendingBuffers.append(captured)
                    pendingArchiveBufferedFrames += captured.frameLength
                    archiveDiagnostics.archiveQueueMaxDepth = max(
                        archiveDiagnostics.archiveQueueMaxDepth,
                        pendingBuffers.count
                    )
                } else {
                    droppedPendingArchiveBuffers += 1
                    archiveDiagnostics.archiveFailure = Self.pendingArchiveDropMessage(droppedPendingArchiveBuffers)
                }
            } else {
                enqueueArchiveWrite(captured, for: activeURL)
            }
        case .failure(let failure):
            if captureFailure == nil {
                captureFailure = failure
                NSLog("AudioRecorder capture failed: \(failure.localizedDescription)")
            }
            applyCaptureFailureLocked()
            // A stop can begin as soon as this lock is released. Publish the
            // terminal failure first so AppState cannot snapshot a healthy
            // live path and accept an incomplete transcript.
            streamHandler?(captureEvent)
        }
        stateLock.unlock()
        if isFirstBuffer {
            audioRecorderStartupLogger.info(
                "AudioRecorder firstBuffer frames=\(buffer.frameLength, privacy: .public) sampleRate=\(Int(buffer.format.sampleRate), privacy: .public)"
            )
        }

        if let onFirstBuffer {
            onFirstBuffer()
        }

        if case .captured = captureEvent {
            streamHandler?(captureEvent)
        }
    }

    private func enqueueArchiveWrite(_ captured: CapturedAudioBuffer, for url: URL) {
        AudioRecorder.fileOpenQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            guard self.currentURL == url,
                  let writer = self.archiveWriter else {
                self.stateLock.unlock()
                return
            }
            self.stateLock.unlock()

            writer.append(captured)
            self.updateArchiveState(from: writer)
        }
    }

    private func updateArchiveState(from writer: ArchiveAudioWriter) {
        stateLock.lock()
        archiveStatus = writer.status
        archiveDiagnostics = writer.diagnostics
        if droppedPendingArchiveBuffers > 0 {
            archiveDiagnostics.archiveFailure = Self.pendingArchiveDropMessage(droppedPendingArchiveBuffers)
        }
        applyCaptureFailureLocked()
        let status = archiveStatus
        stateLock.unlock()

        if case .failed(let message) = status {
            NSLog("AudioRecorder archive write failed: \(message)")
        }
    }

    private func clearActiveRecordingState() {
        stateLock.lock()
        archiveWriter = nil
        archiveStatus = .unavailable
        archiveDiagnostics = AudioCaptureDiagnostics()
        currentURL = nil
        pendingBuffers.removeAll()
        pendingArchiveBufferedFrames = 0
        pendingArchiveFrameCapacity = 0
        droppedPendingArchiveBuffers = 0
        nextCapturedAudioSequence = 0
        captureFailure = nil
        observedFirstBuffer = false
        activeStreamHandler = nil
        activeOnFirstBuffer = nil
        stateLock.unlock()
    }

    func stop() -> URL? {
        stopWithResult().audioURL
    }

    func stopWithResult() -> AudioRecordingStopResult {
        stateLock.lock()
        let url = currentURL
        activeStreamHandler = nil
        activeOnFirstBuffer = nil
        stateLock.unlock()

        #if os(macOS)
        // Returns after the last captured buffer reaches handleAudioBuffer, so the archive gets it.
        inputCapture?.stop()
        inputCapture = nil
        #endif

        if let url {
            AudioRecorder.fileOpenQueue.sync {
                finishArchiveWriter(for: url)
            }
        }

        stateLock.lock()
        let result = AudioRecordingStopResult(
            audioURL: url,
            archiveStatus: archiveStatus,
            diagnostics: archiveDiagnostics
        )
        archiveWriter = nil
        archiveStatus = .unavailable
        archiveDiagnostics = AudioCaptureDiagnostics()
        currentURL = nil
        pendingBuffers.removeAll()
        pendingArchiveBufferedFrames = 0
        pendingArchiveFrameCapacity = 0
        droppedPendingArchiveBuffers = 0
        nextCapturedAudioSequence = 0
        captureFailure = nil
        observedFirstBuffer = false
        stateLock.unlock()
        return result
    }

    private func finishArchiveWriter(for url: URL) {
        stateLock.lock()
        guard currentURL == url else {
            stateLock.unlock()
            return
        }
        let writer = archiveWriter
        let pending = pendingBuffers
        pendingBuffers = []
        pendingArchiveBufferedFrames = 0
        stateLock.unlock()

        if let writer {
            if case .writing = writer.status {
                for captured in pending {
                    writer.append(captured)
                }
                _ = writer.finish()
            }
            updateArchiveState(from: writer)
        }
    }

    func releaseWarmResources() {
        clearActiveRecordingState()

        #if os(macOS)
        inputCapture?.stop()
        inputCapture = nil
        #endif

        if engine.isRunning {
            engine.stop()
        }

        removeInputTap()
        stateLock.lock()
        halPrimed = false
        stateLock.unlock()

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        audioSessionActive = false
        #endif
    }

    private static func pendingArchiveFrameCapacity(
        sampleRate: Double,
        bufferSize: AVAudioFrameCount
    ) -> AVAudioFrameCount {
        let durationFrames = AVAudioFrameCount(ceil(sampleRate * pendingArchiveBufferDuration))
        return max(bufferSize, durationFrames)
    }

    private static func pendingArchiveDropMessage(_ droppedBuffers: Int) -> String {
        "Dropped \(droppedBuffers) early archive buffers after buffering \(pendingArchiveBufferDuration)s while the file writer opened."
    }

    /// Must be called while `stateLock` is held.
    private func applyCaptureFailureLocked() {
        guard let captureFailure else { return }
        let message = captureFailure.localizedDescription
        archiveStatus = .failed(message)
        archiveDiagnostics.archiveFailure = message
        archiveDiagnostics.realtimeFailure = message
    }

    #if os(iOS)
    private func configureAudioSession() throws {
        if audioSessionConfigured, audioSessionActive {
            return
        }

        let session = AVAudioSession.sharedInstance()
        if !audioSessionConfigured {
            try session.setCategory(
                .playAndRecord,
                mode: .spokenAudio,
                options: [.defaultToSpeaker, .allowBluetoothHFP]
            )
            // Request a short IO buffer to minimise tap-to-first-buffer latency.
            // Hardware honours the closest supported value (typically 5-10 ms).
            try? session.setPreferredIOBufferDuration(0.005)
            audioSessionConfigured = true
        }

        if !audioSessionActive {
            try session.setActive(true)
            audioSessionActive = true
        }
    }
    #endif
}
