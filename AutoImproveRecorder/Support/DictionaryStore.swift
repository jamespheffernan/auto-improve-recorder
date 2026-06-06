import AppKit
import Combine
import Foundation

struct UserDictionaryEntry: Codable, Equatable, Identifiable {
    var id: UUID
    var text: String
    var source: String
    var kind: String
    var createdAt: Date
}

struct DictionaryReplacementRule: Codable, Equatable, Identifiable {
    var id: UUID
    var phrase: String
    var replacement: String
    var source: String
    var createdAt: Date
}

struct DictionaryImportResult: Equatable {
    var sourceURL: URL?
    var addedEntries: Int
    var skippedEntries: Int
    var addedReplacementRules: Int
    var skippedReplacementRules: Int
    var message: String
}

enum UserDictionaryStoreError: LocalizedError, Equatable {
    case emptyEntry
    case emptyReplacementPhrase
    case emptyReplacementText
    case noSuperwhisperSource([String])
    case malformedSuperwhisperSource(path: String, message: String)

    var errorDescription: String? {
        switch self {
        case .emptyEntry:
            return "Dictionary entry is empty."
        case .emptyReplacementPhrase:
            return "Replacement phrase is empty."
        case .emptyReplacementText:
            return "Replacement text is empty."
        case .noSuperwhisperSource:
            return "No Superwhisper dictionary source was found."
        case .malformedSuperwhisperSource(let path, let message):
            return "Could not import Superwhisper dictionary from \(path): \(message)"
        }
    }
}

@MainActor
final class UserDictionaryStore: ObservableObject {
    @Published private(set) var entries: [UserDictionaryEntry]
    @Published private(set) var replacementRules: [DictionaryReplacementRule]
    @Published private(set) var lastLoadError: String?

    private let directoryURL: URL
    private let entriesURL: URL
    private let replacementRulesURL: URL
    private let fileManager: FileManager

    init(directoryURL: URL = UserDictionaryStore.defaultDirectoryURL(), fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.entriesURL = directoryURL.appendingPathComponent("dictionary.json")
        self.replacementRulesURL = directoryURL.appendingPathComponent("replacement-rules.json")
        self.fileManager = fileManager
        self.entries = []
        self.replacementRules = []
        load()
    }

    var currentSnapshotString: String {
        entries.map(\.text).joined(separator: ",")
    }

    @discardableResult
    func addEntry(
        _ rawText: String,
        source: String = "manual",
        kind: String = "normal",
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) throws -> UserDictionaryEntry? {
        let text = Self.normalizedText(rawText)
        guard !text.isEmpty else { throw UserDictionaryStoreError.emptyEntry }
        guard !entries.contains(where: { Self.dedupeKey($0.text) == Self.dedupeKey(text) }) else {
            return nil
        }

        let entry = UserDictionaryEntry(
            id: id,
            text: text,
            source: source,
            kind: kind,
            createdAt: createdAt
        )
        entries.insert(entry, at: 0)
        sortNewestFirst()
        try saveEntries()
        return entry
    }

    func deleteEntry(id: UserDictionaryEntry.ID) throws {
        entries.removeAll { $0.id == id }
        try saveEntries()
    }

    @discardableResult
    func addReplacementRule(
        phrase rawPhrase: String,
        replacement rawReplacement: String,
        source: String = "manual",
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) throws -> DictionaryReplacementRule? {
        let phrase = Self.normalizedText(rawPhrase)
        let replacement = Self.normalizedText(rawReplacement)
        guard !phrase.isEmpty else { throw UserDictionaryStoreError.emptyReplacementPhrase }
        guard !replacement.isEmpty else { throw UserDictionaryStoreError.emptyReplacementText }

        let phraseKey = Self.dedupeKey(phrase)
        let replacementKey = Self.dedupeKey(replacement)
        guard !replacementRules.contains(where: {
            Self.dedupeKey($0.phrase) == phraseKey && Self.dedupeKey($0.replacement) == replacementKey
        }) else {
            return nil
        }

        let rule = DictionaryReplacementRule(
            id: id,
            phrase: phrase,
            replacement: replacement,
            source: source,
            createdAt: createdAt
        )
        replacementRules.insert(rule, at: 0)
        replacementRules.sort { $0.createdAt > $1.createdAt }
        try saveReplacementRules()
        return rule
    }

    func deleteReplacementRule(id: DictionaryReplacementRule.ID) throws {
        replacementRules.removeAll { $0.id == id }
        try saveReplacementRules()
    }

