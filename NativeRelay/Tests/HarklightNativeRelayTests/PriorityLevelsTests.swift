import AttentionDomain
import Foundation
import XCTest
@testable import HarklightNativeRelay

private final class PriorityLevelsAsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var signaled = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if signaled {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func signal() {
        lock.lock()
        signaled = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

private final class PriorityLevelsUpdateCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

final class PriorityLevelsTests: XCTestCase {
    private final class Session: AuthenticatedInboxPagingSession, @unchecked Sendable {
        private let requestLock = NSLock()
        private let heldRequestStarted = PriorityLevelsAsyncSignal()
        private var holdNextRequest = false
        private var heldRequestContinuation: CheckedContinuation<Data, any Error>?
        let authenticatedIdentity: ProfileIdentity
        var requests: [(Data, String)] = []
        var responses: [Data] = []
        var failsNextRequest = false

        init(_ identity: ProfileIdentity) { authenticatedIdentity = identity }

        func resync(_ request: Data, consume: @Sendable (Data) async throws -> Void) async throws {}
        func acknowledge(_ request: Data) async throws {}
        func sendOriginalOperation(_ frame: Data, operationID: UUID) async throws -> OriginalOperationResult {
            .unresolved
        }
        func inboxRequest(_ request: Data, ref: String) async throws -> Data {
            requests.append((request, ref))
            let shouldHold = requestLock.withLock {
                let shouldHold = holdNextRequest
                holdNextRequest = false
                return shouldHold
            }
            if shouldHold {
                return try await withCheckedThrowingContinuation { continuation in
                    requestLock.lock()
                    heldRequestContinuation = continuation
                    requestLock.unlock()
                    heldRequestStarted.signal()
                }
            }
            if failsNextRequest {
                failsNextRequest = false
                throw InstallationTransportError.unexpectedServerFrame
            }
            guard !responses.isEmpty else { throw InstallationTransportError.unexpectedServerFrame }
            return responses.removeFirst()
        }
        func attachInboxReplay(_ request: Data, ref: String,
                              consume: @Sendable (Data) async throws -> Void) async throws {}

        func holdNextInboxRequest() {
            requestLock.lock()
            holdNextRequest = true
            requestLock.unlock()
        }

        func waitForHeldInboxRequest() async {
            await heldRequestStarted.wait()
        }

        func resumeHeldInboxRequest(with response: Data) {
            requestLock.lock()
            let continuation = heldRequestContinuation
            heldRequestContinuation = nil
            requestLock.unlock()
            continuation?.resume(returning: response)
        }
    }

    private struct Fixture {
        let context: ProfileContext
        let persistence: MemoryAttentionStatePersistence
        let store: AttentionDomainStore
    }

    private let routine = PriorityLevel(name: ExactText("Routine"), lowerBound: 0,
                                        bounceAfterDays: nil)
    private let followUp = PriorityLevel(name: ExactText("Follow up"), lowerBound: 0.6,
                                         bounceAfterDays: 1.5)

    private func fixture(personID: String = "account-a", deviceID: String = "phone-a") throws -> Fixture {
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText(personID),
            deviceID: ExactText(deviceID)), transportMode: .relay)
        let persistence = MemoryAttentionStatePersistence()
        let store = try AttentionDomainStore(context: context, persistence: persistence)
        return Fixture(context: context, persistence: persistence, store: store)
    }

    private func successSave(_ operation: PendingPriorityLevelsSave) -> Data {
        Data("""
        {"v":1,"type":"ok","ref":"native-priority-levels","op_id":"\(operation.operationID.uuidString.lowercased())","levels":[{"name":"Routine","lower_bound":0,"bounce_after_days":null},{"name":"Follow up","lower_bound":0.6,"bounce_after_days":1.5}]}
        """.utf8)
    }

    private func successRead(_ levels: String = #"[{"name":"Routine","lower_bound":0,"bounce_after_days":null},{"name":"Follow up","lower_bound":0.6,"bounce_after_days":1.5}]"#) -> Data {
        Data("""
        {"v":1,"type":"ok","ref":"native-priority-levels","levels":\(levels)}
        """.utf8)
    }

