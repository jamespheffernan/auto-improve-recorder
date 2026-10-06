import Foundation
import XCTest
@testable import AutoImproveRecorderCore
@testable import AutoSendRecorderCore

final class AutoSendBackupMicrophoneTests: XCTestCase {
    private let mainURL = URL(fileURLWithPath: "/tmp/recording-main.wav")
    private let backupURL = URL(fileURLWithPath: "/tmp/recording-main-backup.wav")
    private let ankerName = "Anker PowerConf C200"

    func testEmptyMainTranscriptUsesTheBackup() async {
        let run = await finishRun(main: .success("  "), backup: .success("hello from the webcam"))
        XCTAssertEqual(run.phase, .ready)
        XCTAssertEqual(run.deliveredText, "hello from the webcam")
        XCTAssertEqual(run.snapshot.backupMicrophoneUsed, ankerName)
        XCTAssertEqual(run.transcribed, [mainURL, backupURL])
        XCTAssertEqual(run.records.discarded, [mainURL])
        XCTAssertEqual(run.records.archived.map(\.audioURL), [backupURL])
        XCTAssertEqual(run.lastAudioURL, backupURL)
        XCTAssertEqual(
            present(run.snapshot),
            AutoSendRunPresentation(
                experienceState: .sent,
                statusMessage: "Pasted and sent. Used the backup microphone (Anker PowerConf C200)."
            )
        )
    }

    func testMainTranscriptionFailureUsesTheBackup() async {
        let run = await finishRun(main: .failure(BackupTestError.main), backup: .success("saved by the backup"))
        XCTAssertEqual(run.phase, .ready)
        XCTAssertEqual(run.deliveredText, "saved by the backup")
        XCTAssertEqual(run.snapshot.backupMicrophoneUsed, ankerName)
        XCTAssertEqual(run.records.archived.map(\.audioURL), [backupURL])
    }

    func testWatchReportedAndBackupHasMoreWordsUsesTheBackup() async {
        let run = await finishRun(
            main: .success("um"),
            backup: .success("the whole five minute ramble"),
            primaryWasSilent: true
        )
        XCTAssertEqual(run.deliveredText, "the whole five minute ramble")
        XCTAssertEqual(run.snapshot.backupMicrophoneUsed, ankerName)
        XCTAssertEqual(run.records.discarded, [mainURL])
    }

    func testWatchReportedButMainHasMoreWordsKeepsTheMain() async {
        let run = await finishRun(
            main: .success("the main microphone came back and heard all of it"),
            backup: .success("came back"),
            primaryWasSilent: true
        )
        XCTAssertEqual(run.deliveredText, "the main microphone came back and heard all of it")
        XCTAssertNil(run.snapshot.backupMicrophoneUsed)
        XCTAssertEqual(run.transcribed, [mainURL, backupURL])
        XCTAssertEqual(run.records.discarded, [backupURL])
        XCTAssertEqual(run.records.archived.map(\.audioURL), [mainURL])
        XCTAssertEqual(present(run.snapshot).statusMessage, "Pasted and sent.")
    }

    func testArchiveNamesTheEngineThatTranscribedTheTextThatWasUsed() async {
        let engines = [mainURL: "Main Engine", backupURL: "Backup Engine"]
        let usedBackup = await finishRun(
            main: .success("um"),
            backup: .success("the whole five minute ramble"),
            primaryWasSilent: true,
            engines: engines
        )
        XCTAssertEqual(usedBackup.records.archived.map(\.audioURL), [backupURL])
        XCTAssertEqual(usedBackup.records.archived.map(\.transcriptionEngine), ["Backup Engine"])

        let keptMain = await finishRun(
            main: .success("the main microphone came back and heard all of it"),
            backup: .success("came back"),
            primaryWasSilent: true,
            engines: engines
        )
        XCTAssertEqual(keptMain.records.archived.map(\.audioURL), [mainURL])
        XCTAssertEqual(keptMain.records.archived.map(\.transcriptionEngine), ["Main Engine"])
    }

    func testNormalRunDoesNotAskToWaitForTheBackup() async {
        let run = await finishRun(main: .success("all good"), backup: .success("all good too and longer"))
        XCTAssertEqual(run.deliveredText, "all good")
        // The capture side is told the main text is usable, so it discards the backup itself.
        XCTAssertEqual(run.unusableArguments, [false])
        XCTAssertEqual(run.transcribed, [mainURL])
        XCTAssertTrue(run.records.discarded.isEmpty)
        XCTAssertNil(run.snapshot.backupMicrophoneUsed)
    }

