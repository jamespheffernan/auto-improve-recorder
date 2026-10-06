import AVFoundation
import Darwin
import Foundation

/// The capture and transcription layers depend on this small contract, not on
/// a specific model library. A future measured winner can replace the factory
/// choice without changing AppState or TranscriptionService again.
protocol LocalLiveTranscriptionSession: AnyObject, Sendable {
    var engineName: String { get }
    func append(_ captured: CapturedAudioBuffer)
    func recordCaptureFailure(_ failure: AudioCaptureFailure)
    func finalize() async throws -> String
    func cancel()
}

enum RecommendedLiveTranscription {
    static var isAvailable: Bool { ParakeetLiveStreamSession.isAvailable }
    static func warmUp() async { await ParakeetLiveStreamSession.warmUp() }
    static func begin() -> any LocalLiveTranscriptionSession { ParakeetLiveStreamSession.begin() }
}

/// In-process bindings to parakeet.cpp's C API (libparakeet.dylib), loaded
/// with dlopen so the app builds and runs when the runtime is not installed.
///
/// Contexts are loaded once per model and intentionally never freed:
/// `parakeet_capi_free` trips a ggml-metal residency assert at teardown, so
/// the context must outlive the process (mirrors LocalAI's usage).
enum ParakeetCAPI {
    struct Symbols: @unchecked Sendable {
        let load: @convention(c) (UnsafePointer<CChar>) -> OpaquePointer?
        let transcribePath: @convention(c) (OpaquePointer, UnsafePointer<CChar>, Int32) -> UnsafeMutablePointer<CChar>?
        let transcribePCM: @convention(c) (OpaquePointer, UnsafePointer<Float>, Int32, Int32, Int32) -> UnsafeMutablePointer<CChar>?
        let streamBegin: @convention(c) (OpaquePointer) -> OpaquePointer?
        let streamFeed: @convention(c) (OpaquePointer, UnsafePointer<Float>, Int32, UnsafeMutablePointer<Int32>?) -> UnsafeMutablePointer<CChar>?
        let streamFinalize: @convention(c) (OpaquePointer) -> UnsafeMutablePointer<CChar>?
        let streamFree: @convention(c) (OpaquePointer) -> Void
        let freeString: @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
        let lastError: @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
    }

    static var libraryURL: URL { ParakeetResidentRuntime.shared.libraryURL }

    static var isInstalled: Bool { symbols != nil }

    static var symbols: Symbols? { ParakeetResidentRuntime.shared.symbols }

    /// Opens the library at `path` and resolves every symbol. Returns nil when
    /// the library cannot be opened or any symbol is missing.
    static func loadSymbols(libraryPath path: String) -> Symbols? {
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            if FileManager.default.fileExists(atPath: path) {
                let message = dlerror().map { String(cString: $0) } ?? "unknown dlopen failure"
                NSLog("parakeet capi: dlopen failed: \(message)")
            }
            return nil
        }

        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else {
                NSLog("parakeet capi: missing symbol \(name)")
                return nil
            }
            return unsafeBitCast(pointer, to: T.self)
        }

        guard
            let load = symbol("parakeet_capi_load", as: (@convention(c) (UnsafePointer<CChar>) -> OpaquePointer?).self),
            let transcribePath = symbol("parakeet_capi_transcribe_path", as: (@convention(c) (OpaquePointer, UnsafePointer<CChar>, Int32) -> UnsafeMutablePointer<CChar>?).self),
            let transcribePCM = symbol("parakeet_capi_transcribe_pcm", as: (@convention(c) (OpaquePointer, UnsafePointer<Float>, Int32, Int32, Int32) -> UnsafeMutablePointer<CChar>?).self),
            let streamBegin = symbol("parakeet_capi_stream_begin", as: (@convention(c) (OpaquePointer) -> OpaquePointer?).self),
            let streamFeed = symbol("parakeet_capi_stream_feed", as: (@convention(c) (OpaquePointer, UnsafePointer<Float>, Int32, UnsafeMutablePointer<Int32>?) -> UnsafeMutablePointer<CChar>?).self),
            let streamFinalize = symbol("parakeet_capi_stream_finalize", as: (@convention(c) (OpaquePointer) -> UnsafeMutablePointer<CChar>?).self),
            let streamFree = symbol("parakeet_capi_stream_free", as: (@convention(c) (OpaquePointer) -> Void).self),
            let freeString = symbol("parakeet_capi_free_string", as: (@convention(c) (UnsafeMutablePointer<CChar>?) -> Void).self),
            let lastError = symbol("parakeet_capi_last_error", as: (@convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?).self)
        else {
            return nil
        }

        return Symbols(
            load: load,
            transcribePath: transcribePath,
            transcribePCM: transcribePCM,
            streamBegin: streamBegin,
            streamFeed: streamFeed,
            streamFinalize: streamFinalize,
            streamFree: streamFree,
            freeString: freeString,
            lastError: lastError
        )
    }
}

