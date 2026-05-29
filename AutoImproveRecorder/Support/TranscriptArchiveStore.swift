import Foundation

struct TranscriptArchiveDraft: Equatable {
    let id: String
    let createdAt: Date
    let directoryURL: URL
    let audioURL: URL
}

struct TranscriptArchiveRecord: Codable, Equatable {
    var id: String
    var createdAt: Date
    var updatedAt: Date
    var audioPath: String
    var rawTranscript: String
    var cleanedTranscript: String
    var finalTranscript: String
    var improveFailed: Bool
    var message: String?
    var transcriptionMode: String
    var transcriptionEngine: String?
    var improvementMode: String
    var cleanupMode: String
    var autoImproveMode: String
    var thresholdWords: Int
}

enum TranscriptArchiveStore {
    private static let appDirectoryName = "AutoImproveRecorder"
    private static let archiveDirectoryName = "TranscriptTruth"
    private static let recordFileName = "record.json"
    private static let indexFileName = "index.jsonl"

    static func prepareRecording(createdAt: Date = Date()) throws -> TranscriptArchiveDraft {
        let id = UUID().uuidString
        let directoryURL = archiveRoot()
            .appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        return TranscriptArchiveDraft(
            id: id,
            createdAt: createdAt,
            directoryURL: directoryURL,
            audioURL: directoryURL.appendingPathComponent("audio.wav")
        )
    }

    static func deleteDraft(_ draft: TranscriptArchiveDraft?) {
        guard let draft else { return }
        try? FileManager.default.removeItem(at: draft.directoryURL)
    }

    static func recordURL(for id: String) -> URL {
        archiveRoot()
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent(recordFileName)
    }

    static func save(_ record: TranscriptArchiveRecord) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(record)
            let recordURL = recordURL(for: record.id)
            try FileManager.default.createDirectory(
                at: recordURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: recordURL, options: .atomic)
            appendIndex(record)
        } catch {
            NSLog("TranscriptArchiveStore save failed: \(error.localizedDescription)")
        }
    }

    private static func archiveRoot() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser

        return base
            .appendingPathComponent(appDirectoryName, isDirectory: true)
            .appendingPathComponent(archiveDirectoryName, isDirectory: true)
    }

    private static func appendIndex(_ record: TranscriptArchiveRecord) {
        let indexURL = archiveRoot().appendingPathComponent(indexFileName)
        var indexRow = record
        if indexRow.rawTranscript.count > 500 {
            indexRow.rawTranscript = String(indexRow.rawTranscript.prefix(500))
        }
        if indexRow.cleanedTranscript.count > 500 {
            indexRow.cleanedTranscript = String(indexRow.cleanedTranscript.prefix(500))
        }
        if indexRow.finalTranscript.count > 500 {
            indexRow.finalTranscript = String(indexRow.finalTranscript.prefix(500))
        }

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(indexRow) + Data([0x0A])
            try FileManager.default.createDirectory(
                at: indexURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: indexURL.path) {
                let handle = try FileHandle(forWritingTo: indexURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: indexURL, options: .atomic)
            }
        } catch {
            NSLog("TranscriptArchiveStore index append failed: \(error.localizedDescription)")
        }
    }
}
