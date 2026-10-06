import Foundation
import XCTest
@testable import AutoImproveRecorderDictionaryCore
@testable import AutoSendRecorderCore

/// ASR wiring as AutoSendState builds it: SharedReplacementRules.process feeds `processTranscript`,
/// and the archive hook writes TranscriptArchiveStore.saveAutoSend records.
final class AutoSendLexiconTests: XCTestCase {
    func testASRAppliesTheSeedRuleBeforeSendingAndArchivesThreeTexts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("asr-lexicon-\(UUID().uuidString)", isDirectory: true)
        let termsURL = root.appendingPathComponent("lexicon/terms.json")
        try FileManager.default.createDirectory(at: termsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Self.seedTermsJSON.utf8).write(to: termsURL)
        let rules = SharedReplacementRules(
            lexicon: LexiconReader(url: termsURL),
            manualDirectoryURL: root.appendingPathComponent("NoManualDictionary")
        )
        let archiveRoot = root.appendingPathComponent("TranscriptTruth")
        let archived = EvidenceBox()
        let delivery = RecordingDelivery()
        let workflow = AutoSendWorkflow(environment: AutoSendWorkflowEnvironment(
            capture: StubCapture(url: root.appendingPathComponent("recording-fixture.wav")),
            transcription: StubTranscript(text: "put it on perf review"),
            delivery: delivery,
            processTranscript: {
                let outcome = rules.process($0)
                return AutoSendProcessedTranscript(afterRules: outcome.afterRules, final: outcome.final)
            },
            archive: { evidence in
                archived.append(evidence)
                TranscriptArchiveStore.saveAutoSend(
                    audioURL: evidence.audioURL,
                    outcome: TranscriptRuleOutcome(
                        recognizer: evidence.recognizerText,
                        afterRules: evidence.afterRulesText,
                        final: evidence.finalText
                    ),
                    deliveredText: evidence.deliveredText,
                    deliveredVia: evidence.disposition?.archiveLabel,
                    message: evidence.failure,
                    root: archiveRoot
                )
            }
        ))

        await workflow.start()
        let stopped = await workflow.stop()

        XCTAssertTrue(stopped)
        let sent = await delivery.text
        XCTAssertEqual(sent, "put it on Turf Review")
        XCTAssertEqual(archived.items.count, 1)

        let recordURL = TranscriptArchiveStore.recordURL(for: "recording-fixture", root: archiveRoot)
        let record = try JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any]
        XCTAssertEqual(record?["recognizerTranscript"] as? String, "put it on perf review")
        XCTAssertEqual(record?["postRulesTranscript"] as? String, "put it on Turf Review")
        XCTAssertEqual(record?["deliveredText"] as? String, "put it on Turf Review")
        XCTAssertEqual(record?["deliveredVia"] as? String, "sent")
        XCTAssertEqual(record?["product"] as? String, "ASR")
    }

    func testASRReadsAIRsManualRulesWithoutWritingThem() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("asr-manual-\(UUID().uuidString)", isDirectory: true)
        let dictionary = root.appendingPathComponent("Dictionary")
        try FileManager.default.createDirectory(at: dictionary, withIntermediateDirectories: true)
        let rulesFile = dictionary.appendingPathComponent("replacement-rules.json")
        let manual = #"{"rules":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","phrase":"perf review","replacement":"performance review","source":"manual","createdAt":"2026-06-04T10:00:00Z"}]}"#
        try Data(manual.utf8).write(to: rulesFile)
        let termsURL = root.appendingPathComponent("terms.json")
        try Data(Self.seedTermsJSON.utf8).write(to: termsURL)
        let before = try Data(contentsOf: rulesFile)

        let outcome = SharedReplacementRules(lexicon: LexiconReader(url: termsURL), manualDirectoryURL: dictionary)
            .process("put it on perf review")

        XCTAssertEqual(outcome.final, "put it on performance review", "a manual rule for the same phrase wins")
        XCTAssertEqual(try Data(contentsOf: rulesFile), before)
    }

    static let seedTermsJSON = """
    {"schemaVersion": 1, "terms": [{"text": "Turf Review", "score": 3}],
     "rules": [{"heard": "perf review", "meant": "Turf Review",
                "evidence": [{"kind": "user-correction", "ref": "chat correction, 23 Sep 2026"}]}]}
    """
}

private final class EvidenceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AutoSendTranscriptEvidence] = []

    func append(_ evidence: AutoSendTranscriptEvidence) {
        lock.lock()
        stored.append(evidence)
        lock.unlock()
    }

    var items: [AutoSendTranscriptEvidence] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private actor StubCapture: AutoSendCaptureService {
    let url: URL
    init(url: URL) { self.url = url }
    func start(operationID: AutoSendOperationID, source: AutoSendRecordingSource) async throws {}
    func stop(operationID: AutoSendOperationID) async throws -> URL { url }
    func cancel(operationID: AutoSendOperationID) async {}
}

private actor StubTranscript: AutoSendTranscriptService {
    let text: String
    init(text: String) { self.text = text }
    func transcribe(audioURL: URL, operationID: AutoSendOperationID) async throws -> String { text }
    func cancel(operationID: AutoSendOperationID) async {}
}

private actor RecordingDelivery: AutoSendDeliveryService {
    private(set) var text: String?
    func deliver(text: String) async throws -> AutoSendDeliveryDisposition {
        self.text = text
        return .sent
    }
}
