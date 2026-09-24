import AudioToolbox
import Darwin
import Foundation

private typealias Load = @convention(c) (UnsafePointer<CChar>) -> OpaquePointer?
private typealias TranscribePath = @convention(c) (
    OpaquePointer,
    UnsafePointer<CChar>,
    Int32
) -> UnsafeMutablePointer<CChar>?
private typealias StreamBegin = @convention(c) (OpaquePointer) -> OpaquePointer?
private typealias StreamFeed = @convention(c) (
    OpaquePointer,
    UnsafePointer<Float>,
    Int32,
    UnsafeMutablePointer<Int32>?
) -> UnsafeMutablePointer<CChar>?
private typealias StreamFinalize = @convention(c) (OpaquePointer) -> UnsafeMutablePointer<CChar>?
private typealias StreamFree = @convention(c) (OpaquePointer) -> Void
private typealias FreeString = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
private typealias LastError = @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?

private struct Runtime {
    let context: OpaquePointer
    let transcribePath: TranscribePath
    let streamBegin: StreamBegin
    let streamFeed: StreamFeed
    let streamFinalize: StreamFinalize
    let streamFree: StreamFree
    let freeString: FreeString
    let lastError: LastError
}

private struct ResidentMeasurement: Codable {
    let run: Int
    let elapsedMilliseconds: Double
    let transcript: String
}

private struct Measurement: Codable {
    struct Emission: Codable {
        let endSample: Int64
        let text: String
    }

    let audio: String
    let audioPath: String
    let durationSeconds: Double
    let elapsedMilliseconds: Double
    let feedChunkCount: Int
    let feedChunkSamples: Int
    let finalSilenceSamples: Int
    let feedMillisecondsTotal: Double
    let feedMillisecondsAverage: Double
    let feedMillisecondsMaximum: Double
    let finalizeMilliseconds: Double
    let transcript: String
    let emissions: [Emission]
}

private enum BenchError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}

private let chunkSamples = Int(ProcessInfo.processInfo.environment["PARAKEET_LIVE_CHUNK_SAMPLES"] ?? "") ?? 1_280
private let finalSilenceSamples = Int(ProcessInfo.processInfo.environment["PARAKEET_LIVE_FINAL_SILENCE_SAMPLES"] ?? "") ?? 0

private func requireSymbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, as: T.Type) throws -> T {
    guard let pointer = dlsym(handle, name) else {
        throw BenchError.failed("Missing symbol: \(name)")
    }
    return unsafeBitCast(pointer, to: T.self)
}

private func loadRuntime(libraryPath: String, modelPath: String) throws -> Runtime {
    guard let handle = dlopen(libraryPath, RTLD_NOW | RTLD_LOCAL) else {
        let message = dlerror().map { String(cString: $0) } ?? "unknown dlopen error"
        throw BenchError.failed("Could not open runtime: \(message)")
    }
    let load = try requireSymbol(handle, "parakeet_capi_load", as: Load.self)
    let transcribePath = try requireSymbol(handle, "parakeet_capi_transcribe_path", as: TranscribePath.self)
    let streamBegin = try requireSymbol(handle, "parakeet_capi_stream_begin", as: StreamBegin.self)
    let streamFeed = try requireSymbol(handle, "parakeet_capi_stream_feed", as: StreamFeed.self)
    let streamFinalize = try requireSymbol(handle, "parakeet_capi_stream_finalize", as: StreamFinalize.self)
    let streamFree = try requireSymbol(handle, "parakeet_capi_stream_free", as: StreamFree.self)
    let freeString = try requireSymbol(handle, "parakeet_capi_free_string", as: FreeString.self)
    let lastError = try requireSymbol(handle, "parakeet_capi_last_error", as: LastError.self)
    let context = modelPath.withCString { load($0) }
    guard let context else {
        let message = lastError(nil).map { String(cString: $0) } ?? "unknown model load error"
        throw BenchError.failed("Could not load model: \(message)")
    }
    return Runtime(
        context: context,
        transcribePath: transcribePath,
        streamBegin: streamBegin,
        streamFeed: streamFeed,
        streamFinalize: streamFinalize,
        streamFree: streamFree,
        freeString: freeString,
        lastError: lastError
    )
}

