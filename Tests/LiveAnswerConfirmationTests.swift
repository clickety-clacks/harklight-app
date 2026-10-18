import AttentionDomain
import Foundation
import HarklightNativeRelay
import XCTest
@testable import AttentionClientDuoPrototype

@MainActor
final class LiveAnswerConfirmationTests: XCTestCase {
    private func setup() throws -> (ProfileContext, AttentionDomainStore, LivePresentationStore, RequestKey) {
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("relay.example"), personID: ExactText("person"),
            deviceID: ExactText("device")), transportMode: .relay)
        let store = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        let key = RequestKey(accountScope: context.identity.personID,
                             senderID: ExactText("sender"), messageID: ExactText("sample"))
        let payload = try JSONValue.parse(Data(#"{"title":"Sample","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"got-it","label":"Got it","kind":"value","value":"got-it"}]}}"#.utf8))
        _ = try store.apply(RelayEvent(sequence: 1, body: .delivery(
            StoredRequest(key: key, originalPayload: payload), .message)), context: context)
        return (context, store, try LivePresentationStore(store: store, context: context), key)
    }

    private func commitAnswer(_ store: AttentionDomainStore, key: RequestKey) throws -> IntentReceipt {
        let port = AttentionDomainPort(store: store)
        let selector = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first?.selector)
        return try port.submit(SubmitIntent(context: port.context, selector: selector, intentID: UUID(),
                                             inputs: [.compatibilityValue(action: ExactText("got-it"))]))
    }

    func testDelayedSendAfterDurableAnswerNeverClaimsFailureOrCreatesAnotherIntent() throws {
        let (context, store, live, key) = try setup()
        // The displayed Open view is deliberately older than the durable intent.
        let receipt = try commitAnswer(store, key: key)
        live.submitFromUser(key)
        XCTAssertNil(live.actionError)
        XCTAssertEqual(live.request(for: key)?.intentReceipt?.opID, receipt.opID)
        XCTAssertEqual(try store.snapshot(context: context).intents.count, 1)
        XCTAssertEqual(try store.snapshot(context: context).outbox.map(\.operationID), [receipt.opID])

        try store.recordAcceptedOperation(receipt.intentID, operationID: receipt.opID,
                                          terminalSequence: 2, context: context)
        _ = try store.apply(RelayEvent(sequence: 2, body: .terminal(key, .answered, nil)), context: context)
        live.submitFromUser(key)
        XCTAssertNil(live.actionError)
        XCTAssertEqual(live.request(for: key)?.lifecycleStatus, .answered)
        XCTAssertEqual(live.request(for: key)?.receiptFacts?.ownOutcome, .accepted)
        XCTAssertTrue(try store.snapshot(context: context).outbox.isEmpty)
        XCTAssertEqual(try store.snapshot(context: context).intents.count, 1)
    }

    func testNewDurableReceiptClearsAnObsoleteSubmissionError() throws {
        let (context, store, live, key) = try setup()
        live.submitFromUser(key) // No choice made: a genuine local validation error.
        XCTAssertEqual(live.actionError, "Complete the response before sending your answer.")
        XCTAssertTrue(try store.snapshot(context: context).intents.isEmpty)
        let receipt = try commitAnswer(store, key: key)
        try store.recordAcceptedOperation(receipt.intentID, operationID: receipt.opID,
                                          terminalSequence: 2, context: context)
        try live.refreshFromDurableStore()
        XCTAssertNil(live.actionError)
        XCTAssertEqual(live.request(for: key)?.receiptFacts?.ownOutcome, .accepted)
    }

    func testDisconnectedInboxKeepsDraftReadOnlyAndCannotCreateOrRetryAnAnswer() throws {
        let (context, store, live, key) = try setup()
        live.selectAction(ExactText("got-it"), input: nil, for: key)
        let savedDraft = try XCTUnwrap(live.request(for: key)?.draft)
        XCTAssertTrue(savedDraft.hasEdits)

        live.enterReadOnlyMode()
        live.selectAction(ExactText("different"), input: nil, for: key)
        live.updateCompatibilityText("changed after disconnect", action: ExactText("got-it"), for: key)
        live.submitFromUser(key)
        live.retryPendingDelivery()

        XCTAssertTrue(live.isReadOnly)
        XCTAssertEqual(live.request(for: key)?.draft, savedDraft)
        XCTAssertEqual(live.request(for: key)?.lifecycleStatus, .open)
        XCTAssertThrowsError(try live.submit(key))
        let snapshot = try store.snapshot(context: context)
        XCTAssertTrue(snapshot.intents.isEmpty)
        XCTAssertTrue(snapshot.outbox.isEmpty)
    }

    func testAnswerCommittedDuringRefreshGetsADeliveryPassAfterThatRefresh() async {
        let (started, startedSignal) = AsyncStream<Void>.makeStream()
        let (release, releaseSignal) = AsyncStream<Void>.makeStream()
        let (queued, queuedSignal) = AsyncStream<Void>.makeStream()
        var hasSavedAnswer = false
        var passes = 0
        var deliveries = 0
        let flights = RelayRefreshFlights(inactive: false) {
            passes += 1
            let answerSeen = hasSavedAnswer
            if passes == 1 {
                startedSignal.yield()
                for await _ in release { break }
            }
            if answerSeen { deliveries += 1 }
            return true
        }
        let initial = Task { await flights.coalesced() }
        for await _ in started { break }
        hasSavedAnswer = true
        let delivery = Task {
            queuedSignal.yield()
            return await flights.afterCurrent()
        }
        for await _ in queued { break }
        releaseSignal.yield()
        let initialReached = await initial.value
        let deliveryReached = await delivery.value
        XCTAssertTrue(initialReached)
        XCTAssertTrue(deliveryReached)
        XCTAssertEqual(passes, 2)
        XCTAssertEqual(deliveries, 1, "The saved original operation cannot wait for another app wake.")
    }

    func testLateSendOnAnotherDevicesTerminalRequestDoesNotClaimOurAnswerWasAccepted() throws {
        let (context, store, live, key) = try setup()
        _ = try store.apply(RelayEvent(sequence: 2, body: .terminal(key, .answered, nil)), context: context)
        live.submitFromUser(key)
        XCTAssertEqual(live.actionError, "This request is no longer open for an answer.")
        XCTAssertTrue(try store.snapshot(context: context).intents.isEmpty)
        XCTAssertEqual(live.request(for: key)?.receiptFacts?.ownOutcome, .unconfirmed)
    }

    func testAcceptedAnswerReplaysTerminalEventBeforeCompletingRefresh() async throws {
        let (context, store, live, key) = try setup()
        let receipt = try commitAnswer(store, key: key)
        let session = AnswerSession(context.identity)
        let core = try NativeRelayCore(store: store, context: context, session: session)
        let high = try await core.resyncAndDrainOutbox()
        try live.refreshFromDurableStore()
        XCTAssertEqual(high, 2)
        XCTAssertEqual(try store.snapshot(context: context).cursor, 2)
        XCTAssertEqual(session.sentOperationIDs, [receipt.opID])
        XCTAssertEqual(session.acknowledgedCursors, [1, 2])
        XCTAssertTrue(try store.snapshot(context: context).outbox.isEmpty)
        XCTAssertEqual(live.request(for: key)?.lifecycleStatus, .answered)
        XCTAssertEqual(live.request(for: key)?.receiptFacts?.ownOutcome, .accepted)
    }

    func testLostOperationReplyCanShowTerminalLifecycleWithoutInventingAcceptance() async throws {
        let (context, store, live, key) = try setup()
        let receipt = try commitAnswer(store, key: key)
        let session = AnswerSession(context.identity)
        session.loseOperationReply = true
        let core = try NativeRelayCore(store: store, context: context, session: session)
        _ = try await core.resyncAndDrainOutbox()
        try live.refreshFromDurableStore()
        XCTAssertEqual(session.sentOperationIDs, [receipt.opID])
        XCTAssertEqual(live.request(for: key)?.lifecycleStatus, .answered)
        XCTAssertEqual(live.request(for: key)?.receiptFacts?.ownOutcome, .unconfirmed)
        XCTAssertTrue(try store.snapshot(context: context).outbox.isEmpty)
        XCTAssertNil(live.actionError)
    }

    func testFailedTerminalReplayDoesNotEraseAcceptedAnswerOrResendItOnReconnect() async throws {
        let (context, store, live, key) = try setup()
        let receipt = try commitAnswer(store, key: key)
        let session = AnswerSession(context.identity)
        session.failReplayAfterSend = true
        let core = try NativeRelayCore(store: store, context: context, session: session)
        do { _ = try await core.resyncAndDrainOutbox(); XCTFail("The second replay is interrupted") }
        catch InstallationTransportError.unexpectedServerFrame {}
        try live.refreshFromDurableStore()
        XCTAssertEqual(live.request(for: key)?.receiptFacts?.ownOutcome, .accepted)
        XCTAssertTrue(try store.snapshot(context: context).outbox.isEmpty)
        XCTAssertEqual(try store.snapshot(context: context).cursor, 1)
        session.failReplayAfterSend = false
        _ = try await core.resyncAndDrainOutbox()
        try live.refreshFromDurableStore()
        XCTAssertEqual(session.sentOperationIDs, [receipt.opID])
        XCTAssertEqual(live.request(for: key)?.lifecycleStatus, .answered)
        XCTAssertEqual(live.request(for: key)?.receiptFacts?.ownOutcome, .accepted)
    }

    func testNotificationRegistrationRefusalDoesNotDowngradeAcceptedAnswer() async throws {
        let (context, store, live, key) = try setup()
        let receipt = try commitAnswer(store, key: key)
        let session = AnswerSession(context.identity)
        let core = try NativeRelayCore(store: store, context: context, session: session)
        _ = try await core.resyncAndDrainOutbox()
        try live.refreshFromDurableStore()

        let result = await NativeRelayRefreshResult.afterConfirmedRelay {
            throw InstallationTransportError.serverRejected
        }
        live.applyRefreshResult(result)
        XCTAssertTrue(result.relayConfirmed)
        XCTAssertEqual(result.pushRegistration, .unconfirmed)
        XCTAssertFalse(result.completedWithoutError)
        XCTAssertNil(live.connectionWarning, "A refused notification setup is not a failed relay answer.")
        XCTAssertNotNil(live.pushRegistrationWarning)
        XCTAssertNil(live.actionError)
        XCTAssertEqual(live.request(for: key)?.lifecycleStatus, .answered)
        XCTAssertEqual(live.request(for: key)?.receiptFacts?.ownOutcome, .accepted)
        XCTAssertEqual(session.sentOperationIDs, [receipt.opID])
        XCTAssertTrue(try store.snapshot(context: context).outbox.isEmpty)
    }

    func testLaterRelayFailureKeepsAcceptedReceiptAndNoRegistrationIsInventedOnRecovery() async throws {
        let (context, store, live, key) = try setup()
        let receipt = try commitAnswer(store, key: key)
        try store.recordAcceptedOperation(receipt.intentID, operationID: receipt.opID,
                                          terminalSequence: 2, context: context)
        try live.refreshFromDurableStore()
        live.applyRefreshResult(.unavailable)
        XCTAssertNotNil(live.connectionWarning)
        XCTAssertEqual(live.request(for: key)?.receiptFacts?.ownOutcome, .accepted)
        XCTAssertNil(live.actionError)

        let result = await NativeRelayRefreshResult.afterConfirmedRelay { .notAttempted }
        live.applyRefreshResult(result)
        XCTAssertNil(live.connectionWarning)
        XCTAssertEqual(result.pushRegistration, .notAttempted,
                       "A working relay alone cannot establish APNs registration.")
        XCTAssertEqual(live.request(for: key)?.receiptFacts?.ownOutcome, .accepted)
    }

    func testConfirmedNotificationSetupClearsItsWarningWithoutCreatingAnAnswer() async throws {
        let (context, store, live, key) = try setup()
        let refused = await NativeRelayRefreshResult.afterConfirmedRelay {
            throw InstallationTransportError.serverRejected
        }
        live.applyRefreshResult(refused)
        XCTAssertNotNil(live.pushRegistrationWarning)
        let registered = await NativeRelayRefreshResult.afterConfirmedRelay { .confirmed }
        live.applyRefreshResult(registered)
        XCTAssertEqual(registered.pushRegistration, .confirmed)
        XCTAssertNil(live.pushRegistrationWarning)
        XCTAssertNil(live.connectionWarning)
        XCTAssertEqual(live.request(for: key)?.lifecycleStatus, .open)
        XCTAssertTrue(try store.snapshot(context: context).intents.isEmpty)
    }
}