enum ParakeetCAPIError: LocalizedError {
    case libraryUnavailable
    case modelMissing(String)
    case loadFailed(String)
    case transcriptionFailed(provider: String, message: String)
    case streamUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .libraryUnavailable:
            return "The in-process parakeet runtime (libparakeet.dylib) is not installed."
        case .modelMissing(let path):
            return "Parakeet model was not found at \(path). Install the local model, then try again."
        case .loadFailed(let message):
            return "Could not load the Parakeet model in-process: \(message)"
        case .transcriptionFailed(let provider, let message):
            return "\(provider) transcription failed: \(message)"
        case .streamUnavailable(let message):
            return "Parakeet live streaming is unavailable: \(message)"
        }
    }
}

/// One resident model context. All C calls on a context are serialized
/// through its lock; distinct models run independently.
final class ParakeetResidentContext: @unchecked Sendable {
    private let pointer: OpaquePointer
    private let symbols: ParakeetCAPI.Symbols
    private let lock = NSLock()
    private var warmedOnce = false

    fileprivate init(pointer: OpaquePointer, symbols: ParakeetCAPI.Symbols) {
        self.pointer = pointer
        self.symbols = symbols
    }

    func transcribe(wavPath: String, provider: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let raw = symbols.transcribePath(pointer, wavPath, 0) else {
            throw ParakeetCAPIError.transcriptionFailed(provider: provider, message: lastErrorMessage())
        }
        defer { symbols.freeString(raw) }
        return String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// First inference in a process compiles Metal pipelines (hundreds of ms
    /// warm, seconds after a shader-cache eviction). Run one short silent
    /// inference so user-facing transcriptions never pay it. Resident weights
    /// stay hot afterwards, so this only ever runs once per model.
    func warmUpOnce() {
        lock.lock()
        defer { lock.unlock() }
        guard !warmedOnce else { return }
        warmedOnce = true
        let silence = [Float](repeating: 0, count: 5_120) // 0.32 s at 16 kHz
        if let raw = symbols.transcribePCM(pointer, silence, Int32(silence.count), 16_000, 0) {
            symbols.freeString(raw)
        }
    }

    /// Streaming models reject the offline entry points, so warm them with a
    /// short silent stream instead.
    func warmUpStreamingOnce() {
        lock.lock()
        defer { lock.unlock() }
        guard !warmedOnce else { return }
        warmedOnce = true
        guard let stream = symbols.streamBegin(pointer) else { return }
        let silence = [Float](repeating: 0, count: 5_120)
        if let raw = symbols.streamFeed(stream, silence, Int32(silence.count), nil) {
            symbols.freeString(raw)
        }
        if let raw = symbols.streamFinalize(stream) {
            symbols.freeString(raw)
        }
        symbols.streamFree(stream)
    }

    fileprivate func beginStreamLocked() throws -> OpaquePointer {
        lock.lock()
        defer { lock.unlock() }
        warmedOnce = true
        guard let stream = symbols.streamBegin(pointer) else {
            throw ParakeetCAPIError.streamUnavailable(lastErrorMessage())
        }
        return stream
    }

    fileprivate func feedLocked(
        stream: OpaquePointer,
        samples: UnsafeBufferPointer<Float>
    ) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let baseAddress = samples.baseAddress,
              let raw = symbols.streamFeed(stream, baseAddress, Int32(samples.count), nil) else {
            throw ParakeetCAPIError.transcriptionFailed(
                provider: "parakeet.cpp streaming",
                message: lastErrorMessage()
            )
        }
        defer { symbols.freeString(raw) }
        return String(cString: raw)
    }

