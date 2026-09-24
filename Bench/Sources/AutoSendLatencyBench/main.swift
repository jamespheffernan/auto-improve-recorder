import CryptoKit
import Darwin
import Foundation

private let measuredLiveParakeetSpeechFinalizeMilliseconds = 30.82
private let fixedPasteSettlementMilliseconds = 80.0
private let expectedBaselineGoldenSHA256 = "67ea4dfb0ba00e6ab67b5a941041ae42e9971cc5b9e8bd1c159a8e355d386071"
private let expectedCandidateGoldenSHA256 = "67ca63409ddca1607a07367d079c26bfca2f713b614afaf404a75dc116733752"

private enum HarnessMode: String, Codable, CaseIterable {
    case baseline
    case candidate
}

private enum SendCommand: String, Codable {
    case none
    case enter
    case commandEnter
}

private struct DeliveryRule: Codable {
    let bundleIdentifier: String
    let shouldPaste: Bool
    let sendCommand: SendCommand
}

private struct Fixture: Codable {
    let id: String
    let bundleIdentifier: String
    let displayName: String
    let fakeTranscript: String
    let acceptsText: Bool
    let accessibilityTrusted: Bool
}

private struct DeliveryEvent: Codable, Equatable {
    let fixtureID: String
    let bundleIdentifier: String
    let text: String
    let action: String
    let sendCommand: SendCommand
}

private struct GoldenEnvelope: Codable, Equatable {
    let schemaVersion: Int
    let mode: HarnessMode
    let outputs: [DeliveryEvent]
}

private struct Percentiles: Codable {
    let p50: Double
    let p95: Double
    let p99: Double
}

private struct StageMetrics: Codable {
    let unit: String
    let fakeTranscription: Percentiles
    let normalization: Percentiles
    let deliveryPolicy: Percentiles
    let orchestrationTotal: Percentiles
}

private struct LiveEvidence: Codable {
    let source: String
    let hardware: String
    let speechFinalizeMilliseconds: Double
    let longRecordingFinalizeMilliseconds: Double
    let maximumRSSBytes: UInt64
    let peakFootprintBytes: UInt64
}

private struct ComposedEstimate: Codable {
    let warning: String
    let liveFinalizeMilliseconds: Double
    let orchestrationP50Milliseconds: Double
    let orchestrationP95Milliseconds: Double
    let orchestrationP99Milliseconds: Double
    let fixedPasteSettlementMilliseconds: Double
    let planningEstimateUsingMedianOrchestrationMilliseconds: Double
    let planningEstimateUsingUpperTailOrchestrationMilliseconds: Double
    let planningEstimateUsingExtremeTailOrchestrationMilliseconds: Double
}

private struct MemoryMetrics: Codable {
    let maximumResidentSetBytes: UInt64
    let physicalMemoryBytes: UInt64
}

private struct Summary: Codable {
    let schemaVersion: Int
    let scope: String
    let mode: HarnessMode
    let runs: Int
    let iterationsPerRun: Int
    let fixtureCount: Int
    let operationsPerRun: Int
    let stages: StageMetrics
    let fixedPasteSettlementMilliseconds: Double
    let liveEvidence: LiveEvidence
    let composedEstimate: ComposedEstimate
    let memory: MemoryMetrics
    let goldenSHA256: String
    let expectedGoldenSHA256: String
    let goldenVerification: String
}

private struct Options {
    var mode: HarnessMode = .baseline
    var runs = 30
    var iterationsPerRun = 5_000
    var evidenceDirectory: URL?
}

private struct StageSample {
    let fakeTranscriptionNanosecondsPerOperation: Double
    let normalizationNanosecondsPerOperation: Double
    let deliveryPolicyNanosecondsPerOperation: Double
    let orchestrationTotalNanosecondsPerOperation: Double
}

