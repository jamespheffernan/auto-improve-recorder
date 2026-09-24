import XCTest
@testable import AutoImproveRecorderDictionaryCore

enum LexiconFixture {
    /// The seed rule as the generator writes it, plus terms at different scores, one inactive term
    /// and one rule backed only by a lead's assumption (which must not run).
    static let termsJSON = """
    {
      "schemaVersion": 1,
      "generatedAt": "2026-09-24T09:00:00Z",
      "classifier": {"model": "jev-1.13.0", "questionVersion": "entity-span-v1", "threshold": 0.8},
      "terms": [
        {"text": "Herdr", "score": 2.5, "probability": 0.93, "count": 4, "lastSeen": "2026-09-23T10:00:00Z", "active": true,
         "sources": [{"kind": "herdr-label", "ref": "herdr workspace list", "quote": "Herdr", "seen": "2026-09-23T10:00:00Z", "id": "a1"}]},
        {"text": "Turf Review", "score": 9.1, "probability": 0.99, "count": 12, "lastSeen": "2026-09-24T08:00:00Z", "active": true},
        {"text": "Old Project", "score": 0.1, "probability": 0.9, "count": 1, "lastSeen": "2026-05-01T08:00:00Z", "active": false}
      ],
      "rules": [
        {"heard": "perf review", "meant": "Turf Review",
         "evidence": [{"kind": "user-correction", "ref": "chat correction, 23 Sep 2026", "quote": "perf review is Turf Review", "seen": "2026-09-23T17:00:00Z", "id": "seed"}]},
        {"heard": "of", "meant": "OmniFocus",
         "evidence": [{"kind": "assumed", "ref": "pi-tasks session", "quote": "of", "seen": "2026-09-23T17:00:00Z", "id": "x"}]}
      ]
    }
    """

    static func write(_ json: String = termsJSON, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url, options: .atomic)
    }

    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("lexicon-tests-\(UUID().uuidString)", isDirectory: true)
    }
}

final class LexiconReaderTests: XCTestCase {
    func testReaderOrdersActiveTermsByScoreAndKeepsOnlyVerifiedRules() throws {
        let url = LexiconFixture.temporaryDirectory().appendingPathComponent("terms.json")
        try LexiconFixture.write(to: url)

        let snapshot = LexiconReader(url: url).reload()

        XCTAssertEqual(snapshot.terms, ["Turf Review", "Herdr"])
        XCTAssertEqual(snapshot.rules.map(\.phrase), ["perf review"])
        XCTAssertEqual(snapshot.rules.first?.replacement, "Turf Review")
        XCTAssertEqual(snapshot.rules.first?.source, "lexicon")
    }

    func testMissingFileMeansNoGeneratedTerms() {
        let url = LexiconFixture.temporaryDirectory().appendingPathComponent("terms.json")
        let reader = LexiconReader(url: url)

        XCTAssertEqual(reader.reload(), .empty)
        XCTAssertNil(reader.lastError)
    }