    fileprivate func finalizeLocked(stream: OpaquePointer) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let raw = symbols.streamFinalize(stream) else {
            symbols.streamFree(stream)
            throw ParakeetCAPIError.transcriptionFailed(
                provider: "parakeet.cpp streaming",
                message: lastErrorMessage()
            )
        }
        let text = String(cString: raw)
        symbols.freeString(raw)
        symbols.streamFree(stream)
        return text
    }

    fileprivate func freeStreamLocked(stream: OpaquePointer) {
        lock.lock()
        defer { lock.unlock() }
        symbols.streamFree(stream)
    }

    private func lastErrorMessage() -> String {
        guard let message = symbols.lastError(pointer) else { return "Unknown parakeet error." }
        let text = String(cString: message)
        return text.isEmpty ? "Unknown parakeet error." : text
    }
}

/// Loads each GGUF once and keeps the context resident for the app's
/// lifetime. The load (~0.5 s warm) happens inside the lock so concurrent
/// callers wait for one load instead of duplicating it.
///
/// The runtime also owns the C symbols for its configured install root.
final class ParakeetResidentRuntime: @unchecked Sendable {
    static let shared = ParakeetResidentRuntime(configuration: .app)

    private let configuration: ParakeetRuntimeConfiguration
    private let loadSymbols: (String) -> ParakeetCAPI.Symbols?
    private let fileExists: (String) -> Bool
    private let symbolsLock = NSLock()
    private var resolvedSymbols: ParakeetCAPI.Symbols?
    private let lock = NSLock()
    private var contexts: [String: ParakeetResidentContext] = [:]
    private var failedLoads: [String: String] = [:]

    init(
        configuration: ParakeetRuntimeConfiguration,
        loadSymbols: @escaping (String) -> ParakeetCAPI.Symbols? = ParakeetCAPI.loadSymbols(libraryPath:),
        fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.configuration = configuration
        self.loadSymbols = loadSymbols
        self.fileExists = fileExists
    }

    var libraryURL: URL {
        configuration.resolveRoot().appendingPathComponent("capi/libparakeet.dylib")
    }

    /// Loaded on first use and kept for the life of the runtime. A failed
    /// load is not kept: the next use resolves the root and tries again. A
    /// successful load fixes the configuration's root to the one the library
    /// came from. Concurrent first callers wait for the one load.
    var symbols: ParakeetCAPI.Symbols? {
        symbolsLock.lock()
        defer { symbolsLock.unlock() }
        if resolvedSymbols == nil {
            let root = configuration.resolveRoot()
            resolvedSymbols = loadSymbols(root.appendingPathComponent("capi/libparakeet.dylib").path)
            if resolvedSymbols != nil {
                configuration.keepRoot(root)
            }
        }
        return resolvedSymbols
    }

    /// The model's path under the configuration's root: the root the library
    /// loaded from, or the current root while no load has succeeded.
    func modelPath(filename: String) -> String {
        configuration.resolveRoot().appendingPathComponent("models/\(filename)").path
    }

    /// The context for the model with this file name. The library is loaded
    /// first, which fixes the root on success, and the model path is built
    /// after it, so both come from one resolution of the root.
    func context(modelFilename: String) throws -> ParakeetResidentContext {
        guard symbols != nil else {
            throw ParakeetCAPIError.libraryUnavailable
        }
        return try context(modelPath: modelPath(filename: modelFilename))
    }

