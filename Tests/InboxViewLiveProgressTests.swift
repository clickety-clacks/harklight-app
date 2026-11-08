import AttentionDomain
import Foundation
import HarklightNativeRelay
import XCTest

/// Controls an allowed socket order: an ordinary event is queued before the
/// correlated view response. Advancing the event reader makes that response
/// available. The core must keep receiving while the view request waits.
private actor InboxViewProgressSession: AuthenticatedInboxEventStreamSession {
    nonisolated let authenticatedIdentity: ProfileIdentity
    nonisolated let supportsPostCheckpointInboxEvents = true
    private let acknowledged: XCTestExpectation
    private let viewReturned: XCTestExpectation
    private var armed = false
    private var stopped = false
    private var viewStarted = false
    private var deliveryTaken = false
    private var acknowledgementReported = false
    private var viewReturnReported = false
    private var queued: [Data] = []
    private var eventWaiter: CheckedContinuation<Data, any Error>?
    private var deliveryWaiter: CheckedContinuation<Data, any Error>?
    private var viewWaiter: CheckedContinuation<Void, any Error>?

    init(identity: ProfileIdentity, acknowledged: XCTestExpectation, viewReturned: XCTestExpectation) {
        authenticatedIdentity = identity
        self.acknowledged = acknowledged
        self.viewReturned = viewReturned
    }

    func resync(_ request: Data, consume: @Sendable (Data) async throws -> Void) async throws {
        try await consume(Data(#"{"v":1,"type":"resynced","seq":0}"#.utf8))
    }

    func inboxRequest(_ request: Data, ref: String) async throws -> Data {
        let value = try JSONValue.parse(request)
        guard value.uniqueValue(named: "type")?.stringValue?.rawValue == "view_get" else {
            return try await emptyInboxReply(request, ref: ref)
        }
        if armed {
            viewStarted = true
            deliveryWaiter?.resume(returning: delivery())
            deliveryWaiter = nil
            if !deliveryTaken {
                try await withCheckedThrowingContinuation { viewWaiter = $0 }
            }
            if !viewReturnReported {
                viewReturnReported = true
                viewReturned.fulfill()
            }
        }
        return Data(#"{"v":1,"type":"error","ref":"\#(ref)","reason":"temporarily_unavailable"}"#.utf8)
    }

    func acknowledge(_ request: Data) async throws {
        let value = try JSONValue.parse(request)
        if value.uniqueValue(named: "seq")?.integerValue == 1, !acknowledgementReported {
            acknowledgementReported = true
            acknowledged.fulfill()
        }
    }

    func sendOriginalOperation(_ frame: Data, operationID: UUID) async throws -> OriginalOperationResult {
        .unresolved
    }

    func nextPostCheckpointInboxEvent() async throws -> Data {
        if stopped { throw CancellationError() }
        if !queued.isEmpty { return queued.removeFirst() }
        if armed && !deliveryTaken {
            let frame: Data
            if viewStarted {
                frame = delivery()
            } else {
                frame = try await withCheckedThrowingContinuation { deliveryWaiter = $0 }
            }
            deliveryTaken = true
            viewWaiter?.resume()
            viewWaiter = nil
            return frame
        }
        return try await withCheckedThrowingContinuation { eventWaiter = $0 }
    }

    func publishNoticeBeforeDelivery() {
        armed = true
        let notice = Data(#"{"v":1,"type":"view_changed","view_rev":"changed"}"#.utf8)
        if let eventWaiter {
            self.eventWaiter = nil
            eventWaiter.resume(returning: notice)
        } else {
            queued.append(notice)
        }
    }

    func stop() {
        stopped = true
        eventWaiter?.resume(throwing: CancellationError())
        deliveryWaiter?.resume(throwing: CancellationError())
        viewWaiter?.resume(throwing: CancellationError())
        eventWaiter = nil
        deliveryWaiter = nil
        viewWaiter = nil
    }

    private func delivery() -> Data {
        Data(#"{"v":1,"type":"delivery","seq":1,"sender_id":"sender","message_id":"request","origin":"source","as":"message","message":{"title":"Progress fixture"}}"#.utf8)
    }
}

final class InboxViewLiveProgressTests: XCTestCase {
    func testLiveDeliveryProgressesWhileViewResponseWaitsForEventConsumption() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("reader"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let store = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        let acknowledged = expectation(description: "The live delivery is durably applied and acknowledged")
        let viewReturned = expectation(description: "The pending view response completes")
        let session = InboxViewProgressSession(identity: identity, acknowledged: acknowledged,
                                               viewReturned: viewReturned)
        let core = try NativeRelayCore(store: store, context: context, session: session)
        addTeardownBlock {
            await session.stop()
            await core.deactivate()
        }
        _ = try await core.resyncAndDrainOutbox()
        await session.publishNoticeBeforeDelivery()
        await fulfillment(of: [acknowledged, viewReturned], timeout: 2)

        let snapshot = try store.snapshot(context: context)
        XCTAssertEqual(snapshot.cursor, 1)
        let request = RequestKey(accountScope: identity.personID, senderID: ExactText("sender"),
                                 messageID: ExactText("request"))
        XCTAssertNotNil(snapshot.requests[request])
    }
}
