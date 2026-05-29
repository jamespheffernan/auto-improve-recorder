import AVFoundation
import Foundation
import Speech

#if canImport(FoundationModels)
import FoundationModels
#endif

struct AppleLocalAudioTranscriber: TranscriptionEngine {
    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw TranscriptionEngineError.audioMissing(audioURL.path)
        }

        #if os(iOS)
        if #available(iOS 26.0, *) {
            return try await AppleSpeechTranscriber().transcribe(audioURL: audioURL)
        }
        #elseif os(macOS)
        if #available(macOS 26.0, *) {
            return try await AppleSpeechTranscriber().transcribe(audioURL: audioURL)
        }
        #endif
        throw AppleLocalEngineError.requiresSupportedOS
    }
}

struct AppleLocalImproveEngine: ImproveEngine {
    func improve(rawTranscript: String, outputMode: OutputMode, modificationStrength: Int) async throws -> String {
        #if canImport(FoundationModels)
        #if os(iOS)
        if #available(iOS 26.0, *) {
            return try await AppleFoundationModelImproveEngine().improve(
                rawTranscript: rawTranscript,
                outputMode: outputMode,
                modificationStrength: modificationStrength
            )
        }
        #elseif os(macOS)
        if #available(macOS 26.0, *) {
            return try await AppleFoundationModelImproveEngine().improve(
                rawTranscript: rawTranscript,
                outputMode: outputMode,
                modificationStrength: modificationStrength
            )
        }
        #endif
        throw AppleLocalEngineError.requiresSupportedOS
        #else
        throw AppleLocalEngineError.foundationModelsUnavailable
        #endif
    }
}

@available(iOS 26.0, macOS 26.0, *)
private struct AppleSpeechTranscriber {
    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        guard SpeechTranscriber.isAvailable else {
            throw AppleLocalEngineError.speechUnavailable
        }

        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            throw AppleLocalEngineError.unsupportedSpeechLocale(Locale.current.identifier)
        }

        let audioFile = try AVAudioFile(forReading: audioURL)
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let resultCollector = Task {
            var finalChunks: [String] = []
            var latestVolatileText = ""

            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }

                if result.isFinal {
                    finalChunks.append(text)
                    latestVolatileText = ""
                } else {
                    latestVolatileText = text
                }
            }

            let text = finalChunks.isEmpty ? latestVolatileText : finalChunks.joined(separator: " ")
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        do {
            try await analyzer.prepareToAnalyze(in: audioFile.processingFormat)
            try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
            let text = try await resultCollector.value

            guard !text.isEmpty else {
                throw TranscriptionEngineError.emptyTranscript
            }

            return TranscriptionResult(text: text, engineName: "Apple Speech")
        } catch {
            resultCollector.cancel()
            throw error
        }
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, *)
private struct AppleFoundationModelImproveEngine {
    func improve(rawTranscript: String, outputMode: OutputMode, modificationStrength: Int) async throws -> String {
        let raw = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            throw ImproveEngineError.emptyOutput
        }

        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            throw AppleLocalEngineError.foundationModelUnavailable(model.availability.readableDescription)
        }

        let prompt = ImprovePrompt.make(
            rawTranscript: raw,
            outputMode: outputMode,
            modificationStrength: modificationStrength
        )

        let session = LanguageModelSession(
            model: model,
            instructions: prompt.instructions
        )
        let response = try await session.respond(to: prompt.input)
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ImproveEngineError.emptyOutput
        }
        return text
    }
}
#endif

enum AppleLocalEngineError: LocalizedError {
    case requiresSupportedOS
    case speechUnavailable
    case unsupportedSpeechLocale(String)
    case foundationModelsUnavailable
    case foundationModelUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .requiresSupportedOS:
            return "Apple local processing requires iOS 26 or macOS 26 or later."
        case .speechUnavailable:
            return "Apple on-device speech transcription is not available on this device."
        case .unsupportedSpeechLocale(let locale):
            return "Apple on-device speech transcription does not support the current locale (\(locale))."
        case .foundationModelsUnavailable:
            return "Apple Foundation Models are not available in this SDK."
        case .foundationModelUnavailable(let reason):
            return "Apple on-device improvement is unavailable: \(reason)."
        }
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, *)
private extension SystemLanguageModel.Availability {
    var readableDescription: String {
        switch self {
        case .available:
            return "available"
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "this device is not eligible for Apple Intelligence"
            case .appleIntelligenceNotEnabled:
                return "Apple Intelligence is not enabled"
            case .modelNotReady:
                return "the on-device model is not ready"
            @unknown default:
                return "unknown reason"
            }
        }
    }
}
#endif
