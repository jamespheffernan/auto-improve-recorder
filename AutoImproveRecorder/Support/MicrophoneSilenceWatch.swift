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
    /// A main buffer is faint when its largest sample is below this (full scale is 1; 0.001 is
    /// about −60 dBFS).
    var faintPrimaryPeakLevel: Float = 0.001
    /// Continuous faint audio on the main microphone before a report, while a backup runs.
    var faintDurationWithBackup: TimeInterval = 2.0
    /// How much backup sound the faint span must contain before a report.
    var faintBackupSoundDuration: TimeInterval = 0.5
    /// How much audio a running backup delivers, with no main buffer in that time, before a report.
    var missingBuffersDurationWithBackup: TimeInterval = 1.0
    /// Wall-clock time with no main buffer before a report, with no backup running.
    var missingBuffersDurationWithoutBackup: TimeInterval = 3.0

    static let standard = MicrophoneSilenceWatchConfiguration(
        silentDurationWithBackup: 1.0,
        silentDurationWithoutBackup: 3.0,
        backupSoundPeakLevel: 0.01,
        backupSoundDuration: 0.2
    )
}

struct MicrophoneSilenceReport: Equatable {
    enum Kind: String, Equatable {
        /// The main microphone delivered exact digital silence.
        case exactSilence
        /// The main microphone stayed below the faint level while the backup heard sound.
        case faintAudio
        /// The main microphone delivered no buffers.
        case noBuffers
    }

    var kind: Kind = .exactSilence
    /// How long the main microphone had been silent, faint or without buffers at the report.
    var silentDuration: TimeInterval
    /// True when the backup heard sound while the main microphone was silent.
    var backupHeardSound: Bool
}

