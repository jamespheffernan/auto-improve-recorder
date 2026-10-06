import Foundation
import XCTest
@testable import AutoImproveRecorderCore

/// The root each app supplies, the one-time symbol load, the first-use model
/// path and the live input limit. Nothing here opens a library or reads a
/// model: the root, the loader and the file check are fakes.
final class ParakeetRuntimeConfigurationTests: XCTestCase {
    private let versionedRoot = URL(fileURLWithPath: "/asr/Runtime/20260918")
    private let fallbackRoot = URL(fileURLWithPath: "/air/ParakeetCpp")

    override func setUp() {
        super.setUp()
        fakeLoadedModelPaths = []
    }

    // MARK: Root configuration

    func testPreferredRootIsUsedOnlyWhileReadyAndReadinessIsCheckedOnEveryResolution() {
        let ready = Flag(false)
        let configuration = ParakeetRuntimeConfiguration.preferring(
            { [versionedRoot] in versionedRoot },
            whenReady: { ready.value },
            otherwise: { [fallbackRoot] in fallbackRoot }
        )

        XCTAssertEqual(configuration.resolveRoot(), fallbackRoot)
        ready.value = true
        XCTAssertEqual(configuration.resolveRoot(), versionedRoot)
        ready.value = false
        XCTAssertEqual(configuration.resolveRoot(), fallbackRoot)
    }

    func testAIRSuppliesItsFixedInstallRoot() {
        XCTAssertEqual(
            ParakeetRuntimeConfiguration.app.resolveRoot(),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/AutoImproveRecorder/ParakeetCpp")
        )
        XCTAssertEqual(ParakeetRuntimeConfiguration.app.resolveRoot(), ParakeetCppTranscriber.installBaseURL)
    }

    func testLibraryAndModelPathsFollowTheCurrentRoot() {
        let root = MutableRoot(fallbackRoot)
        let runtime = ParakeetResidentRuntime(
            configuration: root.configuration,
            loadSymbols: { _ in nil },
            fileExists: { _ in false }
        )

        XCTAssertEqual(runtime.libraryURL.path, "/air/ParakeetCpp/capi/libparakeet.dylib")
        XCTAssertEqual(runtime.modelPath(filename: "live.gguf"), "/air/ParakeetCpp/models/live.gguf")

        root.value = versionedRoot
        XCTAssertEqual(runtime.libraryURL.path, "/asr/Runtime/20260918/capi/libparakeet.dylib")
        XCTAssertEqual(runtime.modelPath(filename: "live.gguf"), "/asr/Runtime/20260918/models/live.gguf")
    }

    func testLiveModelFilenameIsSharedWithTheAIRInventory() {
        XCTAssertEqual(ParakeetModelFilename.liveRecommended, "nemotron-3.5-asr-streaming-0.6b-q8_0.gguf")
        XCTAssertEqual(LocalModelInventory.liveRecommendedModelFilename, ParakeetModelFilename.liveRecommended)
        XCTAssertEqual(ParakeetLiveStreamSession.modelFilename, ParakeetModelFilename.liveRecommended)
    }

    // MARK: Lazy symbol loading

    func testSymbolsLoadOnceFromTheRootAtFirstUse() {
        let root = MutableRoot(fallbackRoot)
        let loader = FakeLoader(result: fakeSymbols)
        let runtime = ParakeetResidentRuntime(
            configuration: root.configuration,
            loadSymbols: loader.load,
            fileExists: { _ in true }
        )
        XCTAssertEqual(loader.paths, [], "creating the runtime must not load the library")

        XCTAssertNotNil(runtime.symbols)
        root.value = versionedRoot
        XCTAssertNotNil(runtime.symbols)
        XCTAssertNoThrow(try runtime.context(modelPath: "/models/good.gguf"))

        XCTAssertEqual(loader.paths, ["/air/ParakeetCpp/capi/libparakeet.dylib"])
    }

