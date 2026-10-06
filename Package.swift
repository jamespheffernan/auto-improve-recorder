// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AutoImproveRecorderDictionaryCore",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(
            name: "AutoImproveRecorderCore",
            path: "AutoImproveRecorder",
            exclude: [
                "AppIcon.icns",
                "Assets.xcassets",
                "AutoImproveRecorderApp.swift",
                "Info.plist"
            ]
        ),
        .target(
            name: "AutoSendRecorderCore",
            path: "AutoSendRecorder",
            exclude: [
                "UI",
                "Info.plist",
                "AutoSendAppDelegate.swift",
                "AutoSendDeliveryAdapter.swift",
                "AutoSendHotKeyCenter.swift",
                "AutoSendParakeetCompatibility.swift",
                "AutoSendParakeetService.swift",
                "AutoSendRecorderApp.swift",
                "AutoSendRecordingService.swift",
                "AutoSendSettingsView.swift",
                "AutoSendState.swift"
            ],
            sources: [
                "AutoSendCore.swift",
                "AutoSendRuntimeInstaller.swift",
                "AutoSendPasteboardWriter.swift",
                "AutoSendSettingsStore.swift"
            ]
        ),
        .testTarget(
            name: "AutoImproveRecorderAppStateTests",
            dependencies: ["AutoImproveRecorderCore"],
            path: "Tests/AutoImproveRecorderAppStateTests"
        ),
        .testTarget(
            name: "AutoImproveRecorderDictionaryCoreTests",
            dependencies: ["AutoImproveRecorderCore"],
            path: "Tests/AutoImproveRecorderDictionaryCoreTests"
        ),
        .testTarget(
            name: "AutoImproveRecorderLocalModelTests",
            dependencies: ["AutoImproveRecorderCore"],
            path: "Tests/AutoImproveRecorderLocalModelTests"
        ),
        .testTarget(
            name: "AutoImproveRecorderAudioPipelineTests",
            dependencies: ["AutoImproveRecorderCore"],
            path: "Tests/AutoImproveRecorderAudioPipelineTests"
        ),
        .testTarget(
            name: "AutoImproveRecorderTriggerCoreTests",
            dependencies: ["AutoImproveRecorderCore"],
            path: "Tests/AutoImproveRecorderTriggerCoreTests"
        ),
        .testTarget(
            name: "AutoSendRecorderCoreTests",
            dependencies: ["AutoSendRecorderCore", "AutoImproveRecorderCore"],
            path: "Tests/AutoSendRecorderCoreTests"
        )
    ]
)