private let fixtures = [
    Fixture(
        id: "default-enter",
        bundleIdentifier: "com.apple.TextEdit",
        displayName: "TextEdit",
        fakeTranscript: "  Meet me on August twenty third at nine.  ",
        acceptsText: true,
        accessibilityTrusted: true
    ),
    Fixture(
        id: "slack-command-enter",
        bundleIdentifier: "com.tinyspeck.slackmacgap",
        displayName: "Slack",
        fakeTranscript: "Ship build one hundred and twenty three when the checks pass.",
        acceptsText: true,
        accessibilityTrusted: true
    ),
    Fixture(
        id: "whatsapp-no-send",
        bundleIdentifier: "net.whatsapp.WhatsApp",
        displayName: "WhatsApp",
        fakeTranscript: "I will arrive at seven thirty.",
        acceptsText: true,
        accessibilityTrusted: true
    ),
    Fixture(
        id: "terminal-copy-only",
        bundleIdentifier: "com.apple.Terminal",
        displayName: "Terminal",
        fakeTranscript: "Run release build then send the result.",
        acceptsText: true,
        accessibilityTrusted: true
    ),
    Fixture(
        id: "untrusted-copy-fallback",
        bundleIdentifier: "com.example.UntrustedEditor",
        displayName: "Untrusted Editor",
        fakeTranscript: "Keep this text available on the clipboard.",
        acceptsText: true,
        accessibilityTrusted: false
    ),
]

private let baselineRules = [
    DeliveryRule(
        bundleIdentifier: "net.whatsapp.WhatsApp",
        shouldPaste: true,
        sendCommand: .none
    ),
]

// Candidate hook: this models the requested per-application command choice.
// It has no product dependency and does not claim that the product has this behavior.
private let candidateRules = [
    DeliveryRule(
        bundleIdentifier: "com.tinyspeck.slackmacgap",
        shouldPaste: true,
        sendCommand: .commandEnter
    ),
    DeliveryRule(
        bundleIdentifier: "net.whatsapp.WhatsApp",
        shouldPaste: true,
        sendCommand: .none
    ),
    DeliveryRule(
        bundleIdentifier: "com.apple.Terminal",
        shouldPaste: false,
        sendCommand: .none
    ),
]

@inline(never)
private func fakeTranscribe(_ fixture: Fixture) -> String {
    String(fixture.fakeTranscript)
}

@inline(never)
private func normalize(_ transcript: String) -> String {
    let compact = transcript
        .split(whereSeparator: \ .isWhitespace)
        .joined(separator: " ")

    let replacements = [
        "twenty third": "23rd",
        "one hundred and twenty three": "123",
        "seven thirty": "7:30",
    ]
    return replacements.reduce(compact) { text, pair in
        text.replacingOccurrences(of: pair.key, with: pair.value, options: [.caseInsensitive])
    }
}

@inline(never)
private func resolveDelivery(
    fixture: Fixture,
    text: String,
    mode: HarnessMode
) -> DeliveryEvent {
    let rules = mode == .baseline ? baselineRules : candidateRules
    let rule = rules.first { $0.bundleIdentifier == fixture.bundleIdentifier }
    let shouldPaste = rule?.shouldPaste ?? true
    let defaultCommand: SendCommand = .enter
    let sendCommand = rule?.sendCommand ?? defaultCommand

    guard fixture.accessibilityTrusted, fixture.acceptsText, shouldPaste else {
        return DeliveryEvent(
            fixtureID: fixture.id,
            bundleIdentifier: fixture.bundleIdentifier,
            text: text,
            action: "copy",
            sendCommand: .none
        )
    }

    return DeliveryEvent(
        fixtureID: fixture.id,
        bundleIdentifier: fixture.bundleIdentifier,
        text: text,
        action: sendCommand == .none ? "paste" : "pasteAndSend",
        sendCommand: sendCommand
    )
}

@inline(never)
private func consume(_ event: DeliveryEvent) -> Int {
    event.text.utf8.count &+ event.bundleIdentifier.utf8.count &+ event.sendCommand.rawValue.utf8.count
}

private func runTrial(mode: HarnessMode, iterations: Int) -> StageSample {
    var transcriptionNanoseconds: UInt64 = 0
    var normalizationNanoseconds: UInt64 = 0
    var deliveryNanoseconds: UInt64 = 0
    var totalNanoseconds: UInt64 = 0
    var checksum = 0

    for iteration in 0..<iterations {
        for fixture in fixtures {
            let totalStart = DispatchTime.now().uptimeNanoseconds

            let transcriptionStart = DispatchTime.now().uptimeNanoseconds
            let transcript = fakeTranscribe(fixture)
            transcriptionNanoseconds &+= DispatchTime.now().uptimeNanoseconds &- transcriptionStart

            let normalizationStart = DispatchTime.now().uptimeNanoseconds
            let normalized = normalize(transcript)
            normalizationNanoseconds &+= DispatchTime.now().uptimeNanoseconds &- normalizationStart

            let deliveryStart = DispatchTime.now().uptimeNanoseconds
            let event = resolveDelivery(fixture: fixture, text: normalized, mode: mode)
            checksum &+= consume(event) &+ iteration
            deliveryNanoseconds &+= DispatchTime.now().uptimeNanoseconds &- deliveryStart

            totalNanoseconds &+= DispatchTime.now().uptimeNanoseconds &- totalStart
        }
    }

    precondition(checksum != 0)
    let operationCount = Double(iterations * fixtures.count)
    return StageSample(
        fakeTranscriptionNanosecondsPerOperation: Double(transcriptionNanoseconds) / operationCount,
        normalizationNanosecondsPerOperation: Double(normalizationNanoseconds) / operationCount,
        deliveryPolicyNanosecondsPerOperation: Double(deliveryNanoseconds) / operationCount,
        orchestrationTotalNanosecondsPerOperation: Double(totalNanoseconds) / operationCount
    )
}

