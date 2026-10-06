import Foundation

enum MicrophoneSilenceCommand: Equatable {
    case ignore
    /// The silent microphone is now quarantined. Resolve again, pass the
    /// result to `restartCommand`, then call `recoveryFinished`.
    case recover(quarantinedUntil: Date)
}

enum MicrophoneRestartCommand: Equatable {
    case restart(on: MicrophoneResolution)
    /// Resolving again returned the microphone that failed.
    case giveUp
}

/// A startup silence event that was not acted on because a backup microphone had been
/// requested for the recording.
struct SkippedMicrophoneSilence: Equatable {
    var event: MicrophoneHealthEvent
    var resolution: MicrophoneResolution
}

/// Decides which microphone a recording uses and what to do when that
/// microphone fails. It has no lock of its own; the caller's isolation
/// protects it. The caller starts and stops the recorder.
struct MicrophoneRecovery {
    let retryCooldown: TimeInterval

    private(set) var quarantinedUntil: [String: Date] = [:]
    private(set) var activeResolution: MicrophoneResolution?
    private(set) var recoveryInProgress = false
    private(set) var skippedSilence: SkippedMicrophoneSilence?

    init(retryCooldown: TimeInterval) {
        self.retryCooldown = retryCooldown
    }

    func resolve(
        preferences: MicrophonePreferences,
        devices: [MicrophoneDevice],
        now: Date
    ) throws -> MicrophoneResolution {
        try MicrophoneResolver.resolve(
            preferences: preferences,
            devices: devices,
            quarantinedUntil: quarantinedUntil,
            now: now
        )
    }

    /// True only for the preferred microphone itself, not a fallback or the
    /// system default.
    static func shouldMonitor(
        _ resolution: MicrophoneResolution,
        preferredMicrophoneID: String
    ) -> Bool {
        !resolution.usedFallback &&
            !resolution.device.id.isEmpty &&
            preferredMicrophoneID == resolution.device.id
    }

    mutating func recordingStarted(on resolution: MicrophoneResolution) {
        activeResolution = resolution
        skippedSilence = nil
    }

    /// Quarantines stay in place.
    mutating func recordingEnded() {
        activeResolution = nil
        recoveryInProgress = false
        skippedSilence = nil
    }

    /// Call in place of `silentMicrophoneReported` when the event is not acted on because a
    /// backup microphone has been requested for the recording. The event is kept until
    /// `backupFailedToOpen` returns it or the recording ends or restarts.
    mutating func silentMicrophoneSkippedForBackup(
        _ event: MicrophoneHealthEvent,
        on resolution: MicrophoneResolution
    ) {
        guard event.kind == .exactSilentStartup, activeResolution == resolution else { return }
        skippedSilence = SkippedMicrophoneSilence(event: event, resolution: resolution)
    }

    /// Call when the recording's backup microphone failed to open. Returns the event that was
    /// skipped for that backup, once, while its microphone is still the active one. Pass it to
    /// `silentMicrophoneReported` now, as if it had just arrived.
    mutating func backupFailedToOpen() -> SkippedMicrophoneSilence? {
        defer { skippedSilence = nil }
        guard let skippedSilence, activeResolution == skippedSilence.resolution else { return nil }
        return skippedSilence
    }

    /// Returns when the quarantine ends, or nil for an empty id, which is
    /// not quarantined.
    @discardableResult
    mutating func quarantine(_ id: String, now: Date) -> Date? {
        guard !id.isEmpty else { return nil }
        let expiresAt = now.addingTimeInterval(retryCooldown)
        quarantinedUntil[id] = expiresAt
        return expiresAt
    }

    /// Pass the current preferred microphone ID to apply `shouldMonitor`
    /// again before recovering, or nil to skip that check.
    mutating func silentMicrophoneReported(
        _ event: MicrophoneHealthEvent,
        on resolution: MicrophoneResolution,
        recheckingPreferredMicrophoneID preferredMicrophoneID: String?,
        now: Date
    ) -> MicrophoneSilenceCommand {
        guard event.kind == .exactSilentStartup,
              !recoveryInProgress,
              activeResolution == resolution else {
            return .ignore
        }
        if let preferredMicrophoneID,
           !Self.shouldMonitor(resolution, preferredMicrophoneID: preferredMicrophoneID) {
            return .ignore
        }
        guard let expiresAt = quarantine(resolution.device.id, now: now) else {
            return .ignore
        }

        recoveryInProgress = true
        return .recover(quarantinedUntil: expiresAt)
    }

    static func restartCommand(
        replacing failed: MicrophoneResolution,
        with candidate: MicrophoneResolution
    ) -> MicrophoneRestartCommand {
        guard candidate.device.id != failed.device.id else {
            return .giveUp
        }
        return .restart(on: candidate)
    }

    mutating func recoveryFinished() {
        recoveryInProgress = false
    }
}
