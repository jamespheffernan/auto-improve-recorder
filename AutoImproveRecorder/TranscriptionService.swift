import Foundation

protocol TranscriptionService {
    /// Starts the transcription work for one recording in the request's mode.
    /// It is called before the first capture buffer and does not wait for a
    /// model to load.
    func beginRecording(
        _ request: RecordingTranscriptionRequest,
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) -> any RecordingSessionHandle
}

struct LiveTranscriptionService: TranscriptionService {
    typealias Dependencies = AIRTranscriberCatalog.Dependencies

    var dependencies = Dependencies()

    func beginRecording(
        _ request: RecordingTranscriptionRequest,
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) -> any RecordingSessionHandle {
        AIRTranscriberCatalog(dependencies: dependencies).transcriber(for: request).begin(events: events)
    }
}