    func context(modelPath: String) throws -> ParakeetResidentContext {
        guard let symbols else {
            throw ParakeetCAPIError.libraryUnavailable
        }
        lock.lock()
        defer { lock.unlock() }
        if let context = contexts[modelPath] {
            return context
        }
        if let failure = failedLoads[modelPath] {
            throw ParakeetCAPIError.loadFailed(failure)
        }
        guard fileExists(modelPath) else {
            throw ParakeetCAPIError.modelMissing(modelPath)
        }
        let loadStartedAt = Date()
        guard let pointer = symbols.load(modelPath) else {
            let message = "parakeet_capi_load returned NULL for \(modelPath)."
            failedLoads[modelPath] = message
            throw ParakeetCAPIError.loadFailed(message)
        }
        NSLog(
            "parakeet capi: loaded %@ in %.2fs (resident for app lifetime)",
            (modelPath as NSString).lastPathComponent,
            Date().timeIntervalSince(loadStartedAt)
        )
        let context = ParakeetResidentContext(pointer: pointer, symbols: symbols)
        contexts[modelPath] = context
        return context
    }
}

/// Option B: live streaming transcription for one dictation. The shared tap
/// copy is converted to 16 kHz mono float and fed to a cache-aware streaming
/// model (nemotron 0.6B: capitalized + punctuated output) on a serial queue, so
/// the transcript is already complete ~30 ms after the last chunk when the
/// user stops recording.
final class ParakeetLiveStreamSession: LocalLiveTranscriptionSession, @unchecked Sendable {
    static let modelFilename = ParakeetModelFilename.liveRecommended
    static let engineName = "parakeet.cpp nemotron 0.6B streaming Q8_0 Metal"
    static let providerName = "parakeet.cpp nemotron streaming"

    static var modelPath: String {
        ParakeetResidentRuntime.shared.modelPath(filename: modelFilename)
    }

    static var isAvailable: Bool {
        ParakeetCAPI.isInstalled && FileManager.default.fileExists(atPath: modelPath)
    }

    static func warmUp() async {
        guard isAvailable else { return }
        await Task.detached(priority: .utility) {
            guard let context = try? ParakeetResidentRuntime.shared.context(modelFilename: modelFilename) else { return }
            context.warmUpStreamingOnce()
        }.value
    }

    /// 80 ms at 16 kHz: matches the encoder chunking the model was built for
    /// and keeps per-feed compute around 10 ms on M-series.
    private static let feedChunkSamples = 1_280

    private let queue = DispatchQueue(label: "recorder.parakeet-stream", qos: .userInitiated)
    private let inputAdmission = ParakeetLiveInputAdmission()
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    // All mutable state below is confined to `queue`.
    private var context: ParakeetResidentContext?
    private var stream: OpaquePointer?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private let outputBufferPool = ReusableAudioPCMBuffer()
    private var pendingSamples: [Float] = []
    private var transcript = ""
    private var failureMessage: String?
    private var finished = false

    private init() {}

    var engineName: String { Self.engineName }

    /// Begins a session immediately; the model load + stream begin run on the
    /// session queue, and buffers appended meanwhile queue up behind them.
    static func begin() -> ParakeetLiveStreamSession {
        let session = ParakeetLiveStreamSession()
        session.queue.async {
            do {
                let context = try ParakeetResidentRuntime.shared.context(modelFilename: modelFilename)
                session.context = context
                session.stream = try context.beginStreamLocked()
            } catch {
                session.failureMessage = error.localizedDescription
                NSLog("parakeet streaming: session start failed: \(error.localizedDescription)")
            }
        }
        return session
    }

    /// Safe to call from the audio tap thread: retains the immutable capture
    /// block, reserves bounded queue capacity, and returns.
    func append(_ captured: CapturedAudioBuffer) {
        let byteCount = captured.byteCount
        guard inputAdmission.reserve(byteCount: byteCount) else { return }
        let admission = inputAdmission
        queue.async { [weak self] in
            defer { admission.complete(byteCount: byteCount) }
            guard admission.shouldProcessQueuedInput else { return }
            self?.convertAndFeed(captured.buffer)
        }
    }

    func recordCaptureFailure(_ failure: AudioCaptureFailure) {
        // Close admission on the tap thread without waiting for inference.
        // Queue the terminal cause so finalize can never accept a transcript
        // that crossed a missing capture block.
        inputAdmission.cancel()
        queue.async {
            guard !self.finished, self.failureMessage == nil else { return }
            self.failureMessage = failure.localizedDescription
        }
    }