private final class AnswerSession: AuthenticatedInboxPagingSession, @unchecked Sendable {
    let authenticatedIdentity: ProfileIdentity
    var sentOperationIDs: [UUID] = []
    var acknowledgedCursors: [UInt64] = []
    var loseOperationReply = false
    var failReplayAfterSend = false

    init(_ identity: ProfileIdentity) { authenticatedIdentity = identity }

    func resync(_ request: Data, consume: @Sendable (Data) async throws -> Void) async throws {
        if !sentOperationIDs.isEmpty && failReplayAfterSend {
            throw InstallationTransportError.unexpectedServerFrame
        }
        try await consume(Data("{\"v\":1,\"type\":\"ok\",\"ref\":\"native-sync\"}\n".utf8))
        let since = try JSONValue.parse(request).uniqueValue(named: "since")
        if !sentOperationIDs.isEmpty {
            if case .number(let number)? = since, number.lexeme == "1" {
                try await consume(Data("{\"v\":1,\"type\":\"lifecycle\",\"seq\":2,\"sender_id\":\"sender\",\"message_id\":\"sample\",\"origin\":\"device\",\"state\":\"answered\",\"at\":1,\"answer\":\"got-it\"}\n".utf8))
            }
            try await consume(Data("{\"v\":1,\"type\":\"resynced\",\"seq\":2}\n".utf8))
        } else {
            try await consume(Data("{\"v\":1,\"type\":\"resynced\",\"seq\":1}\n".utf8))
        }
    }

    func acknowledge(_ request: Data) async throws {
        if case .number(let value)? = try JSONValue.parse(request).uniqueValue(named: "seq"),
           let sequence = UInt64(value.lexeme) { acknowledgedCursors.append(sequence) }
    }

    func sendOriginalOperation(_ frame: Data, operationID: UUID) async throws -> OriginalOperationResult {
        sentOperationIDs.append(operationID)
        return loseOperationReply ? .unresolved : .accepted(operationID: operationID, terminalSequence: 2)
    }
}
