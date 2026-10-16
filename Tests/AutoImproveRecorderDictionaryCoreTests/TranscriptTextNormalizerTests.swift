import XCTest
@testable import AutoImproveRecorderCore

final class TranscriptTextNormalizerTests: XCTestCase {
    func testNormalizesCommonCardinalNumbers() {
        let text = "I need twenty five options and one hundred and twelve rows."

        XCTAssertEqual(
            TranscriptTextNormalizer.normalizeSpokenNumbers(in: text),
            "I need 25 options and 112 rows."
        )
    }

    func testNormalizesYearPhrases() {
        let text = "Compare nineteen ninety seven with twenty twenty six and two thousand and six."

        XCTAssertEqual(
            TranscriptTextNormalizer.normalizeSpokenNumbers(in: text),
            "Compare 1997 with 2026 and 2006."
        )
    }

    func testNormalizesDigitSequencesDecimalsAndNegatives() {
        let text = "Use code zero one two three four, version two point five, and negative seven."

        XCTAssertEqual(
            TranscriptTextNormalizer.normalizeSpokenNumbers(in: text),
            "Use code 01234, version 2.5, and -7."
        )
    }

    func testPreservesCommonNonNumericOnePhrase() {
        let text = "One of the issues is line twenty one, and one more thing."

        XCTAssertEqual(
            TranscriptTextNormalizer.normalizeSpokenNumbers(in: text),
            "One of the issues is line 21, and 1 more thing."
        )
    }

    func testNonDateOrdinalsUseOrdinalSuffixes() {
        let text = "Use the first pass, then the second review, rank the first and second options, and note the twenty first checkpoint."

        XCTAssertEqual(
            TranscriptTextNormalizer.normalizeSpokenNumbers(in: text),
            "Use the 1st pass, then the 2nd review, rank the 1st and 2nd options, and note the 21st checkpoint."
        )
    }

    func testMonthDateOrdinalsUseBareDayNumbers() {
        let text = "The window is June first and second, then July twenty first."

        XCTAssertEqual(
            TranscriptTextNormalizer.normalizeSpokenNumbers(in: text),
            "The window is June 1 and 2, then July 21."
        )
    }

    func testPreservesOrdinalModifiersBeforeQuantities() {
        let text = "Keep the first one, the first two rows, and the second hundred examples."

        XCTAssertEqual(
            TranscriptTextNormalizer.normalizeSpokenNumbers(in: text),
            "Keep the first one, the first two rows, and the second hundred examples."
        )
    }
}
