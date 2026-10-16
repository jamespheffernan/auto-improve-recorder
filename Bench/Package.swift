// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AutoImproveBench",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "TranscriptionBench",
            path: "Sources/TranscriptionBench"
        ),
        .executableTarget(
            name: "IOSNetworkBench",
            path: "Sources/IOSNetworkBench"
        ),
        .executableTarget(
            name: "StreamSharedClientBench",
            path: "Sources/StreamSharedClientBench"
        ),
        .executableTarget(
            name: "ParakeetLiveBench",
            path: "Sources/ParakeetLiveBench"
        ),
        .executableTarget(
            name: "AudioCaptureProfile",
            path: "Sources/AudioCaptureProfile"
        ),
        .executableTarget(
            name: "AutoSendLatencyBench",
            path: "Sources/AutoSendLatencyBench"
        )
    ]
)
