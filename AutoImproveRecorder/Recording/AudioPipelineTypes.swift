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

/// One owned copy of a microphone callback shared by every active consumer.
///
/// `AVAudioPCMBuffer` is mutable, but AIR treats `buffer` as read-only after
/// this object is published. The tap buffer is copied once so CoreAudio can
/// reuse its storage while archive and realtime queues retain this block.
final class CapturedAudioBuffer: @unchecked Sendable {
    let sequence: UInt64
    let capturedAtHostTime: UInt64
    let receivedAt: Date
    let format: AVAudioFormat
    let frameLength: AVAudioFrameCount
    let buffer: AVAudioPCMBuffer
    let byteCount: Int

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
        self.byteCount = Self.byteCount(of: buffer)
    }

    static func copying(
        sequence: UInt64,
        capturedAtHostTime: UInt64 = 0,
        receivedAt: Date = Date(),
        buffer: AVAudioPCMBuffer
    ) -> CapturedAudioBuffer? {
        guard let copiedBuffer = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameLength
        ) else {
            return nil
        }
        copiedBuffer.frameLength = buffer.frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList)
        )
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(
            copiedBuffer.mutableAudioBufferList
        )

        for index in 0..<min(sourceBuffers.count, destinationBuffers.count) {
            guard let sourceData = sourceBuffers[index].mData,
                  let destinationData = destinationBuffers[index].mData else {
                continue
            }
            let byteCount = Int(sourceBuffers[index].mDataByteSize)
            memcpy(destinationData, sourceData, byteCount)
            destinationBuffers[index].mDataByteSize = sourceBuffers[index].mDataByteSize
        }

        return CapturedAudioBuffer(
            sequence: sequence,
            capturedAtHostTime: capturedAtHostTime,
            receivedAt: receivedAt,
            buffer: copiedBuffer
        )
    }

    private static func byteCount(of buffer: AVAudioPCMBuffer) -> Int {
        UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList)
        ).reduce(0) { $0 + Int($1.mDataByteSize) }
    }
}

enum AudioCaptureFailure: LocalizedError, Equatable, Sendable {
    case sharedBufferAllocationFailed(sequence: UInt64)

    var errorDescription: String? {
        switch self {
        case .sharedBufferAllocationFailed(let sequence):
            return "Audio capture could not allocate shared buffer \(sequence). The recording contains a gap and cannot be transcribed safely."
        }
    }
}

enum AudioCaptureEvent: Sendable {
    case captured(CapturedAudioBuffer)
    case failure(AudioCaptureFailure)
}

/// Creates the one owned tap copy and turns allocation failure into data.
/// The injected copier is the test seam; production still allocates exactly
/// one shared block and does not retain a buffer pool.
struct CapturedAudioBufferFactory {
    typealias Copier = (_ sequence: UInt64, _ buffer: AVAudioPCMBuffer) -> CapturedAudioBuffer?

    private let copier: Copier

    init(_ copier: @escaping Copier = { sequence, buffer in
        CapturedAudioBuffer.copying(sequence: sequence, buffer: buffer)
    }) {
        self.copier = copier
    }

    func capture(sequence: UInt64, buffer: AVAudioPCMBuffer) -> AudioCaptureEvent {
        guard let captured = copier(sequence, buffer) else {
            return .failure(.sharedBufferAllocationFailed(sequence: sequence))
        }
        return .captured(captured)
    }
}

/// A bounded pool of one converter output buffer.
///
/// Both realtime conversion paths are serial. Their converted bytes are
/// materialized before the next call, so one retained buffer can be reused
/// until the format changes or a larger capacity is required.
final class ReusableAudioPCMBuffer {
    typealias Allocator = (_ format: AVAudioFormat, _ capacity: AVAudioFrameCount) -> AVAudioPCMBuffer?

    private let allocator: Allocator
    private var storage: AVAudioPCMBuffer?
    private(set) var allocationCount = 0

    init(_ allocator: @escaping Allocator = { format, capacity in
        AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)
    }) {
        self.allocator = allocator
    }

    func buffer(
        format: AVAudioFormat,
        minimumFrameCapacity: AVAudioFrameCount
    ) -> AVAudioPCMBuffer? {
        if let storage,
           storage.format.isEqual(format),
           storage.frameCapacity >= minimumFrameCapacity {
            storage.frameLength = 0
            return storage
        }

        guard let replacement = allocator(format, minimumFrameCapacity) else {
            return nil
        }
        storage = replacement
        allocationCount += 1
        return replacement
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

/// The archive state captured after all queued writes and final validation.
struct AudioRecordingStopResult {
    var audioURL: URL?
    var archiveStatus: ArchiveStatus
    var diagnostics: AudioCaptureDiagnostics

    var archiveFailureMessage: String? {
        if let message = diagnostics.archiveFailure {
            return message
        }
        switch archiveStatus {
        case .finished:
            return nil
        case .failed(let message):
            return message
        case .writing:
            return "The audio archive did not finish."
        case .unavailable:
            return audioURL == nil ? nil : "The audio archive was unavailable."
        }
    }
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
