import AVFoundation
import CryptoKit
import Darwin
import Foundation

private enum ProfilePath: String, Codable {
    case archive
    case openAI = "openai"
    case parakeet
}

private enum Implementation: String, Codable {
    case baseline
    case candidate
}

private struct Options {
    var path: ProfilePath = .archive
    var implementation: Implementation = .baseline
    var durationSeconds = 5
    var bufferFrames = 256
    var waitForSignal = false
    var skipGolden = false
    var captureConsumerGolden = false
    var outputURL: URL?

    static func parse() throws -> Options {
        var options = Options()
        var arguments = Array(CommandLine.arguments.dropFirst())
        while !arguments.isEmpty {
            let flag = arguments.removeFirst()
            switch flag {
            case "--path":
                guard let value = arguments.first, let path = ProfilePath(rawValue: value) else {
                    throw BenchError.usage("--path must be archive, openai, or parakeet")
                }
                arguments.removeFirst()
                options.path = path
            case "--implementation":
                guard let value = arguments.first,
                      let implementation = Implementation(rawValue: value) else {
                    throw BenchError.usage("--implementation must be baseline or candidate")
                }
                arguments.removeFirst()
                options.implementation = implementation
            case "--duration":
                guard let value = arguments.first, let duration = Int(value), [5, 30, 120].contains(duration) else {
                    throw BenchError.usage("--duration must be 5, 30, or 120")
                }
                arguments.removeFirst()
                options.durationSeconds = duration
            case "--buffer-frames":
                guard let value = arguments.first, let frames = Int(value), frames > 0 else {
                    throw BenchError.usage("--buffer-frames must be a positive integer")
                }
                arguments.removeFirst()
                options.bufferFrames = frames
            case "--wait-for-signal":
                options.waitForSignal = true
            case "--skip-golden":
                options.skipGolden = true
            case "--capture-consumer-golden":
                options.captureConsumerGolden = true
            case "--output":
                guard let value = arguments.first else {
                    throw BenchError.usage("--output needs a path")
                }
                arguments.removeFirst()
                options.outputURL = URL(fileURLWithPath: value)
            case "--help", "-h":
                print("AudioCaptureProfile --implementation baseline|candidate --path archive|openai|parakeet --duration 5|30|120 [--wait-for-signal] [--skip-golden] [--capture-consumer-golden] [--output FILE]")
                exit(0)
            default:
                throw BenchError.usage("unknown argument: \(flag)")
            }
        }
        return options
    }
}

private enum BenchError: LocalizedError {
    case usage(String)
    case allocation(String)
    case conversion(String)
    case parakeet(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message), .allocation(let message), .conversion(let message), .parakeet(let message):
            return message
        }
    }
}

private struct Counters: Codable {
    var callbackCount = 0
    var archiveBufferAllocations = 0
    var streamBufferAllocations = 0
    var conversionBufferAllocations = 0
    var convertedDataAllocations = 0
    var feedChunkArrayAllocations = 0
    var rawCopyOperations = 0
    var rawBytesCopied = 0
    var archiveWriteOperations = 0
    var archiveFramesWritten = 0
    var realtimeChunks = 0
    var realtimePCMBytes = 0
    var serializedEvents = 0
    var serializedEventBytes = 0
    var parakeetFeedCalls = 0
    var parakeetInputSamples = 0
}

private struct Result: Codable {
    let schemaVersion: Int
    let implementation: Implementation
    let path: ProfilePath
    let durationSeconds: Int
    let sampleRate: Int
    let channels: Int
    let bufferFrames: Int
    let wallMilliseconds: Double
    let cpuMilliseconds: Double
    let cpuDutyPercentOfAudioDuration: Double
    let peakResidentBytes: UInt64
    let sourcePCM_SHA256: String
    let archivePCM_SHA256: String
    let archivePCMMatchesSource: Bool
    let consumerInputSHA256: String?
    let transcriptSHA256: String?
    let counters: Counters
}

private let inputSampleRate = 48_000.0
private let inputChannels: AVAudioChannelCount = 1