    /// Flushes the stream tail and returns the full cleaned transcript.
    func finalize() async throws -> String {
        inputAdmission.closeForFinalize()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.finalizeOnQueue() })
            }
        }
    }

    func cancel() {
        // Close admission synchronously. Buffers already queued behind a cold
        // model load see the cancelled gate and are discarded without inference.
        inputAdmission.cancel()
        queue.async {
            guard !self.finished else { return }
            self.finished = true
            if let stream = self.stream, let context = self.context {
                context.freeStreamLocked(stream: stream)
            }
            self.stream = nil
        }
    }

    private func convertAndFeed(_ buffer: AVAudioPCMBuffer) {
        guard !finished, failureMessage == nil, let context, let stream else { return }
        guard appendConvertedSamples(from: buffer) else { return }

        while pendingSamples.count >= Self.feedChunkSamples {
            do {
                let text = try pendingSamples.withUnsafeBufferPointer { samples in
                    try context.feedLocked(
                        stream: stream,
                        samples: UnsafeBufferPointer(rebasing: samples.prefix(Self.feedChunkSamples))
                    )
                }
                transcript += text
                pendingSamples.removeFirst(Self.feedChunkSamples)
            } catch {
                failureMessage = error.localizedDescription
                NSLog("parakeet streaming: feed failed: \(error.localizedDescription)")
                return
            }
        }
    }

    private func finalizeOnQueue() throws -> String {
        if let admissionFailure = inputAdmission.failureMessage {
            discardStreamOnQueue()
            throw ParakeetCAPIError.streamUnavailable(admissionFailure)
        }
        if let failureMessage {
            discardStreamOnQueue()
            throw ParakeetCAPIError.streamUnavailable(failureMessage)
        }
        guard !finished, let context, let stream else {
            throw ParakeetCAPIError.streamUnavailable("The streaming session did not start in time.")
        }
        finished = true

        if !pendingSamples.isEmpty {
            do {
                transcript += try pendingSamples.withUnsafeBufferPointer { samples in
                    try context.feedLocked(stream: stream, samples: samples)
                }
            } catch {
                self.stream = nil
                context.freeStreamLocked(stream: stream)
                throw error
            }
            pendingSamples = []
        }
        self.stream = nil
        transcript += try context.finalizeLocked(stream: stream)
        return Self.cleanTranscript(transcript)
    }

    private func discardStreamOnQueue() {
        if let stream, let context {
            context.freeStreamLocked(stream: stream)
        }
        stream = nil
        finished = true
    }

    private func appendConvertedSamples(from buffer: AVAudioPCMBuffer) -> Bool {
        if converter == nil || converterInputFormat?.isEqual(buffer.format) != true {
            guard let newConverter = AVAudioConverter(from: buffer.format, to: outputFormat) else {
                failureMessage = "Could not create the 16 kHz mono audio converter."
                return false
            }
            newConverter.primeMethod = .none
            converter = newConverter
            converterInputFormat = buffer.format
        }
        guard let converter else { return false }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 512
        guard let outputBuffer = outputBufferPool.buffer(
            format: outputFormat,
            minimumFrameCapacity: capacity
        ) else {
            failureMessage = "Live transcription could not allocate its conversion output. Using the intact saved recording instead."
            inputAdmission.cancel()
            return false
        }

        var didProvideInput = false
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if didProvideInput {
                status.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            status.pointee = .haveData
            return buffer
        }
        if let conversionError {
            failureMessage = "Audio conversion failed: \(conversionError.localizedDescription)"
            return false
        }

        let frames = Int(outputBuffer.frameLength)
        guard frames > 0, let channelData = outputBuffer.floatChannelData else { return true }
        pendingSamples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: frames))
        return true
    }

    /// The nemotron model appends language tags (`<en-US>`) and the API can
    /// surface event tokens; strip every `<...>` token and tidy whitespace.
    static func cleanTranscript(_ text: String) -> String {
        let withoutTags = text.replacingOccurrences(
            of: #"<[A-Za-z][A-Za-z0-9_-]*>"#,
            with: "",
            options: .regularExpression
        )
        return withoutTags
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

}