/// Watches a whole recording for a main microphone that delivers exact digital silence, audio
/// too faint to be speech, or no buffers.
/// Exact silence: it reports once per silent span, after `silentDurationWithBackup` when the
/// backup heard sound in that span, or after `silentDurationWithoutBackup` when no backup is
/// running. A span ends when the main microphone delivers any non-zero sample.
/// Faint audio: it reports once per faint span, after `faintDurationWithBackup` when a running
/// backup heard `faintBackupSoundDuration` of sound in that span. A span ends when a main buffer
/// reaches `faintPrimaryPeakLevel`. A span that reported exact silence does not report again as faint.
/// No buffers: it reports once per span with no main buffer, from `observeBackup` when a running
/// backup has delivered `missingBuffersDurationWithBackup` of audio in that span, or from
/// `checkPrimaryDelivery` after `missingBuffersDurationWithoutBackup` of wall-clock time when no
/// backup is running. A span ends when the main microphone delivers a buffer.
final class MicrophoneSilenceWatch: @unchecked Sendable {
    private let configuration: MicrophoneSilenceWatchConfiguration
    private let lock = NSLock()
    private var backupIsRunning = false
    private var silentDuration: TimeInterval = 0
    private var backupSoundDuration: TimeInterval = 0
    private var reportedThisSpan = false
    private var faintDuration: TimeInterval = 0
    private var faintBackupSoundDuration: TimeInterval = 0
    private var reportedThisFaintSpan = false
    /// Audio the running backup has delivered since the last main buffer.
    private var backupDurationSincePrimaryBuffer: TimeInterval = 0
    private var backupSoundSincePrimaryBuffer = false
    private var reportedMissingBuffers = false
    /// True when a main buffer has arrived since the last `checkPrimaryDelivery`.
    private var primaryBufferSinceCheck = false
    /// The first `checkPrimaryDelivery`, or the latest one that found a main buffer had arrived.
    private var lastDeliveryCheckedAt: Date?

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
        faintBackupSoundDuration = 0
        backupDurationSincePrimaryBuffer = 0
        backupSoundSincePrimaryBuffer = false
        lock.unlock()
    }

    func observePrimary(_ buffer: AVAudioPCMBuffer) -> MicrophoneSilenceReport? {
        let isExactlySilent = MicrophoneHealthMonitor.isExactlySilent(buffer)
        return observePrimary(
            duration: Self.duration(of: buffer),
            isExactlySilent: isExactlySilent,
            peakLevel: isExactlySilent ? 0 : Self.peakLevel(of: buffer)
        )
    }

    @discardableResult
    func observeBackup(_ buffer: AVAudioPCMBuffer) -> MicrophoneSilenceReport? {
        observeBackup(duration: Self.duration(of: buffer), peakLevel: Self.peakLevel(of: buffer))
    }

    /// A buffer that is not exactly silent counts as full scale, so it is never faint.
    func observePrimary(duration: TimeInterval, isExactlySilent: Bool) -> MicrophoneSilenceReport? {
        observePrimary(duration: duration, isExactlySilent: isExactlySilent, peakLevel: isExactlySilent ? 0 : 1)
    }

    func observePrimary(
        duration: TimeInterval,
        isExactlySilent: Bool,
        peakLevel: Float
    ) -> MicrophoneSilenceReport? {
        lock.lock()
        defer { lock.unlock() }

        backupDurationSincePrimaryBuffer = 0
        backupSoundSincePrimaryBuffer = false
        reportedMissingBuffers = false
        primaryBufferSinceCheck = true

        let isFaint = isExactlySilent || peakLevel < configuration.faintPrimaryPeakLevel
        if isFaint {
            faintDuration += duration
        } else {
            faintDuration = 0
            faintBackupSoundDuration = 0
            reportedThisFaintSpan = false
        }

        if isExactlySilent {
            silentDuration += duration
            if !reportedThisSpan, exactSilenceHasLastedLongEnough {
                reportedThisSpan = true
                reportedThisFaintSpan = true
                return MicrophoneSilenceReport(
                    silentDuration: silentDuration,
                    backupHeardSound: backupIsRunning
                )
            }
        } else {
            silentDuration = 0
            backupSoundDuration = 0
            reportedThisSpan = false
        }

        guard isFaint, backupIsRunning, !reportedThisFaintSpan,
              faintDuration >= configuration.faintDurationWithBackup,
              faintBackupSoundDuration >= configuration.faintBackupSoundDuration else {
            return nil
        }
        reportedThisFaintSpan = true
        return MicrophoneSilenceReport(kind: .faintAudio, silentDuration: faintDuration, backupHeardSound: true)
    }

    /// Call with the lock held.
    private var exactSilenceHasLastedLongEnough: Bool {
        if backupIsRunning {
            return backupSoundDuration >= configuration.backupSoundDuration &&
                silentDuration >= configuration.silentDurationWithBackup
        }
        return silentDuration >= configuration.silentDurationWithoutBackup
    }

    /// Backup sound counts only while the main microphone is in a silent or faint span. Buffers
    /// from a backup that is not running are not counted.
    @discardableResult
    func observeBackup(duration: TimeInterval, peakLevel: Float) -> MicrophoneSilenceReport? {
        lock.lock()
        defer { lock.unlock() }

        guard backupIsRunning else { return nil }
        if peakLevel >= configuration.backupSoundPeakLevel {
            if silentDuration > 0 {
                backupSoundDuration += duration
            }
            if faintDuration > 0 {
                faintBackupSoundDuration += duration
            }
            backupSoundSincePrimaryBuffer = true
        }
        backupDurationSincePrimaryBuffer += duration
        guard !reportedMissingBuffers,
              backupDurationSincePrimaryBuffer >= configuration.missingBuffersDurationWithBackup else {
            return nil
        }
        reportedMissingBuffers = true
        return MicrophoneSilenceReport(
            kind: .noBuffers,
            silentDuration: backupDurationSincePrimaryBuffer,
            backupHeardSound: backupSoundSincePrimaryBuffer
        )
    }

    /// Call when the recording starts and then about once a second, with the current time. Audio
    /// duration cannot measure a main microphone that delivers nothing when no backup runs, so
    /// this measures wall-clock time from the first call, or from the latest call that found a
    /// main buffer had arrived since the call before it.
    func checkPrimaryDelivery(now: Date) -> MicrophoneSilenceReport? {
        lock.lock()
        defer { lock.unlock() }

        guard let lastDeliveryCheckedAt, !primaryBufferSinceCheck else {
            lastDeliveryCheckedAt = now
            primaryBufferSinceCheck = false
            return nil
        }
        let missingDuration = now.timeIntervalSince(lastDeliveryCheckedAt)
        guard !backupIsRunning, !reportedMissingBuffers,
              missingDuration >= configuration.missingBuffersDurationWithoutBackup else {
            return nil
        }
        reportedMissingBuffers = true
        return MicrophoneSilenceReport(kind: .noBuffers, silentDuration: missingDuration, backupHeardSound: false)
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
