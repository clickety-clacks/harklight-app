import AttentionDomain
import Foundation
import XCTest
@testable import Harklight

final class SeenActionPresentationTests: XCTestCase {
    func testPendingSeenIsDistinctFromCompletedPresentation() {
        let presentation = SeenActionPresentation(status: .pending)

        XCTAssertTrue(presentation.isPending)
        XCTAssertFalse(presentation.isCompleted)
        XCTAssertEqual(String(localized: presentation.title), "Pending")
        XCTAssertEqual(presentation.symbolName, "clock")
        XCTAssertEqual(String(localized: presentation.accessibilityLabel), "Seen pending confirmation")
        XCTAssertEqual(String(localized: presentation.accessibilityValue), "Pending")
    }

    func testConfirmedSeenUsesCompletedPresentation() {
        let presentation = SeenActionPresentation(status: .confirmed)

        XCTAssertFalse(presentation.isPending)
        XCTAssertTrue(presentation.isCompleted)
        XCTAssertEqual(String(localized: presentation.title), "Seen")
        XCTAssertEqual(presentation.symbolName, "checkmark")
        XCTAssertEqual(String(localized: presentation.accessibilityLabel), "Seen with green checkmark")
        XCTAssertEqual(String(localized: presentation.accessibilityValue), "Completed")
    }

    func testAvailableAndResolvedWithoutSeenAreNotCompleted() {
        for status in [InformationalSeenStatus.available, .resolvedWithoutSeen] {
            XCTAssertFalse(SeenActionPresentation(status: status).isCompleted,
                           "Only a confirmed Seen action uses completed presentation.")
        }
    }
}