private final class RawPCMHasher {
    private var hasher = SHA256()

    func update(_ buffer: AVAudioPCMBuffer) {
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for audioBuffer in buffers {
            guard let data = audioBuffer.mData, audioBuffer.mDataByteSize > 0 else { continue }
            hasher.update(data: Data(bytesNoCopy: data, count: Int(audioBuffer.mDataByteSize), deallocator: .none))
        }
    }

    func finalize() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private func makeSyntheticInput(frameCount: Int) throws -> AVAudioPCMBuffer {
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: inputSampleRate,
        channels: inputChannels,
        interleaved: false
    ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
        throw BenchError.allocation("could not allocate synthetic input buffer")
    }
    buffer.frameLength = AVAudioFrameCount(frameCount)
    guard let samples = buffer.floatChannelData?[0] else {
        throw BenchError.allocation("synthetic input buffer has no float channel")
    }
    for index in 0..<frameCount {
        let time = Double(index) / inputSampleRate
        samples[index] = Float(0.15 * sin(2.0 * Double.pi * 220.0 * time) + 0.04 * sin(2.0 * Double.pi * 997.0 * time))
    }
    return buffer
}

// Mirrors AudioRecorder.copyBuffer and OpenAIRealtimeAudioSink.copyBuffer.
private func copyBuffer(
    _ buffer: AVAudioPCMBuffer,
    allocationCounter: WritableKeyPath<Counters, Int>,
    counters: inout Counters
) throws -> AVAudioPCMBuffer {
    guard let copied = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
        throw BenchError.allocation("could not allocate copied audio buffer")
    }
    counters[keyPath: allocationCounter] += 1
    copied.frameLength = buffer.frameLength
    let sourceBuffers = UnsafeMutableAudioBufferListPointer(
        UnsafeMutablePointer(mutating: buffer.audioBufferList)
    )
    let destinationBuffers = UnsafeMutableAudioBufferListPointer(copied.mutableAudioBufferList)
    for index in 0..<min(sourceBuffers.count, destinationBuffers.count) {
        guard let source = sourceBuffers[index].mData,
              let destination = destinationBuffers[index].mData else { continue }
        let byteCount = Int(sourceBuffers[index].mDataByteSize)
        memcpy(destination, source, byteCount)
        destinationBuffers[index].mDataByteSize = sourceBuffers[index].mDataByteSize
        counters.rawCopyOperations += 1
        counters.rawBytesCopied += byteCount
    }
    return copied
}

private final class ArchiveMirror {
    private let url: URL
    private var file: AVAudioFile?

    init(format: AVAudioFormat) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("air-audio-profile-\(UUID().uuidString).wav")
        file = try AVAudioFile(forWriting: url, settings: format.settings)
    }

    func append(_ source: AVAudioPCMBuffer, counters: inout Counters) throws -> AVAudioPCMBuffer {
        let captured = try copyBuffer(
            source,
            allocationCounter: \Counters.archiveBufferAllocations,
            counters: &counters
        )
        guard let file else { throw BenchError.allocation("archive writer is closed") }
        try file.write(from: captured)
        counters.archiveWriteOperations += 1
        counters.archiveFramesWritten += Int(captured.frameLength)
        return captured
    }

    func digest() throws -> String {
        file = nil
        let reader = try AVAudioFile(forReading: url)
        let hasher = RawPCMHasher()
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: reader.processingFormat,
            frameCapacity: 16_384
        ) else {
            throw BenchError.allocation("could not allocate archive verification buffer")
        }
        while reader.framePosition < reader.length {
            buffer.frameLength = 0
            try reader.read(into: buffer)
            if buffer.frameLength == 0 { break }
            hasher.update(buffer)
        }
        return hasher.finalize()
    }
}

private struct RealtimeChunk { let data: Data }

