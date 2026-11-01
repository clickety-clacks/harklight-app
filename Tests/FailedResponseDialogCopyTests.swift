import XCTest
@testable import Harklight

final class FailedResponseDialogCopyTests: XCTestCase {
    func testCopyPayloadContainsTheVisibleSummaryAndFullDetailOnly() {
        let content = FailedResponseDialogCopyContent(
            summary: "Your response was not delivered.",
            detail: "The relay rejected this response.\nSafe code: relay_server_rejected")
        var copiedText: String?

        XCTAssertEqual(FailedResponseDialogCopyContent.buttonAccessibilityIdentifier,
                       "failed-response-copy")
        content.copy { copiedText = $0 }
        XCTAssertEqual(copiedText,
                       "Your response was not delivered.\n\n" +
                           "The relay rejected this response.\nSafe code: relay_server_rejected")
    }
}
