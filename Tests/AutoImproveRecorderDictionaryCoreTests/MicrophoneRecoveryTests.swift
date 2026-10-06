import XCTest
@testable import AutoImproveRecorderCore

final class MicrophoneRecoveryTests: XCTestCase {
    private let startedAt = Date(timeIntervalSince1970: 1_000)
    private let silence = MicrophoneHealthEvent(
        kind: .exactSilentStartup,
        observedDuration: 0.75,
        silentBufferCount: 3
    )
    private let boyaPreference = MicrophonePreferences.fromPreferredMicrophoneID("boya")

    func testQuarantinedMicrophoneIsSkippedUntilCooldownExpiresThenUsedAgain() throws {
        var recovery = MicrophoneRecovery(retryCooldown: 10)
        let expiresAt = recovery.quarantine("boya", now: startedAt)

        let duringCooldown = try recovery.resolve(
            preferences: boyaPreference,
            devices: builtInAndBoya,
            now: startedAt.addingTimeInterval(9.9)
        )
        let afterCooldown = try recovery.resolve(
            preferences: boyaPreference,
            devices: builtInAndBoya,
            now: startedAt.addingTimeInterval(10)
        )

        XCTAssertEqual(expiresAt, startedAt.addingTimeInterval(10))
        XCTAssertEqual(duringCooldown.device.id, "built-in")
        XCTAssertTrue(duringCooldown.usedFallback)
        XCTAssertEqual(duringCooldown.reason, .preferredQuarantined)
        XCTAssertEqual(afterCooldown.device.id, "boya")
        XCTAssertFalse(afterCooldown.usedFallback)
        XCTAssertEqual(afterCooldown.reason, .preferredAvailable)
    }

    func testSilentPreferredMicrophoneIsQuarantinedAndRestartsOnResolverFallback() throws {
        var recovery = MicrophoneRecovery(retryCooldown: 10)
        let preferred = try startRecording(&recovery, devices: builtInAndBoya)

        let silenceCommand = recovery.silentMicrophoneReported(
            silence,
            on: preferred,
            recheckingPreferredMicrophoneID: "boya",
            now: startedAt
        )
        let candidate = try recovery.resolve(
            preferences: boyaPreference,
            devices: builtInAndBoya,
            now: startedAt
        )
        let restartCommand = MicrophoneRecovery.restartCommand(replacing: preferred, with: candidate)

        XCTAssertEqual(silenceCommand, .recover(quarantinedUntil: startedAt.addingTimeInterval(10)))
        XCTAssertEqual(recovery.quarantinedUntil, ["boya": startedAt.addingTimeInterval(10)])
        XCTAssertTrue(recovery.recoveryInProgress)
        XCTAssertEqual(candidate.device.id, "built-in")
        XCTAssertTrue(candidate.usedFallback)
        XCTAssertEqual(candidate.reason, .preferredQuarantined)
        XCTAssertEqual(restartCommand, .restart(on: candidate))

        recovery.recordingStarted(on: candidate)
        recovery.recoveryFinished()

        XCTAssertEqual(recovery.activeResolution, candidate)
        XCTAssertFalse(recovery.recoveryInProgress)
    }

    func testSecondSilenceReportDuringRecoveryIsIgnored() throws {
        var recovery = MicrophoneRecovery(retryCooldown: 10)
        let preferred = try startRecording(&recovery, devices: builtInAndBoya)

        let first = recovery.silentMicrophoneReported(
            silence,
            on: preferred,
            recheckingPreferredMicrophoneID: nil,
            now: startedAt
        )
        let second = recovery.silentMicrophoneReported(
            silence,
            on: preferred,
            recheckingPreferredMicrophoneID: nil,
            now: startedAt.addingTimeInterval(1)
        )

        XCTAssertEqual(first, .recover(quarantinedUntil: startedAt.addingTimeInterval(10)))
        XCTAssertEqual(second, .ignore)
        XCTAssertEqual(recovery.quarantinedUntil, ["boya": startedAt.addingTimeInterval(10)])
    }

    func testNoOtherMicrophoneLeavesNothingToRestartOn() throws {
        var recovery = MicrophoneRecovery(retryCooldown: 10)
        let boyaOnly = [makeDevice(id: "boya", name: "BOYA mini 2")]
        let preferred = try startRecording(&recovery, devices: boyaOnly)

        let silenceCommand = recovery.silentMicrophoneReported(
            silence,
            on: preferred,
            recheckingPreferredMicrophoneID: "boya",
            now: startedAt
        )

        XCTAssertEqual(silenceCommand, .recover(quarantinedUntil: startedAt.addingTimeInterval(10)))
        XCTAssertThrowsError(
            try recovery.resolve(preferences: boyaPreference, devices: boyaOnly, now: startedAt)
        ) { error in
            XCTAssertEqual(error as? MicrophoneResolverError, .noUsableMicrophone)
        }

        recovery.recoveryFinished()

        XCTAssertEqual(recovery.activeResolution, preferred)
        XCTAssertFalse(recovery.recoveryInProgress)
    }

