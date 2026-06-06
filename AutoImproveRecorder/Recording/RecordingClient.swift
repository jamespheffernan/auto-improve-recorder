import AVFoundation
import Foundation

protocol RecordingClient {
    var fastStartBufferSize: AVAudioFrameCount { get }

    func prepareForFastStartIfAuthorized()
    func startRecording(
        at url: URL,
        microphone: AudioInputDevice?,
        bufferSize: AVAudioFrameCount,
        streamHandler: AudioRecorder.AudioBufferHandler?,
        onFirstBuffer: (() -> Void)?
    ) throws -> URL
    func stopRecording() -> URL?
    func releaseWarmResources()
}

final class AudioRecorderClient: RecordingClient {
    private let recorder: AudioRecorder

    init(recorder: AudioRecorder = AudioRecorder()) {
        self.recorder = recorder
    }

    var fastStartBufferSize: AVAudioFrameCount {
        AudioRecorder.fastStartBufferSize
    }

    func prepareForFastStartIfAuthorized() {
        recorder.prepareForFastStartIfAuthorized()
    }

    func startRecording(
        at url: URL,
        microphone: AudioInputDevice?,
        bufferSize: AVAudioFrameCount,
        streamHandler: AudioRecorder.AudioBufferHandler?,
        onFirstBuffer: (() -> Void)?
    ) throws -> URL {
        try recorder.start(
            at: url,
            microphone: microphone,
            bufferSize: bufferSize,
            streamHandler: streamHandler,
            onFirstBuffer: onFirstBuffer
        )
    }

    func stopRecording() -> URL? {
        recorder.stop()
    }

    func releaseWarmResources() {
        recorder.releaseWarmResources()
    }
}
