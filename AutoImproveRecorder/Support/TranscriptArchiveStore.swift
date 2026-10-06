import Foundation

struct TranscriptArchiveDraft: Equatable {
    let id: String
    let createdAt: Date
    let directoryURL: URL
    let audioURL: URL
}

struct ActiveTranscriptArchiveDraftState: Equatable {
    private(set) var draft: TranscriptArchiveDraft?
    private(set) var isCommitted = false

    mutating func replace(with draft: TranscriptArchiveDraft?) {
        self.draft = draft
        isCommitted = false
    }

    mutating func markCommittedIfCurrent(id: String) {
        guard draft?.id == id else { return }
        isCommitted = true
    }

    mutating func takeDraftToDelete() -> TranscriptArchiveDraft? {
        defer {
            draft = nil
            isCommitted = false
        }
        return isCommitted ? nil : draft
    }
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
    var dictionarySnapshot: String
    var microphonePreferenceID: String
    var microphoneResolvedID: String?
    var microphoneResolvedName: String?
    var microphoneUsedFallback: Bool
    var microphoneFallbackReason: String?
    /// The recogniser's output before any replacement rule or normalisation. Absent in records written before 24 Sep 2026.
    var recognizerTranscript: String?
    /// The recogniser's output after replacement rules only.
    var postRulesTranscript: String?
    /// What reached the destination: AIR's paste or copy, including any preview edit; ASR's sent text. Nil until delivered.
    var deliveredText: String?
    /// How `deliveredText` was delivered, for example "auto-paste", "manual-paste", "manual-copy", "sent".
    var deliveredVia: String?
    /// "AIR" or "ASR". Absent means AIR.
    var product: String?
}

extension TranscriptArchiveRecord {
    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case updatedAt
        case audioPath
        case rawTranscript
        case cleanedTranscript
        case finalTranscript
        case improveFailed
        case message
        case transcriptionMode
        case transcriptionEngine
        case improvementMode
        case cleanupMode
        case autoImproveMode
        case thresholdWords
        case dictionarySnapshot
        case microphonePreferenceID
        case microphoneResolvedID
        case microphoneResolvedName
        case microphoneUsedFallback
        case microphoneFallbackReason
        case recognizerTranscript
        case postRulesTranscript
        case deliveredText
        case deliveredVia
        case product
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        audioPath = try container.decode(String.self, forKey: .audioPath)
        rawTranscript = try container.decode(String.self, forKey: .rawTranscript)
        cleanedTranscript = try container.decode(String.self, forKey: .cleanedTranscript)
        finalTranscript = try container.decode(String.self, forKey: .finalTranscript)
        improveFailed = try container.decode(Bool.self, forKey: .improveFailed)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        transcriptionMode = try container.decode(String.self, forKey: .transcriptionMode)
        transcriptionEngine = try container.decodeIfPresent(String.self, forKey: .transcriptionEngine)
        improvementMode = try container.decode(String.self, forKey: .improvementMode)
        cleanupMode = try container.decode(String.self, forKey: .cleanupMode)
        autoImproveMode = try container.decode(String.self, forKey: .autoImproveMode)
        thresholdWords = try container.decode(Int.self, forKey: .thresholdWords)
        dictionarySnapshot = try container.decodeIfPresent(String.self, forKey: .dictionarySnapshot) ?? ""
        microphonePreferenceID = try container.decodeIfPresent(String.self, forKey: .microphonePreferenceID) ?? ""
        microphoneResolvedID = try container.decodeIfPresent(String.self, forKey: .microphoneResolvedID)
        microphoneResolvedName = try container.decodeIfPresent(String.self, forKey: .microphoneResolvedName)
        microphoneUsedFallback = try container.decodeIfPresent(Bool.self, forKey: .microphoneUsedFallback) ?? false
        microphoneFallbackReason = try container.decodeIfPresent(String.self, forKey: .microphoneFallbackReason)
        recognizerTranscript = try container.decodeIfPresent(String.self, forKey: .recognizerTranscript)
        postRulesTranscript = try container.decodeIfPresent(String.self, forKey: .postRulesTranscript)
        deliveredText = try container.decodeIfPresent(String.self, forKey: .deliveredText)
        deliveredVia = try container.decodeIfPresent(String.self, forKey: .deliveredVia)
        product = try container.decodeIfPresent(String.self, forKey: .product)
    }

    /// An ASR recording: no cleanup, no prompt terms, delivered text equals the post-processed text when sent.
    static func autoSend(
        id: String,
        createdAt: Date,
        updatedAt: Date = Date(),
        audioURL: URL,
        outcome: TranscriptRuleOutcome,
        deliveredText: String?,
        deliveredVia: String?,
        message: String?,
        transcriptionEngine: String?
    ) -> TranscriptArchiveRecord {
        TranscriptArchiveRecord(
            id: id,
            createdAt: createdAt,
            updatedAt: updatedAt,
            audioPath: audioURL.path,
            rawTranscript: outcome.final,
            cleanedTranscript: "",
            finalTranscript: outcome.final,
            improveFailed: false,
            message: message,
            transcriptionMode: "autoSend",
            transcriptionEngine: transcriptionEngine,
            improvementMode: "none",
            cleanupMode: "none",
            autoImproveMode: "off",
            thresholdWords: 0,
            dictionarySnapshot: "",
            microphonePreferenceID: "",
            microphoneResolvedID: nil,
            microphoneResolvedName: nil,
            microphoneUsedFallback: false,
            microphoneFallbackReason: nil,
            recognizerTranscript: outcome.recognizer,
            postRulesTranscript: outcome.afterRules,
            deliveredText: deliveredText,
            deliveredVia: deliveredVia,
            product: "ASR"
        )
    }
}

