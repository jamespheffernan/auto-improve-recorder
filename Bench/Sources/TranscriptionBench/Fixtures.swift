import Foundation
import AVFoundation

enum Fixtures {
    struct Spec {
        let name: String
        let durationSeconds: Double
        let sampleRate: Double
        let channels: AVAudioChannelCount
    }

    static let specs: [Spec] = [
        Spec(name: "short-5s", durationSeconds: 5, sampleRate: 48_000, channels: 1),
        Spec(name: "medium-30s", durationSeconds: 30, sampleRate: 48_000, channels: 1),
        Spec(name: "long-120s", durationSeconds: 120, sampleRate: 48_000, channels: 1)
    ]

    /// Generate a deterministic synthetic WAV for each spec into the given dir.
    /// Uses a sum-of-sines waveform so audio is non-zero and not trivially compressible
    /// (more representative of real speech than a single tone).
    static func ensure(in dir: URL) throws -> [(spec: Spec, url: URL)] {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var results: [(Spec, URL)] = []
        for spec in specs {
            let url = dir.appendingPathComponent("\(spec.name).wav")
            if fm.fileExists(atPath: url.path) {
                results.append((spec, url))
                continue
            }
            try writeSineWAV(at: url, spec: spec)
            results.append((spec, url))
        }
        return results
    }

    private static func writeSineWAV(at url: URL, spec: Spec) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: spec.sampleRate,
            channels: spec.channels,
            interleaved: false
        )!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: spec.sampleRate,
            AVNumberOfChannelsKey: Int(spec.channels),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let chunkFrames = AVAudioFrameCount(spec.sampleRate)
        let chunks = Int(spec.durationSeconds)
        for chunkIndex in 0..<chunks {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames)!
            buffer.frameLength = chunkFrames
            let sr = spec.sampleRate
            let chPtr = buffer.floatChannelData!
            for ch in 0..<Int(spec.channels) {
                let p = chPtr[ch]
                for i in 0..<Int(chunkFrames) {
                    let t = Double(chunkIndex) + Double(i) / sr
                    // Speech-like: three sine partials + slow envelope + tiny noise.
                    let a1 = sin(2 * .pi * 220.0 * t)
                    let a2 = 0.4 * sin(2 * .pi * 440.0 * t + 0.7)
                    let a3 = 0.25 * sin(2 * .pi * 880.0 * t + 1.3)
                    let env = 0.5 + 0.5 * sin(2 * .pi * 0.5 * t)
                    p[i] = Float(0.4 * env * (a1 + a2 + a3))
                }
            }
            try file.write(from: buffer)
        }
    }
}
