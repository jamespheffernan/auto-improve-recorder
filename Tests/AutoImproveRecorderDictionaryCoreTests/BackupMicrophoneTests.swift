import Foundation
import XCTest
@testable import AutoImproveRecorderCore

final class BackupMicrophoneChooserTests: XCTestCase {
    private let boya = device("BOYA mini 2", transport: "usb", coreAudioID: 10)
    private let anker = device("Anker PowerConf C200", transport: "usb", coreAudioID: 11)
    private let esp32 = device("TinyUSB UAC1", transport: "usb", coreAudioID: 12)
    private let builtIn = device("MacBook Pro Microphone", transport: "built-in", coreAudioID: 13)
    private let airPods = device("AirPods Pro", transport: "bluetooth", coreAudioID: 14)
    // Continuity Camera's wireless transport has no name in discovery; it arrives as a number.
    private let iPhone = device("iPhone Microphone", transport: "1667463020", coreAudioID: 15)
    private let otherUSB = device("Blue Yeti", transport: "usb", coreAudioID: 16)

    func testMacMiniWithBoyaAnkerAndESP32AudioUsesTheAnker() {
        let devices = [.systemDefault, esp32, boya, anker]
        XCTAssertEqual(choose(primary: boya, devices: devices), anker)
    }

    func testMacBookWithBoyaBuiltInAirPodsAndIPhoneUsesTheBuiltInMicrophone() {
        let devices = [.systemDefault, airPods, iPhone, boya, builtIn]
        XCTAssertEqual(choose(primary: boya, devices: devices), builtIn)
    }

    func testNoBackupWhenThePrimaryIsBuiltInOrTheFeatureIsOff() {
        XCTAssertNil(choose(primary: builtIn, devices: [builtIn, anker, otherUSB]))
        XCTAssertNil(choose(primary: boya, devices: [boya, anker, builtIn], isEnabled: false))
    }

    func testBluetoothVirtualAggregateAirPlayContinuityAndUnknownTransportsAreNeverUsed() {
        let devices = [
            boya,
            airPods,
            iPhone,
            device("AirPods LE", transport: "bluetooth-le", coreAudioID: 20),
            device("Loopback", transport: "virtual", coreAudioID: 21),
            device("Aggregate Device", transport: "aggregate", coreAudioID: 22),
            device("AirPlay", transport: "1634300528", coreAudioID: 23),
            device("Unknown", transport: nil, coreAudioID: 24)
        ]
        XCTAssertNil(choose(primary: boya, devices: devices))
    }

    func testTheESP32BoardAudioIsNeverUsed() {
        XCTAssertNil(choose(primary: boya, devices: [boya, esp32]))
        let lowercased = device("tinyusb uac1", transport: "usb", coreAudioID: 30)
        XCTAssertNil(choose(primary: boya, devices: [boya, lowercased]))
    }

    func testPreferenceOrderIsAnkerThenBuiltInThenOtherUSB() {
        let lowercasedAnker = device("anker powerconf c200", transport: "usb", coreAudioID: 31)
        XCTAssertEqual(
            choose(primary: boya, devices: [boya, otherUSB, builtIn, lowercasedAnker]),
            lowercasedAnker
        )
        XCTAssertEqual(choose(primary: boya, devices: [boya, otherUSB, builtIn]), builtIn)
        XCTAssertEqual(choose(primary: boya, devices: [boya, otherUSB]), otherUSB)
    }

    func testDisconnectedAndOutputOnlyDevicesAndThePrimaryItselfAreSkipped() {
        var unplugged = anker
        unplugged.isConnected = false
        var outputOnly = builtIn
        outputOnly.isInputCapable = false
        XCTAssertNil(choose(primary: boya, devices: [boya, unplugged, outputOnly]))

        var sameHardware = boya
        sameHardware.id = "another-uid"
        XCTAssertNil(choose(primary: boya, devices: [boya, sameHardware]))
    }