enum TranscriptArchiveStore {
    private static let appDirectoryName = "AutoImproveRecorder"
    private static let archiveDirectoryName = "TranscriptTruth"
    private static let recordFileName = "record.json"
    private static let indexFileName = "index.jsonl"

    static func prepareRecording(createdAt: Date = Date()) throws -> TranscriptArchiveDraft {
        let id = UUID().uuidString
        let directoryURL = defaultRoot()
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

    static func recordURL(for id: String, root: URL = defaultRoot()) -> URL {
        root
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent(recordFileName)
    }

    @discardableResult
    static func save(_ record: TranscriptArchiveRecord, root: URL = defaultRoot()) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(record)
            let recordURL = recordURL(for: record.id, root: root)
            try FileManager.default.createDirectory(
                at: recordURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: recordURL, options: .atomic)
            appendIndex(record, root: root)
            return true
        } catch {
            NSLog("TranscriptArchiveStore save failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Saves an ASR recording's record, keyed by the audio file's name.
    @discardableResult
    static func saveAutoSend(
        audioURL: URL,
        outcome: TranscriptRuleOutcome,
        deliveredText: String?,
        deliveredVia: String?,
        message: String?,
        transcriptionEngine: String?,
        root: URL = autoSendRoot()
    ) -> Bool {
        let name = audioURL.deletingPathExtension().lastPathComponent
        let record = TranscriptArchiveRecord.autoSend(
            id: name.isEmpty ? UUID().uuidString : name,
            createdAt: Date(),
            audioURL: audioURL,
            outcome: outcome,
            deliveredText: deliveredText,
            deliveredVia: deliveredVia,
            message: message,
            transcriptionEngine: transcriptionEngine
        )
        return save(record, root: root)
    }

    /// AIR's archive root.
    static func defaultRoot() -> URL {
        root(appDirectoryName: appDirectoryName)
    }

    /// ASR's archive root, beside its recordings.
    static func autoSendRoot() -> URL {
        root(appDirectoryName: "Auto Send Recorder")
    }

    private static func root(appDirectoryName: String) -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser

        return base
            .appendingPathComponent(appDirectoryName, isDirectory: true)
            .appendingPathComponent(archiveDirectoryName, isDirectory: true)
    }

    private static func appendIndex(_ record: TranscriptArchiveRecord, root: URL) {
        let indexURL = root.appendingPathComponent(indexFileName)
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
        indexRow.recognizerTranscript = indexRow.recognizerTranscript.map { String($0.prefix(500)) }
        indexRow.postRulesTranscript = indexRow.postRulesTranscript.map { String($0.prefix(500)) }
        indexRow.deliveredText = indexRow.deliveredText.map { String($0.prefix(500)) }

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
