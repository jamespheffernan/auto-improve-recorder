import Foundation
import XCTest

final class AutoSendTargetManifestTests: XCTestCase {
    func testAutoSendTargetContainsOnlyBoundedParakeetDeliverySources() throws {
        let project = try String(contentsOf: projectURL, encoding: .utf8)
        let sourcePhase = try targetSourcesPhase(in: project)

        let required = [
            "AutoSendRecorderApp.swift",
            "AutoSendState.swift",
            "AudioRecorder.swift",
            "AudioPipelineTypes.swift",
            "MicrophoneHealthMonitor.swift",
            "ArchiveAudioWriter.swift",
            "ParakeetCAPI.swift",
            "AccessibilityPasteController.swift",
            "AppDeliveryRules.swift",
            "DeliveryOptimization.swift",
            "DeliveryService.swift",
            "TranscriptTextNormalizer.swift"
        ]
        for filename in required {
            XCTAssertTrue(
                sourcePhase.contains("/* \(filename) in Sources */"),
                "Missing required source: \(filename)"
            )
        }

        let forbidden = [
            "ImprovementService.swift",
            "ImproveEngine.swift",
            "OpenAIImproveEngine.swift",
            "AlternativeImproveEngines.swift",
            "OllamaImproveEngine.swift",
            "OpenAIRealtimeTranscriber.swift",
            "OpenAIAudioTranscriber.swift",
            "AppleLocalEngines.swift",
            "SharedNetworkClient.swift",
            "AppState.swift",
            "AppEnvironment.swift",
            "AppSettingsStore.swift",
            "Models.swift",
            "PreviewView.swift",
            "SettingsView.swift"
        ]
        for filename in forbidden {
            XCTAssertFalse(
                sourcePhase.contains("/* \(filename) in Sources */"),
                "Forbidden source selected: \(filename)"
            )
        }
    }

    func testAutoSendSourcesDoNotImportImprovementProviders() throws {
        let sourceDirectory = projectURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AutoSendRecorder")
        guard let enumerator = FileManager.default.enumerator(
            at: sourceDirectory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return XCTFail("Could not enumerate Auto Send Recorder sources")
        }
        let sourceURLs = enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        let forbiddenTokens = ["OpenAI", "Anthropic", "Gemini", "Ollama", "ImprovementService", "ImproveEngine"]
        for sourceURL in sourceURLs {
            let text = try String(contentsOf: sourceURL)
            for token in forbiddenTokens {
                XCTAssertFalse(
                    text.contains(token),
                    "\(sourceURL.lastPathComponent) contains forbidden dependency token \(token)"
                )
            }
        }
    }

    func testAutoSendUsesStableDevelopmentSigningInsteadOfAdHocSigning() throws {
        let project = try String(contentsOf: projectURL, encoding: .utf8)
        for marker in [
            "ASR0000000000000000000082 /* Debug */ = {",
            "ASR0000000000000000000083 /* Release */ = {"
        ] {
            guard let start = project.range(of: marker) else {
                return XCTFail("Missing Auto Send build configuration: \(marker)")
            }
            let suffix = project[start.lowerBound...]
            guard let end = suffix.range(of: "\n\t\t};") else {
                return XCTFail("Malformed Auto Send build configuration: \(marker)")
            }
            let configuration = suffix[..<end.upperBound]
            XCTAssertFalse(configuration.contains("CODE_SIGN_IDENTITY = \"-\";"))
            XCTAssertTrue(configuration.contains("CODE_SIGN_IDENTITY = \"Apple Development:"))
            XCTAssertTrue(configuration.contains("DEVELOPMENT_TEAM = 7W38KL8969;"))
        }
    }

