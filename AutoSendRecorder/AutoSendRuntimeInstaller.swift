import CryptoKit
import Darwin
import Foundation

/// Installs a versioned runtime without changing the legacy AIR installation.
enum AutoSendRuntimeInstaller {
    struct Model: Codable, Sendable {
        let filename: String
        let url: URL
        let sha256: String
        let bytes: Int64
    }

    static var destination: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AutoSendRecorder/Runtime/20260918")
    }

    static func isReady(at root: URL = destination) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("complete.json").path)
            && FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("bin/parakeet-cli").path)
            && FileManager.default.fileExists(atPath: root.appendingPathComponent("capi/libparakeet.dylib").path)
            && ["tdt-0.6b-v2-q4_k.gguf", "tdt_ctc-110m-q4_k.gguf", "nemotron-3.5-asr-streaming-0.6b-q8_0.gguf"].allSatisfy {
                FileManager.default.fileExists(atPath: root.appendingPathComponent("models/\($0)").path)
            }
    }

    static func verify(_ file: URL, model: Model) throws {
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, Int64(values.fileSize ?? -1) == model.bytes else {
            throw failure("The downloaded \(model.filename) has the wrong size. Please retry.")
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == model.sha256 else {
            throw failure("The downloaded \(model.filename) failed verification. Please retry.")
        }
    }

    static func install(
        bundledRuntime: URL,
        destination: URL = destination,
        progress: @escaping @Sendable (String, Double) -> Void
    ) async throws {
        try Task.checkCancellation()
        let fm = FileManager.default
        let manifest = try Data(contentsOf: bundledRuntime.appendingPathComponent("models.json"))
        let models = try JSONDecoder().decode([Model].self, from: manifest)
        guard !models.isEmpty, models.allSatisfy({
            $0.filename == URL(fileURLWithPath: $0.filename).lastPathComponent
                && !$0.filename.hasPrefix(".") && $0.url.scheme == "https"
                && $0.url.host == "huggingface.co" && $0.bytes > 0
                && $0.sha256.count == 64
        }) else { throw failure("The bundled model manifest is invalid.") }
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let lock = open(parent.appendingPathComponent("install.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw failure("Cannot create the runtime installation lock.") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw failure("Another setup is already installing the speech models.")
        }
        defer { flock(lock, LOCK_UN) }
        if isReady(at: destination) { return }
        guard !fm.fileExists(atPath: destination.path) else {
            throw failure("An incomplete runtime already exists at \(destination.path). Move that folder aside, then retry setup.")
        }
        let needed = models.reduce(Int64(0)) { $0 + $1.bytes } * 2 + 200_000_000
        let disk = try fm.attributesOfFileSystem(forPath: parent.path)
        guard (disk[.systemFreeSize] as? NSNumber)?.int64Value ?? 0 > needed else {
            throw failure("Setup needs at least 4 GB of free disk space.")
        }
        let staging = parent.appendingPathComponent(".install-\(UUID().uuidString)")
        try fm.copyItem(at: bundledRuntime, to: staging)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging.appendingPathComponent("models"), withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 7200
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for (index, model) in models.enumerated() {
            try Task.checkCancellation()
            let label = "Downloading speech model \(index + 1) of \(models.count)"
            progress(label, Double(index) / Double(models.count))
            let observer = ModelDownloadProgress { fraction in
                progress(label, (Double(index) + fraction) / Double(models.count))
            }
            let (temporary, response) = try await session.download(from: model.url, delegate: observer)
            defer { try? fm.removeItem(at: temporary) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw failure("The model server could not complete the download. Please retry.")
            }
            progress("Verifying speech model \(index + 1) of \(models.count)", Double(index + 1) / Double(models.count))
            try verify(temporary, model: model)
            try fm.moveItem(at: temporary, to: staging.appendingPathComponent("models/\(model.filename)"))
        }
        try Task.checkCancellation()
        try manifest.write(to: staging.appendingPathComponent("complete.json"), options: .atomic)
        try fm.moveItem(at: staging, to: destination)
        progress("Speech models installed. Quit and reopen the app to finish setup.", 1)
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "AutoSendRuntimeInstaller", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private final class ModelDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var lastPercentage = -1
    init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            let fraction = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
            let percentage = Int(fraction * 100)
            lock.lock()
            let changed = percentage != lastPercentage
            lastPercentage = percentage
            lock.unlock()
            if changed { progress(fraction) }
        }
    }
}
