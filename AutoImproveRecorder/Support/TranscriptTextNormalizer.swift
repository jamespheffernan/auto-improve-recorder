import Foundation

enum TranscriptTextNormalizer {
    static func normalizeSpokenNumbers(in text: String) -> String {
        SpokenNumberRewriter.normalize(text)
    }
}

private enum SpokenNumberRewriter {
    private enum TokenKind {
        case word
        case separator
    }

    private struct Token {
        var text: String
        var kind: TokenKind
    }

    private struct WordToken {
        var tokenIndex: Int
        var word: String
    }

    private struct Rewrite {
        var text: String
        var consumedWordCount: Int
    }

    static func normalize(_ text: String) -> String {
        let tokens = tokenize(text)
        var result = ""
        var index = 0

        while index < tokens.count {
            guard tokens[index].kind == .word else {
                result += tokens[index].text
                index += 1
                continue
            }

            if let rewrite = rewriteStarting(at: index, in: tokens) {
                result += rewrite.text
                index = rewrite.endTokenIndex
            } else {
                result += tokens[index].text
                index += 1
            }
        }

        return result
    }

    private struct TokenRewrite {
        var text: String
        var endTokenIndex: Int
    }

    private static func rewriteStarting(at index: Int, in tokens: [Token]) -> TokenRewrite? {
        let words = collectNumberWords(startingAt: index, in: tokens)
        guard !words.isEmpty else { return nil }

        if let preserveWordCount = ordinalModifierPreserveWordCount(words) {
            let endTokenIndex = words[preserveWordCount - 1].tokenIndex + 1
            return TokenRewrite(
                text: tokens[index..<endTokenIndex].map(\.text).joined(),
                endTokenIndex: endTokenIndex
            )
        }

        let previousDateMonth = previousMonthInOrdinalDatePhrase(startingAt: index, in: tokens)
        let nextWord = nextWordAfterCollectedPhrase(words, in: tokens)
        for count in stride(from: words.count, through: 1, by: -1) {
            let candidate = Array(words.prefix(count).map(\.word))
            let contextNextWord = count == words.count ? nextWord : words[count].word
            guard let rewrite = rewriteWords(
                candidate,
                previousDateMonth: previousDateMonth,
                nextWord: contextNextWord
            ) else {
                continue
            }

            let endTokenIndex = words[count - 1].tokenIndex + 1
            return TokenRewrite(text: rewrite.text, endTokenIndex: endTokenIndex)
        }

        return nil
    }

    private static func collectNumberWords(startingAt index: Int, in tokens: [Token]) -> [WordToken] {
        var words: [WordToken] = []
        var cursor = index

        while cursor < tokens.count {
            guard tokens[cursor].kind == .word else { break }
            let word = normalizedWord(tokens[cursor].text)
            guard isNumberPhraseWord(word) else { break }

            words.append(WordToken(tokenIndex: cursor, word: word))

            var next = cursor + 1
            guard next < tokens.count else { break }
            while next < tokens.count, tokens[next].kind == .separator {
                guard canJoinAcrossSeparator(tokens[next].text) else {
                    return words
                }
                next += 1
            }
            guard next < tokens.count else { break }
            cursor = next
        }

        return words
    }

    private static func ordinalModifierPreserveWordCount(_ words: [WordToken]) -> Int? {
        guard words.count > 1,
              isOrdinalWord(words[0].word),
              words[1].word != "and" else {
            return nil
        }
        if isOrdinalWord(words[1].word) {
            return 2
        }
        if cardinalScaleWords.contains(words[1].word) {
            return 2
        }

        let followingWords = Array(words.dropFirst().map(\.word))
        for count in stride(from: followingWords.count, through: 1, by: -1) {
            let candidate = Array(followingWords.prefix(count))
            if parseIntegerText(candidate, allowSingleOh: false, nextWord: nil) != nil {
                return count + 1
            }
        }
        return nil
    }

    private static func previousMonthInOrdinalDatePhrase(startingAt index: Int, in tokens: [Token]) -> String? {
        var cursor = index - 1
        while cursor >= 0 {
            switch tokens[cursor].kind {
            case .word:
                let word = normalizedWord(tokens[cursor].text)
                if monthNames.contains(word) {
                    return word
                }
                guard word == "and" || isNumberPhraseWord(word) else {
                    return nil
                }
                cursor -= 1
            case .separator:
                guard canJoinAcrossSeparator(tokens[cursor].text) else {
                    return nil
                }
                cursor -= 1
            }
        }
        return nil
    }

