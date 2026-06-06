import AVFoundation
import Foundation

enum AudioCaptureSourceKind: String, Codable, Equatable {
    case microphone
    case systemAudio
}

enum RealtimeAudioFormat: String, Codable, Equatable {
    case pcm16Mono24k

    var sampleRate: Double { 24_000.0 }
    var channelCount: AVAudioChannelCount { 1 }
    var bytesPerFrame: Int { MemoryLayout<Int16>.size }
}

struct CapturedAudioBuffer {
    let sequence: UInt64
    let capturedAtHostTime: UInt64
    let receivedAt: Date
    let format: AVAudioFormat
    let frameLength: AVAudioFrameCount
    let buffer: AVAudioPCMBuffer

    init(
        sequence: UInt64,
        capturedAtHostTime: UInt64 = 0,
        receivedAt: Date = Date(),
        buffer: AVAudioPCMBuffer
    ) {
        self.sequence = sequence
        self.capturedAtHostTime = capturedAtHostTime
        self.receivedAt = receivedAt
        self.format = buffer.format
        self.frameLength = buffer.frameLength
        self.buffer = buffer
    }
}

struct RealtimeAudioChunk: Equatable {
    let sequence: UInt64
    let firstCaptureSequence: UInt64
    let lastCaptureSequence: UInt64
    let producedAt: Date
    let format: RealtimeAudioFormat
    let data: Data
}

struct AudioCaptureDiagnostics: Equatable {
    var sourceKind: AudioCaptureSourceKind = .microphone
    var requestedDeviceID = ""
    var resolvedDeviceName = ""
    var inputSampleRate: Double = 0
    var inputChannelCount: AVAudioChannelCount = 0
    var tapBufferFrames: AVAudioFrameCount = 0
    var startRequestedAt: Date?
    var engineStartedAt: Date?
    var firstBufferAt: Date?
    var archiveOpenMs: Double = 0
    var archiveWriteCount = 0
    var archiveBytesWritten = 0
    var archiveQueueMaxDepth = 0
    var archiveFailure: String?
    var converterRecreateCount = 0
    var conversionFailure: String?
    var chunkByteCount = RealtimePCMChunker.defaultChunkByteCount
    var realtimeChunksProduced = 0
    var realtimeChunksSent = 0
    var realtimeChunksDropped = 0
    var realtimePendingBytesMax = 0
    var realtimeSocketReadyMs: Double = 0
    var realtimeSendLagMaxMs: Double = 0
    var realtimeFailure: String?
    var fallbackReason: String?

    var realtimeIsDegraded: Bool {
        realtimeChunksDropped > 0 || conversionFailure != nil || realtimeFailure != nil
    }

    var archiveIsFailed: Bool {
        archiveFailure != nil
    }
}

struct RecordingCaptureResult {
    var audioURL: URL?
    var archiveStatus: ArchiveStatus
    var realtimeStatus: RealtimeCaptureStatus
    var diagnostics: AudioCaptureDiagnostics
}

enum ArchiveStatus: Equatable {
    case unavailable
    case writing
    case finished(URL)
    case failed(String)

    var isUsable: Bool {
        if case .finished = self { return true }
        return false
    }
}

enum RealtimeCaptureStatus: Equatable {
    case unavailable
    case preparing
    case active
    case degraded(String)
    case failed(String)

    var shouldTrustForFinalTranscript: Bool {
        switch self {
        case .active:
            return true
        case .unavailable, .preparing, .degraded, .failed:
            return false
        }
    }
}

struct AudioCaptureSourceConfiguration: Equatable {
    var sourceKind: AudioCaptureSourceKind
    var requestedDeviceID: String

    static let systemDefaultMicrophone = AudioCaptureSourceConfiguration(
        sourceKind: .microphone,
        requestedDeviceID: ""
    )
}

protocol AudioCaptureSource {
    var configuration: AudioCaptureSourceConfiguration { get }
}