    func testResolvingToTheSilentMicrophoneAgainGivesUp() throws {
        var recovery = MicrophoneRecovery(retryCooldown: 10)
        let boyaAsSystemDefault = [makeDevice(id: "boya", name: "BOYA mini 2", isSystemDefault: true)]
        let preferred = try startRecording(&recovery, devices: boyaAsSystemDefault)
        _ = recovery.silentMicrophoneReported(
            silence,
            on: preferred,
            recheckingPreferredMicrophoneID: nil,
            now: startedAt
        )

        // The preferred microphone changed to one that is not connected, so
        // the resolver falls back to the system default, which is the silent one.
        let candidate = try recovery.resolve(
            preferences: .fromPreferredMicrophoneID("anker"),
            devices: boyaAsSystemDefault,
            now: startedAt
        )

        XCTAssertEqual(candidate.device.id, "boya")
        XCTAssertEqual(
            MicrophoneRecovery.restartCommand(replacing: preferred, with: candidate),
            .giveUp
        )
    }

    func testSilenceOnTheFallbackIsIgnoredWhenTheMonitoringRuleIsRechecked() throws {
        var recovery = MicrophoneRecovery(retryCooldown: 10)
        let preferred = try startRecording(&recovery, devices: builtInAndBoya)
        _ = recovery.silentMicrophoneReported(
            silence,
            on: preferred,
            recheckingPreferredMicrophoneID: "boya",
            now: startedAt
        )
        let fallback = try recovery.resolve(
            preferences: boyaPreference,
            devices: builtInAndBoya,
            now: startedAt
        )
        recovery.recordingStarted(on: fallback)
        recovery.recoveryFinished()

        let command = recovery.silentMicrophoneReported(
            silence,
            on: fallback,
            recheckingPreferredMicrophoneID: "boya",
            now: startedAt.addingTimeInterval(1)
        )

        XCTAssertEqual(command, .ignore)
        XCTAssertEqual(recovery.quarantinedUntil, ["boya": startedAt.addingTimeInterval(10)])
        XCTAssertFalse(recovery.recoveryInProgress)
    }

    func testCooldownIsTheCallers() throws {
        var tenSeconds = MicrophoneRecovery(retryCooldown: 10)
        var thirtySeconds = MicrophoneRecovery(retryCooldown: 30)
        let preferredForTen = try startRecording(&tenSeconds, devices: builtInAndBoya)
        let preferredForThirty = try startRecording(&thirtySeconds, devices: builtInAndBoya)

        let tenCommand = tenSeconds.silentMicrophoneReported(
            silence,
            on: preferredForTen,
            recheckingPreferredMicrophoneID: nil,
            now: startedAt
        )
        let thirtyCommand = thirtySeconds.silentMicrophoneReported(
            silence,
            on: preferredForThirty,
            recheckingPreferredMicrophoneID: nil,
            now: startedAt
        )
        let twentySecondsLater = startedAt.addingTimeInterval(20)

        XCTAssertEqual(tenCommand, .recover(quarantinedUntil: startedAt.addingTimeInterval(10)))
        XCTAssertEqual(thirtyCommand, .recover(quarantinedUntil: startedAt.addingTimeInterval(30)))
        XCTAssertEqual(
            try tenSeconds.resolve(
                preferences: boyaPreference,
                devices: builtInAndBoya,
                now: twentySecondsLater
            ).device.id,
            "boya"
        )
        XCTAssertEqual(
            try thirtySeconds.resolve(
                preferences: boyaPreference,
                devices: builtInAndBoya,
                now: twentySecondsLater
            ).device.id,
            "built-in"
        )
    }

    func testOnlyThePreferredMicrophoneItselfIsMonitored() throws {
        var recovery = MicrophoneRecovery(retryCooldown: 10)
        let preferred = try recovery.resolve(
            preferences: boyaPreference,
            devices: builtInAndBoya,
            now: startedAt
        )
        recovery.quarantine("boya", now: startedAt)
        let fallback = try recovery.resolve(
            preferences: boyaPreference,
            devices: builtInAndBoya,
            now: startedAt
        )
        let systemDefault = try recovery.resolve(
            preferences: .fromPreferredMicrophoneID(""),
            devices: [.systemDefault] + builtInAndBoya,
            now: startedAt
        )

        XCTAssertTrue(MicrophoneRecovery.shouldMonitor(preferred, preferredMicrophoneID: "boya"))
        XCTAssertFalse(MicrophoneRecovery.shouldMonitor(fallback, preferredMicrophoneID: "boya"))
        XCTAssertFalse(MicrophoneRecovery.shouldMonitor(fallback, preferredMicrophoneID: "built-in"))
        XCTAssertFalse(MicrophoneRecovery.shouldMonitor(systemDefault, preferredMicrophoneID: ""))
        XCTAssertFalse(MicrophoneRecovery.shouldMonitor(preferred, preferredMicrophoneID: "anker"))
        XCTAssertFalse(MicrophoneRecovery.shouldMonitor(preferred, preferredMicrophoneID: " boya "))
    }

