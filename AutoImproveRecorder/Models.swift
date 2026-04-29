import Foundation

enum RecorderPhase: Equatable {
    case idle
    case recording(URL)
    case transcribing
    case improving
    case ready
    case failed

    var label: String {
        switch self {
        case .idle:
            return "Ready"
        case .recording:
            return "Recording"
        case .transcribing:
            return "Transcribing"
        case .improving:
            return "Improving"
        case .ready:
            return "Preview"
        case .failed:
            return "Needs attention"
        }
    }

    var isBusy: Bool {
        switch self {
        case .recording, .transcribing, .improving:
            return true
        case .idle, .ready, .failed:
            return false
        }
    }
}

enum AutoImproveMode: String, CaseIterable, Identifiable {
    case off
    case manual
    case automatic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off:
            return "Off"
        case .manual:
            return "Manual"
        case .automatic:
            return "Automatic"
        }
    }
}

enum OutputMode: String, CaseIterable, Identifiable {
    case verbatim
    case lightCleanup
    case promptCleanup
    case structuredTask

    var id: String { rawValue }

    var label: String {
        switch self {
        case .verbatim:
            return "Verbatim"
        case .lightCleanup:
            return "Light cleanup"
        case .promptCleanup:
            return "Prompt cleanup"
        case .structuredTask:
            return "Structured task"
        }
    }

    var promptInstruction: String {
        switch self {
        case .verbatim:
            return "Keep wording as close to the raw transcript as possible. Fix only obvious transcription errors and punctuation."
        case .lightCleanup:
            return "Lightly clean the transcript by removing filler, repeated starts, and obvious speech artifacts while preserving the speaker's wording."
        case .promptCleanup:
            return "Rewrite the transcript into a clear prompt or instruction while preserving intent, constraints, names, and technical details."
        case .structuredTask:
            return "Convert the transcript into a concise structured task with clear objective, constraints, and deliverables when they are present."
        }
    }
}

struct TranscriptSession: Equatable {
    var audioURL: URL?
    var rawTranscript: String
    var improvedText: String
    var message: String?
    var improveFailed: Bool

    static let empty = TranscriptSession(
        audioURL: nil,
        rawTranscript: "",
        improvedText: "",
        message: nil,
        improveFailed: false
    )

    var preferredText: String {
        if !improvedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return improvedText
        }
        return rawTranscript
    }
}
