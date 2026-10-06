import AVFoundation
import Foundation

/// Records a second microphone to its own file with its own audio engine. Every failure is
/// logged and swallowed: nothing here throws, and all engine work runs on a private queue so the
/// main recording never waits for it.
final class BackupMicrophoneRecorder: @unchecked Sendable {
    /// The longest a caller waits for the backup file to finish.
    static let stopTimeout: TimeInterval = 1.0
    static let bufferSize: AVAudioFrameCount = 1024

    /// The backup file for a main recording: the same folder and name with "-backup" added.
    static func backupURL(forMainRecording url: URL) -> URL {
        let name = url.deletingPathExtension().lastPathComponent + "-backup"
        return url.deletingLastPathComponent()
            .appendingPathComponent(name)
            .appendingPathExtension(url.pathExtension)
    }

    private let queue = DispatchQueue(label: "recorder.audio.backup", qos: .utility)
    private let makeRecorder: () -> AudioRecorder
    /// Read and written on `queue` only.
    private var active: (recorder: AudioRecorder, url: URL, failure: BackupCaptureFailureFlag)?

    init(makeRecorder: @escaping () -> AudioRecorder = { AudioRecorder() }) {
        self.makeRecorder = makeRecorder
    }

    /// Starts recording `microphone` to `url` on the private queue. `onBuffer` runs on the audio
    /// thread for every captured buffer. `onResult` reports whether the recording started.
    func start(
        at url: URL,
        microphone: MicrophoneDevice,
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onResult: @escaping (Bool) -> Void
    ) {
        queue.async { [self] in
            if let leftover = active {
                active = nil
                _ = leftover.recorder.stopWithResult()
            }
            let recorder = makeRecorder()
            let failure = BackupCaptureFailureFlag()
            do {
                _ = try recorder.start(
                    at: url,
                    microphone: microphone,
                    bufferSize: Self.bufferSize,
                    streamHandler: { event in
                        switch event {
                        case .captured(let captured):
                            onBuffer(captured.buffer)
                        case .failure:
                            failure.set()
                        }
                    }
                )
                active = (recorder, url, failure)
                NSLog("Backup microphone recording started on %@.", microphone.name)
                onResult(true)
            } catch {
                NSLog(
                    "Backup microphone %@ could not start: %@. Recording continues without a backup.",
                    microphone.name,
                    error.localizedDescription
                )
                _ = recorder.stopWithResult()
                try? FileManager.default.removeItem(at: url)
                onResult(false)
            }
        }
    }

    /// Begins stopping the backup and returns at once. The returned value gives the finished file.
    func stop() -> BackupMicrophoneStop {
        let pending = BackupMicrophoneStop()
        queue.async { [self] in
            guard let stopping = active else {
                pending.finish(nil)
                return
            }
            active = nil
            let result = stopping.recorder.stopWithResult()
            let failureMessage = result.archiveFailureMessage
                ?? (stopping.failure.isSet ? "A captured buffer could not be copied." : nil)
            if let failureMessage {
                NSLog("Backup microphone recording was discarded: %@", failureMessage)
                try? FileManager.default.removeItem(at: stopping.url)
                pending.finish(nil)
                return
            }
            pending.finish(result.audioURL)
        }
        return pending
    }
}

/// A backup recording that is stopping. The file is ready when `wait` returns it.
final class BackupMicrophoneStop: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var url: URL?
    private var finished = false
    private var abandoned = false

    func finish(_ url: URL?) {
        lock.lock()
        self.url = abandoned ? nil : url
        finished = true
        let deleteNow = abandoned
        lock.unlock()
        if deleteNow, let url {
            try? FileManager.default.removeItem(at: url)
        }
        done.signal()
    }

    /// The finished backup file, or nil when there is none or it did not finish within `timeout`.
    /// A file that finishes after the timeout is deleted. Call once.
    func wait(timeout: TimeInterval = BackupMicrophoneRecorder.stopTimeout) -> URL? {
        let timedOut = done.wait(timeout: .now() + timeout) == .timedOut
        lock.lock()
        defer { lock.unlock() }
        if timedOut, !finished {
            abandoned = true
            NSLog("Backup microphone recording did not stop in time and was abandoned.")
            return nil
        }
        return url
    }

    /// Deletes the backup file, now or when it finishes.
    func discard() {
        lock.lock()
        let finishedURL = url
        url = nil
        abandoned = true
        lock.unlock()
        if let finishedURL {
            try? FileManager.default.removeItem(at: finishedURL)
        }
    }
}

private final class BackupCaptureFailureFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
