import AVFoundation
import Foundation

enum AudioRecorderError: LocalizedError {
    case microphoneDenied
    case inputUnavailable
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
        case .fileUnavailable:
            return "Could not create a temporary recording file."
        case .engineStartFailed(let message):
            return "Could not start microphone recording. \(message)"
        }
    }
}

final class AudioRecorder {
    typealias AudioBufferHandler = (AVAudioPCMBuffer) -> Void

    fileprivate static let fileOpenQueue = DispatchQueue(label: "com.fieldtheory.air.fileopen", qos: .userInitiated)

    private let engine = AVAudioEngine()
    fileprivate let stateLock = NSLock()
    fileprivate var audioFile: AVAudioFile?
    fileprivate var currentURL: URL?
    fileprivate var pendingBuffers: [AVAudioPCMBuffer] = []
    fileprivate var halPrimed = false
    private var observedFirstBuffer = false
    private var tapInstalled = false
    private var installedBufferSize: AVAudioFrameCount?
    private var installedFormat: AVAudioFormat?
    private var activeStreamHandler: AudioBufferHandler?
    private var activeOnFirstBuffer: (() -> Void)?
    #if os(iOS)
    private var audioSessionConfigured = false
    private var audioSessionActive = false
    #endif

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
        bufferSize: AVAudioFrameCount = 1024,
        streamHandler: AudioBufferHandler? = nil,
        onFirstBuffer: (() -> Void)? = nil
    ) throws -> URL {
        let tStart = Date()
        #if os(iOS)
        try configureAudioSession()
        #endif
        let tSession = Date()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioRecorderError.inputUnavailable
        }
        let tFormat = Date()

        let shouldStartEngine = prepareEngine(bufferSize: bufferSize, format: format)
        let tPrepEng = Date()

        stateLock.lock()
        audioFile = nil  // Pending: filled by background open task.
        currentURL = url
        observedFirstBuffer = false
        activeStreamHandler = streamHandler
        activeOnFirstBuffer = onFirstBuffer
        stateLock.unlock()

        // Open the AVAudioFile on a background queue so the engine start path is not blocked
        // on file IO. The handler buffers any audio that arrives before the file is ready.
        AudioRecorder.fileOpenQueue.async { [weak self] in
            guard let self else { return }
            let opened: AVAudioFile?
            do {
                opened = try AVAudioFile(forWriting: url, settings: format.settings)
            } catch {
                NSLog("AudioRecorder file open failed: \(error.localizedDescription)")
                opened = nil
            }
            self.stateLock.lock()
            // Only assign if this URL is still the active recording.
            if self.currentURL == url {
                self.audioFile = opened
                let pending = self.pendingBuffers
                self.pendingBuffers = []
                self.stateLock.unlock()
                if let opened {
                    for buf in pending {
                        try? opened.write(from: buf)
                    }
                }
            } else {
                self.stateLock.unlock()
            }
        }

        do {
            engine.prepare()
            let tPrepare = Date()
            if shouldStartEngine {
                try engine.start()
            }
            let tEngStart = Date()
            NSLog("AudioRecorder.phase session=%.2fms format=%.2fms prepEng=%.2fms prepare=%.2fms engStart=%.2fms total=%.2fms",
                tSession.timeIntervalSince(tStart) * 1000,
                tFormat.timeIntervalSince(tSession) * 1000,
                tPrepEng.timeIntervalSince(tFormat) * 1000,
                tPrepare.timeIntervalSince(tPrepEng) * 1000,
                tEngStart.timeIntervalSince(tPrepare) * 1000,
                tEngStart.timeIntervalSince(tStart) * 1000
            )
        } catch {
            clearActiveRecordingState()
            if engine.isRunning {
                engine.stop()
            }
            removeInputTap()
            throw AudioRecorderError.engineStartFailed(error.localizedDescription)
        }
        return url
    }

    func prepareForFastStartIfAuthorized() {
        guard Self.hasMicrophonePermission else { return }
        do {
            #if os(iOS)
            try configureAudioSession()
            #endif

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { return }

            let shouldStartEngine = prepareEngine(bufferSize: 1024, format: format)
            engine.prepare()

            #if os(iOS)
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
            #endif
        } catch {
            NSLog("AudioRecorder prewarm failed: \(error.localizedDescription)")
        }
    }

    private func prepareEngine(bufferSize: AVAudioFrameCount, format: AVAudioFormat) -> Bool {
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

        input.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            self?.handleAudioBuffer(buffer)
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
        guard currentURL != nil else {
            // No active recording (likely a prewarm flow).
            stateLock.unlock()
            return
        }
        let file = audioFile
        let streamHandler = activeStreamHandler
        let onFirstBuffer = observedFirstBuffer ? nil : activeOnFirstBuffer
        let isFirstBuffer = !observedFirstBuffer
        observedFirstBuffer = true
        // If the file isn't ready yet, queue the buffer for later flush by the
        // background opener. Bound the queue so a stuck open doesn't grow without limit.
        if file == nil, pendingBuffers.count < 16 {
            // We need to keep a strong copy; PCMBuffer is reference-counted but the AVAudioEngine
            // tap may reuse the same backing storage on the next callback. Copy frames to a new
            // buffer to be safe.
            if let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) {
                copy.frameLength = buffer.frameLength
                if let dst = copy.floatChannelData, let src = buffer.floatChannelData {
                    let channelCount = Int(buffer.format.channelCount)
                    let frameCount = Int(buffer.frameLength)
                    for ch in 0..<channelCount {
                        memcpy(dst[ch], src[ch], frameCount * MemoryLayout<Float>.stride)
                    }
                    pendingBuffers.append(copy)
                } else if let dst = copy.int16ChannelData, let src = buffer.int16ChannelData {
                    let channelCount = Int(buffer.format.channelCount)
                    let frameCount = Int(buffer.frameLength)
                    for ch in 0..<channelCount {
                        memcpy(dst[ch], src[ch], frameCount * MemoryLayout<Int16>.stride)
                    }
                    pendingBuffers.append(copy)
                }
            }
        }
        stateLock.unlock()
        if isFirstBuffer {
            NSLog("AudioRecorder.firstBuffer frames=%d sr=%.0f", buffer.frameLength, buffer.format.sampleRate)
        }

        if let onFirstBuffer {
            onFirstBuffer()
        }

        if let file {
            do {
                try file.write(from: buffer)
            } catch {
                NSLog("AudioRecorder write failed: \(error.localizedDescription)")
            }
        }
        streamHandler?(buffer)
    }

    private func clearActiveRecordingState() {
        stateLock.lock()
        audioFile = nil
        currentURL = nil
        pendingBuffers.removeAll()
        observedFirstBuffer = false
        activeStreamHandler = nil
        activeOnFirstBuffer = nil
        stateLock.unlock()
    }

    func stop() -> URL? {
        stateLock.lock()
        let url = currentURL
        audioFile = nil
        currentURL = nil
        pendingBuffers.removeAll()
        observedFirstBuffer = false
        activeStreamHandler = nil
        activeOnFirstBuffer = nil
        stateLock.unlock()

        #if !os(iOS)
        if engine.isRunning {
            engine.stop()
        }
        removeInputTap()
        #endif
        return url
    }

    func releaseWarmResources() {
        clearActiveRecordingState()

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
