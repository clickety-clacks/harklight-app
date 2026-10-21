import AttentionDomain
import Foundation
import XCTest
@testable import Harklight

/// The ruled behavior for the Answered control: a pending or refused send must
/// never present as Answered; only an answered request or an accepted
/// submission completes the state.
@MainActor
final class AnswerStatusPresentationTests: XCTestCase {
    func testPendingUnconfirmedSendIsNeverAnswered() {
        XCTAssertFalse(LiveRequestDetail.answerStatusIsComplete(
            lifecycleStatus: .pending, ownOutcome: .unconfirmed, answerNotDelivered: false))
    }

    func testRefusedSendIsNeverAnswered() {
        for status in [AppLifecycleStatus.pending, .cleared, .expired, .superseded] {
            XCTAssertFalse(LiveRequestDetail.answerStatusIsComplete(
                lifecycleStatus: status, ownOutcome: .refused, answerNotDelivered: false),
                "A refused send must not show Answered under \(status).")
        }
    }

    func testUndeliveredAnswerIsNeverAnsweredEvenWhenRequestClosed() {
        for status in [AppLifecycleStatus.pending, .answered, .cleared] {
            XCTAssertFalse(LiveRequestDetail.answerStatusIsComplete(
                lifecycleStatus: status, ownOutcome: .unconfirmed, answerNotDelivered: true),
                "An undelivered answer must not show Answered under \(status).")
        }
    }

    func testAcceptedSendShowsAnswered() {
        XCTAssertTrue(LiveRequestDetail.answerStatusIsComplete(
            lifecycleStatus: .pending, ownOutcome: .accepted, answerNotDelivered: false))
        XCTAssertTrue(LiveRequestDetail.answerStatusIsComplete(
            lifecycleStatus: .answered, ownOutcome: .accepted, answerNotDelivered: false))
    }

    func testAnsweredRequestShowsAnsweredEvenWithoutLocalSubmission() {
        XCTAssertTrue(LiveRequestDetail.answerStatusIsComplete(
            lifecycleStatus: .answered, ownOutcome: .unconfirmed, answerNotDelivered: false))
        XCTAssertTrue(LiveRequestDetail.answerStatusIsComplete(
            lifecycleStatus: .answered, ownOutcome: nil, answerNotDelivered: false))
    }

    func testNoCommentKeepsItsOwnStateInsteadOfAnswered() {
        XCTAssertFalse(LiveRequestDetail.answerStatusIsComplete(
            lifecycleStatus: .noComment, ownOutcome: .accepted, answerNotDelivered: false))
    }

    func testContentStatusTextStaysPlainLanguage() {
        XCTAssertEqual(
            LiveRequestDetail.answerStatusText(lifecycleStatus: .pending,
                                               ownOutcome: .unconfirmed,
                                               answeredFromThisDevice: true),
            "Your answer is saved on this device. Delivery is not yet confirmed.")
        XCTAssertNil(LiveRequestDetail.answerStatusText(lifecycleStatus: .answered,
                                                        ownOutcome: .accepted,
                                                        answeredFromThisDevice: true),
                     "A completed answer shows the Answered control, not a redundant status line.")
        let retracted = LiveRequestDetail.answerStatusText(lifecycleStatus: .cleared,
                                                           ownOutcome: .refused,
                                                           answeredFromThisDevice: true)
        XCTAssertEqual(retracted,
                       "The sender retracted this request before your answer was accepted. The answer was not accepted.")
        for text in [retracted,
                     LiveRequestDetail.answerStatusText(lifecycleStatus: .expired,
                                                        ownOutcome: .unconfirmed,
                                                        answeredFromThisDevice: true)] {
            let lowered = text?.lowercased() ?? ""
            XCTAssertFalse(lowered.contains("relay"), "Internal relay wording stays out of the content area.")
            XCTAssertFalse(lowered.contains("lifecycle"), "Internal lifecycle wording stays out of the content area.")
            XCTAssertFalse(lowered.contains("evidence"), "Internal evidence wording stays out of the content area.")
        }
    }
}

/// The ruled behavior for the automatic return to the list: only a submission
/// the relay confirms accepted dismisses the compact detail. A pending or
/// refused submission must not dismiss as if it were done.
@MainActor
final class SubmissionDismissalTests: XCTestCase {
    func testPendingUnconfirmedSubmissionDoesNotDismiss() {
        XCTAssertFalse(LiveRequestDetail.submissionDismissesToList(
            ownOutcome: .unconfirmed, answerNotDelivered: false))
        XCTAssertFalse(LiveRequestDetail.submissionDismissesToList(
            ownOutcome: nil, answerNotDelivered: false))
    }

    func testRefusedSubmissionDoesNotDismiss() {
        XCTAssertFalse(LiveRequestDetail.submissionDismissesToList(
            ownOutcome: .refused, answerNotDelivered: false))
    }

    func testUndeliveredAnswerDoesNotDismiss() {
        XCTAssertFalse(LiveRequestDetail.submissionDismissesToList(
            ownOutcome: .accepted, answerNotDelivered: true))
    }

    func testConfirmedAcceptedSubmissionDismisses() {
        XCTAssertTrue(LiveRequestDetail.submissionDismissesToList(
            ownOutcome: .accepted, answerNotDelivered: false))
    }
}

/// The ruled behavior for links: ordinary URLs become tappable with the
/// standard system behavior while the visible characters stay exactly as
/// written, and nothing else is interpreted as markup.
final class MessageTextLinksTests: XCTestCase {
    private func visibleText(_ attributed: AttributedString) -> String {
        String(attributed.characters)
    }

    private func links(_ attributed: AttributedString) -> [URL] {
        attributed.runs.compactMap { $0.link }
    }

    func testPlainTextGetsNoLinks() {
        let source = "No addresses here, just words."
        let attributed = MessageTextLinks.attributed(source)
        XCTAssertEqual(visibleText(attributed), source)
        XCTAssertTrue(links(attributed).isEmpty)
    }

    func testURLBecomesTappableAndCharactersAreUnchanged() {
        let source = "Build is at https://example.com/builds/15 for review."
        let attributed = MessageTextLinks.attributed(source)
        XCTAssertEqual(visibleText(attributed), source)
        XCTAssertEqual(links(attributed), [URL(string: "https://example.com/builds/15")!])
    }

    func testMultipleURLsEachGetTheirOwnLink() {
        let source = "See https://example.com/a then https://example.org/b."
        let attributed = MessageTextLinks.attributed(source)
        XCTAssertEqual(visibleText(attributed), source)
        XCTAssertEqual(links(attributed).count, 2)
        XCTAssertEqual(links(attributed).first?.host(), "example.com")
        XCTAssertEqual(links(attributed).last?.host(), "example.org")
    }

    func testMarkupIsNotInterpreted() {
        let source = "Literal *stars*, _underscores_ and [brackets](stay) as typed."
        let attributed = MessageTextLinks.attributed(source)
        XCTAssertEqual(visibleText(attributed), source)
        XCTAssertTrue(links(attributed).isEmpty)
    }
}