    func testEmptyOrFailedMainTextAsksForTheBackup() async {
        let empty = await finishRun(main: .success(""), backup: nil)
        XCTAssertEqual(empty.unusableArguments, [true])
        let failed = await finishRun(main: .failure(BackupTestError.main), backup: nil)
        XCTAssertEqual(failed.unusableArguments, [true])
    }

    func testStopFailureWithBackupTextUsesTheBackup() async {
        let run = await finishRun(
            main: .success("never read"),
            backup: .success("rescued after the capture gap"),
            stopError: BackupTestError.stop
        )
        XCTAssertEqual(run.phase, .ready)
        XCTAssertEqual(run.deliveredText, "rescued after the capture gap")
        XCTAssertEqual(run.unusableArguments, [true])
        XCTAssertEqual(run.transcribed, [backupURL])
        XCTAssertEqual(run.snapshot.backupMicrophoneUsed, ankerName)
        XCTAssertEqual(run.records.archived.map(\.audioURL), [backupURL])
        XCTAssertTrue(run.records.discarded.isEmpty)
        XCTAssertEqual(run.lastAudioURL, backupURL)
        XCTAssertEqual(
            present(run.snapshot).statusMessage,
            "Pasted and sent. Used the backup microphone (Anker PowerConf C200)."
        )
    }

    func testStopFailureWithEmptyBackupReportsTheStopFailure() async {
        let run = await finishRun(main: .success("never read"), backup: .success("  "), stopError: BackupTestError.stop)
        XCTAssertEqual(run.phase, .failed("main recording failed at stop"))
        XCTAssertEqual(run.snapshot.failureKind, .transcription)
        XCTAssertNil(run.deliveredText)
        XCTAssertNil(run.snapshot.backupMicrophoneUsed)
        XCTAssertEqual(run.records.discarded, [backupURL])
    }

    func testStopFailureWithUnreadableBackupReportsTheStopFailureAndKeepsTheFile() async {
        let run = await finishRun(
            main: .success("never read"),
            backup: .failure(BackupTestError.backup),
            stopError: BackupTestError.stop
        )
        XCTAssertEqual(run.phase, .failed("main recording failed at stop"))
        XCTAssertTrue(run.records.discarded.isEmpty)
    }

    func testStopFailureWithNoBackupReportsTheStopFailure() async {
        let run = await finishRun(main: .success("never read"), backup: nil, stopError: BackupTestError.stop)
        XCTAssertEqual(run.phase, .failed("main recording failed at stop"))
        XCTAssertEqual(run.snapshot.failureKind, .transcription)
        XCTAssertTrue(run.transcribed.isEmpty)
        XCTAssertNil(run.deliveredText)
        XCTAssertNil(run.lastAudioURL)
    }

    func testNoBackupBehavesAsBefore() async {
        let sent = await finishRun(main: .success("plain run"), backup: nil)
        XCTAssertEqual(sent.phase, .ready)
        XCTAssertEqual(sent.deliveredText, "plain run")
        XCTAssertEqual(sent.transcribed, [mainURL])
        XCTAssertTrue(sent.records.discarded.isEmpty)
        XCTAssertEqual(sent.lastAudioURL, mainURL)

        let empty = await finishRun(main: .success(""), backup: nil)
        XCTAssertEqual(empty.phase, .failed("No speech was detected. The recording was kept."))
        XCTAssertEqual(empty.snapshot.failureKind, .transcription)
        XCTAssertEqual(empty.transcribed, [mainURL])
        XCTAssertNil(empty.deliveredText)

        let failed = await finishRun(main: .failure(BackupTestError.main), backup: nil)
        XCTAssertEqual(failed.phase, .failed("main transcription failed"))
        XCTAssertTrue(failed.records.archived.isEmpty)
    }

    func testBothFailingReportsTheOriginalFailureAndKeepsBothFiles() async {
        let run = await finishRun(main: .failure(BackupTestError.main), backup: .failure(BackupTestError.backup))
        XCTAssertEqual(run.phase, .failed("main transcription failed"))
        XCTAssertEqual(run.snapshot.failureKind, .transcription)
        XCTAssertNil(run.deliveredText)
        XCTAssertTrue(run.records.discarded.isEmpty)
        XCTAssertNil(run.snapshot.backupMicrophoneUsed)
    }

    func testBothEmptyReportsNoSpeechAsBefore() async {
        let run = await finishRun(main: .success(""), backup: .success(" "), primaryWasSilent: true)
        XCTAssertEqual(run.phase, .failed("No speech was detected. The recording was kept."))
        XCTAssertEqual(run.records.archived.map(\.audioURL), [mainURL])
        XCTAssertEqual(run.records.discarded, [backupURL])
    }