// Mirrors production RealtimePCMChunker, including output allocation,
// Data materialization, 4,800-byte chunk copies, and removeFirst.
private final class OpenAIRealtimeMirror {
    private let implementation: Implementation
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24_000,
        channels: 1,
        interleaved: true
    )!
    private let chunkByteCount = 4_800
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var reusableOutputBuffer: AVAudioPCMBuffer?
    private var pendingData = Data()
    private var consumerHasher: SHA256?

    init(implementation: Implementation, captureConsumerGolden: Bool) {
        self.implementation = implementation
        consumerHasher = captureConsumerGolden ? SHA256() : nil
    }

    func append(_ source: AVAudioPCMBuffer, counters: inout Counters) throws {
        if converter == nil || converterInputFormat?.isEqual(source.format) != true {
            converter = AVAudioConverter(from: source.format, to: outputFormat)
            converter?.primeMethod = .none
            converterInputFormat = source.format
        }
        guard let converter else { throw BenchError.conversion("could not create OpenAI converter") }
        let ratio = outputFormat.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 512
        let output: AVAudioPCMBuffer?
        if implementation == .candidate,
           let reusableOutputBuffer,
           reusableOutputBuffer.frameCapacity >= capacity {
            reusableOutputBuffer.frameLength = 0
            output = reusableOutputBuffer
        } else {
            output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
            if implementation == .candidate {
                reusableOutputBuffer = output
            }
            counters.conversionBufferAllocations += 1
        }
        guard let output else {
            throw BenchError.allocation("could not allocate OpenAI conversion buffer")
        }
        var provided = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if provided {
                status.pointee = .noDataNow
                return nil
            }
            provided = true
            status.pointee = .haveData
            return source
        }
        if let conversionError { throw BenchError.conversion(conversionError.localizedDescription) }
        let byteCount = Int(output.frameLength) * MemoryLayout<Int16>.size
        if byteCount > 0,
           let data = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList).first?.mData {
            pendingData.append(data.assumingMemoryBound(to: UInt8.self), count: byteCount)
            counters.convertedDataAllocations += 1
        }
        while pendingData.count >= chunkByteCount {
            let chunk = RealtimeChunk(data: Data(pendingData.prefix(chunkByteCount)))
            pendingData.removeFirst(chunkByteCount)
            serialize(chunk, counters: &counters)
        }
    }

    func finish(counters: inout Counters) {
        if !pendingData.isEmpty {
            let chunk = RealtimeChunk(data: pendingData)
            pendingData.removeAll(keepingCapacity: true)
            serialize(chunk, counters: &counters)
        }
    }

    func consumerDigest() -> String? {
        guard let consumerHasher else { return nil }
        return consumerHasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func serialize(_ chunk: RealtimeChunk, counters: inout Counters) {
        if var hasher = consumerHasher {
            hasher.update(data: chunk.data)
            consumerHasher = hasher
        }
        let object: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": chunk.data.base64EncodedString()
        ]
        if let event = try? JSONSerialization.data(withJSONObject: object) {
            counters.realtimeChunks += 1
            counters.realtimePCMBytes += chunk.data.count
            counters.serializedEvents += 1
            counters.serializedEventBytes += event.count
            withExtendedLifetime(event) {}
        }
    }
}

private final class ParakeetSymbols {
    typealias Load = @convention(c) (UnsafePointer<CChar>) -> OpaquePointer?
    typealias StreamBegin = @convention(c) (OpaquePointer) -> OpaquePointer?
    typealias StreamFeed = @convention(c) (OpaquePointer, UnsafePointer<Float>, Int32, UnsafeMutablePointer<Int32>?) -> UnsafeMutablePointer<CChar>?
    typealias StreamFinalize = @convention(c) (OpaquePointer) -> UnsafeMutablePointer<CChar>?
    typealias StreamFree = @convention(c) (OpaquePointer) -> Void
    typealias FreeString = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
    typealias LastError = @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?

    let load: Load
    let streamBegin: StreamBegin
    let streamFeed: StreamFeed
    let streamFinalize: StreamFinalize
    let streamFree: StreamFree
    let freeString: FreeString
    let lastError: LastError

