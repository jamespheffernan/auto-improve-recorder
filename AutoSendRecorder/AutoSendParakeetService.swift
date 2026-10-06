import Foundation

extension ParakeetRuntimeConfiguration {
    /// ASR's Parakeet root: its own versioned runtime once the installer
    /// reports it ready, otherwise AIR's install root.
    static let app = ParakeetRuntimeConfiguration.preferring(
        { AutoSendRuntimeInstaller.destination },
        whenReady: { AutoSendRuntimeInstaller.isReady() },
        otherwise: {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/AutoImproveRecorder/ParakeetCpp")
        }
    )
}

extension LocalTranscriberPolicy {
    /// ASR's engines: Phonon-2, live Parakeet, the resident 110M model for
    /// the ESP32 button, and the one-shot CLI as the Parakeet fallback.
    static let app: LocalTranscriberPolicy = {
        let oneShot = ParakeetOneShotProcess(configuration: .app)
        return LocalTranscriberPolicy(
            phonon: PhononRecordingAdapter.shared,
            parakeetLive: ParakeetLiveRecordingAdapter.recommended,
            parakeetResident: ParakeetResidentRecordingAdapter.runtime(
                modelFilename: "tdt_ctc-110m-q4_k.gguf",
                provider: "parakeet.cpp 110M resident"
            ),
            parakeetOneShot: ParakeetOneShotRecordingAdapter.process(oneShot),
            liveGate: .installed(oneShot: oneShot)
        )
    }()
}

/// Translates ASR's selected model, recording source and operation IDs onto
/// the shared local policy and operation slot.
final class AutoSendParakeetService: AutoSendTranscriptService, @unchecked Sendable {
    private let lock = NSLock()
    private let policy = LocalTranscriberPolicy.app
    private let slot = OperationRecordingSlot()
    private var selectedModel: AutoSendTranscriptionModel

    init(model: AutoSendTranscriptionModel = .phonon2) {
        selectedModel = model
    }

    func selectModel(_ model: AutoSendTranscriptionModel) {
        lock.lock()
        selectedModel = model
        lock.unlock()
    }

    private var currentModel: LocalTranscriberPolicy.Model {
        lock.lock()
        defer { lock.unlock() }
        switch selectedModel {
        case .phonon2:
            return .phonon
        case .parakeet:
            return .parakeet
        }
    }

    func beginRecording(
        operationID: AutoSendOperationID,
        source: AutoSendRecordingSource
    ) {
        let handle = policy.begin(
            model: currentModel,
            source: source == .esp32Button ? .wirelessButton : .hotKey
        )
        slot.replace(operation: operationID.rawValue, with: handle)
    }

    func handleCaptureEvent(_ event: AudioCaptureEvent, operationID: AutoSendOperationID) {
        slot.receive(event, operation: operationID.rawValue)
    }

    /// A finish whose operation has no stored handle uses the model selected
    /// now and reads the saved file only.
    func transcribe(audioURL: URL, operationID: AutoSendOperationID) async throws -> String {
        let handle = slot.take(operation: operationID.rawValue)
            ?? policy.beginWithoutCapture(model: currentModel)
        return try await handle.finish(audioURL: audioURL).text
    }

    func cancel(operationID: AutoSendOperationID) async {
        slot.cancel(operation: operationID.rawValue)
    }

    func warmUp() async {
        await policy.warmUp(model: currentModel)
    }
}
