import AttentionDomain
import HarklightNativeRelay
import XCTest
@testable import Harklight

@MainActor
final class RetractionPresentationTests: XCTestCase {
    private static let retractedAt: UInt64 = 1_760_000_000_123
    private static let retractedAtSeconds: TimeInterval = 1_760_000_000.123



    func testRetractionExpiryUsesItsTimestampAndKeepsRowsWithoutOne() {
        let retractedAt = Date(timeIntervalSince1970: Self.retractedAtSeconds)
        let expiry = retractedAt.addingTimeInterval(24 * 60 * 60)
        XCTAssertFalse(LivePresentationStore.isRetractionExpired(
            retractionDate: retractedAt, at: expiry.addingTimeInterval(-1)))
        XCTAssertTrue(LivePresentationStore.isRetractionExpired(retractionDate: retractedAt, at: expiry))
        XCTAssertNil(LivePresentationStore.retractionExpiryDate(for: nil))
        XCTAssertFalse(LivePresentationStore.isRetractionExpired(retractionDate: nil, at: .distantFuture))
    }


    func testDisconnectedRetractionDoesNotPresentLocalAttemptAsServerAnswer() throws {
        let context = profile()
        let domain = try ClientRepository(context: context,
            persistence: MemoryPendingActionPersistence())
        let key = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("fixture-sender"), messageID: ExactText("not-accepted-retained"))
        let payload = try JSONValue.parse(Data(#"{"title":"Archive sketches","body":"Choose what to do with the earlier sketches.","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"keep","label":"Keep original choice","kind":"value","value":"keep"}]}}"#.utf8))
        try domain.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: payload), .message),
            conversation: RelayConversationMetadata(revision: 1,
                sessionHandle: ExactText("local-not-accepted-session"), eventID: ExactText("1"))),
            context: context)

        let binding = ConversationBinding(request: key, revision: 1)
        try domain.applyConversation(ConversationEvent(sequence: 1, binding: binding,
            fact: .request(sessionHandle: ExactText("local-not-accepted-session"), payload: payload)),
            context: context)
        try domain.applyConversation(ConversationEvent(sequence: 2, binding: binding,
            fact: .availability(sessionHandle: ExactText("local-not-accepted-session"), .listening)),
            context: context)
        try domain.saveConversationDraft(ConversationDraft(binding: binding,
            text: ExactText("Please keep this unsent note.")), context: context)

        let port = AttentionDomainPort(store: domain)
        let selector = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first?.selector)
        let receipt = try port.submit(SubmitIntent(context: port.context, selector: selector,
            intentID: UUID(), inputs: [.compatibilityValue(action: ExactText("keep"))]))
        try domain.recordAnswerRefusedByRetraction(receipt.intentID, operationID: receipt.opID,
            retractedAtMilliseconds: Self.retractedAt, context: context)
        try domain.applyConversation(ConversationEvent(sequence: 3, binding: binding,
            fact: .retraction(turn: ExactText("not-accepted-retracted"), terminalSequence: 1),
            retractedAtMilliseconds: Self.retractedAt), context: context)

        let disconnected = try LivePresentationStore(disconnectedStore: domain, context: context)
        let shown = try XCTUnwrap(disconnected.request(for: key))
        XCTAssertTrue(disconnected.isRetracted(key))
        XCTAssertNil(shown.receiptFacts, "The disconnected account-terminal view keeps the existing receipt boundary.")
        XCTAssertNil(shown.intentReceipt, "The card does not require exposing the full intent receipt.")
        XCTAssertTrue(shown.ownAnswerWasRefusedByRetraction)

        let attemptedAnswer = AnswerConfirmationText.formatted(accountAnswerOutcome: nil,
            submittedAnswer: shown.submittedAnswer, projection: shown.projection)
        XCTAssertNil(attemptedAnswer, "A locally attempted choice is not a server answer.")
        XCTAssertEqual(try domain.lookupIntent(receipt.intentID, context: context)?.operationID, receipt.opID)
        XCTAssertFalse(LiveRequestDetail.shouldShowNotAcceptedConfirmation(
            isRetracted: disconnected.isRetracted(key), isSupersedesReadOnly: false,
            ownOutcome: shown.receiptFacts?.ownOutcome,
            relayOutcome: shown.intentReceipt?.relayOutcome,
            attemptedAnswerText: attemptedAnswer,
            ownAnswerWasRefusedByRetraction: shown.ownAnswerWasRefusedByRetraction))
    }






    private func profile() -> ProfileContext {
        ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("reader")), transportMode: .relay)
    }
}