    func testTableValidationRequiresCompleteOrderedBoundsAndAllowsDisabledBounce() {
        let rows = [
            PriorityLevelDraftRow(name: "Routine", lowerBound: "0", bounceAfterDays: ""),
            PriorityLevelDraftRow(name: "Follow up", lowerBound: "0.6", bounceAfterDays: "1,5")
        ]
        XCTAssertEqual(PriorityLevelsTableValidation.levels(from: rows), [routine, followUp])

        XCTAssertNil(PriorityLevelsTableValidation.levels(from: []))
        XCTAssertNil(PriorityLevelsTableValidation.levels(from: [
            PriorityLevelDraftRow(name: "Follow up", lowerBound: "0.2", bounceAfterDays: "2")
        ]))
        XCTAssertNil(PriorityLevelsTableValidation.levels(from: [
            PriorityLevelDraftRow(name: "Routine", lowerBound: "0", bounceAfterDays: "0")
        ]))
        XCTAssertNil(PriorityLevelsTableValidation.levels(from: [
            PriorityLevelDraftRow(name: "   ", lowerBound: "0", bounceAfterDays: "")
        ]))
        XCTAssertNil(PriorityLevelsTableValidation.levels(from: [
            PriorityLevelDraftRow(name: "Routine", lowerBound: "1.01", bounceAfterDays: "")
        ]))
        XCTAssertNil(PriorityLevelsTableValidation.levels(from: [
            PriorityLevelDraftRow(name: "Routine", lowerBound: "0", bounceAfterDays: "infinity")
        ]))
        XCTAssertNil(PriorityLevelsTableValidation.levels(from: [
            PriorityLevelDraftRow(name: "Routine", lowerBound: "0", bounceAfterDays: ""),
            PriorityLevelDraftRow(name: "Repeated", lowerBound: "0", bounceAfterDays: "1")
        ]))
        XCTAssertNil(PriorityLevelsTableValidation.message(for: rows))
        XCTAssertNil(PriorityLevelsTableValidation.message(for: [
            PriorityLevelDraftRow(name: "Routine", lowerBound: "0", bounceAfterDays: ""),
            PriorityLevelDraftRow(name: "Follow up", lowerBound: "0.6", bounceAfterDays: "1.5")
        ]))
    }

