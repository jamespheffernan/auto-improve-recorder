import Foundation

final class AudioCaptureFanout {
    typealias ArchiveConsumer = (CapturedAudioBuffer) throws -> Void
    typealias RealtimeConsumer = (CapturedAudioBuffer) throws -> [RealtimeAudioChunk]

    private let archiveConsumer: ArchiveConsumer?
    private let realtimeConsumer: RealtimeConsumer?
    private(set) var archiveStatus: ArchiveStatus
    private(set) var realtimeStatus: RealtimeCaptureStatus
    private(set) var diagnostics = AudioCaptureDiagnostics()

    init(
        archiveStatus: ArchiveStatus = .writing,
        realtimeStatus: RealtimeCaptureStatus = .active,
        archiveConsumer: ArchiveConsumer?,
        realtimeConsumer: RealtimeConsumer?
    ) {
        self.archiveStatus = archiveConsumer == nil ? .unavailable : archiveStatus
        self.realtimeStatus = realtimeConsumer == nil ? .unavailable : realtimeStatus
        self.archiveConsumer = archiveConsumer
        self.realtimeConsumer = realtimeConsumer
    }

    @discardableResult
    func offer(_ captured: CapturedAudioBuffer) -> [RealtimeAudioChunk] {
        if case .writing = archiveStatus, let archiveConsumer {
            do {
                try archiveConsumer(captured)
                diagnostics.archiveWriteCount += 1
            } catch {
                let message = error.localizedDescription
                diagnostics.archiveFailure = message
                archiveStatus = .failed(message)
            }
        }

        guard realtimeStatus.shouldTrustForFinalTranscript, let realtimeConsumer else {
            return []
        }

        do {
            let chunks = try realtimeConsumer(captured)
            diagnostics.realtimeChunksProduced += chunks.count
            return chunks
        } catch {
            let message = error.localizedDescription
            diagnostics.realtimeFailure = message
            realtimeStatus = .failed(message)
            return []
        }
    }
}