    func testSilenceReportForAResolutionThatIsNotActiveIsIgnored() throws {
        var recovery = MicrophoneRecovery(retryCooldown: 10)
        let preferred = try recovery.resolve(
            preferences: boyaPreference,
            devices: builtInAndBoya,
            now: startedAt
        )

        let beforeStart = recovery.silentMicrophoneReported(
            silence,
            on: preferred,
            recheckingPreferredMicrophoneID: nil,
            now: startedAt
        )
        recovery.recordingStarted(on: preferred)
        recovery.recordingEnded()
        let afterEnd = recovery.silentMicrophoneReported(
            silence,
            on: preferred,
            recheckingPreferredMicrophoneID: nil,
            now: startedAt
        )

        XCTAssertEqual(beforeStart, .ignore)
        XCTAssertEqual(afterEnd, .ignore)
        XCTAssertEqual(recovery.quarantinedUntil, [:])
        XCTAssertFalse(recovery.recoveryInProgress)
    }

    func testRecheckingIgnoresSilenceAfterThePreferredMicrophoneChanged() throws {
        var rechecking = MicrophoneRecovery(retryCooldown: 10)
        var notRechecking = MicrophoneRecovery(retryCooldown: 10)
        let preferredForRechecking = try startRecording(&rechecking, devices: builtInAndBoya)
        let preferredForNotRechecking = try startRecording(&notRechecking, devices: builtInAndBoya)

        let recheckedCommand = rechecking.silentMicrophoneReported(
            silence,
            on: preferredForRechecking,
            recheckingPreferredMicrophoneID: "built-in",
            now: startedAt
        )
        let uncheckedCommand = notRechecking.silentMicrophoneReported(
            silence,
            on: preferredForNotRechecking,
            recheckingPreferredMicrophoneID: nil,
            now: startedAt
        )

        XCTAssertEqual(recheckedCommand, .ignore)
        XCTAssertEqual(rechecking.quarantinedUntil, [:])
        XCTAssertEqual(uncheckedCommand, .recover(quarantinedUntil: startedAt.addingTimeInterval(10)))
    }

    func testRecordingEndedClearsTheRecordingButKeepsQuarantines() throws {
        var recovery = MicrophoneRecovery(retryCooldown: 10)
        let preferred = try startRecording(&recovery, devices: builtInAndBoya)
        _ = recovery.silentMicrophoneReported(
            silence,
            on: preferred,
            recheckingPreferredMicrophoneID: nil,
            now: startedAt
        )

        recovery.recordingEnded()

        XCTAssertNil(recovery.activeResolution)
        XCTAssertFalse(recovery.recoveryInProgress)
        XCTAssertEqual(recovery.quarantinedUntil, ["boya": startedAt.addingTimeInterval(10)])
    }

    func testEmptyMicrophoneIDIsNotQuarantined() {
        var recovery = MicrophoneRecovery(retryCooldown: 10)

        XCTAssertNil(recovery.quarantine("", now: startedAt))
        XCTAssertEqual(recovery.quarantinedUntil, [:])
    }

    private var builtInAndBoya: [MicrophoneDevice] {
        [
            makeDevice(id: "built-in", name: "Built-in", isSystemDefault: true),
            makeDevice(id: "boya", name: "BOYA mini 2")
        ]
    }

    private func startRecording(
        _ recovery: inout MicrophoneRecovery,
        devices: [MicrophoneDevice]
    ) throws -> MicrophoneResolution {
        let resolution = try recovery.resolve(
            preferences: boyaPreference,
            devices: devices,
            now: startedAt
        )
        recovery.recordingStarted(on: resolution)
        return resolution
    }

    private func makeDevice(
        id: String,
        name: String,
        isSystemDefault: Bool = false
    ) -> MicrophoneDevice {
        MicrophoneDevice(
            id: id,
            name: name,
            coreAudioDeviceID: nil,
            transportType: nil,
            isConnected: true,
            isInputCapable: true,
            isSystemDefault: isSystemDefault
        )
    }
}