    init(baseURL: URL) throws {
        let libraryURL = baseURL.appendingPathComponent("capi/libparakeet.dylib")
        guard let handle = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL) else {
            let message = dlerror().map { String(cString: $0) } ?? "unknown"
            throw BenchError.parakeet("dlopen failed: \(message)")
        }
        func symbol<T>(_ name: String, _: T.Type) throws -> T {
            guard let pointer = dlsym(handle, name) else {
                throw BenchError.parakeet("missing Parakeet symbol \(name)")
            }
            return unsafeBitCast(pointer, to: T.self)
        }
        load = try symbol("parakeet_capi_load", Load.self)
        streamBegin = try symbol("parakeet_capi_stream_begin", StreamBegin.self)
        streamFeed = try symbol("parakeet_capi_stream_feed", StreamFeed.self)
        streamFinalize = try symbol("parakeet_capi_stream_finalize", StreamFinalize.self)
        streamFree = try symbol("parakeet_capi_stream_free", StreamFree.self)
        freeString = try symbol("parakeet_capi_free_string", FreeString.self)
        lastError = try symbol("parakeet_capi_last_error", LastError.self)
    }
}

// Mirrors ParakeetLiveStreamSession, including its second raw copy,
// per-callback conversion allocation, Float array, and 1,280-sample chunks.
private final class ParakeetLiveMirror {
    private static let feedChunkSamples = 1_280
    private let symbols: ParakeetSymbols
    private let context: OpaquePointer
    private let implementation: Implementation
    private var stream: OpaquePointer
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var reusableOutputBuffer: AVAudioPCMBuffer?
    private var pendingSamples: [Float] = []
    private var transcript = ""
    private var consumerHasher: SHA256?

