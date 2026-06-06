import Foundation

struct TranscriptArchiveContent: Equatable {
    var rawTranscript: String
    var cleanedTranscript: String
    var finalTranscript: String
    var improveFailed: Bool
    var message: String?
    var dictionarySnapshot: String
}

struct TranscriptArchiveMetadata: Equatable {
    var updatedAt: Date
    var transcriptionMode: String
    var transcriptionEngine: String?
    var improvementMode: String
    var cleanupMode: String
    var autoImproveMode: String
    var thresholdWords: Int
    var microphonePreferenceID: String
    var microphoneResolvedID: String?
    var microphoneResolvedName: String?
    var microphoneUsedFallback: Bool
    var microphoneFallbackReason: String?
}

protocol TranscriptArchiveClient {
    func prepareRecording(createdAt: Date) throws -> TranscriptArchiveDraft
    func deleteDraft(_ draft: TranscriptArchiveDraft?)
    func record(
        draft: TranscriptArchiveDraft,
        content: TranscriptArchiveContent,
        metadata: TranscriptArchiveMetadata
    ) -> TranscriptArchiveRecord
    func save(_ record: TranscriptArchiveRecord) -> Bool
}

struct LiveTranscriptArchiveClient: TranscriptArchiveClient {
    func prepareRecording(createdAt: Date = Date()) throws -> TranscriptArchiveDraft {
        try TranscriptArchiveStore.prepareRecording(createdAt: createdAt)
    }

    func deleteDraft(_ draft: TranscriptArchiveDraft?) {
        TranscriptArchiveStore.deleteDraft(draft)
    }

    func record(
        draft: TranscriptArchiveDraft,
        content: TranscriptArchiveContent,
        metadata: TranscriptArchiveMetadata
    ) -> TranscriptArchiveRecord {
        TranscriptArchiveRecord(
            id: draft.id,
            createdAt: draft.createdAt,
            updatedAt: metadata.updatedAt,
            audioPath: draft.audioURL.path,
            rawTranscript: content.rawTranscript,
            cleanedTranscript: content.cleanedTranscript,
            finalTranscript: content.finalTranscript,
            improveFailed: content.improveFailed,
            message: content.message,
            transcriptionMode: metadata.transcriptionMode,
            transcriptionEngine: metadata.transcriptionEngine,
            improvementMode: metadata.improvementMode,
            cleanupMode: metadata.cleanupMode,
            autoImproveMode: metadata.autoImproveMode,
            thresholdWords: metadata.thresholdWords,
            dictionarySnapshot: content.dictionarySnapshot,
            microphonePreferenceID: metadata.microphonePreferenceID,
            microphoneResolvedID: metadata.microphoneResolvedID,
            microphoneResolvedName: metadata.microphoneResolvedName,
            microphoneUsedFallback: metadata.microphoneUsedFallback,
            microphoneFallbackReason: metadata.microphoneFallbackReason
        )
    }

    func save(_ record: TranscriptArchiveRecord) -> Bool {
        TranscriptArchiveStore.save(record)
    }
}
