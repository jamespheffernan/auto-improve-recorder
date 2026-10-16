import XCTest
@testable import AutoSendRecorderCore

/// How ASR turns shared delivery's report into its own disposition.
final class AutoSendDeliveryDispositionTests: XCTestCase {
    func testSubmittedTextIsSent() {
        XCTAssertEqual(resolve(report(.submitted)).disposition, .sent)
    }

    func testPastedTextIsReportedByWhetherSendingWasRequested() {
        XCTAssertEqual(
            resolve(report(.pasted, sendWasRequested: false)).disposition,
            .pastedWithoutSending
        )
        XCTAssertEqual(
            resolve(report(.pasted, sendWasRequested: true, statusMessage: "Send held back.")).disposition,
            .sendSuppressed("Send held back.")
        )
    }

    func testCopiedTextIsCopied() {
        XCTAssertEqual(
            resolve(report(.copied, statusMessage: "Copied.")).disposition,
            .copied("Copied.")
        )
    }

    func testCopiedTextAfterAPasteErrorDependsOnAccessibilityPermission() {
        XCTAssertEqual(
            resolve(report(.copied, errorSummary: "Paste failed.")).disposition,
            .copiedAfterPasteFailed("Paste failed.")
        )
        XCTAssertEqual(
            resolve(
                report(.copied, statusMessage: "Allow access.", errorSummary: "Paste failed.", trusted: false)
            ).disposition,
            .permissionRequired("Allow access.")
        )
    }

    func testUndeliveredTextIsCopiedWhenNoTextFieldWasAvailable() {
        let result = resolve(report(.ready))

        XCTAssertEqual(result.clipboardWrites, 1)
        XCTAssertEqual(
            result.disposition,
            .copied("Copied to clipboard. No editable text field was available.")
        )
    }

    func testUndeliveredTextWithoutAccessibilityPermissionAsksForIt() {
        XCTAssertEqual(
            resolve(report(.ready, statusMessage: "Allow access.", trusted: false)).disposition,
            .permissionRequired("Copied to clipboard. Allow access.")
        )
    }

    func testUndeliveredTextThatCannotBeCopiedIsAFailure() {
        XCTAssertEqual(
            resolve(report(.ready), clipboardWriteSucceeds: false).disposition,
            .pasteFailed("Could not write the transcript to the clipboard.")
        )
    }

    func testUndeliveredTextAfterAPasteErrorReportsTheErrorAndTheClipboardResult() {
        XCTAssertEqual(
            resolve(report(.ready, errorSummary: "Paste failed.")).disposition,
            .copiedAfterPasteFailed("Copied to clipboard. Paste failed.")
        )
        XCTAssertEqual(
            resolve(
                report(.ready, statusMessage: "Allow access.", errorSummary: "Paste failed.", trusted: false)
            ).disposition,
            .permissionRequired("Copied to clipboard. Allow access.")
        )
        XCTAssertEqual(
            resolve(report(.ready, errorSummary: "Paste failed."), clipboardWriteSucceeds: false).disposition,
            .pasteFailed("Could not paste or copy the transcript. Paste failed.")
        )
    }

    func testAPasteFailureCountsAsDeliveredOnlyWhenTheTextReachedTheClipboard() {
        let copiedByDelivery = resolve(report(.copied, errorSummary: "Paste failed.")).disposition
        let copiedByFallback = resolve(report(.ready, errorSummary: "Paste failed.")).disposition
        for disposition in [copiedByDelivery, copiedByFallback] {
            XCTAssertTrue(disposition.delivered, "\(disposition)")
            XCTAssertEqual(disposition.archiveLabel, "copied-paste-failed", "\(disposition)")
        }

        let notCopied = resolve(
            report(.ready, errorSummary: "Paste failed."),
            clipboardWriteSucceeds: false
        ).disposition
        XCTAssertFalse(notCopied.delivered)
        XCTAssertEqual(notCopied.archiveLabel, "paste-failed")
    }

    func testClipboardIsWrittenOnlyWhenTheTextIsUndelivered() {
        for outcome in [AutoSendDeliveryReport.Outcome.submitted, .pasted, .copied] {
            XCTAssertEqual(resolve(report(outcome)).clipboardWrites, 0, "\(outcome)")
        }
    }

    private func report(
        _ outcome: AutoSendDeliveryReport.Outcome,
        sendWasRequested: Bool = true,
        statusMessage: String = "status",
        errorSummary: String? = nil,
        trusted: Bool = true
    ) -> AutoSendDeliveryReport {
        AutoSendDeliveryReport(
            outcome: outcome,
            sendWasRequested: sendWasRequested,
            statusMessage: statusMessage,
            errorSummary: errorSummary,
            accessibilityTrusted: trusted
        )
    }

    private func resolve(
        _ report: AutoSendDeliveryReport,
        clipboardWriteSucceeds: Bool = true
    ) -> (disposition: AutoSendDeliveryDisposition, clipboardWrites: Int) {
        var clipboardWrites = 0
        let disposition = AutoSendDeliveryDisposition.resolving(report) {
            clipboardWrites += 1
            return clipboardWriteSucceeds
        }
        return (disposition, clipboardWrites)
    }
}
