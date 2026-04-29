import AVFoundation
import Foundation

enum AudioRecorderError: LocalizedError {
    case microphoneDenied
    case inputUnavailable
    case fileUnavailable

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access is required. Enable it for AutoImproveRecorder in System Settings."
        case .inputUnavailable:
            return "No microphone input is available."
        case .fileUnavailable:
            return "Could not create a temporary recording file."
        }
    }
}

final class AudioRecorder {
    typealias AudioBufferHandler = (AVAudioPCMBuffer) -> Void

    private let engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var currentURL: URL?

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

    func start(streamHandler: AudioBufferHandler? = nil) throws -> URL {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            throw AudioRecorderError.inputUnavailable
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("auto-improve-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        do {
            audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
        } catch {
            throw AudioRecorderError.fileUnavailable
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let file = self?.audioFile else { return }
            do {
                try file.write(from: buffer)
            } catch {
                NSLog("AudioRecorder write failed: \(error.localizedDescription)")
            }
            streamHandler?(buffer)
        }

        engine.prepare()
        try engine.start()
        currentURL = url
        return url
    }

    func stop() -> URL? {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioFile = nil
        let url = currentURL
        currentURL = nil
        return url
    }
}
