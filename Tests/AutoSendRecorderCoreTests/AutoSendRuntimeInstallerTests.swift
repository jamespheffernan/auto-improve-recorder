import CryptoKit
import Foundation
import XCTest
@testable import AutoSendRecorderCore

final class AutoSendRuntimeInstallerTests: XCTestCase {
    func testChecksumRejectsSameSizeCorruption() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("model.gguf")
        let original = Data("original".utf8)
        let hash = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
        let model = AutoSendRuntimeInstaller.Model(filename: "model.gguf", url: URL(string: "https://huggingface.co/example")!, sha256: hash, bytes: 8)
        try original.write(to: file)
        XCTAssertNoThrow(try AutoSendRuntimeInstaller.verify(file, model: model))
        try Data("tampered".utf8).write(to: file)
        XCTAssertThrowsError(try AutoSendRuntimeInstaller.verify(file, model: model))
        try Data("short".utf8).write(to: file)
        XCTAssertThrowsError(try AutoSendRuntimeInstaller.verify(file, model: model))
    }

    func testUnsafeModelFilenameCannotCreateInstallation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundle = root.appendingPathComponent("bundle")
        let target = root.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AutoSendRuntimeInstaller.Model(filename: "../escape", url: URL(string: "https://huggingface.co/example")!, sha256: String(repeating: "0", count: 64), bytes: 8)
        try JSONEncoder().encode([model]).write(to: bundle.appendingPathComponent("models.json"))
        do {
            try await AutoSendRuntimeInstaller.install(bundledRuntime: bundle, destination: target) { _, _ in }
            XCTFail("Invalid manifest was accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("manifest"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testCancellationDoesNotCreateDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await AutoSendRuntimeInstaller.install(bundledRuntime: root, destination: root) { _, _ in }
                XCTFail("Cancelled installation continued")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
        }
        await task.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testPartialRuntimeIsNeverReady() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("[]".utf8).write(to: root.appendingPathComponent("complete.json"))
        XCTAssertFalse(AutoSendRuntimeInstaller.isReady(at: root))
    }
}
