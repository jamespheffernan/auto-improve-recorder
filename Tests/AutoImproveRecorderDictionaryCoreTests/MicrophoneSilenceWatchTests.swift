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
