import Foundation

#if canImport(Carbon)
import Carbon
#else
private let cmdKey = 0x0100
private let shiftKey = 0x0200
private let optionKey = 0x0800
private let controlKey = 0x1000

private let kVK_ANSI_A = 0x00
private let kVK_ANSI_S = 0x01
private let kVK_ANSI_D = 0x02
private let kVK_ANSI_F = 0x03
private let kVK_ANSI_H = 0x04
private let kVK_ANSI_G = 0x05
private let kVK_ANSI_Z = 0x06
private let kVK_ANSI_X = 0x07
private let kVK_ANSI_C = 0x08
private let kVK_ANSI_V = 0x09
private let kVK_ANSI_B = 0x0B
private let kVK_ANSI_Q = 0x0C
private let kVK_ANSI_W = 0x0D
private let kVK_ANSI_E = 0x0E
private let kVK_ANSI_R = 0x0F
private let kVK_ANSI_Y = 0x10
private let kVK_ANSI_T = 0x11
private let kVK_ANSI_1 = 0x12
private let kVK_ANSI_2 = 0x13
private let kVK_ANSI_3 = 0x14
private let kVK_ANSI_4 = 0x15
private let kVK_ANSI_6 = 0x16
private let kVK_ANSI_5 = 0x17
private let kVK_ANSI_Equal = 0x18
private let kVK_ANSI_9 = 0x19
private let kVK_ANSI_7 = 0x1A
private let kVK_ANSI_Minus = 0x1B
private let kVK_ANSI_8 = 0x1C
private let kVK_ANSI_0 = 0x1D
private let kVK_ANSI_RightBracket = 0x1E
private let kVK_ANSI_O = 0x1F
private let kVK_ANSI_U = 0x20
private let kVK_ANSI_LeftBracket = 0x21
private let kVK_ANSI_I = 0x22
private let kVK_ANSI_P = 0x23
private let kVK_Return = 0x24
private let kVK_ANSI_L = 0x25
private let kVK_ANSI_J = 0x26
private let kVK_ANSI_Quote = 0x27
private let kVK_ANSI_K = 0x28
private let kVK_ANSI_Semicolon = 0x29
private let kVK_ANSI_Backslash = 0x2A
private let kVK_ANSI_Comma = 0x2B
private let kVK_ANSI_Slash = 0x2C
private let kVK_ANSI_N = 0x2D
private let kVK_ANSI_M = 0x2E
private let kVK_ANSI_Period = 0x2F
private let kVK_Tab = 0x30
private let kVK_Space = 0x31
private let kVK_ANSI_Grave = 0x32
private let kVK_Delete = 0x33
private let kVK_Escape = 0x35
private let kVK_F17 = 0x40
private let kVK_F18 = 0x4F
private let kVK_F19 = 0x50
private let kVK_F20 = 0x5A
private let kVK_F5 = 0x60
private let kVK_F6 = 0x61
private let kVK_F7 = 0x62
private let kVK_F3 = 0x63
private let kVK_F8 = 0x64
private let kVK_F9 = 0x65
private let kVK_F11 = 0x67
private let kVK_F16 = 0x6A
private let kVK_F14 = 0x6B
private let kVK_F10 = 0x6D
private let kVK_F12 = 0x6F
private let kVK_F15 = 0x71
private let kVK_Home = 0x73
private let kVK_PageUp = 0x74
private let kVK_ForwardDelete = 0x75
private let kVK_F4 = 0x76
private let kVK_End = 0x77
private let kVK_F2 = 0x78
private let kVK_PageDown = 0x79
private let kVK_F1 = 0x7A
private let kVK_LeftArrow = 0x7B
private let kVK_RightArrow = 0x7C
private let kVK_DownArrow = 0x7D
private let kVK_UpArrow = 0x7E
private let kVK_F13 = 0x69
#endif

enum RecorderPhase: Equatable {
    case idle
    case starting
    case recording(URL)
    case transcribing
    case improving
    case delivering
    case ready
    case failed

    var label: String {
        switch self {
        case .idle:
            return "Ready"
        case .starting:
            return "Starting"
        case .recording:
            return "Recording"
        case .transcribing:
            return "Transcribing"
        case .improving:
            return "Cleaning"
        case .delivering:
            return "Pasting"
        case .ready:
            return "Done"
        case .failed:
            return "Needs attention"
        }
    }