    private static func nextWordAfterCollectedPhrase(_ words: [WordToken], in tokens: [Token]) -> String? {
        guard let last = words.last else { return nil }
        var cursor = last.tokenIndex + 1
        while cursor < tokens.count {
            switch tokens[cursor].kind {
            case .word:
                return normalizedWord(tokens[cursor].text)
            case .separator:
                guard canJoinAcrossSeparator(tokens[cursor].text) else { return nil }
                cursor += 1
            }
        }
        return nil
    }

    private static func rewriteWords(
        _ words: [String],
        previousDateMonth: String?,
        nextWord: String?
    ) -> Rewrite? {
        guard !words.isEmpty else { return nil }

        let sign: String
        let unsignedWords: [String]
        if words.first == "minus" || words.first == "negative" {
            guard words.count > 1 else { return nil }
            sign = "-"
            unsignedWords = Array(words.dropFirst())
        } else {
            sign = ""
            unsignedWords = words
        }

        if let decimal = parseDecimal(unsignedWords) {
            return Rewrite(text: sign + decimal, consumedWordCount: words.count)
        }

        guard sign.isEmpty else {
            if let integer = parseIntegerText(unsignedWords, allowSingleOh: false, nextWord: nextWord) {
                return Rewrite(text: "-\(integer)", consumedWordCount: words.count)
            }
            return nil
        }

        if let ordinal = parseOrdinal(unsignedWords) {
            let text = shouldUseBareOrdinalDateNumber(
                previousDateMonth: previousDateMonth,
                nextWord: nextWord
            ) ? "\(ordinal)" : ordinalText(for: ordinal)
            return Rewrite(text: text, consumedWordCount: words.count)
        }

        if let year = parseYear(unsignedWords) {
            return Rewrite(text: "\(year)", consumedWordCount: words.count)
        }

        if let integer = parseIntegerText(unsignedWords, allowSingleOh: false, nextWord: nextWord) {
            return Rewrite(text: "\(integer)", consumedWordCount: words.count)
        }

        return nil
    }

    private static func parseDecimal(_ words: [String]) -> String? {
        guard let pointIndex = words.firstIndex(of: "point"),
              pointIndex > 0,
              pointIndex < words.count - 1 else {
            return nil
        }

        let integerWords = Array(words[..<pointIndex])
        let fractionalWords = Array(words[(pointIndex + 1)...])
        guard let integer = parseInteger(integerWords, allowSingleOh: true, nextWord: nil) else { return nil }

        let fractionalDigits = fractionalWords.compactMap(digitValue)
        guard fractionalDigits.count == fractionalWords.count else { return nil }
        return "\(integer).\(fractionalDigits.map(String.init).joined())"
    }

    private static func parseYear(_ words: [String]) -> Int? {
        guard !words.isEmpty else { return nil }

        if words.starts(with: ["two", "thousand"]) {
            let remainder = wordsAfterOptionalAnd(Array(words.dropFirst(2)))
            guard let yearRemainder = parseYearRemainder(remainder, upperBound: 999) else {
                return remainder.isEmpty ? 2000 : nil
            }
            return 2000 + yearRemainder
        }

        if words.first == "eighteen" || words.first == "nineteen" {
            guard words.count >= 2 else { return nil }
            if words.count == 2, words[1] == "hundred" {
                return words[0] == "eighteen" ? 1800 : 1900
            }
            let base = words[0] == "eighteen" ? 1800 : 1900
            guard let remainder = parseYearRemainder(Array(words.dropFirst()), upperBound: 99) else {
                return nil
            }
            return base + remainder
        }

        guard words.first == "twenty", words.count >= 2 else { return nil }
        let rest = Array(words.dropFirst())
        if rest.count == 1, let teen = teenValues[rest[0]] {
            return 2000 + teen
        }
        if rest.first == "twenty" {
            guard let remainder = parseYearRemainder(rest, upperBound: 29),
                  remainder >= 20 else {
                return nil
            }
            return 2000 + remainder
        }
        if rest.count == 2,
           isZeroWord(rest[0]),
           let digit = digitValue(rest[1]),
           digit > 0 {
            return 2000 + digit
        }
        return nil
    }

    private static func parseYearRemainder(_ words: [String], upperBound: Int) -> Int? {
        guard !words.isEmpty else { return 0 }
        if words.count >= 2, isZeroWord(words[0]) {
            let digits = words.dropFirst().compactMap(digitValue)
            guard digits.count == words.count - 1 else { return nil }
            let value = Int(digits.map(String.init).joined()) ?? 0
            return value <= upperBound ? value : nil
        }

        guard let value = parseInteger(words, allowSingleOh: true, nextWord: nil),
              value <= upperBound else {
            return nil
        }
        return value
    }