    func testFailedSymbolLoadIsRetriedFromTheCurrentRootOnTheNextUse() {
        let root = MutableRoot(fallbackRoot)
        let loader = FakeLoader(result: nil)
        let fileChecks = Counter()
        let runtime = ParakeetResidentRuntime(
            configuration: root.configuration,
            loadSymbols: loader.load,
            fileExists: { _ in
                fileChecks.increment()
                return true
            }
        )

        XCTAssertNil(runtime.symbols)
        XCTAssertThrowsError(try runtime.context(modelPath: "/models/good.gguf")) { error in
            guard case ParakeetCAPIError.libraryUnavailable = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(fileChecks.value, 0)
        XCTAssertEqual(fakeLoadedModelPaths, [])

        root.value = versionedRoot
        loader.result = fakeSymbols
        XCTAssertNotNil(runtime.symbols)
        XCTAssertNoThrow(try runtime.context(modelPath: "/models/good.gguf"))
        XCTAssertNotNil(runtime.symbols)

        XCTAssertEqual(loader.paths, [
            "/air/ParakeetCpp/capi/libparakeet.dylib",
            "/air/ParakeetCpp/capi/libparakeet.dylib",
            "/asr/Runtime/20260918/capi/libparakeet.dylib"
        ])
        XCTAssertEqual(fakeLoadedModelPaths, ["/models/good.gguf"])
    }

    // MARK: One root after a successful load

    func testEveryPathUsesTheRootTheLibraryLoadedFrom() throws {
        let root = MutableRoot(fallbackRoot)
        let configuration = root.configuration
        let loader = FakeLoader(result: nil)
        let runtime = ParakeetResidentRuntime(
            configuration: configuration,
            loadSymbols: loader.load,
            fileExists: { _ in true }
        )
        let cliRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-kept-root-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cliRoot) }

        // Before a load succeeds, every path follows the current root.
        XCTAssertNil(runtime.symbols)
        XCTAssertEqual(runtime.modelPath(filename: "fast.gguf"), "/air/ParakeetCpp/models/fast.gguf")
        root.value = cliRoot
        XCTAssertEqual(runtime.libraryURL, cliRoot.appendingPathComponent("capi/libparakeet.dylib"))
        XCTAssertEqual(runtime.modelPath(filename: "fast.gguf"), cliRoot.appendingPathComponent("models/fast.gguf").path)

        // The library loads from `cliRoot`. The root then changes, as when the installer finishes.
        loader.result = fakeSymbols
        XCTAssertNotNil(runtime.symbols)
        root.value = versionedRoot

        XCTAssertEqual(configuration.resolveRoot(), cliRoot)
        XCTAssertEqual(runtime.libraryURL, cliRoot.appendingPathComponent("capi/libparakeet.dylib"))
        for filename in ["fast.gguf", ParakeetModelFilename.liveRecommended] {
            XCTAssertEqual(
                runtime.modelPath(filename: filename),
                cliRoot.appendingPathComponent("models/\(filename)").path
            )
        }

