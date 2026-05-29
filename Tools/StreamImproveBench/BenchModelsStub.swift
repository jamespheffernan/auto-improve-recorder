// Tiny stand-ins for the symbols the engine sources reach for from
// AutoImproveRecorder/Models.swift. Avoids pulling in AppKit / AVFoundation.

import Foundation

enum OutputMode: String {
    case verbatim
    case lightCleanup
    case promptCleanup
    case structuredTask

    var label: String {
        switch self {
        case .verbatim: return "Near-verbatim"
        case .lightCleanup: return "Clean"
        case .promptCleanup: return "Prompt"
        case .structuredTask: return "Task"
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
