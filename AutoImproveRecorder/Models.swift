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

enum RecordingTriggerMode: String, CaseIterable, Identifiable {
    case walkieTalkie
    case toggle

    var id: String { rawValue }

    var label: String {
        switch self {
        case .walkieTalkie:
            return "Hold to talk"
        case .toggle:
            return "Click on/off"
        }
    }
}

enum RecordingHotKey: String, CaseIterable, Identifiable {
    case a, b, c, d, e, f, g, h, i, j, k, l, m
    case n, o, p, q, r, s, t, u, v, w, x, y, z

    var id: String { rawValue }

    var keyLabel: String {
        rawValue.uppercased()
    }

    var label: String {
        "Hyper + \(keyLabel)"
    }

    var keyCode: UInt32 {
        switch self {
        case .a:
            return 0x00
        case .s:
            return 0x01
        case .d:
            return 0x02
        case .f:
            return 0x03
        case .h:
            return 0x04
        case .g:
            return 0x05
        case .z:
            return 0x06
        case .x:
            return 0x07
        case .c:
            return 0x08
        case .v:
            return 0x09
        case .b:
            return 0x0B
        case .q:
            return 0x0C
        case .w:
            return 0x0D
        case .e:
            return 0x0E
        case .r:
            return 0x0F
        case .y:
            return 0x10
        case .t:
            return 0x11
        case .o:
            return 0x1F
        case .u:
            return 0x20
        case .i:
            return 0x22
        case .p:
            return 0x23
        case .l:
            return 0x25
        case .j:
            return 0x26
        case .k:
            return 0x28
        case .n:
            return 0x2D
        case .m:
            return 0x2E
        }
    }
}

enum TranscriptionMode: String, CaseIterable, Identifiable {
    case localWhisper
    case localParakeet
    case appleLocal
    case openAIAPI
    case fastest

    var id: String { rawValue }

    var label: String {
        switch self {
        case .localWhisper:
            return "Local Whisper"
        case .localParakeet:
            return "Local Parakeet"
        case .appleLocal:
            return "Apple Speech"
        case .openAIAPI:
            return "OpenAI API"
        case .fastest:
            return "Fastest"
        }
    }
}

enum ImprovementMode: String, CaseIterable, Identifiable {
    case openAI
    case geminiFlash
    case claudeHaiku
    case appleLocal
    case ollamaLocal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openAI:
            return "OpenAI"
        case .geminiFlash:
            return "Gemini Flash"
        case .claudeHaiku:
            return "Claude Haiku"
        case .appleLocal:
            return "Apple local"
        case .ollamaLocal:
            return "Ollama local"
        }
    }

    var detailLabel: String {
        switch self {
        case .openAI:
            return "OpenAI gpt-5-mini"
        case .geminiFlash:
            return "Gemini 2.5 Flash"
        case .claudeHaiku:
            return "Claude Haiku 4.5"
        case .appleLocal:
            return "Apple local model"
        case .ollamaLocal:
            return "Ollama qwen3.5:0.8b-mlx"
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
            return "Near-verbatim"
        case .lightCleanup:
            return "Clean"
        case .promptCleanup:
            return "Prompt"
        case .structuredTask:
            return "Task"
        }
    }

    var promptInstruction: String {
        switch self {
        case .verbatim:
            return "Make the smallest possible edits: punctuation, paragraph breaks, capitalization, and obvious transcription corrections only."
        case .lightCleanup:
            return "Default cleanup. Keep the speaker's thinking, uncertainty, caveats, ordering, and substantive asides. Remove only disposable dictation artifacts such as ums, repeated accidental fragments, duplicated words, and obvious speech-to-text mistakes. Do not compress away exploratory reasoning."
        case .promptCleanup:
            return "Turn the transcript into a clear prompt or instruction, preserving every explicit request, constraint, example, name, technical detail, and uncertainty."
        case .structuredTask:
            return "Convert the transcript into a concise structured task with objective, context, constraints, and deliverables when they are present. Preserve unresolved questions instead of inventing answers."
        }
    }

    var promptIntensity: String {
        switch self {
        case .verbatim:
            return "1 out of 4: punctuation and transcription fixes only."
        case .lightCleanup:
            return "2 out of 4: conservative cleanup, preserving thought process."
        case .promptCleanup:
            return "3 out of 4: rewrite into a usable prompt without dropping constraints."
        case .structuredTask:
            return "4 out of 4: restructure into a task while preserving all stated requirements."
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

struct CompletionNotification: Equatable {
    var title: String
    var body: String
}

struct OpenAIRealtimeDiagnostics: Equatable {
    var summary: String
    var details: String

    static let empty = OpenAIRealtimeDiagnostics(summary: "", details: "")

    var isEmpty: Bool {
        summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
