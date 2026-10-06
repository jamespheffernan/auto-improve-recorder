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
}

/// The transcription work for one recording.
protocol RecordingSessionHandle: AnyObject, Sendable {
    /// Called from the capture callback, off the main actor, once per event
    /// and in capture order. It does not block on model work.
    func receive(_ event: AudioCaptureEvent)

    /// Called once, after capture has stopped and the audio file is complete.
    /// Throws `CancellationError` when the handle was cancelled first.
    func finish(audioURL: URL) async throws -> TranscriptionResult

    /// Safe to call from any thread and more than once. After it returns,
    /// `receive` does nothing.
    func cancel()
}
