import AttentionDomain
import Foundation
import XCTest
@testable import Harklight

/// The ruled behavior for the Answered confirmation: a pending or refused send must
/// never present as Answered; only the Server's answered terminal completes it.
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

    func testNotAcceptedRequiresRetractionRefusalAndActualAttemptedAnswer() {
        let refused = RelayOutcome.refusedByRetraction(retractedAtMilliseconds: 1)
        XCTAssertTrue(LiveRequestDetail.shouldShowNotAcceptedConfirmation(
            isRetracted: true, isSupersedesReadOnly: false, ownOutcome: nil,
            relayOutcome: refused, attemptedAnswerText: "Keep original choice"),
            "A retained refusedByRetraction receipt can drive the card without receiptFacts.")
        XCTAssertTrue(LiveRequestDetail.shouldShowNotAcceptedConfirmation(
            isRetracted: true, isSupersedesReadOnly: false, ownOutcome: nil,
            relayOutcome: nil, attemptedAnswerText: "Keep original choice",
            ownAnswerWasRefusedByRetraction: true),
            "An account-terminal projection can retain the local refusal fact without exposing its full receipt.")
        XCTAssertTrue(LiveRequestDetail.shouldShowNotAcceptedConfirmation(
            isRetracted: true, isSupersedesReadOnly: false, ownOutcome: .refused,
            relayOutcome: nil, attemptedAnswerText: "Keep original choice"),
            "A refused terminal receipt still drives the same card.")
        XCTAssertFalse(LiveRequestDetail.shouldShowNotAcceptedConfirmation(
            isRetracted: true, isSupersedesReadOnly: false, ownOutcome: nil,
            relayOutcome: refused, attemptedAnswerText: nil),
            "A retraction without a retained answer is not relabeled as Not accepted.")
        XCTAssertFalse(LiveRequestDetail.shouldShowNotAcceptedConfirmation(
            isRetracted: true, isSupersedesReadOnly: false, ownOutcome: nil,
            relayOutcome: refused, attemptedAnswerText: ""))
        XCTAssertFalse(LiveRequestDetail.shouldShowNotAcceptedConfirmation(
            isRetracted: false, isSupersedesReadOnly: false, ownOutcome: nil,
            relayOutcome: refused, attemptedAnswerText: "Keep original choice"))
        XCTAssertFalse(LiveRequestDetail.shouldShowNotAcceptedConfirmation(
            isRetracted: true, isSupersedesReadOnly: true, ownOutcome: nil,
            relayOutcome: refused, attemptedAnswerText: "Keep original choice"))
        XCTAssertFalse(LiveRequestDetail.shouldShowNotAcceptedConfirmation(
            isRetracted: true, isSupersedesReadOnly: false, ownOutcome: nil,
            relayOutcome: .accepted(sequence: nil), attemptedAnswerText: "Keep original choice"))
    }

    func testUndeliveredAnswerIsNeverAnsweredEvenWhenRequestClosed() {
        for status in [AppLifecycleStatus.pending, .answered, .cleared] {
            XCTAssertFalse(LiveRequestDetail.answerStatusIsComplete(
                lifecycleStatus: status, ownOutcome: .unconfirmed, answerNotDelivered: true),
                "An undelivered answer must not show Answered under \(status).")
        }
    }

    func testAcceptedSendStaysPendingUntilAnsweredTerminal() {
        XCTAssertFalse(LiveRequestDetail.answerStatusIsComplete(
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
        XCTAssertTrue(LiveRequestDetail.showsNoCommentConfirmation(
            lifecycleStatus: .noComment, isSupersedesReadOnly: false))
        XCTAssertFalse(LiveRequestDetail.showsNoCommentConfirmation(
            lifecycleStatus: .answered, isSupersedesReadOnly: false))
        XCTAssertFalse(LiveRequestDetail.showsNoCommentConfirmation(
            lifecycleStatus: .noComment, isSupersedesReadOnly: true))
    }

    func testChoiceAnswerUsesPresentedLabelInsteadOfActionIdentifier() {
        let actionID = ExactText("approve-action-id")
        let submitted = RequestDraft(inputs: [:],
            compatibility: CompatibilityDraft(selectedActionID: actionID))
        let action = ProjectedAction(id: actionID, label: ExactText("Cover A"), kind: .value)

        XCTAssertEqual(AnswerConfirmationText.formatted(accountAnswerOutcome: nil,
            submittedAnswer: submitted, projection: .compatibility([action])), "Cover A")
    }

    func testWrittenReplyUsesTheSubmittedTextAndKeepsItsFormatting() {
        let actionID = ExactText("write-reply")
        let reply = ExactText("Ready for review.\nThe note stays on its own line.")
        let submitted = RequestDraft(inputs: [:], compatibility: CompatibilityDraft(
            selectedActionID: actionID, textByActionID: [actionID: reply]))
        let action = ProjectedAction(id: actionID, label: ExactText("Write a note"), kind: .text)

        XCTAssertEqual(AnswerConfirmationText.formatted(accountAnswerOutcome: nil,
            submittedAnswer: submitted, projection: .compatibility([action])), reply.rawValue)
    }

    func testSenderChoiceAnswerUsesThePresentedLabel() {
        let inputID = ExactText("choice")
        let actionID = ExactText("approve-action-id")
        let action = ProjectedAction(id: actionID, label: ExactText("Cover A"), kind: .value)
        let projection = AdmittedRequestProjection.sender(AdmittedSenderProjection(
            scene: ProjectedSceneNode(id: "choice", kind: .input(inputID, .cards)),
            inputs: [ProjectedInput(id: inputID, label: ExactText("Choose the cover"),
                                    kind: .response([action]))],
            illustrations: [], submissionLabel: ExactText("Send answer")))
        let submitted = RequestDraft(inputs: [inputID: InputDraft(selectedActionID: actionID)])

        XCTAssertEqual(AnswerConfirmationText.formatted(accountAnswerOutcome: nil,
            submittedAnswer: submitted, projection: projection), "Cover A")
    }

    func testSenderWrittenReplyKeepsTheSubmittedTextFormatting() {
        let inputID = ExactText("answer")
        let actionID = ExactText("write-reply")
        let reply = ExactText("Ready for review.\nThe note stays on its own line.")
        let action = ProjectedAction(id: actionID, label: ExactText("Write a note"), kind: .text)
        let projection = AdmittedRequestProjection.sender(AdmittedSenderProjection(
            scene: ProjectedSceneNode(id: "answer", kind: .input(inputID, .editor)),
            inputs: [ProjectedInput(id: inputID, label: ExactText("Response"),
                                    kind: .response([action]))],
            illustrations: [], submissionLabel: ExactText("Send answer")))
        let submitted = RequestDraft(inputs: [inputID: InputDraft(
            selectedActionID: actionID, textByActionID: [actionID: reply])])

        XCTAssertEqual(AnswerConfirmationText.formatted(accountAnswerOutcome: nil,
            submittedAnswer: submitted, projection: projection), reply.rawValue)
    }

    func testSenderPointAnswerUsesResultLabelAndKeepsOtherSubmittedFields() {
        let locationID = ExactText("location")
        let noteID = ExactText("note")
        let point = PointValue(x: 240, y: 610)
        let scene = ProjectedSceneNode(id: "results", kind: .stack(.vertical, [
            ProjectedSceneNode(id: "location-result", kind: .resultPoint(
                illustrationID: ExactText("floor"),
                label: ExactText("Established submitted location"), point: point))
        ]))
        let projection = AdmittedRequestProjection.sender(AdmittedSenderProjection(
            scene: scene,
            inputs: [
                ProjectedInput(id: locationID, label: ExactText("Repair location"),
                               kind: .point(illustrationID: ExactText("floor"))),
                ProjectedInput(id: noteID, label: ExactText("Note"), kind: .text)
            ], illustrations: [], submissionLabel: ExactText("Send answer")))
        let submitted = RequestDraft(inputs: [
            locationID: InputDraft(point: point),
            noteID: InputDraft(text: ExactText("Near the east entrance"))
        ])

        XCTAssertEqual(AnswerConfirmationText.formatted(accountAnswerOutcome: nil,
            submittedAnswer: submitted, projection: projection),
            "Established submitted location\nHorizontal 240, vertical 610\nNote\nNear the east entrance")
    }

    func testAccountOutcomeUsesKnownAnswerInsteadOfAnUnconfirmedLocalAttempt() {
        let attemptedID = ExactText("cover-b")
        let attempted = RequestDraft(inputs: [:],
            compatibility: CompatibilityDraft(selectedActionID: attemptedID))
        let actions = [
            ProjectedAction(id: ExactText("cover-a"), label: ExactText("Cover A"), kind: .value),
            ProjectedAction(id: attemptedID, label: ExactText("Cover B"), kind: .value)
        ]

        XCTAssertEqual(AnswerConfirmationText.formatted(
            accountAnswerOutcome: .reply(ExactText("Cover A")),
            submittedAnswer: nil, projection: .compatibility(actions)), "Cover A")
    }

    func testDefaultAnswerFallsBackToThePresentedChoiceWhenWordsAreAbsent() {
        let actionID = ExactText("hold")
        let action = ProjectedAction(id: actionID, label: ExactText("Hold for now"), kind: .value)

        XCTAssertEqual(AnswerConfirmationText.formatted(
            accountAnswerOutcome: .defaultAnswer(value: nil, text: nil),
            submittedAnswer: nil, projection: .compatibility([action]),
            defaultAnswerAction: ProjectedActionReference(inputID: nil, actionID: actionID)),
            "Hold for now")
    }

    func testNoCommentAndSeenOutcomesHaveNoAnswerText() {
        for outcome in [AccountAnswerOutcome.noComment, .seen] {
            XCTAssertNil(AnswerConfirmationText.formatted(accountAnswerOutcome: outcome,
                submittedAnswer: nil, projection: .compatibility([])))
        }
        XCTAssertNil(AnswerConfirmationText.formatted(accountAnswerOutcome: nil,
            submittedAnswer: nil, projection: .compatibility([])),
            "An unknown other-device answer must not reuse an attempted local draft.")
    }

    func testContentStatusTextStaysPlainLanguage() {
        XCTAssertEqual(
            LiveRequestDetail.answerStatusText(lifecycleStatus: .pending,
                                               ownOutcome: .unconfirmed,
                                               answeredFromThisDevice: true),
            "Submission unconfirmed · saved draft retained")
        XCTAssertNil(LiveRequestDetail.answerStatusText(lifecycleStatus: .answered,
                                                        ownOutcome: .accepted,
                                                        answeredFromThisDevice: true),
                     "A completed answer shows the Answered card, not a redundant status line.")
        XCTAssertNil(LiveRequestDetail.answerStatusText(lifecycleStatus: .noComment,
                                                        ownOutcome: .accepted,
                                                        answeredFromThisDevice: true),
                     "The No comment card is the only confirmation for that outcome.")
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

    func testEmailAddressesAreNotLinkified() {
        let source = "Write to desk@example.com or see https://example.com/help."
        let attributed = MessageTextLinks.attributed(source)
        XCTAssertEqual(visibleText(attributed), source)
        XCTAssertEqual(links(attributed), [URL(string: "https://example.com/help")!],
                       "Only web URLs become links; an email address stays plain text.")
    }
}

/// The ruled behavior for an unresolved send: a send from this device whose
/// request closed without a confirmed result raises a plain-language warning
/// in the inbox warning details, and the warning clears once no send remains
/// unresolved. An in-flight send and a server-resolved request are not
/// unresolved.
@MainActor
final class UnresolvedSendWarningTests: XCTestCase {
    func testClosedRequestWithUnconfirmedOwnSendIsUnresolved() {
        for status in [AppLifecycleStatus.cleared, .expired, .superseded] {
            XCTAssertTrue(LivePresentationStore.sendIsUnresolved(
                lifecycleStatus: status, ownOutcome: .unconfirmed,
                answeredFromThisDevice: true),
                "A send left without a result under \(status) is unresolved.")
        }
    }

    func testInFlightSendIsNotUnresolved() {
        for status in [AppLifecycleStatus.open, .pending] {
            XCTAssertFalse(LivePresentationStore.sendIsUnresolved(
                lifecycleStatus: status, ownOutcome: .unconfirmed,
                answeredFromThisDevice: true),
                "An in-flight send under \(status) carries a status line, not a warning.")
        }
    }

    func testServerResolvedRequestIsNotUnresolved() {
        for status in [AppLifecycleStatus.answered, .noComment] {
            XCTAssertFalse(LivePresentationStore.sendIsUnresolved(
                lifecycleStatus: status, ownOutcome: .unconfirmed,
                answeredFromThisDevice: true),
                "A server-resolved request under \(status) has its result.")
        }
    }

    func testAcceptedOrForeignSendIsNotUnresolved() {
        XCTAssertFalse(LivePresentationStore.sendIsUnresolved(
            lifecycleStatus: .cleared, ownOutcome: .accepted, answeredFromThisDevice: true))
        XCTAssertFalse(LivePresentationStore.sendIsUnresolved(
            lifecycleStatus: .cleared, ownOutcome: nil, answeredFromThisDevice: true))
        XCTAssertFalse(LivePresentationStore.sendIsUnresolved(
            lifecycleStatus: .cleared, ownOutcome: .unconfirmed, answeredFromThisDevice: false))
    }

    func testWarningTextIsPlainLanguageAndClearsAtZero() {
        XCTAssertNil(LivePresentationStore.unresolvedSendWarning(unresolvedSendCount: 0),
                     "No unresolved send leaves no warning, which closes the popup entry.")
        let single = LivePresentationStore.unresolvedSendWarning(unresolvedSendCount: 1)
        XCTAssertEqual(single,
                       "Submission unconfirmed · saved draft retained")
        let several = LivePresentationStore.unresolvedSendWarning(unresolvedSendCount: 3)
        XCTAssertEqual(several,
                       "3 submissions unconfirmed · saved drafts retained")
        for text in [single, several].compactMap({ $0 }) {
            for jargon in ["relay", "lifecycle", "evidence", "reconciliation", "terminal"] {
                XCTAssertFalse(text.lowercased().contains(jargon),
                               "The warning stays in plain language: \(text)")
            }
        }
    }
}
