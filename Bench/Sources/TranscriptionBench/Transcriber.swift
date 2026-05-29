import Foundation

// Vendored copy of OpenAIAudioTranscriber.transcribe(...) shape, parameterized
// for benchmarking. Optimization trials mutate this file (and Preprocess.swift).
// EDIT BOUNDARY: this file + Preprocess.swift only.

struct TranscriptionResult: Equatable {
    var text: String
    var engineName: String
    /// Bytes of the actual multipart body (post-preprocess) sent on the wire.
    var bytesUploaded: Int = 0
}

enum TranscribeError: Error {
    case audioMissing(String)
    case invalidResponse
    case server(status: Int, message: String)
    case empty
}

// Configuration knobs the runner can flip. Treat as part of the edit boundary —
// trials may add/change knobs and update Variant.swift (the active variant).
struct TranscriberConfig {
    var endpointURL: URL
    var model: String = "gpt-4o-transcribe"
    /// When true, use streaming-file upload (URLSession.upload(for:fromFile:))
    /// instead of building the whole multipart body in memory.
    var useStreamingUpload: Bool = false
    /// When true, audio is preprocessed (compressed/downsampled) before upload.
    var preprocess: PreprocessKind = .none
    /// When true, request_response_format="text" so we skip JSON parse on response.
    var plainTextResponse: Bool = false
    /// When non-nil, override the multipart boundary (deterministic for testing).
    var fixedBoundary: String? = nil
    /// Reuse a shared URLSession; mainline matches OpenAIAudioTranscriber.swift.
    var sharedSession: Bool = true
}

enum PreprocessKind: String {
    case none
    case downsample16k        // PCM16 mono 16 kHz WAV
    case opusOgg              // (placeholder — falls back to downsample16k for portability)
    case aac24kbps            // AAC-LC 24 kbps mono 16 kHz in M4A
    case aac16kbps            // AAC-LC 16 kbps mono 16 kHz in M4A
    case aac12kbps            // AAC-LC 12 kbps mono 16 kHz in M4A
    case aac32kbps            // AAC-LC 32 kbps mono 16 kHz in M4A (quality safety net)
}