    init(implementation: Implementation, captureConsumerGolden: Bool) throws {
        self.implementation = implementation
        consumerHasher = captureConsumerGolden ? SHA256() : nil
        let baseURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AutoImproveRecorder/ParakeetCpp")
        let resolvedSymbols = try ParakeetSymbols(baseURL: baseURL)
        let modelURL = baseURL.appendingPathComponent("models/nemotron-3.5-asr-streaming-0.6b-q8_0.gguf")
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw BenchError.parakeet("missing Parakeet model: \(modelURL.path)")
        }
        guard let loaded = modelURL.path.withCString({ resolvedSymbols.load($0) }) else {
            throw BenchError.parakeet("Parakeet model load failed")
        }
        let resolvedError: () -> String = {
            resolvedSymbols.lastError(loaded).map { String(cString: $0) } ?? "unknown Parakeet error"
        }
        guard let warmStream = resolvedSymbols.streamBegin(loaded) else {
            throw BenchError.parakeet(resolvedError())
        }
        let silence = [Float](repeating: 0, count: 5_120)
        if let raw = resolvedSymbols.streamFeed(warmStream, silence, Int32(silence.count), nil) {
            resolvedSymbols.freeString(raw)
        }
        if let raw = resolvedSymbols.streamFinalize(warmStream) { resolvedSymbols.freeString(raw) }
        resolvedSymbols.streamFree(warmStream)
        guard let resolvedStream = resolvedSymbols.streamBegin(loaded) else {
            throw BenchError.parakeet(resolvedError())
        }
        symbols = resolvedSymbols
        context = loaded
        stream = resolvedStream
    }

    func append(
        _ source: AVAudioPCMBuffer,
        sharedCapture: AVAudioPCMBuffer,
        counters: inout Counters
    ) throws {
        let streamInput: AVAudioPCMBuffer
        if implementation == .baseline {
            streamInput = try copyBuffer(
                source,
                allocationCounter: \Counters.streamBufferAllocations,
                counters: &counters
            )
        } else {
            streamInput = sharedCapture
        }
        try convertAndAppend(streamInput, counters: &counters)
        while pendingSamples.count >= Self.feedChunkSamples {
            if implementation == .baseline {
                let chunk = Array(pendingSamples.prefix(Self.feedChunkSamples))
                counters.feedChunkArrayAllocations += 1
                try chunk.withUnsafeBufferPointer { samples in
                    try feed(samples, counters: &counters)
                }
            } else {
                try pendingSamples.withUnsafeBufferPointer { samples in
                    try feed(
                        UnsafeBufferPointer(rebasing: samples.prefix(Self.feedChunkSamples)),
                        counters: &counters
                    )
                }
            }
            pendingSamples.removeFirst(Self.feedChunkSamples)
        }
    }

    func finish(counters: inout Counters) throws -> String {
        if !pendingSamples.isEmpty {
            if implementation == .baseline {
                let tail = pendingSamples
                counters.feedChunkArrayAllocations += 1
                try tail.withUnsafeBufferPointer { samples in
                    try feed(samples, counters: &counters)
                }
            } else {
                try pendingSamples.withUnsafeBufferPointer { samples in
                    try feed(samples, counters: &counters)
                }
            }
            pendingSamples.removeAll(keepingCapacity: true)
        }
        guard let raw = symbols.streamFinalize(stream) else {
            symbols.streamFree(stream)
            throw BenchError.parakeet(lastError())
        }
        transcript += String(cString: raw)
        symbols.freeString(raw)
        symbols.streamFree(stream)
        return transcript
    }

    func consumerDigest() -> String? {
        guard let consumerHasher else { return nil }
        return consumerHasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func convertAndAppend(_ buffer: AVAudioPCMBuffer, counters: inout Counters) throws {
        if converter == nil || converterInputFormat?.isEqual(buffer.format) != true {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            converter?.primeMethod = .none
            converterInputFormat = buffer.format
        }
        guard let converter else { throw BenchError.conversion("could not create Parakeet converter") }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 512
        let output: AVAudioPCMBuffer?
        if implementation == .candidate,
           let reusableOutputBuffer,
           reusableOutputBuffer.frameCapacity >= capacity {
            reusableOutputBuffer.frameLength = 0
            output = reusableOutputBuffer
        } else {
            output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
            if implementation == .candidate {
                reusableOutputBuffer = output
            }
            counters.conversionBufferAllocations += 1
        }
        guard let output else {
            throw BenchError.allocation("could not allocate Parakeet conversion buffer")
        }
        var provided = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if provided {
                status.pointee = .noDataNow
                return nil
            }
            provided = true
            status.pointee = .haveData
            return buffer
        }
        if let conversionError { throw BenchError.conversion(conversionError.localizedDescription) }
        let frames = Int(output.frameLength)
        guard frames > 0, let channel = output.floatChannelData?[0] else { return }
        if implementation == .baseline {
            let converted = Array(UnsafeBufferPointer(start: channel, count: frames))
            counters.convertedDataAllocations += 1
            pendingSamples.append(contentsOf: converted)
        } else {
            pendingSamples.append(contentsOf: UnsafeBufferPointer(start: channel, count: frames))
        }
    }

    private func feed(
        _ samples: UnsafeBufferPointer<Float>,
        counters: inout Counters
    ) throws {
        if var hasher = consumerHasher {
            if let baseAddress = samples.baseAddress {
                hasher.update(data: Data(
                    bytes: baseAddress,
                    count: samples.count * MemoryLayout<Float>.size
                ))
            }
            consumerHasher = hasher
        }
        guard let baseAddress = samples.baseAddress,
              let raw = symbols.streamFeed(stream, baseAddress, Int32(samples.count), nil) else {
            throw BenchError.parakeet(lastError())
        }
        transcript += String(cString: raw)
        symbols.freeString(raw)
        counters.parakeetFeedCalls += 1
        counters.parakeetInputSamples += samples.count
    }

    private func lastError() -> String {
        symbols.lastError(context).map(String.init(cString:)) ?? "unknown Parakeet error"
    }
}

private func processCPUSeconds() -> Double {
    var info = task_thread_times_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &count)
        }
    }
    guard status == KERN_SUCCESS else { return 0 }
    func seconds(_ value: time_value_t) -> Double {
        Double(value.seconds) + Double(value.microseconds) / 1_000_000
    }
    return seconds(info.user_time) + seconds(info.system_time)
}