    var isBusy: Bool {
        switch self {
        case .starting, .recording, .transcribing, .improving, .delivering:
            return true
        case .idle, .ready, .failed:
            return false
        }
    }
}

enum ProcessingVisualState: Equatable {
    case idle
    case starting
    case recording
    case transcribing
    case improving
    case delivering
    case pasted
    case submitted
    case copied
    case ready
    case failed

    var label: String {
        switch self {
        case .idle:
            return "Ready"
        case .starting:
            return "Opening mic"
        case .recording:
            return "Listening"
        case .transcribing:
            return "Transcribing"
        case .improving:
            return "Cleaning"
        case .delivering:
            return "Pasting"
        case .pasted:
            return "Pasted"
        case .submitted:
            return "Submitted"
        case .copied:
            return "Copied"
        case .ready:
            return "Ready"
        case .failed:
            return "Needs attention"
        }
    }

    var detail: String {
        switch self {
        case .idle:
            return "Hold the hotkey to dictate."
        case .starting:
            return "Getting the recorder ready."
        case .recording:
            return "Release to send."
        case .transcribing:
            return "Turning audio into text."
        case .improving:
            return "Shaping the final text."
        case .delivering:
            return "Sending it to the focused field."
        case .pasted:
            return "Text landed in the focused field."
        case .submitted:
            return "Text landed and Return was sent."
        case .copied:
            return "Text is on the clipboard."
        case .ready:
            return "Text is ready."
        case .failed:
            return "Open preview for details."
        }
    }

    var symbolName: String {
        switch self {
        case .idle:
            return "mic"
        case .starting:
            return "dot.radiowaves.left.and.right"
        case .recording:
            return "waveform"
        case .transcribing:
            return "text.bubble"
        case .improving:
            return "sparkles"
        case .delivering:
            return "arrow.down.doc"
        case .pasted:
            return "checkmark.circle"
        case .submitted:
            return "return"
        case .copied:
            return "doc.on.doc"
        case .ready:
            return "checkmark"
        case .failed:
            return "exclamationmark.triangle"
        }
    }

    var isActiveProcessing: Bool {
        switch self {
        case .starting, .recording, .transcribing, .improving, .delivering:
            return true
        case .idle, .pasted, .submitted, .copied, .ready, .failed:
            return false
        }
    }

    var isSuccessfulDelivery: Bool {
        switch self {
        case .pasted, .submitted, .copied, .ready:
            return true
        case .idle, .starting, .recording, .transcribing, .improving, .delivering, .failed:
            return false
        }
    }
}

enum AutoImproveMode: String, CaseIterable, Identifiable, Codable {
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

enum RecordingTriggerMode: String, CaseIterable, Identifiable, Codable {
    case walkieTalkie
    case toggle

    var id: String { rawValue }

    var label: String {
        switch self {
        case .walkieTalkie:
            return "Hold to talk"
        case .toggle:
            return "Toggle"
        }
    }
}

struct RecordingHotKey: Equatable, Identifiable, RawRepresentable, Codable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let defaultValue = RecordingHotKey(
        keyCode: UInt32(kVK_ANSI_R),
        modifiers: hyperModifiers
    )