    func testSnapshotCarriesTheWarningWhileRecordingAndTheNextRunStartsWithoutIt() async {
        let capture = BackupFakeCapture(mainURL: mainURL, backup: nil)
        let workflow = AutoSendWorkflow(environment: AutoSendWorkflowEnvironment(
            capture: capture,
            transcription: BackupFakeTranscript(results: [mainURL: .success("text")]),
            delivery: BackupFakeDelivery()
        ))
        await workflow.start()
        let operationID = await capture.operationID!
        let warning = AutoSendMicrophoneWarning(
            microphoneName: "BOYA mini 2",
            backupMicrophoneName: ankerName
        )

        await workflow.reportMicrophoneWarning(warning, operationID: AutoSendOperationID(rawValue: 999))
        var snapshot = await workflow.snapshot
        XCTAssertNil(snapshot.microphoneWarning)

        await workflow.reportMicrophoneWarning(warning, operationID: operationID)
        snapshot = await workflow.snapshot
        XCTAssertEqual(snapshot.phase, .recording)
        XCTAssertEqual(snapshot.microphoneWarning, warning)
        let message = "No sound from BOYA mini 2. Recording from Anker PowerConf C200."
        XCTAssertEqual(
            present(snapshot),
            AutoSendRunPresentation(
                experienceState: .recordingWarning(message),
                statusMessage: "\(message) Recording. Press Hyper-R again to send."
            )
        )
        XCTAssertEqual(AutoSendExperienceState.recordingWarning(message).tone, .warning)
        XCTAssertNil(AutoSendExperienceState.recordingWarning(message).hudLifetime)

        // A second report in the same run changes nothing.
        let sequence = snapshot.sequence
        await workflow.reportMicrophoneWarning(
            AutoSendMicrophoneWarning(microphoneName: "Other", backupMicrophoneName: nil),
            operationID: operationID
        )
        snapshot = await workflow.snapshot
        XCTAssertEqual(snapshot.sequence, sequence)
        XCTAssertEqual(snapshot.microphoneWarning, warning)

        await workflow.stop()
        snapshot = await workflow.snapshot
        XCTAssertEqual(present(snapshot).experienceState, .sent)

        await workflow.start()
        snapshot = await workflow.snapshot
        XCTAssertNil(snapshot.microphoneWarning)
        XCTAssertEqual(present(snapshot).experienceState, .recording)
    }

    func testWarningWithoutABackupNamesOnlyTheMainMicrophone() {
        XCTAssertEqual(
            AutoSendMicrophoneWarning(microphoneName: "BOYA mini 2", backupMicrophoneName: nil).message,
            "No sound from BOYA mini 2."
        )
    }

    func testWorkflowAndSharedTextChoiceAgree() {
        let pairs = [("", "hello"), ("one two", "one two three"), ("one two", "a b"), ("a b c", "a"), ("", " \n ")]
        for (main, backup) in pairs {
            XCTAssertEqual(
                AutoSendBackupTranscript.prefersBackup(mainText: main, backupText: backup),
                BackupTranscriptChoice.prefersBackup(mainText: main, backupText: backup)
            )
        }
    }

    func testBackupRecordingSwitchIsOnUnlessSetToFalse() {
        let suiteName = "AutoSendRecorderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertTrue(AutoSendSettingsStore.backupMicrophoneRecordingEnabled(in: defaults))
        defaults.set(false, forKey: "backupMicrophoneRecordingEnabled")
        XCTAssertFalse(AutoSendSettingsStore.backupMicrophoneRecordingEnabled(in: defaults))
        defaults.set(true, forKey: "backupMicrophoneRecordingEnabled")
        XCTAssertTrue(AutoSendSettingsStore.backupMicrophoneRecordingEnabled(in: defaults))
    }

    private struct FinishedRun {
        var snapshot: AutoSendRunSnapshot
        var deliveredText: String?
        var transcribed: [URL]
        var records: BackupRunRecords
        var lastAudioURL: URL?
        var unusableArguments: [Bool]
        var phase: AutoSendPhase { snapshot.phase }
    }