private func runtimeError(_ runtime: Runtime) -> BenchError {
    let message = runtime.lastError(runtime.context).map { String(cString: $0) } ?? "unknown runtime error"
    return .failed(message)
}

private func clientFormat() -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
        mSampleRate: 16_000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4,
        mFramesPerPacket: 1,
        mBytesPerFrame: 4,
        mChannelsPerFrame: 1,
        mBitsPerChannel: 32,
        mReserved: 0
    )
}

private func transcribe(_ audioURL: URL, runtime: Runtime) throws -> Measurement {
    let transcriptionStartedAt = ContinuousClock.now
    var audioFile: ExtAudioFileRef?
    guard ExtAudioFileOpenURL(audioURL as CFURL, &audioFile) == noErr, let audioFile else {
        throw BenchError.failed("Could not open \(audioURL.path)")
    }
    defer { ExtAudioFileDispose(audioFile) }

    var format = clientFormat()
    guard ExtAudioFileSetProperty(
        audioFile,
        kExtAudioFileProperty_ClientDataFormat,
        UInt32(MemoryLayout.size(ofValue: format)),
        &format
    ) == noErr else {
        throw BenchError.failed("Could not configure 16 kHz mono conversion for \(audioURL.path)")
    }
    guard let stream = runtime.streamBegin(runtime.context) else { throw runtimeError(runtime) }

    var transcript = ""
    var emissions: [Measurement.Emission] = []
    var feedTimes: [Double] = []
    var totalFrames: Int64 = 0
    while true {
        var samples = [Float](repeating: 0, count: chunkSamples)
        var frameCount = UInt32(chunkSamples)
        let readStatus = samples.withUnsafeMutableBytes { bytes -> OSStatus in
            var buffer = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(bytes.count),
                mData: bytes.baseAddress
            )
            var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: buffer)
            let status = ExtAudioFileRead(audioFile, &frameCount, &buffers)
            buffer = buffers.mBuffers
            return status
        }
        guard readStatus == noErr else {
            runtime.streamFree(stream)
            throw BenchError.failed("Audio read failed with status \(readStatus)")
        }
        guard frameCount > 0 else { break }
        totalFrames += Int64(frameCount)

        let startedAt = ContinuousClock.now
        guard let raw = runtime.streamFeed(stream, samples, Int32(frameCount), nil) else {
            runtime.streamFree(stream)
            throw runtimeError(runtime)
        }
        feedTimes.append(milliseconds(since: startedAt))
        let emittedText = String(cString: raw)
        transcript += emittedText
        if !emittedText.isEmpty {
            emissions.append(.init(endSample: totalFrames, text: emittedText))
        }
        runtime.freeString(raw)
    }

    if finalSilenceSamples > 0 {
        var remaining = finalSilenceSamples
        let silence = [Float](repeating: 0, count: chunkSamples)
        while remaining > 0 {
            let count = min(remaining, chunkSamples)
            let startedAt = ContinuousClock.now
            guard let raw = runtime.streamFeed(stream, silence, Int32(count), nil) else {
                runtime.streamFree(stream)
                throw runtimeError(runtime)
            }
            feedTimes.append(milliseconds(since: startedAt))
            let emittedText = String(cString: raw)
            transcript += emittedText
            if !emittedText.isEmpty {
                emissions.append(.init(
                    endSample: totalFrames + Int64(finalSilenceSamples - remaining + count),
                    text: emittedText
                ))
            }
            runtime.freeString(raw)
            remaining -= count
        }
    }

    let finalizeStartedAt = ContinuousClock.now
    guard let raw = runtime.streamFinalize(stream) else {
        runtime.streamFree(stream)
        throw runtimeError(runtime)
    }
    let finalizeMilliseconds = milliseconds(since: finalizeStartedAt)
    let finalText = String(cString: raw)
    transcript += finalText
    if !finalText.isEmpty {
        emissions.append(.init(
            endSample: totalFrames + Int64(finalSilenceSamples),
            text: finalText
        ))
    }
    runtime.freeString(raw)
    runtime.streamFree(stream)

    return Measurement(
        audio: audioURL.lastPathComponent,
        audioPath: audioURL.standardizedFileURL.path,
        durationSeconds: Double(totalFrames) / 16_000,
        elapsedMilliseconds: milliseconds(since: transcriptionStartedAt),
        feedChunkCount: feedTimes.count,
        feedChunkSamples: chunkSamples,
        finalSilenceSamples: finalSilenceSamples,
        feedMillisecondsTotal: feedTimes.reduce(0, +),
        feedMillisecondsAverage: feedTimes.reduce(0, +) / Double(max(feedTimes.count, 1)),
        feedMillisecondsMaximum: feedTimes.max() ?? 0,
        finalizeMilliseconds: finalizeMilliseconds,
        transcript: cleanTranscript(transcript),
        emissions: emissions
    )
}