    static let hyperModifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)

    var id: String { rawValue }

    var rawValue: String {
        "v1:\(keyCode):\(modifiers)"
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(rawValue: String) {
        if let legacyHotKey = Self.legacyHotKey(for: rawValue) {
            self = legacyHotKey
            return
        }

        let parts = rawValue.split(separator: ":")
        guard parts.count == 3,
              parts[0] == "v1",
              let keyCode = UInt32(parts[1]),
              let modifiers = UInt32(parts[2]) else {
            return nil
        }

        let hotKey = RecordingHotKey(keyCode: keyCode, modifiers: modifiers)
        guard hotKey.isValidForGlobalRegistration else { return nil }
        self = hotKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let hotKey = RecordingHotKey(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid recording hotkey: \(rawValue)"
            )
        }
        self = hotKey
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var label: String {
        Self.modifierLabel(for: modifiers) + Self.keyLabel(for: keyCode)
    }

    var isValidForGlobalRegistration: Bool {
        guard Self.supportsKeyCode(keyCode), !Self.reservedKeyCodes.contains(keyCode) else {
            return false
        }
        if Self.functionKeyCodes.contains(keyCode) {
            return true
        }
        return (modifiers & Self.primaryModifierMask) != 0
    }

    static func modifierLabel(for modifiers: UInt32) -> String {
        var label = ""
        if modifiers & UInt32(controlKey) != 0 {
            label += "⌃"
        }
        if modifiers & UInt32(optionKey) != 0 {
            label += "⌥"
        }
        if modifiers & UInt32(shiftKey) != 0 {
            label += "⇧"
        }
        if modifiers & UInt32(cmdKey) != 0 {
            label += "⌘"
        }
        return label
    }

    static func keyLabel(for keyCode: UInt32) -> String {
        keyLabels[keyCode] ?? "Key \(keyCode)"
    }

    static func supportsKeyCode(_ keyCode: UInt32) -> Bool {
        keyLabels[keyCode] != nil
    }

    private static let primaryModifierMask = UInt32(cmdKey | optionKey | controlKey)

    private static let reservedKeyCodes: Set<UInt32> = [
        UInt32(kVK_Escape),
        UInt32(kVK_Space),
        UInt32(kVK_Delete),
        UInt32(kVK_ForwardDelete)
    ]

    private static let functionKeyCodes: Set<UInt32> = [
        UInt32(kVK_F1),
        UInt32(kVK_F2),
        UInt32(kVK_F3),
        UInt32(kVK_F4),
        UInt32(kVK_F5),
        UInt32(kVK_F6),
        UInt32(kVK_F7),
        UInt32(kVK_F8),
        UInt32(kVK_F9),
        UInt32(kVK_F10),
        UInt32(kVK_F11),
        UInt32(kVK_F12),
        UInt32(kVK_F13),
        UInt32(kVK_F14),
        UInt32(kVK_F15),
        UInt32(kVK_F16),
        UInt32(kVK_F17),
        UInt32(kVK_F18),
        UInt32(kVK_F19),
        UInt32(kVK_F20)
    ]

    private static let keyLabels: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A",
        UInt32(kVK_ANSI_B): "B",
        UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D",
        UInt32(kVK_ANSI_E): "E",
        UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G",
        UInt32(kVK_ANSI_H): "H",
        UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J",
        UInt32(kVK_ANSI_K): "K",
        UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M",
        UInt32(kVK_ANSI_N): "N",
        UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P",
        UInt32(kVK_ANSI_Q): "Q",
        UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S",
        UInt32(kVK_ANSI_T): "T",
        UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V",
        UInt32(kVK_ANSI_W): "W",
        UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y",
        UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_0): "0",
        UInt32(kVK_ANSI_1): "1",
        UInt32(kVK_ANSI_2): "2",
        UInt32(kVK_ANSI_3): "3",
        UInt32(kVK_ANSI_4): "4",
        UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6",
        UInt32(kVK_ANSI_7): "7",
        UInt32(kVK_ANSI_8): "8",
        UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_ANSI_Equal): "=",
        UInt32(kVK_ANSI_Minus): "-",
        UInt32(kVK_ANSI_RightBracket): "]",
        UInt32(kVK_ANSI_LeftBracket): "[",
        UInt32(kVK_ANSI_Quote): "'",
        UInt32(kVK_ANSI_Semicolon): ";",
        UInt32(kVK_ANSI_Backslash): "\\",
        UInt32(kVK_ANSI_Comma): ",",
        UInt32(kVK_ANSI_Slash): "/",
        UInt32(kVK_ANSI_Period): ".",
        UInt32(kVK_ANSI_Grave): "`",
        UInt32(kVK_Return): "Return",
        UInt32(kVK_Tab): "Tab",
        UInt32(kVK_Delete): "Delete",
        UInt32(kVK_Escape): "Esc",
        UInt32(kVK_Space): "Space",
        UInt32(kVK_ForwardDelete): "Forward Delete",
        UInt32(kVK_Home): "Home",
        UInt32(kVK_End): "End",
        UInt32(kVK_PageUp): "Page Up",
        UInt32(kVK_PageDown): "Page Down",
        UInt32(kVK_LeftArrow): "←",
        UInt32(kVK_RightArrow): "→",
        UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_UpArrow): "↑",
        UInt32(kVK_F1): "F1",
        UInt32(kVK_F2): "F2",
        UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5",
        UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7",
        UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10",
        UInt32(kVK_F11): "F11",
        UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13",
        UInt32(kVK_F14): "F14",
        UInt32(kVK_F15): "F15",
        UInt32(kVK_F16): "F16",
        UInt32(kVK_F17): "F17",
        UInt32(kVK_F18): "F18",
        UInt32(kVK_F19): "F19",
        UInt32(kVK_F20): "F20"
    ]

    private static func legacyHotKey(for rawValue: String) -> RecordingHotKey? {
        let key = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard key.count == 1, let keyCode = legacyLetterKeyCodes[key] else { return nil }
        return RecordingHotKey(keyCode: keyCode, modifiers: hyperModifiers)
    }

    private static let legacyLetterKeyCodes: [String: UInt32] = [
        "a": UInt32(kVK_ANSI_A),
        "b": UInt32(kVK_ANSI_B),
        "c": UInt32(kVK_ANSI_C),
        "d": UInt32(kVK_ANSI_D),
        "e": UInt32(kVK_ANSI_E),
        "f": UInt32(kVK_ANSI_F),
        "g": UInt32(kVK_ANSI_G),
        "h": UInt32(kVK_ANSI_H),
        "i": UInt32(kVK_ANSI_I),
        "j": UInt32(kVK_ANSI_J),
        "k": UInt32(kVK_ANSI_K),
        "l": UInt32(kVK_ANSI_L),
        "m": UInt32(kVK_ANSI_M),
        "n": UInt32(kVK_ANSI_N),
        "o": UInt32(kVK_ANSI_O),
        "p": UInt32(kVK_ANSI_P),
        "q": UInt32(kVK_ANSI_Q),
        "r": UInt32(kVK_ANSI_R),
        "s": UInt32(kVK_ANSI_S),
        "t": UInt32(kVK_ANSI_T),
        "u": UInt32(kVK_ANSI_U),
        "v": UInt32(kVK_ANSI_V),
        "w": UInt32(kVK_ANSI_W),
        "x": UInt32(kVK_ANSI_X),
        "y": UInt32(kVK_ANSI_Y),
        "z": UInt32(kVK_ANSI_Z)
    ]
}