    /// Runs one recording to its end. `backup` nil means the capture has no backup recording.
    private func finishRun(
        main: Result<String, Error>,
        backup: Result<String, Error>?,
        primaryWasSilent: Bool = false,
        stopError: Error? = nil,
        engines: [URL: String] = [:]
    ) async -> FinishedRun {
        let capture = BackupFakeCapture(
            mainURL: mainURL,
            stopError: stopError,
            backup: backup.map { _ in
                AutoSendBackupRecording(
                    audioURL: backupURL,
                    microphoneName: ankerName,
                    primaryWasSilent: primaryWasSilent
                )
            }
        )
        var results = [mainURL: main]
        results[backupURL] = backup
        let transcript = BackupFakeTranscript(results: results, engines: engines)
        let delivery = BackupFakeDelivery()
        let records = BackupRunRecords()
        let workflow = AutoSendWorkflow(environment: AutoSendWorkflowEnvironment(
            capture: capture,
            transcription: transcript,
            delivery: delivery,
            archive: { records.archive($0) },
            discardRecording: { records.discard($0) }
        ))
        await workflow.start()
        await workflow.stop()
        return FinishedRun(
            snapshot: await workflow.snapshot,
            deliveredText: await delivery.deliveredText,
            transcribed: await transcript.calls,
            records: records,
            lastAudioURL: await workflow.lastAudioURL,
            unusableArguments: await capture.unusableArguments
        )
    }

    private func present(_ snapshot: AutoSendRunSnapshot) -> AutoSendRunPresentation {
        snapshot.presentation(triggerMode: .toggle, shortcutName: "Hyper-R", isLatched: false)
    }
}

private enum BackupTestError: LocalizedError {
    case main
    case backup
    case stop

    var errorDescription: String? {
        switch self {
        case .main: return "main transcription failed"
        case .backup: return "backup transcription failed"
        case .stop: return "main recording failed at stop"
        }
    }
}

private final class BackupRunRecords: @unchecked Sendable {
    private let lock = NSLock()
    private var storedArchived: [AutoSendTranscriptEvidence] = []
    private var storedDiscarded: [URL] = []

    var archived: [AutoSendTranscriptEvidence] {
        lock.lock()
        defer { lock.unlock() }
        return storedArchived
    }

    var discarded: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storedDiscarded
    }

    func archive(_ evidence: AutoSendTranscriptEvidence) {
        lock.lock()
        storedArchived.append(evidence)
        lock.unlock()
    }

    func discard(_ url: URL) {
        lock.lock()
        storedDiscarded.append(url)
        lock.unlock()
    }
}

private actor BackupFakeCapture: AutoSendCaptureService {
    let mainURL: URL
    let stopError: Error?
    let backup: AutoSendBackupRecording?
    private(set) var operationID: AutoSendOperationID?
    private(set) var unusableArguments: [Bool] = []

    init(mainURL: URL, stopError: Error? = nil, backup: AutoSendBackupRecording?) {
        self.mainURL = mainURL
        self.stopError = stopError
        self.backup = backup
    }

    func start(operationID: AutoSendOperationID, source: AutoSendRecordingSource) async throws {
        self.operationID = operationID
    }

    func stop(operationID: AutoSendOperationID) async throws -> URL {
        if let stopError { throw stopError }
        return mainURL
    }

    func cancel(operationID: AutoSendOperationID) async {}

    /// Like the real capture: the backup comes back only when it is needed.
    func backupRecording(
        operationID: AutoSendOperationID,
        mainTextIsUnusable: Bool
    ) async -> AutoSendBackupRecording? {
        unusableArguments.append(mainTextIsUnusable)
        guard let backup, mainTextIsUnusable || backup.primaryWasSilent else { return nil }
        return backup
    }
}

private actor BackupFakeTranscript: AutoSendTranscriptService {
    let results: [URL: Result<String, Error>]
    /// The engine name reported for each file. A file without an entry reports none.
    let engines: [URL: String]
    private(set) var calls: [URL] = []

    init(results: [URL: Result<String, Error>], engines: [URL: String] = [:]) {
        self.results = results
        self.engines = engines
    }

    func transcribe(audioURL: URL, operationID: AutoSendOperationID) async throws -> String {
        calls.append(audioURL)
        return try results[audioURL]!.get()
    }

    func transcribeNamingEngine(
        audioURL: URL,
        operationID: AutoSendOperationID
    ) async throws -> AutoSendTranscript {
        AutoSendTranscript(
            text: try await transcribe(audioURL: audioURL, operationID: operationID),
            engineName: engines[audioURL]
        )
    }

    func cancel(operationID: AutoSendOperationID) async {}
}

private actor BackupFakeDelivery: AutoSendDeliveryService {
    private(set) var deliveredText: String?

    func deliver(text: String) async throws -> AutoSendDeliveryDisposition {
        deliveredText = text
        return .sent
    }
}
