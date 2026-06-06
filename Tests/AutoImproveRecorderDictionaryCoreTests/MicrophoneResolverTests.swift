import XCTest
@testable import AutoImproveRecorderDictionaryCore

final class MicrophoneResolverTests: XCTestCase {
    func testSystemDefaultPreferencePreservesSystemDefaultPlaceholder() throws {
        let defaultDevice = makeDevice(id: "built-in", name: "Built-in", isSystemDefault: true)
        let externalDevice = makeDevice(id: "external", name: "External")

        let resolution = try MicrophoneResolver.resolve(
            preferences: .fromPreferredMicrophoneID(""),
            devices: [.systemDefault, externalDevice, defaultDevice],
            quarantinedUntil: [:],
            now: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(resolution.device, .systemDefault)
        XCTAssertFalse(resolution.usedFallback)
        XCTAssertEqual(resolution.reason, .systemDefault)
    }

    func testSystemDefaultPreferenceUsesPlaceholderEvenWhenDiscoveryHasNoUsableConcreteInput() throws {
        let outputOnly = makeDevice(id: "display", name: "Display", isInputCapable: false)

        let resolution = try MicrophoneResolver.resolve(
            preferences: .fromPreferredMicrophoneID(""),
            devices: [.systemDefault, outputOnly],
            quarantinedUntil: [:],
            now: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(resolution.device, .systemDefault)
        XCTAssertFalse(resolution.usedFallback)
        XCTAssertEqual(resolution.reason, .systemDefault)
    }

    func testPreferredConnectedDeviceBeatsSystemDefault() throws {
        let defaultDevice = makeDevice(id: "built-in", name: "Built-in", isSystemDefault: true)
        let preferredDevice = makeDevice(id: "boya", name: "BOYA mini 2")

        let resolution = try MicrophoneResolver.resolve(
            preferences: .fromPreferredMicrophoneID("boya"),
            devices: [defaultDevice, preferredDevice],
            quarantinedUntil: [:],
            now: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(resolution.requestedID, "boya")
        XCTAssertEqual(resolution.device.id, "boya")
        XCTAssertFalse(resolution.usedFallback)
        XCTAssertEqual(resolution.reason, .preferredAvailable)
    }

    func testMissingPreferredDeviceFallsBackToSystemDefault() throws {
        let defaultDevice = makeDevice(id: "built-in", name: "Built-in", isSystemDefault: true)

        let resolution = try MicrophoneResolver.resolve(
            preferences: .fromPreferredMicrophoneID("boya"),
            devices: [defaultDevice],
            quarantinedUntil: [:],
            now: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(resolution.requestedID, "boya")
        XCTAssertEqual(resolution.device.id, "built-in")
        XCTAssertTrue(resolution.usedFallback)
        XCTAssertEqual(resolution.reason, .preferredMissing)
    }

    func testMissingPreferredDeviceFallsBackToSystemDefaultPlaceholderBeforeArbitraryInput() throws {
        let arbitraryDevice = makeDevice(id: "external", name: "External")

        let resolution = try MicrophoneResolver.resolve(
            preferences: .fromPreferredMicrophoneID("boya"),
            devices: [.systemDefault, arbitraryDevice],
            quarantinedUntil: [:],
            now: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(resolution.requestedID, "boya")
        XCTAssertEqual(resolution.device, .systemDefault)
        XCTAssertTrue(resolution.usedFallback)
        XCTAssertEqual(resolution.reason, .preferredMissing)
    }

    func testQuarantinedPreferredDeviceFallsBackUntilCooldownExpires() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let defaultDevice = makeDevice(id: "built-in", name: "Built-in", isSystemDefault: true)
        let preferredDevice = makeDevice(id: "boya", name: "BOYA mini 2")

        let quarantined = try MicrophoneResolver.resolve(
            preferences: .fromPreferredMicrophoneID("boya"),
            devices: [defaultDevice, preferredDevice],
            quarantinedUntil: ["boya": Date(timeIntervalSince1970: 1_010)],
            now: now
        )
        let expired = try MicrophoneResolver.resolve(
            preferences: .fromPreferredMicrophoneID("boya"),
            devices: [defaultDevice, preferredDevice],
            quarantinedUntil: ["boya": Date(timeIntervalSince1970: 990)],
            now: now
        )

        XCTAssertEqual(quarantined.device.id, "built-in")
        XCTAssertTrue(quarantined.usedFallback)
        XCTAssertEqual(quarantined.reason, .preferredQuarantined)
        XCTAssertEqual(expired.device.id, "boya")
        XCTAssertFalse(expired.usedFallback)
        XCTAssertEqual(expired.reason, .preferredAvailable)
    }

    func testQuarantinedPreferredSystemDefaultDoesNotFallbackToSystemDefaultPlaceholder() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let preferredDefaultDevice = makeDevice(id: "boya", name: "BOYA mini 2", isSystemDefault: true)
        let backupDevice = makeDevice(id: "built-in", name: "Built-in")

        let resolution = try MicrophoneResolver.resolve(
            preferences: .fromPreferredMicrophoneID("boya"),
            devices: [.systemDefault, preferredDefaultDevice, backupDevice],
            quarantinedUntil: ["boya": Date(timeIntervalSince1970: 1_010)],
            now: now
        )

        XCTAssertEqual(resolution.requestedID, "boya")
        XCTAssertEqual(resolution.device.id, "built-in")
        XCTAssertTrue(resolution.usedFallback)
        XCTAssertEqual(resolution.reason, .preferredQuarantined)
    }

    func testNoInputCapableDevicesFails() {
        let outputOnly = makeDevice(id: "display", name: "Display", isInputCapable: false)

        XCTAssertThrowsError(
            try MicrophoneResolver.resolve(
                preferences: .fromPreferredMicrophoneID("boya"),
                devices: [outputOnly],
                quarantinedUntil: [:],
                now: Date(timeIntervalSince1970: 1_000)
            )
        ) { error in
            XCTAssertEqual(error as? MicrophoneResolverError, .noUsableMicrophone)
        }
    }

    private func makeDevice(
        id: String,
        name: String,
        isConnected: Bool = true,
        isInputCapable: Bool = true,
        isSystemDefault: Bool = false
    ) -> MicrophoneDevice {
        MicrophoneDevice(
            id: id,
            name: name,
            coreAudioDeviceID: nil,
            transportType: nil,
            isConnected: isConnected,
            isInputCapable: isInputCapable,
            isSystemDefault: isSystemDefault
        )
    }
}
