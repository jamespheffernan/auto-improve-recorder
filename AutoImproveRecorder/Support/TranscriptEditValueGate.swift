import Foundation

/// A conservative, provider-independent check for transcripts that do not need
/// a model edit. The gate only bypasses when every paste-ready check passes.
enum TranscriptEditValueGate {
    enum Mode: String, CaseIterable, Equatable, Sendable {
        case verbatim
        case lightCleanup
        case promptCleanup
        case structuredTask
    }

    enum Action: Equatable, Sendable {
        case bypassImprovement
        case improve
    }

    enum Reason: String, Equatable, Sendable {
        case pasteReady
        case modeRequiresTransformation
        case contextualReplacementPossible
        case emptyTranscript
        case unsafeWordCount
        case nonCanonicalWhitespace
        case explicitTransformationRequest
        case dictationArtifact
        case repeatedAdjacentWord
        case questionNeedsJudgment
        case personalVoiceCleanupSignal
        case leadingDiscourseMarker
        case frontLoadedRequest
        case likelyCleanupOpportunity
        case missingInternalPunctuation
        case missingTerminalPunctuation
        case lowercaseOpening
    }

    struct Result: Equatable, Sendable {
        let action: Action
        let reason: Reason
        let bypassText: String?

        var shouldImprove: Bool {
            action == .improve
        }

        fileprivate static func improve(_ reason: Reason) -> Result {
            Result(action: .improve, reason: reason, bypassText: nil)
        }

        fileprivate static func bypass(_ text: String) -> Result {
            Result(action: .bypassImprovement, reason: .pasteReady, bypassText: text)
        }
    }

    static func evaluate(
        transcript: String,
        mode: Mode,
        dictionarySnapshot: String = ""
    ) -> Result {
        guard mode == .verbatim || mode == .lightCleanup else {
            return .improve(.modeRequiresTransformation)
        }
        guard dictionarySnapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .improve(.contextualReplacementPossible)
        }

        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return .improve(.emptyTranscript)
        }
        guard text == canonicalWhitespace(in: text) else {
            return .improve(.nonCanonicalWhitespace)
        }

        let words = wordTokens(in: text)
        guard (6...90).contains(words.count) else {
            return .improve(.unsafeWordCount)
        }
        guard !containsPattern(explicitTransformationRequestPattern, in: text) else {
            return .improve(.explicitTransformationRequest)
        }
        guard !containsPattern(dictationArtifactPattern, in: text) else {
            return .improve(.dictationArtifact)
        }
        guard !hasRepeatedAdjacentWord(words) else {
            return .improve(.repeatedAdjacentWord)
        }
        guard !containsPattern(questionPattern, in: text) else {
            return .improve(.questionNeedsJudgment)
        }
        guard !containsPattern(personalVoiceCleanupSignalPattern, in: text) else {
            return .improve(.personalVoiceCleanupSignal)
        }
        guard !containsPattern(leadingDiscourseMarkerPattern, in: text) else {
            return .improve(.leadingDiscourseMarker)
        }
        guard !containsPattern(frontLoadedRequestPattern, in: text) else {
            return .improve(.frontLoadedRequest)
        }
        guard !containsPattern(likelyCleanupOpportunityPattern, in: text) else {
            return .improve(.likelyCleanupOpportunity)
        }
        if words.count > 12 {
            guard containsPattern(internalPunctuationPattern, in: text) else {
                return .improve(.missingInternalPunctuation)
            }
        }
        guard containsPattern(terminalPunctuationPattern, in: text) else {
            return .improve(.missingTerminalPunctuation)
        }
        guard text.first?.isUppercase == true else {
            return .improve(.lowercaseOpening)
        }

        return .bypass(text)
    }

    /// Runs improvement only when the deterministic gate cannot prove that the
    /// transcript is paste-ready. Keep provider selection inside `improve` so a
    /// bypass does not initialize or contact any provider.
    static func route(
        transcript: String,
        mode: Mode,
        dictionarySnapshot: String = "",
        onBypass: (String) -> Void,
        improve: () async throws -> String
    ) async rethrows -> String {
        let result = evaluate(
            transcript: transcript,
            mode: mode,
            dictionarySnapshot: dictionarySnapshot
        )
        if let bypassText = result.bypassText {
            onBypass(bypassText)
            return bypassText
        }
        return try await improve()
    }

    private static let explicitTransformationRequestPattern =
        #"(?i)\b(make this into|turn this into|convert this|rewrite this|clean this up|make it sound|summari[sz]e|format this|structure this|write (?:\w+\s+){0,3}(email|slack|message|prompt|task))\b"#

    private static let dictationArtifactPattern =
        #"(?i)\b(um+|uh+|er+|ah+|you know|i mean|sort of|kind of|basically|actually|wait actually|no sorry|scratch that|start over|what i mean|let me rephrase|new paragraph)\b|\bdot\s+[A-Za-z0-9_]+\b|\bslash\s+[A-Za-z0-9_]+\b"#

    private static let questionPattern = #"\?"#

    /// These narrow forms had a high edit rate in TranscriptTruth. They keep
    /// likely hedging, filler, and awkward coordination on the model path while
    /// allowing otherwise paste-ready first-person text to bypass.
    private static let personalVoiceCleanupSignalPattern =
        #"(?i)\b(i'm not sure|i feel like|have like(?:\s+a)?|one that i thought|that i've built that)\b|\bi agree\.|\band\b[^,.!?]{0,30}\band\b"#

    private static let leadingDiscourseMarkerPattern =
        #"(?i)^(okay|ok|so|well|but|and|quick note|hey)\b"#

    private static let frontLoadedRequestPattern = #"(?i)^with\b[^.!?]{0,120}\bplease\b"#

    /// These forms are conservative signals, not general grammar correction.
    /// Each one caused a material edit in the fixed evaluation corpora.
    private static let likelyCleanupOpportunityPattern =
        #"(?i)^when\b[^.!?]{0,80},|\b(just|weird|read aloud|real time|half finished|high quality|low quality|high level|low level|bundle free)\b|\bi think\b[^.!?]{0,40}\b(maybe|probably)\b|\b(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)\s+(?:january|february|march|april|may|june|july|august|september|october|november|december)\b"#

    private static let internalPunctuationPattern = #"[,.!?;:]"#
    private static let terminalPunctuationPattern = #"[.!?]['\")\]]*$"#

    private static func canonicalWhitespace(in text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func wordTokens(in text: String) -> [Substring] {
        text.split { character in
            !character.isLetter && !character.isNumber && character != "'"
        }
    }

    private static func containsPattern(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func hasRepeatedAdjacentWord(_ words: [Substring]) -> Bool {
        guard words.count > 1 else { return false }

        for index in words.indices.dropLast() {
            let current = words[index].lowercased()
            let next = words[words.index(after: index)].lowercased()
            if current == next && current.count > 2 {
                return true
            }
        }
        return false
    }
}