private func verifyCancellation(runtime: Runtime) throws {
    guard let cancelledStream = runtime.streamBegin(runtime.context) else { throw runtimeError(runtime) }
    let silence = [Float](repeating: 0, count: chunkSamples)
    guard let raw = runtime.streamFeed(cancelledStream, silence, Int32(silence.count), nil) else {
        runtime.streamFree(cancelledStream)
        throw runtimeError(runtime)
    }
    runtime.freeString(raw)
    runtime.streamFree(cancelledStream)
    guard let nextStream = runtime.streamBegin(runtime.context) else {
        throw BenchError.failed("Cancellation left the resident context unusable")
    }
    runtime.streamFree(nextStream)
}

private func milliseconds(since start: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: .now)
    return Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
}

private func cleanTranscript(_ text: String) -> String {
    text
        .replacingOccurrences(of: #"<[A-Za-z][A-Za-z0-9_-]*>"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func run() throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let base = home.appendingPathComponent("Library/Application Support/AutoImproveRecorder/ParakeetCpp")
    let arguments = Array(CommandLine.arguments.dropFirst())
    let audioPaths = arguments.isEmpty
        ? ["../Bench/Fixtures/short-5s.wav", "../Bench/Fixtures/medium-30s.wav", "../Bench/Fixtures/long-120s.wav"]
        : arguments
    let residentMode = ProcessInfo.processInfo.environment["PARAKEET_RESIDENT_MODE"] == "1"
    let residentModelFilename = ProcessInfo.processInfo.environment["PARAKEET_RESIDENT_MODEL"]
        ?? "tdt-0.6b-v2-q4_k.gguf"
    let runtime = try loadRuntime(
        libraryPath: base.appendingPathComponent("capi/libparakeet.dylib").path,
        modelPath: base.appendingPathComponent(
            residentMode
                ? "models/\(residentModelFilename)"
                : "models/nemotron-3.5-asr-streaming-0.6b-q8_0.gguf"
        ).path
    )
    if residentMode {
        let audioPath = audioPaths[0]
        let measurements = try (1...2).map { run -> ResidentMeasurement in
            let startedAt = ContinuousClock.now
            guard let raw = audioPath.withCString({ runtime.transcribePath(runtime.context, $0, 0) }) else {
                throw runtimeError(runtime)
            }
            defer { runtime.freeString(raw) }
            return ResidentMeasurement(
                run: run,
                elapsedMilliseconds: milliseconds(since: startedAt),
                transcript: String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(measurements))
        FileHandle.standardOutput.write(Data("\n".utf8))
        fflush(stdout)
        _exit(0)
    }
    try verifyCancellation(runtime: runtime)
    let measurements = try audioPaths.map { try transcribe(URL(fileURLWithPath: $0), runtime: runtime) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(measurements))
    FileHandle.standardOutput.write(Data("\n".utf8))
    fflush(stdout)
    _exit(0) // The installed ggml-metal build asserts if a resident context is torn down.
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("Parakeet live bench failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