private func percentile(_ values: [Double], _ percentile: Double) -> Double {
    precondition(!values.isEmpty)
    let sorted = values.sorted()
    let rank = Int(ceil(percentile * Double(sorted.count))) - 1
    return sorted[max(0, min(rank, sorted.count - 1))]
}

private func percentiles(_ values: [Double]) -> Percentiles {
    Percentiles(
        p50: percentile(values, 0.50),
        p95: percentile(values, 0.95),
        p99: percentile(values, 0.99)
    )
}

private func makeGolden(mode: HarnessMode) -> GoldenEnvelope {
    GoldenEnvelope(
        schemaVersion: 1,
        mode: mode,
        outputs: fixtures.map { fixture in
            resolveDelivery(
                fixture: fixture,
                text: normalize(fakeTranscribe(fixture)),
                mode: mode
            )
        }
    )
}

private func encoded<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value) + Data([0x0A])
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func maximumResidentSetBytes() -> UInt64 {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return UInt64(max(0, usage.ru_maxrss))
}

private func parseOptions() throws -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())
    while !arguments.isEmpty {
        let argument = arguments.removeFirst()
        switch argument {
        case "--mode":
            guard let raw = arguments.first, let mode = HarnessMode(rawValue: raw) else {
                throw NSError(domain: "AutoSendLatencyBench", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "--mode requires baseline or candidate",
                ])
            }
            arguments.removeFirst()
            options.mode = mode
        case "--runs":
            guard let raw = arguments.first, let value = Int(raw), value >= 10 else {
                throw NSError(domain: "AutoSendLatencyBench", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "--runs requires an integer of at least 10",
                ])
            }
            arguments.removeFirst()
            options.runs = value
        case "--iterations":
            guard let raw = arguments.first, let value = Int(raw), value > 0 else {
                throw NSError(domain: "AutoSendLatencyBench", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "--iterations requires a positive integer",
                ])
            }
            arguments.removeFirst()
            options.iterationsPerRun = value
        case "--evidence-directory":
            guard let path = arguments.first else {
                throw NSError(domain: "AutoSendLatencyBench", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "--evidence-directory requires a path",
                ])
            }
            arguments.removeFirst()
            options.evidenceDirectory = URL(fileURLWithPath: path, isDirectory: true)
        case "--help", "-h":
            print("AutoSendLatencyBench [--mode baseline|candidate] [--runs N>=10] [--iterations N] [--evidence-directory PATH]")
            exit(EXIT_SUCCESS)
        default:
            throw NSError(domain: "AutoSendLatencyBench", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Unknown argument: \(argument)",
            ])
        }
    }
    return options
}

private func writeEvidence(
    directory: URL,
    mode: HarnessMode,
    summaryData: Data,
    goldenData: Data,
    goldenDigest: String
) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let summaryURL = directory.appendingPathComponent("\(mode.rawValue)-summary.json")
    let goldenURL = directory.appendingPathComponent("\(mode.rawValue)-golden.json")
    let checksumURL = directory.appendingPathComponent("\(mode.rawValue)-golden.sha256")
    try summaryData.write(to: summaryURL, options: .atomic)
    try goldenData.write(to: goldenURL, options: .atomic)
    try "\(goldenDigest)  \(goldenURL.lastPathComponent)\n".write(
        to: checksumURL,
        atomically: true,
        encoding: .utf8
    )

    let reread = try Data(contentsOf: goldenURL)
    guard sha256(reread) == goldenDigest else {
        throw NSError(domain: "AutoSendLatencyBench", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Golden checksum verification failed after write",
        ])
    }
}

