import XCTest
@testable import AutoImproveRecorderCore

@MainActor
final class DictionaryStoreTests: XCTestCase {
    func testNormalizationRejectsEmptyEntries() throws {
        let store = try makeStore()

        XCTAssertEqual(UserDictionaryStore.normalizedText("  Field\tTheory \n Dictionary  "), "Field Theory Dictionary")
        XCTAssertThrowsError(try store.addEntry(" \n\t "))
    }

    func testDictionaryDedupesCaseInsensitivelyAndSnapshotsNewestFirst() throws {
        let store = try makeStore()
        let oldDate = Date(timeIntervalSince1970: 100)
        let newDate = Date(timeIntervalSince1970: 200)

        _ = try store.addEntry("Field Theory", id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, createdAt: oldDate)
        _ = try store.addEntry("Auto Improve", id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, createdAt: newDate)
        let duplicate = try store.addEntry(" field theory ", id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, createdAt: Date(timeIntervalSince1970: 300))

        XCTAssertNil(duplicate)
        XCTAssertEqual(store.entries.map(\.text), ["Auto Improve", "Field Theory"])
        XCTAssertEqual(store.currentSnapshotString, "Auto Improve,Field Theory")
    }

    func testReplacementRulesApplyLongestPhraseFirstWithBoundaries() throws {
        let store = try makeStore()
        _ = try store.addReplacementRule(
            phrase: "cat",
            replacement: "dog",
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        _ = try store.addReplacementRule(
            phrase: "cat scan",
            replacement: "MRI",
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
            createdAt: Date(timeIntervalSince1970: 200)
        )

        let result = store.applyReplacementRules(to: "Order a cat scan, then review concatenate and cat notes.")

        XCTAssertEqual(result, "Order a MRI, then review concatenate and dog notes.")
    }

    func testJSONPersistenceRoundTripsEntriesAndReplacementRules() throws {
        let directory = try makeTemporaryDirectory()
        var store: UserDictionaryStore? = UserDictionaryStore(directoryURL: directory)
        _ = try store?.addEntry(
            "Parakeet.cpp",
            source: "manual",
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        _ = try store?.addReplacementRule(
            phrase: "air",
            replacement: "AIR",
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000007")!,
            createdAt: Date(timeIntervalSince1970: 200)
        )
        store = nil

        let reloaded = UserDictionaryStore(directoryURL: directory)

        XCTAssertNil(reloaded.lastLoadError)
        XCTAssertEqual(reloaded.entries.map(\.text), ["Parakeet.cpp"])
        XCTAssertEqual(reloaded.replacementRules.map(\.replacement), ["AIR"])
    }

    func testSuperwhisperImportParsesDictionaryAndReplacementData() throws {
        let store = try makeStore()
        let sourceURL = try makeTemporaryDirectory().appendingPathComponent("settings.json")
        let json = """
        {
          "Dictionary": [
            {"phrase": "  Field   Theory ", "manualEntry": 1, "isSnippet": 0, "isDeleted": 0},
            {"phrase": "auto improved", "replacement": "Auto Improve", "manualEntry": true, "isSnippet": false, "isDeleted": false},
            {"phrase": "snippet", "replacement": "Skipped", "manualEntry": true, "isSnippet": true, "isDeleted": false},
            {"phrase": "deleted", "manualEntry": true, "isSnippet": false, "isDeleted": true}
          ]
        }
        """
        try json.write(to: sourceURL, atomically: true, encoding: .utf8)

        let result = try store.importSuperwhisper(candidateURLs: [sourceURL])

        XCTAssertEqual(result.sourceURL, sourceURL)
        XCTAssertEqual(result.addedEntries, 2)
        XCTAssertEqual(result.addedReplacementRules, 1)
        XCTAssertEqual(store.entries.map(\.text), ["Auto Improve", "Field Theory"])
        XCTAssertEqual(store.entries.map(\.source), ["import:superwhisper", "import:superwhisper"])
        XCTAssertEqual(store.replacementRules.map(\.phrase), ["auto improved"])
        XCTAssertEqual(store.replacementRules.map(\.replacement), ["Auto Improve"])
    }

    func testArchiveRecordDecodesOlderJSONWithoutDictionarySnapshot() throws {
        let json = """
        {
          "id": "archive-1",
          "createdAt": "2026-06-04T12:00:00Z",
          "updatedAt": "2026-06-04T12:01:00Z",
          "audioPath": "/tmp/audio.wav",
          "rawTranscript": "raw",
          "cleanedTranscript": "clean",
          "finalTranscript": "final",
          "improveFailed": false,
          "message": null,
          "transcriptionMode": "parakeet",
          "transcriptionEngine": "parakeet.cpp",
          "improvementMode": "ollama",
          "cleanupMode": "near-verbatim",
          "autoImproveMode": "off",
          "thresholdWords": 9
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let record = try decoder.decode(TranscriptArchiveRecord.self, from: Data(json.utf8))

        XCTAssertEqual(record.id, "archive-1")
        XCTAssertEqual(record.dictionarySnapshot, "")
        XCTAssertEqual(record.microphonePreferenceID, "")
        XCTAssertNil(record.microphoneResolvedID)
        XCTAssertNil(record.microphoneResolvedName)
        XCTAssertFalse(record.microphoneUsedFallback)
        XCTAssertNil(record.microphoneFallbackReason)
    }

    func testArchiveRecordEncodesDictionarySnapshot() throws {
        let record = TranscriptArchiveRecord(
            id: "archive-2",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200),
            audioPath: "/tmp/audio.wav",
            rawTranscript: "Service Verification Alpha",
            cleanedTranscript: "Service Verification Alpha",
            finalTranscript: "Service Verification Alpha",
            improveFailed: false,
            message: nil,
            transcriptionMode: "parakeet",
            transcriptionEngine: "parakeet.cpp",
            improvementMode: "ollama",
            cleanupMode: "near-verbatim",
            autoImproveMode: "off",
            thresholdWords: 9,
            dictionarySnapshot: "Service Verification Alpha,Settings Verification Term",
            microphonePreferenceID: "boya",
            microphoneResolvedID: "built-in",
            microphoneResolvedName: "MacBook Pro Microphone",
            microphoneUsedFallback: true,
            microphoneFallbackReason: "preferredQuarantined"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        let encoded = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(encoded.contains("\"dictionarySnapshot\""))
        XCTAssertTrue(encoded.contains("Service Verification Alpha,Settings Verification Term"))
        XCTAssertTrue(encoded.contains("\"microphoneResolvedName\""))
        XCTAssertTrue(encoded.contains("MacBook Pro Microphone"))
        XCTAssertTrue(encoded.contains("\"microphoneFallbackReason\""))
        XCTAssertTrue(encoded.contains("preferredQuarantined"))
    }

    func testArchiveClientBuildsRecordFromDraftContentAndMetadata() throws {
        let draft = TranscriptArchiveDraft(
            id: "archive-client-1",
            createdAt: Date(timeIntervalSince1970: 100),
            directoryURL: URL(fileURLWithPath: "/tmp/archive-client-1", isDirectory: true),
            audioURL: URL(fileURLWithPath: "/tmp/archive-client-1/audio.wav")
        )
        let content = TranscriptArchiveContent(
            rawTranscript: "raw text",
            cleanedTranscript: "clean text",
            finalTranscript: "final text",
            improveFailed: true,
            message: "cleanup failed",
            dictionarySnapshot: "AIR,Parakeet"
        )
        let metadata = TranscriptArchiveMetadata(
            updatedAt: Date(timeIntervalSince1970: 200),
            transcriptionMode: "fastest",
            transcriptionEngine: "OpenAI realtime",
            improvementMode: "ollama",
            cleanupMode: "lightCleanup",
            autoImproveMode: "automatic",
            thresholdWords: 35,
            microphonePreferenceID: "preferred-mic",
            microphoneResolvedID: "fallback-mic",
            microphoneResolvedName: "Built-in Microphone",
            microphoneUsedFallback: true,
            microphoneFallbackReason: "preferredQuarantined"
        )

        let record = LiveTranscriptArchiveClient().record(
            draft: draft,
            content: content,
            metadata: metadata
        )

        XCTAssertEqual(record.id, "archive-client-1")
        XCTAssertEqual(record.createdAt, draft.createdAt)
        XCTAssertEqual(record.updatedAt, metadata.updatedAt)
        XCTAssertEqual(record.audioPath, "/tmp/archive-client-1/audio.wav")
        XCTAssertEqual(record.finalTranscript, "final text")
        XCTAssertTrue(record.improveFailed)
        XCTAssertEqual(record.dictionarySnapshot, "AIR,Parakeet")
        XCTAssertEqual(record.microphoneResolvedID, "fallback-mic")
        XCTAssertTrue(record.microphoneUsedFallback)
        XCTAssertEqual(record.microphoneFallbackReason, "preferredQuarantined")
    }

    func testActiveArchiveDraftStateDeletesOnlyUncommittedDrafts() throws {
        let draft = TranscriptArchiveDraft(
            id: "archive-3",
            createdAt: Date(timeIntervalSince1970: 300),
            directoryURL: URL(fileURLWithPath: "/tmp/archive-3", isDirectory: true),
            audioURL: URL(fileURLWithPath: "/tmp/archive-3/audio.wav")
        )
        var state = ActiveTranscriptArchiveDraftState()

        state.replace(with: draft)

        XCTAssertEqual(state.takeDraftToDelete(), draft)
        XCTAssertNil(state.draft)
        XCTAssertFalse(state.isCommitted)
    }

    func testActiveArchiveDraftStateKeepsCommittedCurrentDraft() throws {
        let draft = TranscriptArchiveDraft(
            id: "archive-4",
            createdAt: Date(timeIntervalSince1970: 400),
            directoryURL: URL(fileURLWithPath: "/tmp/archive-4", isDirectory: true),
            audioURL: URL(fileURLWithPath: "/tmp/archive-4/audio.wav")
        )
        var state = ActiveTranscriptArchiveDraftState()

        state.replace(with: draft)
        state.markCommittedIfCurrent(id: "archive-4")

        XCTAssertNil(state.takeDraftToDelete())
        XCTAssertNil(state.draft)
        XCTAssertFalse(state.isCommitted)
    }

    func testActiveArchiveDraftStateDoesNotCommitDifferentDraftID() throws {
        let draft = TranscriptArchiveDraft(
            id: "archive-5",
            createdAt: Date(timeIntervalSince1970: 500),
            directoryURL: URL(fileURLWithPath: "/tmp/archive-5", isDirectory: true),
            audioURL: URL(fileURLWithPath: "/tmp/archive-5/audio.wav")
        )
        var state = ActiveTranscriptArchiveDraftState()

        state.replace(with: draft)
        state.markCommittedIfCurrent(id: "archive-other")

        XCTAssertEqual(state.takeDraftToDelete(), draft)
    }

    func testRealtimeDiagnosticsRedactsNestedPromptFields() {
        let diagnosticJSON = RealtimeDiagnosticsRedactor.redactedJSON(
            [
                "type": "session.updated",
                "session": [
                    "prompt": "KitchenLux, Service Verification Alpha",
                    "instructions": [
                        ["Prompt": "Case-insensitive nested leak"],
                        ["text": "safe detail"]
                    ]
                ]
            ],
            fallback: "fallback"
        )

        XCTAssertTrue(diagnosticJSON.contains("\"prompt\" : \"<redacted>\""))
        XCTAssertTrue(diagnosticJSON.contains("\"Prompt\" : \"<redacted>\""))
        XCTAssertTrue(diagnosticJSON.contains("safe detail"))
        XCTAssertFalse(diagnosticJSON.contains("KitchenLux"))
        XCTAssertFalse(diagnosticJSON.contains("Case-insensitive nested leak"))
    }

    func testRealtimeProviderErrorRedactsOnlyWhenDictionaryPromptWasActive() {
        let rawMessage = "Provider rejected prompt containing KitchenLux."

        let withoutDictionary = RealtimeDiagnosticsRedactor.sanitizedProviderErrorMessage(
            rawMessage,
            dictionarySnapshot: ""
        )
        let withDictionary = RealtimeDiagnosticsRedactor.sanitizedProviderErrorMessage(
            rawMessage,
            dictionarySnapshot: "KitchenLux"
        )

        XCTAssertEqual(withoutDictionary, rawMessage)
        XCTAssertEqual(
            withDictionary,
            "Realtime API error. Dictionary prompt was active; provider message redacted."
        )
        XCTAssertFalse(withDictionary.contains("KitchenLux"))
    }

    private func makeStore() throws -> UserDictionaryStore {
        UserDictionaryStore(directoryURL: try makeTemporaryDirectory())
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("air-dictionary-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}