    func applyReplacementRules(to text: String) -> String {
        Self.applyReplacementRules(text, rules: replacementRules)
    }

    @discardableResult
    func importSuperwhisper(candidateURLs: [URL] = SuperwhisperDictionaryImporter.defaultCandidateURLs()) throws -> DictionaryImportResult {
        do {
            let payload = try SuperwhisperDictionaryImporter.loadFirstAvailable(from: candidateURLs, fileManager: fileManager)
            var addedEntries = 0
            var skippedEntries = 0
            var addedRules = 0
            var skippedRules = 0

            for term in payload.dictionaryTerms {
                if try addEntry(term, source: "import:superwhisper", kind: "normal") == nil {
                    skippedEntries += 1
                } else {
                    addedEntries += 1
                }
            }

            for rule in payload.replacementRules {
                if try addReplacementRule(
                    phrase: rule.phrase,
                    replacement: rule.replacement,
                    source: "import:superwhisper"
                ) == nil {
                    skippedRules += 1
                } else {
                    addedRules += 1
                }
            }

            let message = "Imported \(addedEntries) dictionary entries and \(addedRules) replacement rules from Superwhisper. Skipped \(skippedEntries + skippedRules) duplicates."
            return DictionaryImportResult(
                sourceURL: payload.sourceURL,
                addedEntries: addedEntries,
                skippedEntries: skippedEntries,
                addedReplacementRules: addedRules,
                skippedReplacementRules: skippedRules,
                message: message
            )
        } catch let error as UserDictionaryStoreError {
            throw error
        } catch {
            throw UserDictionaryStoreError.malformedSuperwhisperSource(path: "Superwhisper", message: error.localizedDescription)
        }
    }

    nonisolated static func normalizedText(_ text: String) -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func applyReplacementRules(_ text: String, rules: [DictionaryReplacementRule]) -> String {
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
            let pattern = replacementPattern(for: phrase)
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: replacementTemplate(for: rule.replacement)
            )
        }

        return result
    }

    nonisolated static func defaultDirectoryURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("AutoImproveRecorder", isDirectory: true)
            .appendingPathComponent("Dictionary", isDirectory: true)
    }

    private func load() {
        do {
            entries = try loadEntries()
            replacementRules = try loadReplacementRules()
            lastLoadError = nil
        } catch {
            entries = []
            replacementRules = []
            lastLoadError = error.localizedDescription
            NSLog("UserDictionaryStore load failed: \(error.localizedDescription)")
        }
    }

    private func loadEntries() throws -> [UserDictionaryEntry] {
        guard fileManager.fileExists(atPath: entriesURL.path) else { return [] }
        let data = try Data(contentsOf: entriesURL)
        let file = try decoder.decode(DictionaryEntriesFile.self, from: data)
        return Self.dedupedNewestFirst(file.entries)
    }

    private func loadReplacementRules() throws -> [DictionaryReplacementRule] {
        guard fileManager.fileExists(atPath: replacementRulesURL.path) else { return [] }
        let data = try Data(contentsOf: replacementRulesURL)
        let file = try decoder.decode(DictionaryReplacementRulesFile.self, from: data)
        return file.rules.sorted { $0.createdAt > $1.createdAt }
    }

    private func sortNewestFirst() {
        entries = Self.dedupedNewestFirst(entries)
    }

    private static func dedupedNewestFirst(_ entries: [UserDictionaryEntry]) -> [UserDictionaryEntry] {
        var seen = Set<String>()
        return entries
            .sorted { $0.createdAt > $1.createdAt }
            .filter { entry in
                let key = dedupeKey(entry.text)
                guard !key.isEmpty, !seen.contains(key) else { return false }
                seen.insert(key)
                return true
            }
    }

    private func saveEntries() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try encoder.encode(DictionaryEntriesFile(entries: entries))
        try data.write(to: entriesURL, options: .atomic)
    }

    private func saveReplacementRules() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try encoder.encode(DictionaryReplacementRulesFile(rules: replacementRules))
        try data.write(to: replacementRulesURL, options: .atomic)
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    nonisolated private static func dedupeKey(_ text: String) -> String {
        normalizedText(text).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    nonisolated private static func replacementPattern(for phrase: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        let prefix = isWordBoundaryCharacter(phrase.first) ? #"(?<![\p{L}\p{N}_])"# : ""
        let suffix = isWordBoundaryCharacter(phrase.last) ? #"(?![\p{L}\p{N}_])"# : ""
        return prefix + escaped + suffix
    }

    nonisolated private static func replacementTemplate(for replacement: String) -> String {
        replacement
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "$", with: "\\$")
    }

    nonisolated private static func isWordBoundaryCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        let underscore = UnicodeScalar("_")
        return character.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == underscore
        }
    }
}

