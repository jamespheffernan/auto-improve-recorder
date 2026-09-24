import Foundation
import XCTest
@testable import AutoImproveRecorderDictionaryCore

final class TranscriptEditValueGateTests: XCTestCase {
    func testBypassesPasteReadyTextInInitialModes() {
        let text = "The app should preserve raw transcripts, keep the audio file, and show a clear error if improvement fails."

        for mode in [TranscriptEditValueGate.Mode.verbatim, .lightCleanup] {
            XCTAssertEqual(
                TranscriptEditValueGate.evaluate(transcript: text, mode: mode),
                .init(action: .bypassImprovement, reason: .pasteReady, bypassText: text)
            )
        }
    }

    func testTransformationModesAlwaysImprove() {
        let text = "The app should preserve raw transcripts, keep the audio file, and show a clear error if improvement fails."

        for mode in [TranscriptEditValueGate.Mode.promptCleanup, .structuredTask] {
            XCTAssertEqual(
                TranscriptEditValueGate.evaluate(transcript: text, mode: mode),
                .init(action: .improve, reason: .modeRequiresTransformation, bypassText: nil)
            )
        }
    }

    func testDictionaryContextAlwaysImproves() {
        let result = TranscriptEditValueGate.evaluate(
            transcript: "The project names are Auto Improve Recorder, Field Theory, and Transcript Truth.",
            mode: .lightCleanup,
            dictionarySnapshot: "Transcript Truth -> TranscriptTruth"
        )

        XCTAssertEqual(result.action, .improve)
        XCTAssertEqual(result.reason, .contextualReplacementPossible)
        XCTAssertNil(result.bypassText)
    }

    func testReturnsSpecificReasonForEachConservativeCheck() {
        let cases: [(String, TranscriptEditValueGate.Reason)] = [
            ("", .emptyTranscript),
            ("Too short.", .unsafeWordCount),
            ("This sentence has  two spaces, so local cleanup remains useful.", .nonCanonicalWhitespace),
            ("Please clean this up and make it sound like a short project update.", .explicitTransformationRequest),
            ("Um, this sentence contains enough words and has complete punctuation.", .dictationArtifact),
            ("This sentence repeats repeats a word and therefore still needs model cleanup.", .repeatedAdjacentWord),
            ("Does this complete and otherwise clean sentence need an answer?", .questionNeedsJudgment),
            ("I feel like this complete sentence has a likely cleanup opportunity.", .personalVoiceCleanupSignal),
            ("Okay, this complete sentence starts with a removable discourse marker.", .leadingDiscourseMarker),
            ("With the same limits in place, please review this complete request.", .frontLoadedRequest),
            ("This is just a complete sentence with a likely cleanup opportunity.", .likelyCleanupOpportunity),
            ("This sentence contains enough words to require an internal punctuation mark before it can safely bypass the model", .missingInternalPunctuation),
            ("This complete sentence has enough words, but it lacks terminal punctuation", .missingTerminalPunctuation),
            ("this complete sentence has enough words, but it starts with lowercase text.", .lowercaseOpening)
        ]

        for (text, expectedReason) in cases {
            let result = TranscriptEditValueGate.evaluate(transcript: text, mode: .lightCleanup)
            XCTAssertEqual(result.action, .improve, "Expected improve for: \(text)")
            XCTAssertEqual(result.reason, expectedReason, "Unexpected reason for: \(text)")
            XCTAssertTrue(result.shouldImprove)
            XCTAssertNil(result.bypassText)
        }
    }

    func testTrimsOuterWhitespaceWithoutRewritingBypassText() {
        let text = "  The app should preserve raw transcripts, keep the audio file, and show a clear error if improvement fails.\n"

        let result = TranscriptEditValueGate.evaluate(transcript: text, mode: .verbatim)

        XCTAssertEqual(result.action, .bypassImprovement)
        XCTAssertEqual(
            result.bypassText,
            "The app should preserve raw transcripts, keep the audio file, and show a clear error if improvement fails."
        )
        XCTAssertFalse(result.shouldImprove)
    }

    func testEvaluationIsDeterministic() {
        let text = "First record the audio, then transcribe it, then run cleanup, then paste the final text."
        let expected = TranscriptEditValueGate.evaluate(transcript: text, mode: .lightCleanup)

        for _ in 0..<1_000 {
            XCTAssertEqual(
                TranscriptEditValueGate.evaluate(transcript: text, mode: .lightCleanup),
                expected
            )
        }
    }

    func testSharedRouteBypassesBeforeEveryProviderSelection() async {
        let providerModes = ["openAI", "geminiFlash", "claudeHaiku", "appleLocal", "ollamaLocal"]
        let text = "The app should preserve raw transcripts, keep the audio file, and show a clear error if improvement fails."

        for providerMode in providerModes {
            var selectedProviders: [String] = []
            var deltas: [String] = []
            let output = await TranscriptEditValueGate.route(
                transcript: text,
                mode: .lightCleanup,
                onBypass: { deltas.append($0) }
            ) {
                selectedProviders.append(providerMode)
                return "Provider output"
            }

            XCTAssertEqual(output, text, providerMode)
            XCTAssertEqual(deltas, [text], providerMode)
            XCTAssertTrue(selectedProviders.isEmpty, providerMode)
        }
    }

