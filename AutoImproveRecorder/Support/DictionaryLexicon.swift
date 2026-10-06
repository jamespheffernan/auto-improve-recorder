import Foundation

// Shared by AIR and ASR: replacement rules, the read-only lexicon at ~/.config/lexicon/terms.json,
// and the merge of both with AIR's manual dictionary. Nothing here writes a file.

struct DictionaryReplacementRule: Codable, Equatable, Identifiable {
    var id: UUID
    var phrase: String
    var replacement: String
    var source: String
    var createdAt: Date
}

enum ReplacementRuleEngine {
    /// Longest phrase first; ties go to the newest rule. Matches are case-insensitive and stop at
    /// letter, digit or underscore boundaries, so "perf review" never matches inside "superf reviewer".
    static func apply(_ text: String, rules: [DictionaryReplacementRule]) -> String {
        var result = text
        let orderedRules = rules.sorted {
            if $0.phrase.count == $1.phrase.count {
                return $0.createdAt > $1.createdAt
            }
            return $0.phrase.count > $1.phrase.count
        }

        for rule in orderedRules {
            let phrase = normalizedText(rule.phrase)
            guard !phrase.isEmpty else { continue }
            guard let regex = try? NSRegularExpression(pattern: pattern(for: phrase), options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: template(for: rule.replacement)
            )
        }

        return result
    }

    static func normalizedText(_ text: String) -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func dedupeKey(_ text: String) -> String {
        normalizedText(text).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func pattern(for phrase: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        let prefix = isWordCharacter(phrase.first) ? #"(?<![\p{L}\p{N}_])"# : ""
        let suffix = isWordCharacter(phrase.last) ? #"(?![\p{L}\p{N}_])"# : ""
        return prefix + escaped + suffix
    }

    private static func template(for replacement: String) -> String {
        replacement
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "$", with: "\\$")
    }

    private static func isWordCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        let underscore = UnicodeScalar("_")
        return character.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == underscore
        }
    }
}

// MARK: - terms.json (written by the lexicon generator, read here)

struct LexiconEvidence: Codable, Equatable {
    var kind: String
    var ref: String?
    var quote: String?
    var seen: String?
    var id: String?
}

struct LexiconTerm: Codable, Equatable {
    var text: String
    var score: Double?
    var probability: Double?
    var count: Int?
    var lastSeen: String?
    var active: Bool?
    var hints: [String]?
    var sources: [LexiconEvidence]?
}

struct LexiconRule: Codable, Equatable {
    var heard: String
    var meant: String
    var evidence: [LexiconEvidence]
}

struct LexiconFile: Codable, Equatable {
    static let supportedSchemaVersion = 1

    var schemaVersion: Int
    var terms: [LexiconTerm]
    var rules: [LexiconRule]
}

struct LexiconSnapshot: Equatable {
    /// Active terms, highest score first.
    var terms: [String]
    /// Rules backed by at least one verified correction.
    var rules: [DictionaryReplacementRule]

    static let empty = LexiconSnapshot(terms: [], rules: [])

    /// Evidence kinds that let a rule run. A lead's assumption ("assumed") never does.
    static let verifiedEvidenceKinds: Set<String> = ["user-correction", "air-edit"]

    init(terms: [String], rules: [DictionaryReplacementRule]) {
        self.terms = terms
        self.rules = rules
    }

    init(file: LexiconFile) {
        terms = file.terms
            .filter { $0.active != false && !ReplacementRuleEngine.normalizedText($0.text).isEmpty }
            .sorted { ($0.score ?? 0) > ($1.score ?? 0) }
            .map { ReplacementRuleEngine.normalizedText($0.text) }
        rules = file.rules
            .filter { rule in rule.evidence.contains { Self.verifiedEvidenceKinds.contains($0.kind) } }
            .compactMap { rule in
                let heard = ReplacementRuleEngine.normalizedText(rule.heard)
                let meant = ReplacementRuleEngine.normalizedText(rule.meant)
                guard !heard.isEmpty, !meant.isEmpty else { return nil }
                return DictionaryReplacementRule(
                    id: LexiconSnapshot.stableID(heard: heard, meant: meant),
                    phrase: heard,
                    replacement: meant,
                    source: "lexicon",
                    createdAt: .distantPast
                )
            }
    }

    private static func stableID(heard: String, meant: String) -> UUID {
        // Deterministic so SwiftUI lists and tests see the same rule across reloads.
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in "\(heard.lowercased())\u{1F}\(meant)".utf8.enumerated() {
            bytes[index % 16] = bytes[index % 16] &* 31 &+ byte
        }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// Reads terms.json on demand. Call `reload()` before each recording's snapshot. A missing file means
/// no generated terms; a malformed or unsupported file keeps the last valid snapshot and sets `lastError`.
final class LexiconReader: @unchecked Sendable {
    static func defaultURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/lexicon/terms.json")
    }

    let url: URL
    private let lock = NSLock()
    private var snapshot = LexiconSnapshot.empty
    private var loadedStamp: FileStamp?
    private var error: String?

    init(url: URL = LexiconReader.defaultURL()) {
        self.url = url
    }

    var lastError: String? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }

    var current: LexiconSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    @discardableResult
    func reload() -> LexiconSnapshot {
        lock.lock()
        defer { lock.unlock() }

        guard let stamp = FileStamp(url: url) else {
            snapshot = .empty
            loadedStamp = nil
            error = nil
            return snapshot
        }
        if stamp == loadedStamp { return snapshot }

        do {
            let data = try Data(contentsOf: url)
            let file = try JSONDecoder().decode(LexiconFile.self, from: data)
            guard file.schemaVersion == LexiconFile.supportedSchemaVersion else {
                throw LexiconReaderError.unsupportedSchema(file.schemaVersion)
            }
            snapshot = LexiconSnapshot(file: file)
            error = nil
        } catch {
            self.error = "Lexicon at \(url.path) could not be read; keeping the last valid copy. \(error.localizedDescription)"
            NSLog("LexiconReader: \(self.error ?? "")")
        }
        loadedStamp = stamp
        return snapshot
    }

    private struct FileStamp: Equatable {
        var modified: Date
        var size: Int

        init?(url: URL) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modified = attributes[.modificationDate] as? Date else {
                return nil
            }
            self.modified = modified
            size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        }
    }
}

enum LexiconReaderError: LocalizedError {
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "Unsupported lexicon schemaVersion \(version)."
        }
    }
}

// MARK: - Merge with the manual dictionary

enum DictionaryMerge {
    /// Terms for the cleanup prompt: every manual entry, then the top lexicon terms.
    static let cleanupLexiconTermLimit = 50
    /// Terms for a recogniser prompt: at most 20 terms or about 150 tokens, whichever comes first.
    static let transcriptionTermLimit = 20
    static let transcriptionTokenBudget = 150

    static func cleanupTerms(manual: [String], lexicon: [String]) -> [String] {
        deduped(manual + Array(lexicon.prefix(cleanupLexiconTermLimit)))
    }

    static func transcriptionTerms(manual: [String], lexicon: [String]) -> [String] {
        var selected: [String] = []
        var tokens = 0
        for term in deduped(manual + lexicon) {
            let cost = approximateTokens(term) + 1
            guard selected.count < transcriptionTermLimit, tokens + cost <= transcriptionTokenBudget else { break }
            selected.append(term)
            tokens += cost
        }
        return selected
    }

    /// Manual rules win: a lexicon rule for a phrase the manual list already covers is dropped.
    static func rules(manual: [DictionaryReplacementRule], lexicon: [DictionaryReplacementRule]) -> [DictionaryReplacementRule] {
        let manualPhrases = Set(manual.map { ReplacementRuleEngine.dedupeKey($0.phrase) })
        return manual + lexicon.filter { !manualPhrases.contains(ReplacementRuleEngine.dedupeKey($0.phrase)) }
    }

    static func approximateTokens(_ text: String) -> Int {
        max(1, Int((Double(text.utf8.count) / 4).rounded(.up)))
    }

    private static func deduped(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms.compactMap { raw in
            let term = ReplacementRuleEngine.normalizedText(raw)
            let key = ReplacementRuleEngine.dedupeKey(term)
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return term
        }
    }
}

// MARK: - Post-recognition text, identical in both apps

struct TranscriptRuleOutcome: Equatable {
    /// The recogniser's output before any rule or normalisation.
    var recognizer: String
    /// After replacement rules only.
    var afterRules: String
    /// After rules and spoken-number normalisation: what the app shows or sends.
    var final: String
}

enum TranscriptPostProcessor {
    static func process(_ recognizer: String, rules: [DictionaryReplacementRule]) -> TranscriptRuleOutcome {
        let afterRules = ReplacementRuleEngine.apply(recognizer, rules: rules)
        return TranscriptRuleOutcome(
            recognizer: recognizer,
            afterRules: afterRules,
            final: TranscriptTextNormalizer.normalizeSpokenNumbers(in: afterRules)
        )
    }
}

/// Where AIR's manual rules file lives and how it is read. AIR's store reads it through this;
/// ASR does too, and never writes AIR's files.
enum ManualDictionaryFiles {
    static let rulesFileName = "replacement-rules.json"

    static func defaultDirectoryURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("AutoImproveRecorder", isDirectory: true)
            .appendingPathComponent("Dictionary", isDirectory: true)
    }

    static func loadRules(directoryURL: URL = defaultDirectoryURL()) throws -> [DictionaryReplacementRule] {
        let url = directoryURL.appendingPathComponent(rulesFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try decodeRules(Data(contentsOf: url))
    }

    static func decodeRules(_ data: Data) throws -> [DictionaryReplacementRule] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RulesFile.self, from: data).rules
    }

    private struct RulesFile: Decodable {
        var rules: [DictionaryReplacementRule]
    }
}

/// ASR's rule source: AIR's manual rules plus lexicon rules, both re-read before each recording is
/// processed. A malformed manual file keeps the last rules that loaded.
final class SharedReplacementRules: @unchecked Sendable {
    private let lexicon: LexiconReader
    private let manualDirectoryURL: URL
    private let lock = NSLock()
    private var lastManualRules: [DictionaryReplacementRule] = []

    init(lexicon: LexiconReader = LexiconReader(), manualDirectoryURL: URL = ManualDictionaryFiles.defaultDirectoryURL()) {
        self.lexicon = lexicon
        self.manualDirectoryURL = manualDirectoryURL
    }

    func currentRules() -> [DictionaryReplacementRule] {
        let lexiconRules = lexicon.reload().rules
        lock.lock()
        defer { lock.unlock() }
        if let manual = try? ManualDictionaryFiles.loadRules(directoryURL: manualDirectoryURL) {
            lastManualRules = manual
        }
        return DictionaryMerge.rules(manual: lastManualRules, lexicon: lexiconRules)
    }

    func process(_ recognizer: String) -> TranscriptRuleOutcome {
        TranscriptPostProcessor.process(recognizer, rules: currentRules())
    }
}
