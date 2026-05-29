import Foundation

// Active variant for the current trial. Trials patch THIS function only —
// this is the smallest possible edit surface.
//
// Variants are addressed by environment variable BENCH_VARIANT so the runner
// can sweep without recompiling. Defaults to "baseline".
enum Variant {
    static func current(endpoint: URL) -> TranscriberConfig {
        let name = ProcessInfo.processInfo.environment["BENCH_VARIANT"] ?? "baseline"
        switch name {
        case "baseline":
            // Mirrors current OpenAIAudioTranscriber.swift.
            return TranscriberConfig(
                endpointURL: endpoint,
                useStreamingUpload: false,
                preprocess: .none,
                plainTextResponse: false,
                sharedSession: true
            )
        case "stream-upload":
            return TranscriberConfig(
                endpointURL: endpoint,
                useStreamingUpload: true,
                preprocess: .none,
                plainTextResponse: false,
                sharedSession: true
            )
        case "downsample-16k":
            return TranscriberConfig(
                endpointURL: endpoint,
                useStreamingUpload: false,
                preprocess: .downsample16k,
                plainTextResponse: false,
                sharedSession: true
            )
        case "downsample-stream":
            return TranscriberConfig(
                endpointURL: endpoint,
                useStreamingUpload: true,
                preprocess: .downsample16k,
                plainTextResponse: false,
                sharedSession: true
            )
        case "plain-text":
            return TranscriberConfig(
                endpointURL: endpoint,
                useStreamingUpload: false,
                preprocess: .none,
                plainTextResponse: true,
                sharedSession: true
            )
        case "downsample-stream-plain":
            return TranscriberConfig(
                endpointURL: endpoint,
                useStreamingUpload: true,
                preprocess: .downsample16k,
                plainTextResponse: true,
                sharedSession: true
            )
        case "dedicated-session":
            return TranscriberConfig(
                endpointURL: endpoint,
                useStreamingUpload: false,
                preprocess: .none,
                plainTextResponse: false,
                sharedSession: false
            )
        case "plain-text-dedicated":
            // Combined winners.
            return TranscriberConfig(
                endpointURL: endpoint,
                useStreamingUpload: false,
                preprocess: .none,
                plainTextResponse: true,
                sharedSession: false
            )
        case "stream-dedicated":
            return TranscriberConfig(
                endpointURL: endpoint,
                useStreamingUpload: true,
                preprocess: .none,
                plainTextResponse: false,
                sharedSession: false
            )
        case "plain-text-stream-dedicated":
            return TranscriberConfig(
                endpointURL: endpoint,
                useStreamingUpload: true,
                preprocess: .none,
                plainTextResponse: true,
                sharedSession: false
            )
        case "aac-24k":
            return TranscriberConfig(
                endpointURL: endpoint,
                useStreamingUpload: false,
                preprocess: .aac24kbps,
                plainTextResponse: true,
                sharedSession: true
            )
        case "aac-16k":
            return TranscriberConfig(
                endpointURL: endpoint,
                useStreamingUpload: false,
                preprocess: .aac16kbps,
                plainTextResponse: true,
                sharedSession: true
            )
        case "aac-12k":
            return TranscriberConfig(
                endpointURL: endpoint,
                useStreamingUpload: false,
                preprocess: .aac12kbps,
                plainTextResponse: true,
                sharedSession: true
            )
        case "aac-32k":
            return TranscriberConfig(
                endpointURL: endpoint,
                useStreamingUpload: false,
                preprocess: .aac32kbps,
                plainTextResponse: true,
                sharedSession: true
            )
        case "aac-24k-stream":
            return TranscriberConfig(
                endpointURL: endpoint,
                useStreamingUpload: true,
                preprocess: .aac24kbps,
                plainTextResponse: true,
                sharedSession: true
            )
        default:
            FileHandle.standardError.write(Data("Unknown BENCH_VARIANT=\(name); falling back to baseline.\n".utf8))
            return TranscriberConfig(endpointURL: endpoint)
        }
    }
}