        // The one-shot CLI with the same configuration reads the kept root too.
        for folder in ["bin", "models", "lib"] {
            try FileManager.default.createDirectory(
                at: cliRoot.appendingPathComponent(folder),
                withIntermediateDirectories: true
            )
        }
        let cli = cliRoot.appendingPathComponent(ParakeetOneShotProcess.executablePath)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        try Data().write(to: cliRoot.appendingPathComponent(ParakeetOneShotProcess.modelPath))
        try Data().write(to: cliRoot.appendingPathComponent("lib/libggml-base.dylib"))
        XCTAssertTrue(ParakeetOneShotProcess(configuration: configuration).runtimeIsInstalled)
    }

    func testAFixedRootIsUnchangedByASuccessfulLoad() {
        let root = MutableRoot(fallbackRoot)
        let configuration = root.configuration
        let runtime = ParakeetResidentRuntime(
            configuration: configuration,
            loadSymbols: { _ in fakeSymbols },
            fileExists: { _ in true }
        )

        XCTAssertEqual(runtime.modelPath(filename: "live.gguf"), "/air/ParakeetCpp/models/live.gguf")
        XCTAssertNotNil(runtime.symbols)
        XCTAssertEqual(configuration.resolveRoot(), fallbackRoot)
        XCTAssertEqual(runtime.libraryURL.path, "/air/ParakeetCpp/capi/libparakeet.dylib")
        XCTAssertEqual(runtime.modelPath(filename: "live.gguf"), "/air/ParakeetCpp/models/live.gguf")
    }

    func testConcurrentFirstUsesShareOneSymbolLoad() {
        let loader = FakeLoader(result: fakeSymbols)
        let runtime = ParakeetResidentRuntime(
            configuration: MutableRoot(fallbackRoot).configuration,
            loadSymbols: loader.load,
            fileExists: { _ in true }
        )

        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            XCTAssertNotNil(runtime.symbols)
        }

        XCTAssertEqual(loader.paths.count, 1)
    }

    // MARK: Resident contexts

    func testContextLoadsEachModelOnceAndKeepsAFailedLoad() throws {
        let existing: Set<String> = ["/models/good.gguf", "/models/broken.gguf"]
        let runtime = ParakeetResidentRuntime(
            configuration: MutableRoot(fallbackRoot).configuration,
            loadSymbols: { _ in fakeSymbols },
            fileExists: { existing.contains($0) }
        )

        XCTAssertThrowsError(try runtime.context(modelPath: "/models/absent.gguf")) { error in
            guard case ParakeetCAPIError.modelMissing("/models/absent.gguf") = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(fakeLoadedModelPaths, [])

        let first = try runtime.context(modelPath: "/models/good.gguf")
        let second = try runtime.context(modelPath: "/models/good.gguf")
        XCTAssertTrue(first === second)
        XCTAssertEqual(fakeLoadedModelPaths, ["/models/good.gguf"])

        for _ in 0..<2 {
            XCTAssertThrowsError(try runtime.context(modelPath: "/models/broken.gguf")) { error in
                guard case ParakeetCAPIError.loadFailed(let message) = error else {
                    return XCTFail("unexpected error: \(error)")
                }
                XCTAssertEqual(message, "parakeet_capi_load returned NULL for /models/broken.gguf.")
            }
        }
        XCTAssertEqual(fakeLoadedModelPaths, ["/models/good.gguf", "/models/broken.gguf"])
    }

    // MARK: Model path before a load

    func testModelPathIsResolvedOnEveryUseWhileNoLoadHasSucceeded() {
        let root = MutableRoot(fallbackRoot)
        let runtime = ParakeetResidentRuntime(
            configuration: root.configuration,
            loadSymbols: { _ in nil },
            fileExists: { _ in false }
        )
        XCTAssertEqual(root.resolutions, 0, "creating the runtime must not resolve the root")

        XCTAssertEqual(runtime.modelPath(filename: "fast.gguf"), "/air/ParakeetCpp/models/fast.gguf")
        XCTAssertEqual(root.resolutions, 1)

        XCTAssertNil(runtime.symbols)
        root.value = versionedRoot
        XCTAssertEqual(runtime.modelPath(filename: "fast.gguf"), "/asr/Runtime/20260918/models/fast.gguf")
        XCTAssertEqual(root.resolutions, 3)
    }

    // MARK: One root per context

    func testContextByFilenameTakesTheModelAndTheLibraryFromOneResolutionOfTheRoot() throws {
        let root = MutableRoot(fallbackRoot)
        let loader = FakeLoader(result: fakeSymbols)
        let newRoot = versionedRoot
        let runtime = ParakeetResidentRuntime(
            configuration: root.configuration,
            loadSymbols: { path in
                // The installer finishes while the library loads.
                defer { root.value = newRoot }
                return loader.load(path)
            },
            fileExists: { _ in true }
        )

        _ = try runtime.context(modelFilename: "one-root.gguf")

        XCTAssertEqual(loader.paths, ["/air/ParakeetCpp/capi/libparakeet.dylib"])
        XCTAssertEqual(fakeLoadedModelPaths.last, "/air/ParakeetCpp/models/one-root.gguf")
    }

    func testContextByFilenameRetriesAFailedLibraryLoadAndThenStaysOnTheRootItLoadedFrom() throws {
        let root = MutableRoot(fallbackRoot)
        let loader = FakeLoader(result: nil)
        let runtime = ParakeetResidentRuntime(
            configuration: root.configuration,
            loadSymbols: loader.load,
            fileExists: { _ in true }
        )

        XCTAssertThrowsError(try runtime.context(modelFilename: "retried.gguf")) { error in
            guard case ParakeetCAPIError.libraryUnavailable = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        root.value = versionedRoot
        loader.result = fakeSymbols
        _ = try runtime.context(modelFilename: "retried.gguf")
        XCTAssertEqual(loader.paths, [
            "/air/ParakeetCpp/capi/libparakeet.dylib",
            "/asr/Runtime/20260918/capi/libparakeet.dylib"
        ])
        XCTAssertEqual(fakeLoadedModelPaths.last, "/asr/Runtime/20260918/models/retried.gguf")

        root.value = fallbackRoot
        XCTAssertEqual(runtime.modelPath(filename: "retried.gguf"), "/asr/Runtime/20260918/models/retried.gguf")
    }

    // MARK: Live input admission

    func testDefaultAdmissionLimitIsTheFourMebibytesAutoSendUsed() {
        XCTAssertEqual(ParakeetLiveSafetyPolicy.maximumQueuedAudioBytes, 4_194_304)
        let admission = ParakeetLiveInputAdmission()

        XCTAssertTrue(admission.reserve(byteCount: 4_194_303))
        XCTAssertTrue(admission.reserve(byteCount: 1))
        XCTAssertEqual(admission.queuedByteCount, 4_194_304)
        XCTAssertTrue(admission.shouldProcessQueuedInput)
        XCTAssertNil(admission.failureMessage)

        XCTAssertFalse(admission.reserve(byteCount: 1))
        XCTAssertFalse(admission.shouldProcessQueuedInput)
        XCTAssertEqual(
            admission.failureMessage,
            "Live transcription could not keep up with audio capture; using the saved recording instead."
        )

        admission.complete(byteCount: 4_194_304)
        XCTAssertFalse(admission.reserve(byteCount: 1), "an overflowed session stays closed")
    }

    func testAdmissionClosedForFinalizeRejectsInputButStillProcessesTheQueue() {
        let admission = ParakeetLiveInputAdmission()
        XCTAssertTrue(admission.reserve(byteCount: 10))

        admission.closeForFinalize()

        XCTAssertFalse(admission.reserve(byteCount: 10))
        XCTAssertFalse(admission.reserve(byteCount: -1))
        XCTAssertTrue(admission.shouldProcessQueuedInput)
        XCTAssertNil(admission.failureMessage)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool

    init(_ value: Bool) {
        stored = value
    }

    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}

/// A root that tests change after the runtime exists, and a count of how
/// often it was resolved.
private final class MutableRoot: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URL
    private var resolved = 0

    init(_ value: URL) {
        stored = value
    }

    var value: URL {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    var resolutions: Int { lock.withLock { resolved } }

    var configuration: ParakeetRuntimeConfiguration {
        ParakeetRuntimeConfiguration {
            self.lock.withLock {
                self.resolved += 1
                return self.stored
            }
        }
    }
}

private final class FakeLoader: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ParakeetCAPI.Symbols?
    private var requested: [String] = []

    init(result: ParakeetCAPI.Symbols?) {
        stored = result
    }

    var result: ParakeetCAPI.Symbols? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    var paths: [String] { lock.withLock { requested } }

    func load(_ path: String) -> ParakeetCAPI.Symbols? {
        lock.withLock {
            requested.append(path)
            return stored
        }
    }
}

/// Model paths passed to the fake C `load`. C function pointers cannot
/// capture, so the record is a file-level variable reset in `setUp`.
private var fakeLoadedModelPaths: [String] = []

/// Stand-in C entry points. `load` fails for any path containing "broken".
private let fakeSymbols = ParakeetCAPI.Symbols(
    load: { path in
        let modelPath = String(cString: path)
        fakeLoadedModelPaths.append(modelPath)
        return modelPath.contains("broken") ? nil : OpaquePointer(bitPattern: 1)
    },
    transcribePath: { _, _, _ in nil },
    transcribePCM: { _, _, _, _, _ in nil },
    streamBegin: { _ in nil },
    streamFeed: { _, _, _, _ in nil },
    streamFinalize: { _ in nil },
    streamFree: { _ in },
    freeString: { _ in },
    lastError: { _ in nil }
)