    func testWireUsesBoundGetAndSetEnvelopesAndRequiresExactDurableConfirmation() throws {
        let fixture = try fixture()
        try fixture.store.savePriorityLevelsDraft([
            PriorityLevelDraftRow(name: "Routine", lowerBound: "0", bounceAfterDays: ""),
            PriorityLevelDraftRow(name: "Follow up", lowerBound: "0.6", bounceAfterDays: "1.5")
        ], context: fixture.context)
        let operation = try fixture.store.beginPriorityLevelsSave([routine, followUp], context: fixture.context)
        let wire = PriorityLevelsWire()

        let get = try JSONValue.parse(wire.getRequest())
        XCTAssertTrue(get.hasExactlyKeys(["v", "type", "ref"]))
        XCTAssertEqual(get.uniqueValue(named: "type")?.stringValue, ExactText("levels_get"))
        XCTAssertEqual(get.uniqueValue(named: "ref")?.stringValue?.rawValue, PriorityLevelsWire.requestRef)

        let set = try JSONValue.parse(wire.setRequest(for: operation))
        XCTAssertTrue(set.hasExactlyKeys(["v", "type", "ref", "op_id", "levels"]))
        XCTAssertEqual(set.uniqueValue(named: "type")?.stringValue, ExactText("levels_set"))
        XCTAssertEqual(set.uniqueValue(named: "op_id")?.stringValue?.rawValue,
                       operation.operationID.uuidString.lowercased())
        XCTAssertEqual(set.uniqueValue(named: "levels")?.arrayValues?.count, 2)
        XCTAssertEqual(wire.decodeGetResult(Data(#"{"v":1,"type":"ok","ref":"native-priority-levels","levels":[]}"#.utf8)),
                       .confirmed([]))
        XCTAssertEqual(wire.decodeGetResult(successRead()), .confirmed([routine, followUp]))
        XCTAssertEqual(wire.decodeSetResult(successSave(operation), for: operation),
                       .confirmed([routine, followUp]))
        XCTAssertEqual(wire.decodeSetResult(Data("""
        {"v":1,"type":"error","ref":"native-priority-levels","op_id":"\(operation.operationID.uuidString.lowercased())","reason":"operation_conflict"}
        """.utf8), for: operation), .unresolved)

        let wrongOperation = Data("""
        {"v":1,"type":"ok","ref":"native-priority-levels","op_id":"00000000-0000-4000-8000-000000000000","levels":[{"name":"Routine","lower_bound":0,"bounce_after_days":null},{"name":"Follow up","lower_bound":0.6,"bounce_after_days":1.5}]}
        """.utf8)
        XCTAssertEqual(wire.decodeSetResult(wrongOperation, for: operation), .unresolved)
        XCTAssertEqual(wire.decodeGetResult(Data(#"{"v":1,"type":"error","ref":"native-priority-levels","reason":"unknown_type"}"#.utf8)),
                       .unsupported)
        XCTAssertEqual(wire.decodeGetResult(Data(#"{"v":1,"type":"error","ref":"native-priority-levels","reason":"storage_unavailable"}"#.utf8)),
                       .unresolved)
        XCTAssertTrue(PriorityLevelsWire.isChangedHint(Data(#"{"v":1,"type":"levels_changed"}"#.utf8)))
        XCTAssertFalse(PriorityLevelsWire.isChangedHint(Data(#"{"v":1,"type":"levels_changed","conversation_seq":4}"#.utf8)))
    }

    func testPendingSaveAndLaterDraftSurviveRelaunchWithoutChangingSubmittedOperation() throws {
        let fixture = try fixture()
        try fixture.store.markPriorityLevelsEditorOpened(context: fixture.context)
        try fixture.store.savePriorityLevelsDraft([
            PriorityLevelDraftRow(name: "Routine", lowerBound: "0", bounceAfterDays: ""),
            PriorityLevelDraftRow(name: "Follow up", lowerBound: "0.6", bounceAfterDays: "1.5")
        ], context: fixture.context)
        let operation = try fixture.store.beginPriorityLevelsSave([routine, followUp], context: fixture.context)

        let laterDraft = [
            PriorityLevelDraftRow(name: "Routine", lowerBound: "0", bounceAfterDays: ""),
            PriorityLevelDraftRow(name: "Later", lowerBound: "0.7", bounceAfterDays: "3")
        ]
        try fixture.store.savePriorityLevelsDraft(laterDraft, context: fixture.context)

        let relaunched = try AttentionDomainStore(context: fixture.context, persistence: fixture.persistence)
        let recovered = try relaunched.snapshot(context: fixture.context).priorityLevels
        XCTAssertEqual(recovered.pendingSave, operation)
        XCTAssertEqual(recovered.pendingSave?.levels, [routine, followUp])
        XCTAssertEqual(recovered.draftRows, laterDraft)

        XCTAssertTrue(try relaunched.confirmPriorityLevelsSave(operation.operationID,
                                                                levels: [routine, followUp],
                                                                context: fixture.context))
        let afterConfirmation = try relaunched.snapshot(context: fixture.context).priorityLevels
        XCTAssertNil(afterConfirmation.pendingSave)
        XCTAssertEqual(afterConfirmation.confirmedLevels, [routine, followUp])
        XCTAssertEqual(afterConfirmation.draftRows, laterDraft)
    }

    func testPriorityTablesArePersistedUnderTheirOriginalAccount() throws {
        let persistence = MemoryAttentionStatePersistence()
        let firstContext = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("relay.example"), personID: ExactText("account-a"),
            deviceID: ExactText("phone-a")), transportMode: .relay)
        let otherContext = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("relay.example"), personID: ExactText("account-b"),
            deviceID: ExactText("phone-b")), transportMode: .relay)
        let firstStore = try AttentionDomainStore(context: firstContext, persistence: persistence)
        let otherStore = try AttentionDomainStore(context: otherContext, persistence: persistence)
        try firstStore.recordPriorityLevelsRead([routine], context: firstContext)

        XCTAssertEqual(try firstStore.snapshot(context: firstContext).priorityLevels.confirmedLevels, [routine])
        XCTAssertNil(try otherStore.snapshot(context: otherContext).priorityLevels.confirmedLevels)
    }

    func testRepeatedReadKeepsTheSameDraftRowIdentities() async throws {
        let fixture = try fixture()
        let session = Session(fixture.context.identity)
        session.responses = [successRead(), successRead()]
        let core = try NativeRelayCore(store: fixture.store, context: fixture.context, session: session)

        await core.refreshPriorityLevels()
        let firstIDs = try XCTUnwrap(fixture.store.snapshot(context: fixture.context)
            .priorityLevels.draftRows?.map(\.id))

        await core.refreshPriorityLevels()
        let secondIDs = try XCTUnwrap(fixture.store.snapshot(context: fixture.context)
            .priorityLevels.draftRows?.map(\.id))

        XCTAssertEqual(secondIDs, firstIDs)
    }

    func testUnconfirmedSaveRetriesSameOperationAndExactTableAfterReconnect() async throws {
        let fixture = try fixture()
        try fixture.store.markPriorityLevelsEditorOpened(context: fixture.context)
        try fixture.store.savePriorityLevelsDraft([
            PriorityLevelDraftRow(name: "Routine", lowerBound: "0", bounceAfterDays: ""),
            PriorityLevelDraftRow(name: "Follow up", lowerBound: "0.6", bounceAfterDays: "1.5")
        ], context: fixture.context)
        let operation = try fixture.store.beginPriorityLevelsSave([routine, followUp], context: fixture.context)
        let session = Session(fixture.context.identity)
        session.failsNextRequest = true
        let connectionLosses = PriorityLevelsUpdateCounter()
        let core = try NativeRelayCore(store: fixture.store, context: fixture.context, session: session,
                                       onPriorityLevelsConnectionLost: { connectionLosses.increment() })

        await core.sendPendingPriorityLevelsSave()
        XCTAssertEqual(try fixture.store.snapshot(context: fixture.context).priorityLevels.pendingSave,
                       operation)
        XCTAssertEqual(connectionLosses.value, 1)
        await core.sendPendingPriorityLevelsSave()
        XCTAssertEqual(session.requests.count, 1)
        XCTAssertEqual(connectionLosses.value, 1)

        let reconnectSession = Session(fixture.context.identity)
        reconnectSession.responses = [successSave(operation), successRead()]
        let reconnectCore = try NativeRelayCore(store: fixture.store, context: fixture.context,
                                                session: reconnectSession)
        await reconnectCore.sendPendingPriorityLevelsSave()
        let state = try fixture.store.snapshot(context: fixture.context).priorityLevels
        XCTAssertNil(state.pendingSave)
        XCTAssertEqual(state.confirmedLevels, [routine, followUp])
        XCTAssertEqual(session.requests.count, 1)
        XCTAssertEqual(reconnectSession.requests.count, 2)
        XCTAssertEqual(connectionLosses.value, 1)

        let firstAttempt = try JSONValue.parse(session.requests[0].0)
        let retry = try JSONValue.parse(reconnectSession.requests[0].0)
        XCTAssertEqual(firstAttempt.uniqueValue(named: "op_id")?.stringValue?.rawValue,
                       operation.operationID.uuidString.lowercased())
        XCTAssertEqual(retry.uniqueValue(named: "op_id")?.stringValue?.rawValue,
                       operation.operationID.uuidString.lowercased())
        XCTAssertEqual(firstAttempt.uniqueValue(named: "levels"), retry.uniqueValue(named: "levels"))
        XCTAssertEqual(session.requests.map { $0.1 }, [PriorityLevelsWire.requestRef])
        XCTAssertEqual(reconnectSession.requests.map { $0.1 },
                       Array(repeating: PriorityLevelsWire.requestRef, count: 2))
        XCTAssertEqual(try JSONValue.parse(reconnectSession.requests[1].0).uniqueValue(named: "type")?.stringValue,
                       ExactText("levels_get"))
    }

    func testUnknownServerLeavesPendingSaveAndDoesNotRetryOnSameConnection() async throws {
        let fixture = try fixture()
        try fixture.store.savePriorityLevelsDraft([
            PriorityLevelDraftRow(name: "Routine", lowerBound: "0", bounceAfterDays: ""),
            PriorityLevelDraftRow(name: "Follow up", lowerBound: "0.6", bounceAfterDays: "1.5")
        ], context: fixture.context)
        let operation = try fixture.store.beginPriorityLevelsSave([routine, followUp], context: fixture.context)
        let session = Session(fixture.context.identity)
        session.responses = [Data(#"{"v":1,"type":"error","ref":"native-priority-levels","reason":"unknown_type"}"#.utf8)]
        let core = try NativeRelayCore(store: fixture.store, context: fixture.context, session: session)

        await core.sendPendingPriorityLevelsSave()
        await core.sendPendingPriorityLevelsSave()

        let state = try fixture.store.snapshot(context: fixture.context).priorityLevels
        XCTAssertEqual(state.pendingSave, operation)
        XCTAssertEqual(state.failureReason, "unknown_type")
        XCTAssertEqual(session.requests.count, 1)
    }

    func testOperationConflictRejectsOnlyThatSaveAndKeepsDraftForNewOperation() async throws {
        let fixture = try fixture()
        try fixture.store.markPriorityLevelsEditorOpened(context: fixture.context)
        let draft = [
            PriorityLevelDraftRow(name: "Routine", lowerBound: "0", bounceAfterDays: ""),
            PriorityLevelDraftRow(name: "Follow up", lowerBound: "0.6", bounceAfterDays: "1.5")
        ]
        try fixture.store.savePriorityLevelsDraft(draft, context: fixture.context)
        let operation = try fixture.store.beginPriorityLevelsSave([routine, followUp], context: fixture.context)
        let session = Session(fixture.context.identity)
        session.responses = [Data("""
        {"v":1,"type":"error","ref":"native-priority-levels","reason":"operation_conflict"}
        """.utf8), successRead()]
        let core = try NativeRelayCore(store: fixture.store, context: fixture.context, session: session)

        await core.sendPendingPriorityLevelsSave()

        let rejected = try fixture.store.snapshot(context: fixture.context).priorityLevels
        XCTAssertNil(rejected.pendingSave)
        XCTAssertEqual(rejected.failureReason, "operation_conflict")
        XCTAssertEqual(rejected.draftRows, draft)
        XCTAssertEqual(rejected.confirmedLevels, [routine, followUp])
        XCTAssertEqual(session.requests.count, 2)
        let correctedOperation = try fixture.store.beginPriorityLevelsSave([routine, followUp],
                                                                           context: fixture.context)
        XCTAssertNotEqual(correctedOperation.operationID, operation.operationID)
        XCTAssertEqual(correctedOperation.levels, operation.levels)
    }

    func testInvalidFieldRejectionSurvivesCurrentTableRefresh() async throws {
        let fixture = try fixture()
        try fixture.store.markPriorityLevelsEditorOpened(context: fixture.context)
        let draft = [
            PriorityLevelDraftRow(name: "Routine", lowerBound: "0", bounceAfterDays: ""),
            PriorityLevelDraftRow(name: "Follow up", lowerBound: "0.6", bounceAfterDays: "1.5")
        ]
        try fixture.store.savePriorityLevelsDraft(draft, context: fixture.context)
        let operation = try fixture.store.beginPriorityLevelsSave([routine, followUp], context: fixture.context)
        let session = Session(fixture.context.identity)
        session.responses = [Data("""
        {"v":1,"type":"error","ref":"native-priority-levels","reason":"invalid_field","field":"levels"}
        """.utf8), successRead()]
        let core = try NativeRelayCore(store: fixture.store, context: fixture.context, session: session)

        await core.sendPendingPriorityLevelsSave()

        let rejected = try fixture.store.snapshot(context: fixture.context).priorityLevels
        XCTAssertNil(rejected.pendingSave)
        XCTAssertEqual(rejected.failureReason, "invalid_field")
        XCTAssertEqual(rejected.draftRows, draft)
        XCTAssertEqual(rejected.confirmedLevels, [routine, followUp])
        XCTAssertEqual(session.requests.count, 2)
    }

    func testReadRefreshDoesNotSubmitAPersistedPendingSave() async throws {
        let fixture = try fixture()
        try fixture.store.markPriorityLevelsEditorOpened(context: fixture.context)
        try fixture.store.savePriorityLevelsDraft([
            PriorityLevelDraftRow(name: "Routine", lowerBound: "0", bounceAfterDays: ""),
            PriorityLevelDraftRow(name: "Follow up", lowerBound: "0.6", bounceAfterDays: "1.5")
        ], context: fixture.context)
        let operation = try fixture.store.beginPriorityLevelsSave([routine, followUp], context: fixture.context)
        let session = Session(fixture.context.identity)
        session.responses = [successRead()]
        let core = try NativeRelayCore(store: fixture.store, context: fixture.context, session: session)

        await core.refreshPriorityLevels()

        XCTAssertEqual(session.requests.count, 1)
        XCTAssertEqual(try JSONValue.parse(session.requests[0].0).uniqueValue(named: "type")?.stringValue,
                       ExactText("levels_get"))
        let state = try fixture.store.snapshot(context: fixture.context).priorityLevels
        XCTAssertEqual(state.pendingSave, operation)
        XCTAssertEqual(state.confirmedLevels, [routine, followUp])
    }

    func testRefreshUpdatesUnchangedDraftAndPreservesUnsubmittedEdits() async throws {
        let fixture = try fixture()
        let session = Session(fixture.context.identity)
        session.responses = [successRead(), successRead(#"[{"name":"Routine","lower_bound":0,"bounce_after_days":null},{"name":"Later","lower_bound":0.7,"bounce_after_days":3}]"#),
                             successRead(#"[{"name":"Routine","lower_bound":0,"bounce_after_days":null},{"name":"Latest","lower_bound":0.8,"bounce_after_days":2}]"#)]
        let core = try NativeRelayCore(store: fixture.store, context: fixture.context, session: session)

        await core.refreshPriorityLevels()
        await core.refreshPriorityLevels()

        var state = try fixture.store.snapshot(context: fixture.context).priorityLevels
        XCTAssertEqual(state.confirmedLevels, [routine, PriorityLevel(name: ExactText("Later"), lowerBound: 0.7,
                                                                       bounceAfterDays: 3)])
        XCTAssertEqual(PriorityLevelsTableValidation.levels(from: state.displayedRows), state.confirmedLevels)

        let localDraft = [
            PriorityLevelDraftRow(name: "Routine", lowerBound: "0", bounceAfterDays: ""),
            PriorityLevelDraftRow(name: "My local edit", lowerBound: "0.9", bounceAfterDays: "4")
        ]
        try fixture.store.savePriorityLevelsDraft(localDraft, context: fixture.context)
        await core.refreshPriorityLevels()

        state = try fixture.store.snapshot(context: fixture.context).priorityLevels
        XCTAssertEqual(state.confirmedLevels, [routine, PriorityLevel(name: ExactText("Latest"), lowerBound: 0.8,
                                                                        bounceAfterDays: 2)])
        XCTAssertEqual(state.draftRows, localDraft)
    }

    func testRefreshRequestedDuringOutstandingReadRunsAnotherRead() async throws {
        let fixture = try fixture()
        let session = Session(fixture.context.identity)
        session.responses = [successRead(), successRead()]
        session.holdNextInboxRequest()
        let core = try NativeRelayCore(store: fixture.store, context: fixture.context, session: session)
        let requestStarted = Task { await session.waitForHeldInboxRequest() }
        let firstRefresh = Task { await core.refreshPriorityLevels() }

        await requestStarted.value
        await core.refreshPriorityLevels()
        session.resumeHeldInboxRequest(with: successRead())
        await firstRefresh.value

        XCTAssertEqual(session.requests.count, 2)
        XCTAssertTrue(session.requests.allSatisfy {
            (try? JSONValue.parse($0.0).uniqueValue(named: "type")?.stringValue) == ExactText("levels_get")
        })
    }

    func testConfirmedReadNotifiesTheOpenEditorProjection() async throws {
        let fixture = try fixture()
        let session = Session(fixture.context.identity)
        session.responses = [successRead()]
        let updates = PriorityLevelsUpdateCounter()
        let core = try NativeRelayCore(store: fixture.store, context: fixture.context, session: session,
                                       onPriorityLevelsChanged: { updates.increment() })

        await core.refreshPriorityLevels()

        XCTAssertEqual(try fixture.store.snapshot(context: fixture.context).priorityLevels.confirmedLevels,
                       [routine, followUp])
        XCTAssertEqual(updates.value, 1)
    }
}
