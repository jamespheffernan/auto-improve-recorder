// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AutoImproveRecorderDictionaryCore",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(
            name: "AutoImproveRecorderDictionaryCore",
            path: "AutoImproveRecorder/Support",
            exclude: [
                "AudioInputDeviceDiscovery.swift",
                "HotKeyCenter.swift",
                "KeychainStore.swift",
                "MicrophoneDeviceObserver.swift",
                "RecordingTrigger",
                "SecretsStore.swift"
            ],
            sources: [
                "AccessibilityPasteController.swift",
                "AppDeliveryRules.swift",
                "DeliveryOptimization.swift",
                "DeliveryService.swift",
                "DiagnosticsStore.swift",
                "DictionaryLexicon.swift",
                "DictionaryStore.swift",
                "FastestTranscriptionFallbackSelector.swift",
                "LocalModelInventory.swift",
                "LocalRuntimeHealth.swift",
                "LocalRuntimeProbe.swift",
                "PhononTranscriber.swift",
                "MicrophoneDevice.swift",
                "MicrophoneHealthMonitor.swift",
                "RealtimeDiagnosticsRedactor.swift",
                "TranscriptEditValueGate.swift",
                "TranscriptTextNormalizer.swift",
                "TranscriptArchiveStore.swift",
                "TranscriptArchiveClient.swift"
            ]
        ),
        .target(
            name: "AutoImproveRecorderAudioPipeline",
            path: "AutoImproveRecorder/Recording",
            exclude: [
                "AudioRecorder.swift",
                "RecordingClient.swift"
            ],
            sources: [
                "AudioPipelineTypes.swift",
                "RealtimePCMChunker.swift",
                "BoundedAudioQueue.swift",
                "ArchiveAudioWriter.swift",
                "AudioCaptureFanout.swift"
            ]
        ),
        .target(
            name: "AutoImproveRecorderTriggerCore",
            path: "AutoImproveRecorder/Support/RecordingTrigger",
            sources: [
                "RecordingTriggerModels.swift",
                "RecordingTriggerController.swift"
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
            name: "AutoImproveRecorderDictionaryCoreTests",
            dependencies: ["AutoImproveRecorderDictionaryCore"],
            path: "Tests/AutoImproveRecorderDictionaryCoreTests"
        ),
        .testTarget(
            name: "AutoImproveRecorderLocalModelTests",
            dependencies: ["AutoImproveRecorderDictionaryCore"],
            path: "Tests/AutoImproveRecorderLocalModelTests"
        ),
        .testTarget(
            name: "AutoImproveRecorderAudioPipelineTests",
            dependencies: ["AutoImproveRecorderAudioPipeline"],
            path: "Tests/AutoImproveRecorderAudioPipelineTests"
        ),
        .testTarget(
            name: "AutoImproveRecorderTriggerCoreTests",
            dependencies: ["AutoImproveRecorderTriggerCore"],
            path: "Tests/AutoImproveRecorderTriggerCoreTests"
        ),
        .testTarget(
            name: "AutoSendRecorderCoreTests",
            dependencies: ["AutoSendRecorderCore", "AutoImproveRecorderDictionaryCore"],
            path: "Tests/AutoSendRecorderCoreTests"
        )
    ]
)