actor Transcriber {
    let config: TranscriberConfig
    private let session: URLSession
    fileprivate var _currentUploadContentType: String = "audio/wav"
    fileprivate var _currentUploadExt: String = "wav"

    init(config: TranscriberConfig) {
        self.config = config
        if config.sharedSession {
            self.session = URLSession.shared
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.httpMaximumConnectionsPerHost = 6
            self.session = URLSession(configuration: cfg)
        }
    }

    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw TranscribeError.audioMissing(audioURL.path)
        }

        // Optionally preprocess (compress/downsample).
        let uploadURL: URL
        let cleanupTempFile: URL?
        let uploadContentType: String
        let uploadExt: String
        switch config.preprocess {
        case .none:
            uploadURL = audioURL
            cleanupTempFile = nil
            uploadContentType = "audio/wav"
            uploadExt = "wav"
        case .downsample16k:
            let temp = try Preprocess.downsamplePCM16Mono16k(source: audioURL)
            uploadURL = temp
            cleanupTempFile = temp
            uploadContentType = "audio/wav"
            uploadExt = "wav"
        case .opusOgg:
            let temp = try Preprocess.downsamplePCM16Mono16k(source: audioURL)
            uploadURL = temp
            cleanupTempFile = temp
            uploadContentType = "audio/wav"
            uploadExt = "wav"
        case .aac24kbps:
            let temp = try Preprocess.encodeAACM4A(source: audioURL, bitrate: 24_000)
            uploadURL = temp
            cleanupTempFile = temp
            uploadContentType = "audio/mp4"
            uploadExt = "m4a"
        case .aac16kbps:
            let temp = try Preprocess.encodeAACM4A(source: audioURL, bitrate: 16_000)
            uploadURL = temp
            cleanupTempFile = temp
            uploadContentType = "audio/mp4"
            uploadExt = "m4a"
        case .aac12kbps:
            let temp = try Preprocess.encodeAACM4A(source: audioURL, bitrate: 12_000)
            uploadURL = temp
            cleanupTempFile = temp
            uploadContentType = "audio/mp4"
            uploadExt = "m4a"
        case .aac32kbps:
            let temp = try Preprocess.encodeAACM4A(source: audioURL, bitrate: 32_000)
            uploadURL = temp
            cleanupTempFile = temp
            uploadContentType = "audio/mp4"
            uploadExt = "m4a"
        }
        defer {
            if let cleanupTempFile, ProcessInfo.processInfo.environment["BENCH_KEEP_TEMP"] == nil {
                try? FileManager.default.removeItem(at: cleanupTempFile)
            }
        }
        // Capture for the multipart body builder. We mutate stored copies on
        // the actor instance via a local closure-friendly tuple.
        self._currentUploadContentType = uploadContentType
        self._currentUploadExt = uploadExt

        let boundary = config.fixedBoundary ?? "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: config.endpointURL)
        request.httpMethod = "POST"
        request.setValue("Bearer test-key", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let (data, response): (Data, URLResponse)
        var bytesSent: Int = 0
        if config.useStreamingUpload {
            // Build a temp file containing the multipart body, then upload with
            // URLSession.upload(for:fromFile:). Avoids materialising the audio
            // bytes in the Swift heap for the in-memory request body.
            let bodyURL = try makeMultipartBodyFile(audioURL: uploadURL, boundary: boundary)
            defer { try? FileManager.default.removeItem(at: bodyURL) }
            bytesSent = (try? FileManager.default.attributesOfItem(atPath: bodyURL.path)[.size] as? Int) ?? 0
            (data, response) = try await session.upload(for: request, fromFile: bodyURL)
        } else {
            let body = try makeMultipartBodyData(audioURL: uploadURL, boundary: boundary)
            bytesSent = body.count
            request.httpBody = body
            (data, response) = try await session.data(for: request)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TranscribeError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TranscribeError.server(status: http.statusCode, message: String(decoding: data, as: UTF8.self))
        }

        let text: String
        if config.plainTextResponse {
            text = String(decoding: data, as: UTF8.self)
        } else {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = object["text"] as? String
            else {
                throw TranscribeError.invalidResponse
            }
            text = value
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranscribeError.empty }
        return TranscriptionResult(text: trimmed, engineName: "bench-\(config.model)", bytesUploaded: bytesSent)
    }

    private func makeMultipartBodyData(audioURL: URL, boundary: String) throws -> Data {
        var body = Data()
        func append(_ s: String) { body.append(Data(s.utf8)) }
        let ct = _currentUploadContentType
        let ext = _currentUploadExt
        let fname = "audio.\(ext)"
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(config.model)\r\n")
        if config.plainTextResponse {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
            append("text\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fname)\"\r\n")
        append("Content-Type: \(ct)\r\n\r\n")
        body.append(try Data(contentsOf: audioURL))
        append("\r\n")
        append("--\(boundary)--\r\n")
        return body
    }

    private func makeMultipartBodyFile(audioURL: URL, boundary: String) throws -> URL {
        let fm = FileManager.default
        let bodyURL = fm.temporaryDirectory.appendingPathComponent("bench-body-\(UUID().uuidString)")
        fm.createFile(atPath: bodyURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: bodyURL)
        defer { try? handle.close() }
        func append(_ s: String) { try? handle.write(contentsOf: Data(s.utf8)) }
        let ct = _currentUploadContentType
        let ext = _currentUploadExt
        let fname = "audio.\(ext)"
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(config.model)\r\n")
        if config.plainTextResponse {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
            append("text\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fname)\"\r\n")
        append("Content-Type: \(ct)\r\n\r\n")
        // Stream the audio file in chunks rather than loading into memory.
        let inHandle = try FileHandle(forReadingFrom: audioURL)
        defer { try? inHandle.close() }
        while autoreleasepool(invoking: { () -> Bool in
            let chunk = inHandle.availableData
            if chunk.isEmpty { return false }
            try? handle.write(contentsOf: chunk)
            return true
        }) { }
        append("\r\n")
        append("--\(boundary)--\r\n")
        return bodyURL
    }
}
