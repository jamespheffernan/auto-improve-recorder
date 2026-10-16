import AVFoundation
import XCTest
@testable import AutoImproveRecorderCore

final class MicrophoneSilenceWatchTests: XCTestCase {
    /// An eighth of a second, so sums of steps are exact.
    private let step: TimeInterval = 0.125
    private let speech: Float = 0.2
    private let roomNoise: Float = 0.001

    func testThresholdsAreTheStandardConfiguration() {
        XCTAssertEqual(
            MicrophoneSilenceWatchConfiguration.standard,
            MicrophoneSilenceWatchConfiguration(
                silentDurationWithBackup: 1.0,
                silentDurationWithoutBackup: 3.0,
                backupSoundPeakLevel: 0.01,
                backupSoundDuration: 0.2
            )
        )
    }

    func testSilenceFromTheStartWithBackupSoundReportsAfterOneSecond() {
        let watch = MicrophoneSilenceWatch()
        watch.backupStarted()
        let reports = run(watch, seconds: 2.0, primarySilent: true, backupPeak: speech)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].at, 1.0, accuracy: 0.01)
        XCTAssertTrue(reports[0].report.backupHeardSound)
    }

    func testQuietPauseWithARunningBackupNeverReports() {
        let watch = MicrophoneSilenceWatch()
        watch.backupStarted()
        XCTAssertTrue(run(watch, seconds: 20, primarySilent: true, backupPeak: roomNoise).isEmpty)
    }

    func testSpeechAfterAQuietPauseReportsAsSoonAsTheBackupHearsIt() {
        let watch = MicrophoneSilenceWatch()
        watch.backupStarted()
        XCTAssertTrue(run(watch, seconds: 5, primarySilent: true, backupPeak: roomNoise).isEmpty)
        let reports = run(watch, seconds: 1, primarySilent: true, backupPeak: speech)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].at, 0.25, accuracy: 0.01)
    }

    func testWithNoBackupRunningItReportsAfterThreeSeconds() {
        let watch = MicrophoneSilenceWatch()
        let reports = run(watch, seconds: 6, primarySilent: true, backupPeak: nil)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].at, 3.0, accuracy: 0.01)
        XCTAssertFalse(reports[0].report.backupHeardSound)
    }

    func testSilenceThatBeginsMidRecordingReports() {
        let watch = MicrophoneSilenceWatch()
        watch.backupStarted()
        XCTAssertTrue(run(watch, seconds: 30, primarySilent: false, backupPeak: speech).isEmpty)
        let reports = run(watch, seconds: 3, primarySilent: true, backupPeak: speech)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].at, 1.0, accuracy: 0.01)
    }

    func testItReportsOncePerSilentSpanAndAgainAfterRealAudioReturns() {
        let watch = MicrophoneSilenceWatch()
        watch.backupStarted()
        XCTAssertEqual(run(watch, seconds: 10, primarySilent: true, backupPeak: speech).count, 1)
        XCTAssertTrue(run(watch, seconds: 2, primarySilent: false, backupPeak: speech).isEmpty)
        XCTAssertEqual(run(watch, seconds: 10, primarySilent: true, backupPeak: speech).count, 1)
    }

    func testBackupSoundHeardBeforeTheSilentSpanDoesNotCount() {
        let watch = MicrophoneSilenceWatch()
        watch.backupStarted()
        _ = run(watch, seconds: 5, primarySilent: false, backupPeak: speech)
        XCTAssertTrue(run(watch, seconds: 5, primarySilent: true, backupPeak: roomNoise).isEmpty)
    }

    func testABackupThatStopsLeavesTheThreeSecondRule() {
        let watch = MicrophoneSilenceWatch()
        watch.backupStarted()
        XCTAssertTrue(run(watch, seconds: 2, primarySilent: true, backupPeak: roomNoise).isEmpty)
        watch.backupStopped()
        let reports = run(watch, seconds: 2, primarySilent: true, backupPeak: nil)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].at, 1.0, accuracy: 0.01)
        XCTAssertFalse(reports[0].report.backupHeardSound)
    }

    func testBuffersAreMeasuredByFramesAndExactZeroBytes() throws {
        let silent = try buffer(frames: 4_800, sample: 0)
        let loud = try buffer(frames: 4_800, sample: -0.5)
        XCTAssertEqual(MicrophoneSilenceWatch.duration(of: silent), 0.1, accuracy: 0.0001)
        XCTAssertTrue(MicrophoneHealthMonitor.isExactlySilent(silent))
        XCTAssertFalse(MicrophoneHealthMonitor.isExactlySilent(loud))
        XCTAssertEqual(MicrophoneSilenceWatch.peakLevel(of: silent), 0)
        XCTAssertEqual(MicrophoneSilenceWatch.peakLevel(of: loud), 0.5, accuracy: 0.0001)

        let watch = MicrophoneSilenceWatch()
        watch.backupStarted()
        var reports = 0
        for _ in 0..<15 {
            watch.observeBackup(loud)
            if watch.observePrimary(silent) != nil { reports += 1 }
        }
        XCTAssertEqual(reports, 1)
        XCTAssertNil(watch.observePrimary(loud))
    }

    // MARK: Faint main microphone

    func testFaintBuffersWithBackupSoundReportAfterTwoSeconds() throws {
        let watch = MicrophoneSilenceWatch()
        watch.backupStarted()
        let faint = try buffer(frames: 6_000, sample: 0.0005)
        let loud = try buffer(frames: 6_000, sample: speech)
        var reportedAfter: [Int] = []
        for index in 1...32 {
            watch.observeBackup(loud)
            if watch.observePrimary(faint) != nil {
                reportedAfter.append(index)
            }
        }
        // Sixteen buffers of an eighth of a second are two seconds.
        XCTAssertEqual(reportedAfter, [16])
    }

    /// Feeds both microphones in steps of audio time, with a peak level for the main microphone
    /// that is not exact silence. Returns each report with the audio time since this call began.
    private func runFaint(
        _ watch: MicrophoneSilenceWatch,
        seconds: TimeInterval,
        primaryPeak: Float,
        backupPeak: Float?
    ) -> [(at: TimeInterval, report: MicrophoneSilenceReport)] {
        var reports: [(at: TimeInterval, report: MicrophoneSilenceReport)] = []
        let steps = Int((seconds / step).rounded())
        for index in 1...steps {
            if let backupPeak, let report = watch.observeBackup(duration: step, peakLevel: backupPeak) {
                reports.append((TimeInterval(index) * step, report))
            }
            if let report = watch.observePrimary(duration: step, isExactlySilent: false, peakLevel: primaryPeak) {
                reports.append((TimeInterval(index) * step, report))
            }
        }
        return reports
    }

    func testFaintMainMicrophoneWithBackupSoundReportsFaintAudioOncePerSpan() {
        let watch = MicrophoneSilenceWatch()
        watch.backupStarted()
        let reports = runFaint(watch, seconds: 5.0, primaryPeak: 0.0005, backupPeak: speech)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].at, 2.0, accuracy: 0.01)
        XCTAssertEqual(reports[0].report.kind, .faintAudio)
        XCTAssertTrue(reports[0].report.backupHeardSound)

        XCTAssertTrue(runFaint(watch, seconds: 0.5, primaryPeak: speech, backupPeak: speech).isEmpty)
        let again = runFaint(watch, seconds: 3.0, primaryPeak: 0.0005, backupPeak: speech)
        XCTAssertEqual(again.map(\.report.kind), [.faintAudio])
    }

    func testBothMicrophonesQuietNeverReports() {
        let watch = MicrophoneSilenceWatch()
        watch.backupStarted()
        XCTAssertTrue(runFaint(watch, seconds: 30.0, primaryPeak: 0.0005, backupPeak: roomNoise).isEmpty)
    }

    func testNormalSpeechOnTheMainMicrophoneNeverReports() {
        let watch = MicrophoneSilenceWatch()
        watch.backupStarted()
        XCTAssertTrue(runFaint(watch, seconds: 30.0, primaryPeak: speech, backupPeak: speech).isEmpty)
        // The faint level itself is not faint.
        XCTAssertTrue(runFaint(watch, seconds: 30.0, primaryPeak: 0.001, backupPeak: speech).isEmpty)
    }

    func testFaintMainMicrophoneNeedsHalfASecondOfBackupSound() {
        let watch = MicrophoneSilenceWatch()
        watch.backupStarted()
        XCTAssertTrue(runFaint(watch, seconds: 3.0, primaryPeak: 0.0005, backupPeak: roomNoise).isEmpty)
        XCTAssertTrue(runFaint(watch, seconds: 0.375, primaryPeak: 0.0005, backupPeak: speech).isEmpty)
        let reports = runFaint(watch, seconds: 0.125, primaryPeak: 0.0005, backupPeak: speech)
        XCTAssertEqual(reports.map(\.report.kind), [.faintAudio])
    }

    func testFaintMainMicrophoneWithNoBackupNeverReports() {
        let watch = MicrophoneSilenceWatch()
        XCTAssertTrue(runFaint(watch, seconds: 30.0, primaryPeak: 0.0005, backupPeak: nil).isEmpty)
    }

    func testExactSilenceReportsOnceAsExactSilenceAndNotAgainAsFaint() {
        let watch = MicrophoneSilenceWatch()
        watch.backupStarted()
        let reports = run(watch, seconds: 5.0, primarySilent: true, backupPeak: speech)
        XCTAssertEqual(reports.map(\.report.kind), [.exactSilence])
    }

    // MARK: Main microphone delivers no buffers

    func testBackupAudioWithNoMainBufferReportsAfterOneSecond() {
        let watch = MicrophoneSilenceWatch()
        watch.backupStarted()
        var reports: [(at: TimeInterval, report: MicrophoneSilenceReport)] = []
        for index in 1...24 {
            if let report = watch.observeBackup(duration: step, peakLevel: roomNoise) {
                reports.append((TimeInterval(index) * step, report))
            }
        }
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].at, 1.0, accuracy: 0.01)
        XCTAssertEqual(reports[0].report.kind, .noBuffers)
        XCTAssertFalse(reports[0].report.backupHeardSound)
    }

    func testMainBuffersThatStopMidRecordingReportAndReportAgainAfterTheyReturn() {
        let watch = MicrophoneSilenceWatch()
        watch.backupStarted()
        XCTAssertTrue(runFaint(watch, seconds: 5.0, primaryPeak: speech, backupPeak: speech).isEmpty)

        func backupOnly(steps: Int) -> [MicrophoneSilenceReport] {
            (1...steps).compactMap { _ in watch.observeBackup(duration: step, peakLevel: speech) }
        }
        XCTAssertTrue(backupOnly(steps: 7).isEmpty)
        let reports = backupOnly(steps: 9)
        XCTAssertEqual(reports.map(\.kind), [.noBuffers])
        XCTAssertEqual(reports.first?.backupHeardSound, true)

        XCTAssertNil(watch.observePrimary(duration: step, isExactlySilent: false, peakLevel: speech))
        XCTAssertEqual(backupOnly(steps: 8).map(\.kind), [.noBuffers])
    }

    func testBackupThatHasRunOneSecondBesideADeliveringMainMicrophoneDoesNotReport() {
        let watch = MicrophoneSilenceWatch()
        // The main recorder delivers before the backup opens and keeps delivering.
        XCTAssertNil(watch.observePrimary(duration: step, isExactlySilent: false, peakLevel: speech))
        watch.backupStarted()
        XCTAssertTrue(runFaint(watch, seconds: 10.0, primaryPeak: speech, backupPeak: speech).isEmpty)
    }

    func testBackupBuffersBeforeTheBackupIsRunningDoNotCount() {
        let watch = MicrophoneSilenceWatch()
        for _ in 1...24 {
            XCTAssertNil(watch.observeBackup(duration: step, peakLevel: speech))
        }
    }

    func testWallClockCheckWithNoBackupReportsAfterThreeSecondsWithNoMainBuffer() {
        let watch = MicrophoneSilenceWatch()
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(watch.checkPrimaryDelivery(now: start))
        XCTAssertNil(watch.checkPrimaryDelivery(now: start.addingTimeInterval(1)))
        XCTAssertNil(watch.checkPrimaryDelivery(now: start.addingTimeInterval(2)))
        let report = watch.checkPrimaryDelivery(now: start.addingTimeInterval(3))
        XCTAssertEqual(report, MicrophoneSilenceReport(kind: .noBuffers, silentDuration: 3, backupHeardSound: false))
        XCTAssertNil(watch.checkPrimaryDelivery(now: start.addingTimeInterval(4)))
    }

    func testWallClockCheckCountsFromTheLastCheckThatSawAMainBuffer() {
        let watch = MicrophoneSilenceWatch()
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(watch.checkPrimaryDelivery(now: start))
        for second in 1...10 {
            XCTAssertNil(watch.observePrimary(duration: step, isExactlySilent: false, peakLevel: speech))
            XCTAssertNil(watch.checkPrimaryDelivery(now: start.addingTimeInterval(TimeInterval(second))))
        }
        XCTAssertNil(watch.checkPrimaryDelivery(now: start.addingTimeInterval(12)))
        XCTAssertEqual(watch.checkPrimaryDelivery(now: start.addingTimeInterval(13))?.kind, .noBuffers)

        // A buffer ends the span; the next span reports again.
        XCTAssertNil(watch.observePrimary(duration: step, isExactlySilent: false, peakLevel: speech))
        XCTAssertNil(watch.checkPrimaryDelivery(now: start.addingTimeInterval(14)))
        XCTAssertNil(watch.checkPrimaryDelivery(now: start.addingTimeInterval(16)))
        XCTAssertEqual(watch.checkPrimaryDelivery(now: start.addingTimeInterval(17))?.kind, .noBuffers)
    }

    func testWallClockCheckDoesNotReportWhileABackupRuns() {
        let watch = MicrophoneSilenceWatch()
        let start = Date(timeIntervalSince1970: 1_000)
        watch.backupStarted()
        XCTAssertNil(watch.checkPrimaryDelivery(now: start))
        XCTAssertNil(watch.checkPrimaryDelivery(now: start.addingTimeInterval(10)))
    }

    func testNewThresholdsAreTheStandardConfiguration() {
        let standard = MicrophoneSilenceWatchConfiguration.standard
        XCTAssertEqual(standard.faintPrimaryPeakLevel, 0.001)
        XCTAssertEqual(standard.faintDurationWithBackup, 2.0)
        XCTAssertEqual(standard.faintBackupSoundDuration, 0.5)
        XCTAssertEqual(standard.missingBuffersDurationWithBackup, 1.0)
        XCTAssertEqual(standard.missingBuffersDurationWithoutBackup, 3.0)
    }

    /// Feeds both microphones in steps of audio time. Returns each report with the audio time
    /// since this call began. `backupPeak` nil feeds no backup buffers.
    private func run(
        _ watch: MicrophoneSilenceWatch,
        seconds: TimeInterval,
        primarySilent: Bool,
        backupPeak: Float?
    ) -> [(at: TimeInterval, report: MicrophoneSilenceReport)] {
        var reports: [(at: TimeInterval, report: MicrophoneSilenceReport)] = []
        let steps = Int((seconds / step).rounded())
        for index in 1...steps {
            if let backupPeak {
                watch.observeBackup(duration: step, peakLevel: backupPeak)
            }
            if let report = watch.observePrimary(duration: step, isExactlySilent: primarySilent) {
                reports.append((TimeInterval(index) * step, report))
            }
        }
        return reports
    }

    private func buffer(frames: AVAudioFrameCount, sample: Float) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for index in 0..<Int(frames) {
            samples[index] = sample
        }
        return buffer
    }
}