private struct DictionaryEntriesFile: Codable {
    var entries: [UserDictionaryEntry]
}

private struct DictionaryReplacementRulesFile: Codable {
    var rules: [DictionaryReplacementRule]
}

struct SuperwhisperDictionaryPayload: Equatable {
    var sourceURL: URL
    var dictionaryTerms: [String]
    var replacementRules: [SuperwhisperReplacementRule]
}

struct SuperwhisperReplacementRule: Equatable {
    var phrase: String
    var replacement: String
}

enum SuperwhisperDictionaryImporter {
    static func defaultCandidateURLs(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let applicationSupport = homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true)
        let documents = homeDirectory.appendingPathComponent("Documents", isDirectory: true)
        let fixedCandidates = [
            documents.appendingPathComponent("Superwhisper/settings/settings.json"),
            documents.appendingPathComponent("superwhisper/settings/settings.json"),
            applicationSupport.appendingPathComponent("com.superduper.superwhisper/settings.json"),
            applicationSupport.appendingPathComponent("com.superduper.superwhisper/settings/settings.json"),
            applicationSupport.appendingPathComponent("com.superduper.superwhisper-setapp/settings.json"),
            applicationSupport.appendingPathComponent("com.superduper.superwhisper-setapp/settings/settings.json"),
            applicationSupport.appendingPathComponent("superwhisper/settings.json"),
            applicationSupport.appendingPathComponent("superwhisper/settings/settings.json")
        ]

        let searchRoots = [
            applicationSupport.appendingPathComponent("com.superduper.superwhisper", isDirectory: true),
            applicationSupport.appendingPathComponent("com.superduper.superwhisper-setapp", isDirectory: true),
            applicationSupport.appendingPathComponent("superwhisper", isDirectory: true)
        ]
        let discovered = searchRoots.flatMap { discoverCandidateFiles(in: $0) }
        var seen = Set<String>()
        return (fixedCandidates + discovered).filter { seen.insert($0.path).inserted }
    }

    static func loadFirstAvailable(from candidateURLs: [URL], fileManager: FileManager = .default) throws -> SuperwhisperDictionaryPayload {
        let checkedPaths = candidateURLs.map(\.path)
        for url in candidateURLs where fileManager.fileExists(atPath: url.path) {
            do {
                return try parse(url: url)
            } catch {
                throw UserDictionaryStoreError.malformedSuperwhisperSource(
                    path: url.path,
                    message: error.localizedDescription
                )
            }
        }
        throw UserDictionaryStoreError.noSuperwhisperSource(checkedPaths)
    }

    static func parse(url: URL) throws -> SuperwhisperDictionaryPayload {
        let lowercasedExtension = url.pathExtension.lowercased()
        if lowercasedExtension == "sqlite" || lowercasedExtension == "sqlite3" || lowercasedExtension == "db" {
            return try parseSQLiteDatabase(url: url)
        }

        let data = try Data(contentsOf: url)
        return try parseJSONData(data, sourceURL: url)
    }

    static func parseJSONData(_ data: Data, sourceURL: URL) throws -> SuperwhisperDictionaryPayload {
        let object = try JSONSerialization.jsonObject(with: data)
        var rows: [SuperwhisperDictionaryRow] = []
        collectRows(from: object, rows: &rows)
        return payload(from: rows, sourceURL: sourceURL)
    }

    private static func parseSQLiteDatabase(url: URL) throws -> SuperwhisperDictionaryPayload {
        let sqliteURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        guard FileManager.default.isExecutableFile(atPath: sqliteURL.path) else {
            throw UserDictionaryStoreError.malformedSuperwhisperSource(path: url.path, message: "sqlite3 is unavailable.")
        }

        let sql = """
        SELECT phrase, replacement, manualEntry, isSnippet, createdAt, modifiedAt
        FROM Dictionary
        WHERE isDeleted = 0
          AND phrase IS NOT NULL AND phrase != ''
          AND manualEntry = 1
          AND isSnippet = 0;
        """
        let process = Process()
        process.executableURL = sqliteURL
        process.arguments = ["-json", url.path, sql]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()

        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw UserDictionaryStoreError.malformedSuperwhisperSource(path: url.path, message: stderr)
        }

        let object = try JSONSerialization.jsonObject(with: stdout)
        var rows: [SuperwhisperDictionaryRow] = []
        collectRows(from: object, rows: &rows)
        return payload(from: rows, sourceURL: url)
    }

    private static func payload(from rows: [SuperwhisperDictionaryRow], sourceURL: URL) -> SuperwhisperDictionaryPayload {
        var terms: [String] = []
        var rules: [SuperwhisperReplacementRule] = []
        var seenTerms = Set<String>()
        var seenRules = Set<String>()

        for row in rows where row.isImportable {
            let phrase = UserDictionaryStore.normalizedText(row.phrase ?? "")
            let replacement = UserDictionaryStore.normalizedText(row.replacement ?? "")
            guard !phrase.isEmpty else { continue }

            if replacement.isEmpty {
                let key = phrase.lowercased()
                if seenTerms.insert(key).inserted {
                    terms.append(phrase)
                }
            } else {
                let termKey = replacement.lowercased()
                if seenTerms.insert(termKey).inserted {
                    terms.append(replacement)
                }
                let ruleKey = "\(phrase.lowercased())\u{1F}\(replacement.lowercased())"
                if seenRules.insert(ruleKey).inserted {
                    rules.append(SuperwhisperReplacementRule(phrase: phrase, replacement: replacement))
                }
            }
        }

        return SuperwhisperDictionaryPayload(sourceURL: sourceURL, dictionaryTerms: terms, replacementRules: rules)
    }

    private static func collectRows(from value: Any, rows: inout [SuperwhisperDictionaryRow]) {
        if let array = value as? [Any] {
            for item in array {
                collectRows(from: item, rows: &rows)
            }
            return
        }

        guard let dictionary = value as? [String: Any] else { return }
        if let row = SuperwhisperDictionaryRow(dictionary: dictionary) {
            rows.append(row)
        }
        for nested in dictionary.values {
            collectRows(from: nested, rows: &rows)
        }
    }

    private static func discoverCandidateFiles(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var candidates: [URL] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            let filename = url.lastPathComponent.lowercased()
            if filename == "settings.json" || ext == "sqlite" || ext == "sqlite3" || ext == "db" {
                candidates.append(url)
            }
            if candidates.count >= 20 { break }
        }
        return candidates
    }
}