    private static func parseIntegerText(
        _ words: [String],
        allowSingleOh: Bool,
        nextWord: String?
    ) -> String? {
        guard !words.isEmpty else { return nil }

        if let digits = parseDigitSequenceText(words, allowSingleOh: allowSingleOh) {
            if words.count == 1, shouldSkipSingleOne(words[0], nextWord: nextWord) {
                return nil
            }
            return digits
        }

        guard let value = parseCardinal(words) else { return nil }
        if words.count == 1, shouldSkipSingleOne(words[0], nextWord: nextWord) {
            return nil
        }
        return "\(value)"
    }

    private static func parseInteger(
        _ words: [String],
        allowSingleOh: Bool,
        nextWord: String?
    ) -> Int? {
        guard let text = parseIntegerText(words, allowSingleOh: allowSingleOh, nextWord: nextWord) else {
            return nil
        }
        return Int(text)
    }

    private static func parseDigitSequenceText(_ words: [String], allowSingleOh: Bool) -> String? {
        let digits = words.compactMap(digitValue)
        guard digits.count == words.count else { return nil }
        if words.count == 1, !allowSingleOh, isOhWord(words[0]) {
            return nil
        }
        guard words.count > 1 || !isOhWord(words[0]) || allowSingleOh else { return nil }
        return digits.map(String.init).joined()
    }

    private static func parseCardinal(_ words: [String]) -> Int? {
        parseNumberPhrase(words, allowOrdinals: false)
    }

    private static func parseOrdinal(_ words: [String]) -> Int? {
        guard words.contains(where: isOrdinalWord),
              words.last.map(isOrdinalWord) == true else {
            return nil
        }
        return parseNumberPhrase(words, allowOrdinals: true)
    }

    private static func parseNumberPhrase(_ words: [String], allowOrdinals: Bool) -> Int? {
        var total = 0
        var current = 0
        var usedAny = false
        var groupHasTens = false
        var groupHasUnitOrTeen = false
        var previousWasAnd = false

        for (index, word) in words.enumerated() {
            if word == "and" {
                guard usedAny, index < words.count - 1, !previousWasAnd else { return nil }
                previousWasAnd = true
                continue
            }

            previousWasAnd = false

            if let value = smallValues[word] ?? (allowOrdinals ? ordinalSmallValues[word] : nil) {
                guard !groupHasUnitOrTeen else { return nil }
                if groupHasTens, value == 0 || value >= 10 {
                    return nil
                }
                current += value
                groupHasUnitOrTeen = true
                usedAny = true
                continue
            }

            if let value = tensValues[word] ?? (allowOrdinals ? ordinalTensValues[word] : nil) {
                guard !groupHasTens, !groupHasUnitOrTeen else { return nil }
                current += value
                groupHasTens = true
                usedAny = true
                continue
            }

            switch word {
            case "hundred":
                guard current > 0 else { return nil }
                current *= 100
                groupHasTens = false
                groupHasUnitOrTeen = false
                usedAny = true
            case "hundredth":
                guard allowOrdinals, current > 0 else { return nil }
                current *= 100
                groupHasTens = false
                groupHasUnitOrTeen = false
                usedAny = true
            case "thousand":
                let group = current == 0 ? 1 : current
                total += group * 1_000
                current = 0
                groupHasTens = false
                groupHasUnitOrTeen = false
                usedAny = true
            case "thousandth":
                guard allowOrdinals else { return nil }
                let group = current == 0 ? 1 : current
                total += group * 1_000
                current = 0
                groupHasTens = false
                groupHasUnitOrTeen = false
                usedAny = true
            case "million":
                let group = current == 0 ? 1 : current
                total += group * 1_000_000
                current = 0
                groupHasTens = false
                groupHasUnitOrTeen = false
                usedAny = true
            case "millionth":
                guard allowOrdinals else { return nil }
                let group = current == 0 ? 1 : current
                total += group * 1_000_000
                current = 0
                groupHasTens = false
                groupHasUnitOrTeen = false
                usedAny = true
            default:
                return nil
            }
        }

        guard usedAny, !previousWasAnd else { return nil }
        return total + current
    }

    private static func shouldUseBareOrdinalDateNumber(previousDateMonth: String?, nextWord: String?) -> Bool {
        previousDateMonth != nil || nextWord.map { monthNames.contains($0) } == true
    }

