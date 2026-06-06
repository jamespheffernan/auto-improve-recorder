import AVFoundation
import Foundation

protocol AudioArchiveFileWriting {
    var fileURL: URL { get }
    func write(from buffer: AVAudioPCMBuffer) throws
}

final class AVAudioArchiveFile: AudioArchiveFileWriting {
    let fileURL: URL
    private let file: AVAudioFile

    init(url: URL, settings: [String: Any]) throws {
        self.fileURL = url
        self.file = try AVAudioFile(forWriting: url, settings: settings)
    }

    func write(from buffer: AVAudioPCMBuffer) throws {
        try file.write(from: buffer)
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
        fileFactory: @escaping FileFactory = { url, settings in
            try AVAudioArchiveFile(url: url, settings: settings)
        }
    ) {
        self.url = url
        self.settings = format.settings
        self.fileFactory = fileFactory
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
        if case .writing = status {
            status = .finished(url)
        }
        file = nil
        return status
    }

    private func fail(_ error: Error) {
        let message = error.localizedDescription
        diagnostics.archiveFailure = message
        status = .failed(message)
    }
}
