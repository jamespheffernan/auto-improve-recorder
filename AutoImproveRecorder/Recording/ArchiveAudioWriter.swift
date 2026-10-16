import AVFoundation
import Foundation

protocol AudioArchiveFileWriting {
    var fileURL: URL { get }
    func write(from buffer: AVAudioPCMBuffer) throws
    func finish() throws
}

final class AVAudioArchiveFile: AudioArchiveFileWriting {
    let fileURL: URL
    private var file: AVAudioFile?

    init(
        url: URL,
        settings: [String: Any],
        commonFormat: AVAudioCommonFormat,
        interleaved: Bool
    ) throws {
        self.fileURL = url
        self.file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: commonFormat,
            interleaved: interleaved
        )
    }

    func write(from buffer: AVAudioPCMBuffer) throws {
        guard let file else { throw ArchiveAudioFileError.alreadyFinished }
        try file.write(from: buffer)
    }

    func finish() throws {
        file = nil
        // AVAudioFile closes when released. Reopening the file checks that the
        // final header is readable before callers accept the archive.
        _ = try AVAudioFile(forReading: fileURL)
    }
}

private enum ArchiveAudioFileError: LocalizedError {
    case alreadyFinished

    var errorDescription: String? {
        "The audio archive was already finished."
    }
}

final class ArchiveAudioWriter {
    typealias FileFactory = (URL, [String: Any]) throws -> AudioArchiveFileWriting

    private let url: URL
    private let settings: [String: Any]
    private let fileFactory: FileFactory
    private var file: AudioArchiveFileWriting?
    private(set) var status: ArchiveStatus = .unavailable
    private(set) var diagnostics = AudioCaptureDiagnostics()

    init(
        url: URL,
        format: AVAudioFormat,
        fileFactory: FileFactory? = nil
    ) {
        self.url = url
        self.settings = format.settings
        self.fileFactory = fileFactory ?? { url, settings in
            try AVAudioArchiveFile(
                url: url,
                settings: settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
        }
    }

    func open() {
        let startedAt = Date()
        do {
            file = try fileFactory(url, settings)
            diagnostics.archiveOpenMs = Date().timeIntervalSince(startedAt) * 1000
            status = .writing
        } catch {
            diagnostics.archiveOpenMs = Date().timeIntervalSince(startedAt) * 1000
            fail(error)
        }
    }

    func append(_ captured: CapturedAudioBuffer) {
        guard case .writing = status, let file else { return }
        do {
            try file.write(from: captured.buffer)
            diagnostics.archiveWriteCount += 1
            diagnostics.archiveBytesWritten += Int(captured.frameLength) *
                Int(captured.format.streamDescription.pointee.mBytesPerFrame)
        } catch {
            self.file = nil
            fail(error)
        }
    }

    func finish() -> ArchiveStatus {
        guard case .writing = status, let file else { return status }
        do {
            try file.finish()
            self.file = nil
            status = .finished(url)
        } catch {
            self.file = nil
            fail(error)
        }
        return status
    }

    private func fail(_ error: Error) {
        let message = error.localizedDescription
        diagnostics.archiveFailure = message
        status = .failed(message)
    }
}