private func peakResidentBytes() -> UInt64 {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return UInt64(usage.ru_maxrss)
}

private func waitForProfilerSignalIfNeeded(_ enabled: Bool) {
    guard enabled else { return }
    var signals = sigset_t()
    sigemptyset(&signals)
    sigaddset(&signals, SIGUSR1)
    pthread_sigmask(SIG_BLOCK, &signals, nil)
    FileHandle.standardError.write(Data("AIR_AUDIO_PROFILE_READY pid=\(getpid())\n".utf8))
    var received: Int32 = 0
    sigwait(&signals, &received)
}

private func run(_ options: Options) throws -> Result {
    let input = try makeSyntheticInput(frameCount: options.bufferFrames)
    let callbackCount = Int(ceil(Double(options.durationSeconds) * inputSampleRate / Double(options.bufferFrames)))
    let archive = try ArchiveMirror(format: input.format)
    let openAI = options.path == .openAI
        ? OpenAIRealtimeMirror(
            implementation: options.implementation,
            captureConsumerGolden: options.captureConsumerGolden
        )
        : nil
    let parakeet = options.path == .parakeet
        ? try ParakeetLiveMirror(
            implementation: options.implementation,
            captureConsumerGolden: options.captureConsumerGolden
        )
        : nil

    waitForProfilerSignalIfNeeded(options.waitForSignal)

    var counters = Counters()
    let cpuStart = processCPUSeconds()
    let wallStart = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<callbackCount {
        counters.callbackCount += 1
        let sharedCapture = try archive.append(input, counters: &counters)
        if let openAI { try openAI.append(input, counters: &counters) }
        if let parakeet {
            try parakeet.append(input, sharedCapture: sharedCapture, counters: &counters)
        }
    }
    if let openAI { openAI.finish(counters: &counters) }
    let transcript = try parakeet?.finish(counters: &counters)
    let wallEnd = DispatchTime.now().uptimeNanoseconds
    let cpuEnd = processCPUSeconds()

    let sourceDigest: String
    let archiveDigest: String
    if options.skipGolden {
        sourceDigest = "skipped"
        archiveDigest = "skipped"
    } else {
        let sourceHasher = RawPCMHasher()
        for _ in 0..<callbackCount { sourceHasher.update(input) }
        sourceDigest = sourceHasher.finalize()
        archiveDigest = try archive.digest()
    }
    let cpuMilliseconds = (cpuEnd - cpuStart) * 1_000
    let wallMilliseconds = Double(wallEnd - wallStart) / 1_000_000
    return Result(
        schemaVersion: 2,
        implementation: options.implementation,
        path: options.path,
        durationSeconds: options.durationSeconds,
        sampleRate: Int(inputSampleRate),
        channels: Int(inputChannels),
        bufferFrames: options.bufferFrames,
        wallMilliseconds: wallMilliseconds,
        cpuMilliseconds: cpuMilliseconds,
        cpuDutyPercentOfAudioDuration: cpuMilliseconds / (Double(options.durationSeconds) * 1_000) * 100,
        peakResidentBytes: peakResidentBytes(),
        sourcePCM_SHA256: sourceDigest,
        archivePCM_SHA256: archiveDigest,
        archivePCMMatchesSource: !options.skipGolden && sourceDigest == archiveDigest,
        consumerInputSHA256: openAI?.consumerDigest() ?? parakeet?.consumerDigest(),
        transcriptSHA256: transcript.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() },
        counters: counters
    )
}

do {
    let options = try Options.parse()
    let result = try run(options)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(result)
    if let outputURL = options.outputURL {
        try data.write(to: outputURL, options: .atomic)
    }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
    if options.path == .parakeet {
        // The installed ggml-metal build asserts while global residency sets
        // are torn down. Production keeps the context for the app lifetime.
        // Exit without global C++ destruction after the benchmark is flushed.
        fflush(nil)
        _exit(0)
    }
} catch {
    FileHandle.standardError.write(Data("AudioCaptureProfile error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