    func testMalformedFileKeepsLastValidSnapshot() throws {
        let url = LexiconFixture.temporaryDirectory().appendingPathComponent("terms.json")
        try LexiconFixture.write(to: url)
        let reader = LexiconReader(url: url)
        let valid = reader.reload()

        try LexiconFixture.write("{ \"schemaVersion\": 1, \"terms\": [", to: url)
        let afterMalformed = reader.reload()

        XCTAssertEqual(afterMalformed, valid)
        XCTAssertNotNil(reader.lastError)

        try LexiconFixture.write(#"{"schemaVersion": 2, "terms": [], "rules": []}"#, to: url)
        XCTAssertEqual(reader.reload(), valid)
        XCTAssertTrue(reader.lastError?.contains("schemaVersion 2") == true)
    }

    func testReloadPicksUpAChangedFile() throws {
        let url = LexiconFixture.temporaryDirectory().appendingPathComponent("terms.json")
        try LexiconFixture.write(#"{"schemaVersion": 1, "terms": [{"text": "Jev", "score": 1}], "rules": []}"#, to: url)
        let reader = LexiconReader(url: url)
        XCTAssertEqual(reader.reload().terms, ["Jev"])

        try LexiconFixture.write(to: url)
        XCTAssertEqual(reader.reload().terms, ["Turf Review", "Herdr"])
        XCTAssertNil(reader.lastError)
    }
}

final class DictionaryMergeTests: XCTestCase {
    func testManualRuleForTheSamePhraseWins() {
        let manual = DictionaryReplacementRule(id: UUID(), phrase: "Perf Review", replacement: "performance review", source: "manual", createdAt: Date())
        let lexicon = DictionaryReplacementRule(id: UUID(), phrase: "perf review", replacement: "Turf Review", source: "lexicon", createdAt: .distantPast)
        let other = DictionaryReplacementRule(id: UUID(), phrase: "her dirt", replacement: "Herdr", source: "lexicon", createdAt: .distantPast)

        let merged = DictionaryMerge.rules(manual: [manual], lexicon: [lexicon, other])

        XCTAssertEqual(merged.map(\.replacement), ["performance review", "Herdr"])
        XCTAssertEqual(ReplacementRuleEngine.apply("put it on perf review", rules: merged), "put it on performance review")
    }

    func testTermsPutManualFirstAndCapTheRecogniserList() {
        let lexicon = (1...80).map { "Term\($0)" }

        let cleanup = DictionaryMerge.cleanupTerms(manual: ["Field Theory", "term1"], lexicon: lexicon)
        XCTAssertEqual(cleanup.first, "Field Theory")
        XCTAssertEqual(cleanup.count, 1 + 50, "term1 duplicates Term1 case-insensitively")

        let transcription = DictionaryMerge.transcriptionTerms(manual: ["Field Theory"], lexicon: lexicon)
        XCTAssertEqual(transcription.first, "Field Theory")
        XCTAssertEqual(transcription.count, 20)

        let long = (1...40).map { "A very long multiword project name number \($0)" }
        let budgeted = DictionaryMerge.transcriptionTerms(manual: [], lexicon: long)
        let tokens = budgeted.reduce(0) { $0 + DictionaryMerge.approximateTokens($1) + 1 }
        XCTAssertLessThanOrEqual(tokens, DictionaryMerge.transcriptionTokenBudget)
        XCTAssertLessThan(budgeted.count, 20)
    }
}

@MainActor
final class AIRLexiconTests: XCTestCase {
    func testAIRAppliesTheSeedRuleFromTermsJSON() throws {
        let root = LexiconFixture.temporaryDirectory()
        let termsURL = root.appendingPathComponent("lexicon/terms.json")
        try LexiconFixture.write(to: termsURL)
        let store = UserDictionaryStore(
            directoryURL: root.appendingPathComponent("Dictionary"),
            lexiconReader: LexiconReader(url: termsURL)
        )

        XCTAssertEqual(store.applyReplacementRules(to: "put it on perf review"), "put it on Turf Review")

        let outcome = TranscriptPostProcessor.process("put it on perf review", rules: store.effectiveReplacementRules)
        XCTAssertEqual(outcome.recognizer, "put it on perf review")
        XCTAssertEqual(outcome.afterRules, "put it on Turf Review")
        XCTAssertEqual(outcome.final, "put it on Turf Review")
    }

    func testAIRSnapshotsCarryManualThenLexiconTermsAndReloadBeforeEachRecording() throws {
        let root = LexiconFixture.temporaryDirectory()
        let termsURL = root.appendingPathComponent("lexicon/terms.json")
        try LexiconFixture.write(#"{"schemaVersion": 1, "terms": [{"text": "Jev", "score": 1}], "rules": []}"#, to: termsURL)
        let store = UserDictionaryStore(
            directoryURL: root.appendingPathComponent("Dictionary"),
            lexiconReader: LexiconReader(url: termsURL)
        )
        try store.addEntry("Field Theory")
        XCTAssertEqual(store.currentSnapshotString, "Field Theory,Jev")

        try LexiconFixture.write(to: termsURL)
        XCTAssertEqual(store.currentSnapshotString, "Field Theory,Jev", "no reload yet")
        store.reloadLexicon()
        XCTAssertEqual(store.currentSnapshotString, "Field Theory,Turf Review,Herdr")
        XCTAssertEqual(store.transcriptionVocabularyString, "Field Theory,Turf Review,Herdr")
        XCTAssertEqual(store.applyReplacementRules(to: "perf review"), "Turf Review")
    }

    func testStoreWithoutLexiconReaderBehavesAsBefore() throws {
        let store = UserDictionaryStore(directoryURL: LexiconFixture.temporaryDirectory())
        XCTAssertEqual(store.applyReplacementRules(to: "put it on perf review"), "put it on perf review")
        XCTAssertEqual(store.lexicon, .empty)
    }
}

final class TranscriptArchiveThreeTextsTests: XCTestCase {
    func testAIRFixtureRecordingArchivesRecognizerPostRulesAndDeliveredText() throws {
        let root = LexiconFixture.temporaryDirectory()
        let draft = TranscriptArchiveDraft(
            id: "fixture-recording",
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            directoryURL: root.appendingPathComponent("fixture-recording"),
            audioURL: root.appendingPathComponent("fixture-recording/audio.wav")
        )
        let outcome = TranscriptPostProcessor.process(
            "put it on perf review at three pm",
            rules: LexiconSnapshot(file: try JSONDecoder().decode(LexiconFile.self, from: Data(LexiconFixture.termsJSON.utf8))).rules
        )
        let content = TranscriptArchiveContent(
            rawTranscript: outcome.final,
            cleanedTranscript: "",
            finalTranscript: outcome.final,
            improveFailed: false,
            message: nil,
            dictionarySnapshot: "Turf Review,Herdr",
            recognizerTranscript: outcome.recognizer,
            postRulesTranscript: outcome.afterRules,
            deliveredText: "Put it on Turf Review at 3 p.m.",
            deliveredVia: "manual-paste"
        )
        let metadata = TranscriptArchiveMetadata(
            updatedAt: Date(timeIntervalSince1970: 1_790_000_010),
            transcriptionMode: "localParakeetStreaming",
            transcriptionEngine: "parakeet.cpp",
            improvementMode: "ollamaLocal",
            cleanupMode: "lightCleanup",
            autoImproveMode: "automatic",
            thresholdWords: 35,
            microphonePreferenceID: "",
            microphoneResolvedID: nil,
            microphoneResolvedName: nil,
            microphoneUsedFallback: false,
            microphoneFallbackReason: nil
        )
        let record = LiveTranscriptArchiveClient().record(draft: draft, content: content, metadata: metadata)
        XCTAssertTrue(TranscriptArchiveStore.save(record, root: root))

        let saved = try JSONSerialization.jsonObject(
            with: Data(contentsOf: TranscriptArchiveStore.recordURL(for: "fixture-recording", root: root))
        ) as? [String: Any]
        XCTAssertEqual(saved?["recognizerTranscript"] as? String, "put it on perf review at three pm")
        XCTAssertEqual(saved?["postRulesTranscript"] as? String, "put it on Turf Review at three pm")
        XCTAssertEqual(saved?["deliveredText"] as? String, "Put it on Turf Review at 3 p.m.")
        XCTAssertEqual(saved?["deliveredVia"] as? String, "manual-paste")
        XCTAssertEqual(saved?["product"] as? String, "AIR")
        XCTAssertEqual(saved?["rawTranscript"] as? String, outcome.final, "existing field keeps its meaning")

        let index = try String(contentsOf: root.appendingPathComponent("index.jsonl"), encoding: .utf8)
        XCTAssertTrue(index.contains("\"recognizerTranscript\":\"put it on perf review at three pm\""))
    }

    func testRecordsWrittenBeforeTheChangeStillDecode() throws {
        let legacy = """
        {"id":"old","createdAt":"2026-06-01T10:00:00Z","updatedAt":"2026-06-01T10:00:01Z","audioPath":"/tmp/a.wav",
         "rawTranscript":"raw","cleanedTranscript":"","finalTranscript":"raw","improveFailed":false,
         "transcriptionMode":"localParakeetStreaming","improvementMode":"ollamaLocal","cleanupMode":"lightCleanup",
         "autoImproveMode":"automatic","thresholdWords":35}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(TranscriptArchiveRecord.self, from: Data(legacy.utf8))

        XCTAssertEqual(record.rawTranscript, "raw")
        XCTAssertNil(record.recognizerTranscript)
        XCTAssertNil(record.deliveredText)
        XCTAssertNil(record.product)
    }
}
