import CoreML
import Darwin
import FluidAudio
import Foundation

/// A private resident worker. It loads only bundled models and never downloads audio or weights.
@main
struct PhononCoreMLWorker {
    static let modelID = "FluidInference/phonon-2-coreml"

    struct Request: Decodable { let audio: String }

    static func reply(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
    }

    static func main() async {
        let parent = getppid()
        DispatchQueue.global(qos: .background).async {
            while getppid() == parent { sleep(2) }
            _exit(0)
        }
        do {
            guard CommandLine.arguments.count == 2 else {
                throw WorkerError("Expected a local Phonon Core ML runtime directory")
            }
            let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            let models = try AsrModels.loadLocal(
                from: root.appendingPathComponent("models"), version: .phonon2,
                configuration: configuration, encoderComputeUnits: .cpuAndNeuralEngine)
            let manager = AsrManager(models: models)
            var warmState = try TdtDecoderState()
            _ = try await manager.transcribe([Float](repeating: 0, count: 16_000), decoderState: &warmState)
            try reply(["ready": true, "model": modelID, "backend": "coreml-neural-engine"])

            while let line = readLine() {
                do {
                    let request = try JSONDecoder().decode(Request.self, from: Data(line.utf8))
                    let audio = URL(fileURLWithPath: request.audio)
                    guard FileManager.default.fileExists(atPath: audio.path) else {
                        throw WorkerError("Recording file is missing")
                    }
                    // Reset decoder state for each independent recording; reuse the loaded models.
                    var state = try TdtDecoderState()
                    let start = Date()
                    let result = try await manager.transcribe(audio, decoderState: &state)
                    try reply(["model": modelID, "backend": "coreml-neural-engine",
                               "text": result.text, "decode_seconds": Date().timeIntervalSince(start),
                               "duration_seconds": result.duration, "truncated": false])
                } catch {
                    try reply(["error": error.localizedDescription])
                }
            }
            await manager.cleanup()
        } catch {
            try? reply(["error": error.localizedDescription])
            exit(1)
        }
    }

    struct WorkerError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
