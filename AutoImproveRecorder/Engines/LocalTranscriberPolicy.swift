import Foundation

/// The checks that decide whether live Parakeet may run on this Mac.
struct ParakeetLiveGate: Sendable {
    static let minimumPhysicalMemory: UInt64 = 16 * 1_024 * 1_024 * 1_024

    var physicalMemory: @Sendable () -> UInt64
    /// True when the one-shot CLI, its model and its ggml library are
    /// installed, so a live recording always has a fallback.
    var oneShotRuntimeIsInstalled: @Sendable () -> Bool
    var liveIsAvailable: @Sendable () -> Bool

    var isSafe: Bool {
        physicalMemory() >= Self.minimumPhysicalMemory &&
            oneShotRuntimeIsInstalled() &&
            liveIsAvailable()
    }
}

extension ParakeetLiveGate {
    /// This Mac's memory, the given one-shot runtime and the recommended live
    /// model.
    static func installed(oneShot: ParakeetOneShotProcess) -> ParakeetLiveGate {
        ParakeetLiveGate(
            physicalMemory: { ProcessInfo.processInfo.physicalMemory },
            oneShotRuntimeIsInstalled: { oneShot.runtimeIsInstalled },
            liveIsAvailable: { RecommendedLiveTranscription.isAvailable }
        )
    }
}

/// Chooses the local engines for one recording from its model and source:
///
/// - Phonon-2 uses Phonon-2 only. A failure is the result.
/// - Parakeet from the hot key uses live Parakeet when the gate is safe, then
///   the one-shot CLI when live throws or returns no text. When the gate is
///   not safe it uses the one-shot CLI only.
/// - Parakeet from the wireless button uses the resident model, then the
///   one-shot CLI when the resident model throws or returns no text. It never
///   starts a live session.
struct LocalTranscriberPolicy: Sendable {
    enum Model: Sendable {
        case phonon
        case parakeet
    }

    enum Source: Sendable {
        case hotKey
        case wirelessButton
    }

    var phonon: any RecordingTranscriber
    var parakeetLive: any RecordingTranscriber
    var parakeetResident: any RecordingTranscriber
    var parakeetOneShot: any RecordingTranscriber
    var liveGate: ParakeetLiveGate

    /// Parakeet warms the resident model first and then, if the gate is safe
    /// at that point, the live model. The one-shot CLI has no warm-up.
    func warmUp(model: Model) async {
        switch model {
        case .phonon:
            await phonon.warmUp()
        case .parakeet:
            await parakeetResident.warmUp()
            if liveGate.isSafe {
                await parakeetLive.warmUp()
            }
        }
    }

    func begin(model: Model, source: Source) -> any RecordingSessionHandle {
        switch model {
        case .phonon:
            return phonon.begin()
        case .parakeet:
            // The gate is read for the wireless button too, although its
            // answer is not used there. Reading it can load the Parakeet
            // library for the first time, and that has always happened before
            // capture starts for both sources.
            let liveIsSafe = liveGate.isSafe
            if source == .wirelessButton {
                return FallbackRecordingHandle(
                    primary: parakeetResident.begin(),
                    fallback: parakeetOneShot.begin()
                )
            }
            guard liveIsSafe else {
                return parakeetOneShot.begin()
            }
            return FallbackRecordingHandle(
                primary: parakeetLive.begin(),
                fallback: parakeetOneShot.begin()
            )
        }
    }

    /// The handle for a recording that reaches finish without a handle from
    /// `begin`. It reads the saved file only: Phonon-2 for Phonon-2, the
    /// one-shot CLI for Parakeet.
    func beginWithoutCapture(model: Model) -> any RecordingSessionHandle {
        switch model {
        case .phonon:
            return phonon.begin()
        case .parakeet:
            return parakeetOneShot.begin()
        }
    }
}

/// Finishes with `primary`. When that throws or returns only whitespace it
/// finishes with `fallback`, and the primary's error is not reported.
private final class FallbackRecordingHandle: RecordingSessionHandle, @unchecked Sendable {
    private let primary: any RecordingSessionHandle
    private let fallback: any RecordingSessionHandle

    init(primary: any RecordingSessionHandle, fallback: any RecordingSessionHandle) {
        self.primary = primary
        self.fallback = fallback
    }

    func receive(_ event: AudioCaptureEvent) {
        primary.receive(event)
        fallback.receive(event)
    }

    func finish(audioURL: URL) async throws -> TranscriptionResult {
        do {
            let result = try await primary.finish(audioURL: audioURL)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return TranscriptionResult(text: text, engineName: result.engineName)
            }
        } catch {
            // The saved WAV is authoritative and remains available for fallback.
        }
        return try await fallback.finish(audioURL: audioURL)
    }

    func cancel() {
        primary.cancel()
        fallback.cancel()
    }
}