    func testSharedRouteSelectsEveryProviderWhenImprovementIsRequired() async {
        let providerModes = ["openAI", "geminiFlash", "claudeHaiku", "appleLocal", "ollamaLocal"]

        for providerMode in providerModes {
            var selectedProviders: [String] = []
            var deltas: [String] = []
            let output = await TranscriptEditValueGate.route(
                transcript: "Please turn this into a structured task with clear deliverables.",
                mode: .structuredTask,
                onBypass: { deltas.append($0) }
            ) {
                selectedProviders.append(providerMode)
                return "Provider output from \(providerMode)"
            }

            XCTAssertEqual(output, "Provider output from \(providerMode)")
            XCTAssertTrue(deltas.isEmpty, providerMode)
            XCTAssertEqual(selectedProviders, [providerMode])
        }
    }

    func testReadAloudTruthCorpusHasZeroFalseBypasses() throws {
        let corpus = try loadReadAloudCorpus()
        let observations = corpus.items.map { item in
            CorpusObservation(
                expectedBypass: item.readTranscript == item.referenceImproved,
                actualBypass: TranscriptEditValueGate.evaluate(
                    transcript: item.readTranscript,
                    mode: .lightCleanup
                ).action == .bypassImprovement
            )
        }
        let metrics = CorpusMetrics(observations: observations)

        print("TranscriptEditValueGate read-aloud metrics: \(metrics)")
        XCTAssertEqual(metrics.total, 16)
        XCTAssertEqual(metrics.safeBypassCandidates, 5)
        // The speech-artifact check deliberately sends the exact-match
        // "audio dot wav" fixture to improvement instead of taking a risk.
        XCTAssertEqual(metrics.bypasses, 4)
        XCTAssertEqual(metrics.falseBypasses, 0)
        XCTAssertEqual(metrics.precision, 1.0)
        XCTAssertEqual(metrics.coverage, 0.8)
    }

    func testTranscriptTruthCorpusHasZeroFalseBypassesWhenRequested() throws {
        guard let directory = ProcessInfo.processInfo.environment["AIR_TRANSCRIPT_TRUTH_DIR"] else {
            throw XCTSkip("Set AIR_TRANSCRIPT_TRUTH_DIR to run the private TranscriptTruth audit.")
        }

        let truthDirectory = URL(fileURLWithPath: directory).resolvingSymlinksInPath()
        let observations = try FileManager.default
            .contentsOfDirectory(at: truthDirectory, includingPropertiesForKeys: nil)
            .compactMap { recordDirectory -> CorpusObservation? in
                guard let observation = try transcriptTruthObservation(at: recordDirectory) else {
                    return nil
                }
                if observation.actualBypass && !observation.expectedBypass {
                    print("TranscriptEditValueGate false-bypass record: \(recordDirectory.lastPathComponent)")
                }
                return observation
            }
        let metrics = CorpusMetrics(observations: observations)

        print("TranscriptEditValueGate TranscriptTruth metrics: \(metrics)")
        XCTAssertFalse(observations.isEmpty)
        XCTAssertEqual(metrics.falseBypasses, 0)
        XCTAssertEqual(metrics.precision, 1.0)
    }

    private func loadReadAloudCorpus() throws -> ReadAloudCorpus {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repositoryRoot.appendingPathComponent("Bench/read_aloud_items.json")
        return try JSONDecoder().decode(ReadAloudCorpus.self, from: Data(contentsOf: url))
    }

    private func transcriptTruthObservation(at directory: URL) throws -> CorpusObservation? {
        let recordURL = directory.appendingPathComponent("record.json")
        guard FileManager.default.fileExists(atPath: recordURL.path) else { return nil }

        let record = try JSONDecoder().decode(TranscriptTruthRecord.self, from: Data(contentsOf: recordURL))
        guard let mode = TranscriptEditValueGate.Mode(rawValue: record.cleanupMode),
              mode == .verbatim || mode == .lightCleanup else {
            return nil
        }

        let raw = record.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = record.cleanedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !cleaned.isEmpty else { return nil }

        return CorpusObservation(
            expectedBypass: raw == cleaned,
            actualBypass: TranscriptEditValueGate.evaluate(
                transcript: record.rawTranscript,
                mode: mode
            ).action == .bypassImprovement
        )
    }
}

private struct ReadAloudCorpus: Decodable {
    let items: [ReadAloudItem]
}

private struct ReadAloudItem: Decodable {
    let readTranscript: String
    let referenceImproved: String

    enum CodingKeys: String, CodingKey {
        case readTranscript = "read_transcript"
        case referenceImproved = "reference_improved"
    }
}

private struct TranscriptTruthRecord: Decodable {
    let rawTranscript: String
    let cleanedTranscript: String
    let cleanupMode: String
}

private struct CorpusObservation {
    let expectedBypass: Bool
    let actualBypass: Bool
}

private struct CorpusMetrics: CustomStringConvertible {
    let total: Int
    let safeBypassCandidates: Int
    let bypasses: Int
    let falseBypasses: Int
    let precision: Double
    let coverage: Double

    init(observations: [CorpusObservation]) {
        total = observations.count
        safeBypassCandidates = observations.filter(\.expectedBypass).count
        bypasses = observations.filter(\.actualBypass).count
        falseBypasses = observations.filter { $0.actualBypass && !$0.expectedBypass }.count
        let trueBypasses = observations.filter { $0.actualBypass && $0.expectedBypass }.count
        precision = bypasses == 0 ? 1 : Double(trueBypasses) / Double(bypasses)
        coverage = safeBypassCandidates == 0 ? 1 : Double(trueBypasses) / Double(safeBypassCandidates)
    }

    var description: String {
        "total=\(total), safe=\(safeBypassCandidates), bypasses=\(bypasses), falseBypasses=\(falseBypasses), precision=\(precision), coverage=\(coverage)"
    }
}