    func testAutoSendBundlesBrandedAppAndMenuBarIcons() throws {
        let project = try String(contentsOf: projectURL, encoding: .utf8)
        let infoPlistURL = projectURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AutoSendRecorder/Info.plist")
        let infoPlist = try String(contentsOf: infoPlistURL, encoding: .utf8)
        let delegateURL = infoPlistURL
            .deletingLastPathComponent()
            .appendingPathComponent("AutoSendAppDelegate.swift")
        let delegate = try String(contentsOf: delegateURL, encoding: .utf8)

        XCTAssertTrue(project.contains("Assets.xcassets in Resources"))
        XCTAssertTrue(project.contains("ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;"))
        XCTAssertTrue(infoPlist.contains("<key>CFBundleIconFile</key>\n\t<string>AppIcon</string>"))
        XCTAssertTrue(delegate.contains("NSImage(named: \"MenuBarIcon\")"))
        XCTAssertTrue(delegate.contains("image.isTemplate = true"))
        XCTAssertTrue(delegate.contains("state.settings.menuBarIconStyle != .white"))
    }

    func testIdentityAndSelectedSourceBranding() throws {
        let root = projectURL.deletingLastPathComponent().deletingLastPathComponent()
        let project = try String(contentsOf: projectURL, encoding: .utf8)
        XCTAssertEqual(project.components(separatedBy: "PRODUCT_BUNDLE_IDENTIFIER = com.turfterrace.autosendrecorder;").count - 1, 2)
        let plist = try String(contentsOf: root.appendingPathComponent("AutoSendRecorder/Info.plist"))
        XCTAssertTrue(plist.contains("<key>CFBundleIdentifier</key>\n\t<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>"))
        let settings = try String(contentsOf: root.appendingPathComponent("AutoSendRecorder/AutoSendSettingsStore.swift"))
        XCTAssertTrue(settings.contains("UserDefaults(suiteName: AutoSendSettingsStore.defaultsSuiteName)"))
        let state = try String(contentsOf: root.appendingPathComponent("AutoSendRecorder/AutoSendState.swift"))
        XCTAssertTrue(state.contains("currentApp?.bundleIdentifier == AutoSendSettingsStore.defaultsSuiteName"))
        XCTAssertTrue(state.contains("app.bundleIdentifier != AutoSendSettingsStore.defaultsSuiteName"))

        let phase = try targetSourcesPhase(in: project)
        let names = phase.components(separatedBy: "\n").compactMap { line -> String? in
            guard let start = line.range(of: "/* "), let end = line.range(of: " in Sources */") else { return nil }
            return String(line[start.upperBound..<end.lowerBound])
        }
        let files = ["AutoSendRecorder", "AutoImproveRecorder"].flatMap { directory in
            FileManager.default.enumerator(at: root.appendingPathComponent(directory), includingPropertiesForKeys: nil)!
                .compactMap { $0 as? URL }
        }
        for name in names {
            let matches = files.filter { $0.lastPathComponent == name }
            XCTAssertEqual(matches.count, 1, name)
            for file in matches {
                let text = try String(contentsOf: file).lowercased()
                let normalized = text.filter { $0.isLetter || $0.isNumber }
                XCTAssertFalse(normalized.contains("field" + "theory"), file.path)
            }
        }
        let compatibility = try String(contentsOf: root.appendingPathComponent("AutoSendRecorder/AutoSendParakeetCompatibility.swift"))
        XCTAssertTrue(compatibility.contains("Library/Application Support/AutoImproveRecorder/ParakeetCpp"))
    }

    private var projectURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AutoImproveRecorder.xcodeproj/project.pbxproj")
    }

    private func targetSourcesPhase(in project: String) throws -> Substring {
        guard let marker = project.range(of: "ASR0000000000000000000051 /* Sources */ = {") else {
            throw ManifestError.missingAutoSendSourcePhase
        }
        let suffix = project[marker.lowerBound...]
        guard let end = suffix.range(of: "\n\t\t};") else {
            throw ManifestError.malformedAutoSendSourcePhase
        }
        return suffix[..<end.upperBound]
    }
}

private enum ManifestError: Error {
    case missingAutoSendSourcePhase
    case malformedAutoSendSourcePhase
}