    func testSystemDefaultPlaceholderIsJudgedByTheDeviceThatIsTheDefaultNow() {
        var defaultBoya = boya
        defaultBoya.isSystemDefault = true
        XCTAssertEqual(
            choose(primary: .systemDefault, devices: [.systemDefault, defaultBoya, anker]),
            anker
        )

        var defaultBuiltIn = builtIn
        defaultBuiltIn.isSystemDefault = true
        XCTAssertNil(choose(primary: .systemDefault, devices: [.systemDefault, defaultBuiltIn, anker]))
        // The list names no default, so the main microphone is unknown.
        XCTAssertNil(choose(primary: .systemDefault, devices: [.systemDefault, boya, anker]))
    }

    func testBluetoothPrimaryGetsABuiltInBackup() {
        XCTAssertEqual(choose(primary: airPods, devices: [airPods, builtIn]), builtIn)
    }

    private func choose(
        primary: MicrophoneDevice,
        devices: [MicrophoneDevice],
        isEnabled: Bool = true
    ) -> MicrophoneDevice? {
        BackupMicrophoneChooser.chooseBackup(primary: primary, devices: devices, isEnabled: isEnabled)
    }
}

final class BackupTranscriptChoiceTests: XCTestCase {
    func testBackupIsUsedOnlyWhenItHasMoreWords() {
        XCTAssertTrue(BackupTranscriptChoice.prefersBackup(mainText: "", backupText: "hello"))
        XCTAssertTrue(BackupTranscriptChoice.prefersBackup(mainText: "one two", backupText: "one two three"))
        XCTAssertFalse(BackupTranscriptChoice.prefersBackup(mainText: "one two", backupText: "three four"))
        XCTAssertFalse(BackupTranscriptChoice.prefersBackup(mainText: "one two three", backupText: "one"))
        XCTAssertFalse(BackupTranscriptChoice.prefersBackup(mainText: "", backupText: " \n "))
    }

    func testWordsAreSeparatedByAnyWhitespace() {
        XCTAssertEqual(BackupTranscriptChoice.wordCount("  one\ttwo\nthree  four "), 4)
        XCTAssertEqual(BackupTranscriptChoice.wordCount(""), 0)
    }
}

final class BackupMicrophoneRecorderTests: XCTestCase {
    func testBackupFileSitsBesideTheMainRecordingWithASuffix() {
        let main = URL(fileURLWithPath: "/tmp/Recordings/recording-ABC.wav")
        XCTAssertEqual(
            BackupMicrophoneRecorder.backupURL(forMainRecording: main).path,
            "/tmp/Recordings/recording-ABC-backup.wav"
        )
    }

    func testStopGivesTheFinishedFile() {
        let stop = BackupMicrophoneStop()
        let url = URL(fileURLWithPath: "/tmp/recording-backup.wav")
        stop.finish(url)
        XCTAssertEqual(stop.wait(timeout: 0.01), url)
    }

    func testStopThatDoesNotFinishInTimeGivesNoFileAndDeletesItWhenItFinishes() throws {
        let url = try temporaryFile()
        let stop = BackupMicrophoneStop()
        XCTAssertNil(stop.wait(timeout: 0.01))
        stop.finish(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDiscardDeletesAFinishedFile() throws {
        let url = try temporaryFile()
        let stop = BackupMicrophoneStop()
        stop.finish(url)
        stop.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    private func temporaryFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-microphone-\(UUID().uuidString).wav")
        try Data([0]).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private func device(_ name: String, transport: String?, coreAudioID: AIRAudioObjectID) -> MicrophoneDevice {
    MicrophoneDevice(
        id: "uid-\(coreAudioID)",
        name: name,
        coreAudioDeviceID: coreAudioID,
        transportType: transport,
        isConnected: true,
        isInputCapable: true,
        isSystemDefault: false
    )
}
