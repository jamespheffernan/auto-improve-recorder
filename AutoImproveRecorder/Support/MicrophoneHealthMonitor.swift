import AVFoundation
import Foundation

struct MicrophoneHealthConfiguration: Equatable {
    var exactSilentFallbackDuration: TimeInterval
    var startupObservationDuration: TimeInterval
    var minimumSilentBuffers: Int

    static let startupFallback = MicrophoneHealthConfiguration(
        exactSilentFallbackDuration: 0.75,
        startupObservationDuration: 1.5,
        minimumSilentBuffers: 3
    )
}

struct MicrophoneHealthEvent: Equatable {
    enum Kind: String, Equatable {
        case exactSilentStartup
    }

    var kind: Kind
    var observedDuration: TimeInterval
    var silentBufferCount: Int
}

final class MicrophoneHealthMonitor: @unchecked Sendable {
    private let configuration: MicrophoneHealthConfiguration
    private let lock = NSLock()
    private var observedDuration: TimeInterval = 0
    private var exactSilentDuration: TimeInterval = 0
    private var silentBufferCount = 0
    private var hasSeenNonSilentAudio = false
    private var hasEmittedEvent = false

    init(configuration: MicrophoneHealthConfiguration = .startupFallback) {
        self.configuration = configuration
    }

    func observe(_ buffer: AVAudioPCMBuffer) -> MicrophoneHealthEvent? {
        let duration = Self.duration(of: buffer)
        let isExactlySilent = Self.isExactlySilent(buffer)

        lock.lock()
        defer { lock.unlock() }

        guard !hasEmittedEvent,
              !hasSeenNonSilentAudio,
              observedDuration <= configuration.startupObservationDuration else {
            return nil
        }

        observedDuration += duration
        if isExactlySilent {
            exactSilentDuration += duration
            silentBufferCount += 1
        } else {
            hasSeenNonSilentAudio = true
            return nil
        }

        guard exactSilentDuration >= configuration.exactSilentFallbackDuration,
              silentBufferCount >= configuration.minimumSilentBuffers else {
            return nil
        }

        hasEmittedEvent = true
        return MicrophoneHealthEvent(
            kind: .exactSilentStartup,
            observedDuration: exactSilentDuration,
            silentBufferCount: silentBufferCount
        )
    }

    private static func duration(of buffer: AVAudioPCMBuffer) -> TimeInterval {
        let sampleRate = buffer.format.sampleRate
        guard sampleRate > 0 else { return 0 }
        return TimeInterval(buffer.frameLength) / sampleRate
    }

    /// True when every byte of the buffer is zero. The silence watch uses the same check.
    static func isExactlySilent(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard buffer.frameLength > 0 else { return true }
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for audioBuffer in buffers {
            guard let data = audioBuffer.mData else { continue }
            let bytes = data.bindMemory(to: UInt8.self, capacity: Int(audioBuffer.mDataByteSize))
            for index in 0..<Int(audioBuffer.mDataByteSize) {
                if bytes[index] != 0 {
                    return false
                }
            }
        }
        return true
    }
}