enum TranscriptionMode: String, CaseIterable, Identifiable, Codable {
    case localPhonon2
    case localWhisper
    case localParakeetCppFast
    case localParakeetCppRecommended
    case localParakeetCppResident
    case localParakeetStreaming
    case appleLocal
    case openAIAPI
    case fastest

    var id: String { rawValue }

    var label: String {
        switch self {
        case .localPhonon2:
            return "Phonon-2 (Default)"
        case .localWhisper:
            return "Local Whisper"
        case .localParakeetCppFast:
            return "Parakeet.cpp Fast"
        case .localParakeetCppRecommended:
            return "Parakeet.cpp Recommended"
        case .localParakeetCppResident:
            return "Parakeet.cpp Resident"
        case .localParakeetStreaming:
            return "Parakeet Live"
        case .appleLocal:
            return "Apple Speech"
        case .openAIAPI:
            return "OpenAI API"
        case .fastest:
            return "Cloud Realtime"
        }
    }

    /// Whether the recogniser accepts dictionary terms as a prompt. Only the OpenAI modes do.
    var takesVocabulary: Bool {
        switch self {
        case .openAIAPI, .fastest:
            return true
        case .localPhonon2, .localWhisper, .localParakeetCppFast, .localParakeetCppRecommended,
             .localParakeetCppResident, .localParakeetStreaming, .appleLocal:
            return false
        }
    }
}

enum ImprovementMode: String, CaseIterable, Identifiable, Codable {
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

enum OutputMode: String, CaseIterable, Identifiable, Codable {
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
    var dictionarySnapshot: String
    /// Capped term list for recognisers that take vocabulary (OpenAI modes).
    var transcriptionVocabulary: String = ""
    /// The recogniser's output before rules and normalisation, and after rules only.
    var recognizerTranscript: String = ""
    var postRulesTranscript: String = ""
    /// What AIR pasted or copied, including any preview edit. Empty until delivered.
    var deliveredText: String = ""
    var deliveredVia: String = ""

    static let empty = TranscriptSession(
        audioURL: nil,
        rawTranscript: "",
        improvedText: "",
        message: nil,
        improveFailed: false,
        dictionarySnapshot: ""
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
