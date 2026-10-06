import AVFoundation
import Foundation

/// The silence watch's thresholds. Durations are audio time: frames divided by sample rate.
struct MicrophoneSilenceWatchConfiguration: Equatable {
    /// Continuous exact silence on the main microphone before a report, while a backup runs.
    var silentDurationWithBackup: TimeInterval
    /// Continuous exact silence on the main microphone before a report, with no backup running.
    var silentDurationWithoutBackup: TimeInterval
    /// A backup buffer counts as sound when its largest sample is at least this (full scale is 1).
    var backupSoundPeakLevel: Float
    /// How much backup sound the silent span must contain before a report.
    var backupSoundDuration: TimeInterval

    static let standard = MicrophoneSilenceWatchConfiguration(
        silentDurationWithBackup: 1.0,
        silentDurationWithoutBackup: 3.0,
        backupSoundPeakLevel: 0.01,
        backupSoundDuration: 0.2
    )
}

struct MicrophoneSilenceReport: Equatable {
    var silentDuration: TimeInterval
    /// True when the backup heard sound while the main microphone was silent.
    var backupHeardSound: Bool
}

/// Watches a whole recording for a main microphone that delivers exact digital silence.
/// It reports once per silent span: after `silentDurationWithBackup` when the backup heard sound
/// in that span, or after `silentDurationWithoutBackup` when no backup is running. A span ends
/// when the main microphone delivers any non-zero sample.
final class MicrophoneSilenceWatch: @unchecked Sendable {
    private let configuration: MicrophoneSilenceWatchConfiguration
    private let lock = NSLock()
    private var backupIsRunning = false
    private var silentDuration: TimeInterval = 0
    private var backupSoundDuration: TimeInterval = 0
    private var reportedThisSpan = false

    init(configuration: MicrophoneSilenceWatchConfiguration = .standard) {
        self.configuration = configuration
    }

    func backupStarted() {
        lock.lock()
        backupIsRunning = true
        lock.unlock()
    }

    func backupStopped() {
        lock.lock()
        backupIsRunning = false
        backupSoundDuration = 0
        lock.unlock()
    }

    func observePrimary(_ buffer: AVAudioPCMBuffer) -> MicrophoneSilenceReport? {
        observePrimary(
            duration: Self.duration(of: buffer),
            isExactlySilent: MicrophoneHealthMonitor.isExactlySilent(buffer)
        )
    }

    func observeBackup(_ buffer: AVAudioPCMBuffer) {
        observeBackup(duration: Self.duration(of: buffer), peakLevel: Self.peakLevel(of: buffer))
    }

    func observePrimary(duration: TimeInterval, isExactlySilent: Bool) -> MicrophoneSilenceReport? {
        lock.lock()
        defer { lock.unlock() }

        guard isExactlySilent else {
            silentDuration = 0
            backupSoundDuration = 0
            reportedThisSpan = false
            return nil
        }
        silentDuration += duration
        guard !reportedThisSpan else { return nil }

        if backupIsRunning {
            guard backupSoundDuration >= configuration.backupSoundDuration,
                  silentDuration >= configuration.silentDurationWithBackup else {
                return nil
            }
        } else {
            guard silentDuration >= configuration.silentDurationWithoutBackup else { return nil }
        }
        reportedThisSpan = true
        return MicrophoneSilenceReport(
            silentDuration: silentDuration,
            backupHeardSound: backupIsRunning
        )
    }

    /// Backup sound counts only while the main microphone is in a silent span.
    func observeBackup(duration: TimeInterval, peakLevel: Float) {
        lock.lock()
        if backupIsRunning, silentDuration > 0, peakLevel >= configuration.backupSoundPeakLevel {
            backupSoundDuration += duration
        }
        lock.unlock()
    }

    static func duration(of buffer: AVAudioPCMBuffer) -> TimeInterval {
        let sampleRate = buffer.format.sampleRate
        guard sampleRate > 0 else { return 0 }
        return TimeInterval(buffer.frameLength) / sampleRate
    }

    /// The largest absolute sample in the buffer, with full scale as 1. Formats other than
    /// 32-bit float and 16- or 32-bit integer give 0.
    static func peakLevel(of buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        let channels = Int(buffer.format.channelCount)
        let pointerCount = buffer.format.isInterleaved ? 1 : channels
        let sampleCount = buffer.format.isInterleaved ? frames * channels : frames
        var peak: Float = 0

        if let data = buffer.floatChannelData {
            for channel in 0..<pointerCount {
                for index in 0..<sampleCount {
                    peak = max(peak, abs(data[channel][index]))
                }
            }
        } else if let data = buffer.int16ChannelData {
            for channel in 0..<pointerCount {
                for index in 0..<sampleCount {
                    peak = max(peak, abs(Float(data[channel][index])) / 32_768)
                }
            }
        } else if let data = buffer.int32ChannelData {
            for channel in 0..<pointerCount {
                for index in 0..<sampleCount {
                    peak = max(peak, abs(Float(data[channel][index])) / 2_147_483_648)
                }
            }
        }
        return peak
    }
}