private struct SuperwhisperDictionaryRow {
    var phrase: String?
    var replacement: String?
    var manualEntry: Bool?
    var isSnippet: Bool?
    var isDeleted: Bool?

    var isImportable: Bool {
        if manualEntry == false { return false }
        if isSnippet == true { return false }
        if isDeleted == true { return false }
        return true
    }

    init?(dictionary: [String: Any]) {
        let phrase = Self.stringValue(from: dictionary["phrase"])
            ?? Self.stringValue(from: dictionary["word"])
            ?? Self.stringValue(from: dictionary["text"])
        let replacement = Self.stringValue(from: dictionary["replacement"])
            ?? Self.stringValue(from: dictionary["replaceWith"])
        guard phrase != nil || replacement != nil else { return nil }

        self.phrase = phrase
        self.replacement = replacement
        self.manualEntry = Self.boolValue(from: dictionary["manualEntry"])
        self.isSnippet = Self.boolValue(from: dictionary["isSnippet"])
        self.isDeleted = Self.boolValue(from: dictionary["isDeleted"])
    }

    private static func stringValue(from value: Any?) -> String? {
        if let string = value as? String { return string }
        return nil
    }

    private static func boolValue(from value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let int = value as? Int { return int != 0 }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            let lowercased = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["1", "true", "yes"].contains(lowercased) { return true }
            if ["0", "false", "no"].contains(lowercased) { return false }
        }
        return nil
    }
}

@MainActor
final class DictionaryServiceProvider: NSObject {
    private let store: UserDictionaryStore
    private let statusHandler: (String) -> Void

    init(store: UserDictionaryStore, statusHandler: @escaping (String) -> Void) {
        self.store = store
        self.statusHandler = statusHandler
        super.init()
    }

    @objc(addToAutoImproveRecorderDictionary:userData:error:)
    func addToAutoImproveRecorderDictionary(
        _ pasteboard: NSPasteboard,
        userData: String?,
        serviceError: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let rawText = pasteboard.string(forType: .string) else {
            let message = "No selected text was provided."
            serviceError.pointee = message as NSString
            statusHandler(message)
            return
        }

        do {
            if try store.addEntry(rawText, source: "service") == nil {
                statusHandler("That dictionary entry already exists.")
            } else {
                statusHandler("Added to Auto Improve Recorder Dictionary.")
            }
        } catch {
            serviceError.pointee = error.localizedDescription as NSString
            statusHandler(error.localizedDescription)
        }
    }
}