do {
    let options = try parseOptions()

    // Warm-up is kept outside the measured runs.
    _ = runTrial(mode: options.mode, iterations: min(options.iterationsPerRun, 1_000))

    var samples: [StageSample] = []
    samples.reserveCapacity(options.runs)
    for _ in 0..<options.runs {
        samples.append(runTrial(mode: options.mode, iterations: options.iterationsPerRun))
    }

    let total = percentiles(samples.map(\ .orchestrationTotalNanosecondsPerOperation))
    let golden = makeGolden(mode: options.mode)
    let goldenData = try encoded(golden)
    let goldenDigest = sha256(goldenData)
    let expectedGoldenDigest = options.mode == .baseline
        ? expectedBaselineGoldenSHA256
        : expectedCandidateGoldenSHA256
    guard goldenDigest == expectedGoldenDigest else {
        throw NSError(domain: "AutoSendLatencyBench", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "Behavior golden changed: expected \(expectedGoldenDigest), got \(goldenDigest)",
        ])
    }
    let estimate = ComposedEstimate(
        warning: "This combines separate live-model evidence, a synthetic orchestration benchmark, and a fixed event delay. It is not measured application latency.",
        liveFinalizeMilliseconds: measuredLiveParakeetSpeechFinalizeMilliseconds,
        orchestrationP50Milliseconds: total.p50 / 1_000_000,
        orchestrationP95Milliseconds: total.p95 / 1_000_000,
        orchestrationP99Milliseconds: total.p99 / 1_000_000,
        fixedPasteSettlementMilliseconds: fixedPasteSettlementMilliseconds,
        planningEstimateUsingMedianOrchestrationMilliseconds: measuredLiveParakeetSpeechFinalizeMilliseconds + total.p50 / 1_000_000 + fixedPasteSettlementMilliseconds,
        planningEstimateUsingUpperTailOrchestrationMilliseconds: measuredLiveParakeetSpeechFinalizeMilliseconds + total.p95 / 1_000_000 + fixedPasteSettlementMilliseconds,
        planningEstimateUsingExtremeTailOrchestrationMilliseconds: measuredLiveParakeetSpeechFinalizeMilliseconds + total.p99 / 1_000_000 + fixedPasteSettlementMilliseconds
    )
    let summary = Summary(
        schemaVersion: 1,
        scope: "Synthetic fake-transcription bridge, representative normalization, and delivery-policy orchestration only. No pasteboard, Accessibility event, app focus, recording, or model execution is measured.",
        mode: options.mode,
        runs: options.runs,
        iterationsPerRun: options.iterationsPerRun,
        fixtureCount: fixtures.count,
        operationsPerRun: options.iterationsPerRun * fixtures.count,
        stages: StageMetrics(
            unit: "nanoseconds per fixture operation",
            fakeTranscription: percentiles(samples.map(\ .fakeTranscriptionNanosecondsPerOperation)),
            normalization: percentiles(samples.map(\ .normalizationNanosecondsPerOperation)),
            deliveryPolicy: percentiles(samples.map(\ .deliveryPolicyNanosecondsPerOperation)),
            orchestrationTotal: total
        ),
        fixedPasteSettlementMilliseconds: fixedPasteSettlementMilliseconds,
        liveEvidence: LiveEvidence(
            source: "Docs/PARAKEET_DISCOVERY.md, current installed Nemotron 3.5 q8_0 on Apple M4",
            hardware: "Apple M4",
            speechFinalizeMilliseconds: measuredLiveParakeetSpeechFinalizeMilliseconds,
            longRecordingFinalizeMilliseconds: 25.10,
            maximumRSSBytes: 2_300_000_000,
            peakFootprintBytes: 2_470_000_000
        ),
        composedEstimate: estimate,
        memory: MemoryMetrics(
            maximumResidentSetBytes: maximumResidentSetBytes(),
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
        ),
        goldenSHA256: goldenDigest,
        expectedGoldenSHA256: expectedGoldenDigest,
        goldenVerification: "passed against the checked-in expected SHA-256; evidence mode also rereads the written file"
    )
    let summaryData = try encoded(summary)

    if let evidenceDirectory = options.evidenceDirectory {
        try writeEvidence(
            directory: evidenceDirectory,
            mode: options.mode,
            summaryData: summaryData,
            goldenData: goldenData,
            goldenDigest: goldenDigest
        )
    }

    FileHandle.standardOutput.write(summaryData)
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}
