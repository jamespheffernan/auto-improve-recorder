import Foundation

/// One configured way to turn a recording into text. The app picks a
/// transcriber before capture starts and keeps the handle that `begin`
/// returns until the recording is finished or cancelled.
protocol RecordingTranscriber: Sendable {
    /// Loads what the transcriber needs ahead of time. Callers do not wait
    /// for this before they start capture.
    func warmUp() async

    /// Starts the transcription work for one recording. It is called before
    /// the first capture buffer.
    func begin() -> any RecordingSessionHandle

    /// The same as `begin()`, for a caller that shows what the transcriber
    /// reports. `events` is awaited in order while `finish` runs.
    func begin(
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) -> any RecordingSessionHandle
}

/// What a transcriber reports while it works on one recording.
enum TranscriptionEvent: Equatable, Sendable {
    /// A line for the app to show as its status.
    case status(String)
    /// A problem for the app to keep in its diagnostics.
    case diagnostic(TranscriptionDiagnostic)
}

struct TranscriptionDiagnostic: Equatable, Sendable {
    let summary: String
    let details: String
}

extension RecordingTranscriber {
    /// Transcribers that report nothing ignore `events`.
    func begin(
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) -> any RecordingSessionHandle {
        begin()
    }
}

/// The transcription work for one recording.
protocol RecordingSessionHandle: AnyObject, Sendable {
    /// The first capture failure the handle received, or nil. Read when
    /// capture has stopped, before `finish` or `cancel`.
    var captureFailure: AudioCaptureFailure? { get }

    /// Called from the capture callback, off the main actor, once per event
    /// and in capture order. It does not block on model work.
    func receive(_ event: AudioCaptureEvent)

    /// Starts the work that needs capture to be running, such as opening a
    /// socket. Called at most once, after capture has started; the caller
    /// does not wait for it before the first capture buffer. Returns the
    /// status line to show when the work has ended, or nil. It returns nil
    /// when the recording stopped or the handle was cancelled first.
    func prepare() async -> String?

    /// Called once, on the caller's thread, when the recording is about to
    /// stop and before capture is stopped. Work that `prepare` has not ended
    /// by then is given up. Returns the status line to show while `finish`
    /// runs, or nil when the handle has none of its own.
    func captureWillStop() -> String?

    /// Called once, after capture has stopped and the audio file is complete.
    /// Throws `CancellationError` when the handle was cancelled first.
    func finish(audioURL: URL) async throws -> TranscriptionResult

    /// Safe to call from any thread and more than once. After it returns,
    /// `receive` does nothing.
    func cancel()
}

extension RecordingSessionHandle {
    /// Handles that do not keep capture failures report none.
    var captureFailure: AudioCaptureFailure? { nil }

    /// Handles with nothing to start after capture do nothing.
    func prepare() async -> String? { nil }

    func captureWillStop() -> String? { nil }
}