    private static func ordinalText(for value: Int) -> String {
        let suffix: String
        let lastTwoDigits = value % 100
        if (11...13).contains(lastTwoDigits) {
            suffix = "th"
        } else {
            switch value % 10 {
            case 1:
                suffix = "st"
            case 2:
                suffix = "nd"
            case 3:
                suffix = "rd"
            default:
                suffix = "th"
            }
        }
        return "\(value)\(suffix)"
    }

    private static func wordsAfterOptionalAnd(_ words: [String]) -> [String] {
        guard words.first == "and" else { return words }
        return Array(words.dropFirst())
    }

    private static func shouldSkipSingleOne(_ word: String, nextWord: String?) -> Bool {
        word == "one" && (nextWord == "of" || nextWord == "another")
    }

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var currentKind: TokenKind?

        for character in text {
            let kind: TokenKind = character.isLetter ? .word : .separator
            if currentKind == kind {
                current.append(character)
            } else {
                if let currentKind {
                    tokens.append(Token(text: current, kind: currentKind))
                }
                current = String(character)
                currentKind = kind
            }
        }

        if let currentKind {
            tokens.append(Token(text: current, kind: currentKind))
        }

        return tokens
    }

    private static func normalizedWord(_ text: String) -> String {
        text.lowercased()
    }

    private static func canJoinAcrossSeparator(_ text: String) -> Bool {
        text.allSatisfy { character in
            character.isWhitespace || character == "-"
        }
    }

    private static func isNumberPhraseWord(_ word: String) -> Bool {
        word == "and" ||
            word == "point" ||
            word == "minus" ||
            word == "negative" ||
            smallValues[word] != nil ||
            tensValues[word] != nil ||
            ordinalSmallValues[word] != nil ||
            ordinalTensValues[word] != nil ||
            scaleWords.contains(word) ||
            isOhWord(word)
    }

    private static func isOrdinalWord(_ word: String) -> Bool {
        ordinalSmallValues[word] != nil ||
            ordinalTensValues[word] != nil ||
            ordinalScaleWords.contains(word)
    }

    private static func digitValue(_ word: String) -> Int? {
        if isOhWord(word) { return 0 }
        return digitValues[word]
    }

    private static func isZeroWord(_ word: String) -> Bool {
        word == "zero" || isOhWord(word)
    }

    private static func isOhWord(_ word: String) -> Bool {
        word == "oh" || word == "o"
    }

    private static let digitValues = [
        "zero": 0,
        "one": 1,
        "two": 2,
        "three": 3,
        "four": 4,
        "five": 5,
        "six": 6,
        "seven": 7,
        "eight": 8,
        "nine": 9
    ]

    private static let teenValues = [
        "ten": 10,
        "eleven": 11,
        "twelve": 12,
        "thirteen": 13,
        "fourteen": 14,
        "fifteen": 15,
        "sixteen": 16,
        "seventeen": 17,
        "eighteen": 18,
        "nineteen": 19
    ]

    private static let smallValues = digitValues.merging(teenValues) { current, _ in current }

    private static let tensValues = [
        "twenty": 20,
        "thirty": 30,
        "forty": 40,
        "fifty": 50,
        "sixty": 60,
        "seventy": 70,
        "eighty": 80,
        "ninety": 90
    ]

    private static let ordinalSmallValues = [
        "first": 1,
        "second": 2,
        "third": 3,
        "fourth": 4,
        "fifth": 5,
        "sixth": 6,
        "seventh": 7,
        "eighth": 8,
        "ninth": 9,
        "tenth": 10,
        "eleventh": 11,
        "twelfth": 12,
        "thirteenth": 13,
        "fourteenth": 14,
        "fifteenth": 15,
        "sixteenth": 16,
        "seventeenth": 17,
        "eighteenth": 18,
        "nineteenth": 19
    ]

    private static let ordinalTensValues = [
        "twentieth": 20,
        "thirtieth": 30,
        "fortieth": 40,
        "fiftieth": 50,
        "sixtieth": 60,
        "seventieth": 70,
        "eightieth": 80,
        "ninetieth": 90
    ]

    private static let scaleWords: Set<String> = [
        "hundred",
        "hundredth",
        "thousand",
        "thousandth",
        "million",
        "millionth"
    ]

    private static let ordinalScaleWords: Set<String> = [
        "hundredth",
        "thousandth",
        "millionth"
    ]

    private static let cardinalScaleWords: Set<String> = [
        "hundred",
        "thousand",
        "million"
    ]

    private static let monthNames: Set<String> = [
        "january",
        "february",
        "march",
        "april",
        "may",
        "june",
        "july",
        "august",
        "september",
        "october",
        "november",
        "december"
    ]
}
