import AttentionDomain
import Foundation
import HarklightNativeRelay
import XCTest

private final class DiagnosticEventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [NativeClientDiagnosticEvent] = []

    func append(_ event: NativeClientDiagnosticEvent) {
        lock.lock(); defer { lock.unlock() }
        storage.append(event)
    }

    var events: [NativeClientDiagnosticEvent] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

final class NativeRelayCoreTests: XCTestCase {
    private final class Session: AuthenticatedInboxEventStreamSession, @unchecked Sendable {
        var authenticatedIdentity: ProfileIdentity
        var supportsPostCheckpointInboxEvents = false
        var frames: [Data] = []
        var requests: [Data] = []
        var acknowledgements: [Data] = []
        var sent: [(Data, UUID)] = []
        var result: OriginalOperationResult = .unresolved
        var replayFrames: [[Data]] = []
        var snapshotHighWater: UInt64?
        var initialItems: [JSONValue] = []
        var nextItemCursor: String?
        var olderPages: [String: [JSONValue]] = [:]
        var checkpointWasAccepted = false
        var reconciliationOverrides: [UUID: JSONValue] = [:]
        var postCheckpointEvents: [Data] = []
        var postCheckpointEventAfterAccept: Data?
        private var activeSnapshotID = "snapshot-test"
        private var activeSnapshotHighWater: UInt64 = 0
        var rejectFirstAcknowledgement = false
        var interruptAfterFrames: Int?
        var resyncFailureOnCall: Int?
        var resyncFailure: Error = InstallationTransportError.unexpectedServerFrame
        private(set) var replayCallCount = 0

        init(_ identity: ProfileIdentity) { authenticatedIdentity = identity }

        func inboxRequest(_ request: Data, ref: String) async throws -> Data {
            requests.append(request)
            let value = try JSONValue.parse(request)
            let type = value.uniqueValue(named: "type")?.stringValue?.rawValue
            let snapshotID = value.uniqueValue(named: "snapshot_id")?.stringValue?.rawValue ?? "snapshot-test"
            let highWater = snapshotHighWater ?? uint64(value.uniqueValue(named: "since")) ?? 0
            switch type {
            case "inbox_start":
                activeSnapshotID = snapshotID
                activeSnapshotHighWater = highWater
                return response([
                    ("v", .number(JSONNumber(lexeme: "1"))), ("type", .string(ExactText("ok"))),
                    ("ref", .string(ExactText(ref))), ("paging_version", .number(JSONNumber(lexeme: "1"))),
                    ("snapshot_id", .string(ExactText(snapshotID))),
                    ("high_water", .number(JSONNumber(lexeme: String(highWater)))),
                    ("items", .array(initialItems)),
                    ("next_cursor", nextItemCursor.map { .string(ExactText($0)) } ?? .null),
                    ("receipt_cursor", .null)
                ])
            case "inbox_page":
                let cursor = value.uniqueValue(named: "cursor")?.stringValue?.rawValue ?? ""
                let items = olderPages[cursor] ?? []
                return response([
                    ("v", .number(JSONNumber(lexeme: "1"))), ("type", .string(ExactText("ok"))),
                    ("ref", .string(ExactText(ref))), ("paging_version", .number(JSONNumber(lexeme: "1"))),
                    ("snapshot_id", .string(ExactText(snapshotID))),
                    ("high_water", .number(JSONNumber(lexeme: String(activeSnapshotHighWater)))),
                    ("items", .array(items)), ("next_cursor", .null)
                ])
            case "inbox_reconcile":
                let operations = value.uniqueValue(named: "operations")?.arrayValues ?? []
                let results: [JSONValue] = operations.compactMap { operation in
                    guard let opIDText = operation.uniqueValue(named: "op_id")?.stringValue?.rawValue,
                          let opID = UUID(uuidString: opIDText) else { return nil }
                    if let override = reconciliationOverrides[opID] { return override }
                    return .object([
                        JSONMember("op_id", .string(ExactText(opIDText))),
                        JSONMember("status", .string(ExactText("not_committed_at_snapshot")))
                    ])
                }
                let batchID = value.uniqueValue(named: "batch_id")?.stringValue?.rawValue ?? "batch-test"
                return response([
                    ("v", .number(JSONNumber(lexeme: "1"))), ("type", .string(ExactText("ok"))),
                    ("ref", .string(ExactText(ref))), ("paging_version", .number(JSONNumber(lexeme: "1"))),
                    ("snapshot_id", .string(ExactText(snapshotID))),
                    ("high_water", .number(JSONNumber(lexeme: String(activeSnapshotHighWater)))),
                    ("batch_id", .string(ExactText(batchID))), ("results", .array(results))
                ])
            case "inbox_receipts":
                return response([
                    ("v", .number(JSONNumber(lexeme: "1"))), ("type", .string(ExactText("ok"))),
                    ("ref", .string(ExactText(ref))), ("paging_version", .number(JSONNumber(lexeme: "1"))),
                    ("snapshot_id", .string(ExactText(snapshotID))),
                    ("high_water", .number(JSONNumber(lexeme: String(snapshotHighWater ?? 0)))),
                    ("events", .array([])), ("next_cursor", .null)
                ])
            case "inbox_checkpoint_ack":
                checkpointWasAccepted = true
                let acceptedHigh = uint64(value.uniqueValue(named: "high_water")) ?? 0
                return response([
                    ("v", .number(JSONNumber(lexeme: "1"))), ("type", .string(ExactText("ok"))),
                    ("ref", .string(ExactText(ref))), ("paging_version", .number(JSONNumber(lexeme: "1"))),
                    ("snapshot_id", .string(ExactText(snapshotID))),
                    ("high_water", .number(JSONNumber(lexeme: String(acceptedHigh)))),
                    ("checkpoint_accepted", .bool(true))
                ])
            case "inbox_attach":
                if value.uniqueValue(named: "mode")?.stringValue?.rawValue == "checkpoint_status" {
                    return response([
                        ("v", .number(JSONNumber(lexeme: "1"))), ("type", .string(ExactText("ok"))),
                        ("ref", .string(ExactText(ref))), ("paging_version", .number(JSONNumber(lexeme: "1"))),
                        ("snapshot_id", .string(ExactText(snapshotID))),
                        ("high_water", .number(JSONNumber(lexeme: String(activeSnapshotHighWater)))),
                        ("checkpoint_accepted", .bool(checkpointWasAccepted)),
                        ("replay_started", .bool(false))
                    ])
                }
                throw InstallationTransportError.unexpectedServerFrame
            default:
                throw InstallationTransportError.unexpectedServerFrame
            }
        }

        func attachInboxReplay(_ request: Data, ref: String,
                               consume: @Sendable (Data) async throws -> Void) async throws {
            requests.append(request)
            replayCallCount += 1
            if resyncFailureOnCall == replayCallCount { throw resyncFailure }
            let requestValue = try JSONValue.parse(request)
            let since = uint64(requestValue.uniqueValue(named: "since")) ?? 0
            let selected = !replayFrames.isEmpty ? replayFrames.removeFirst() : frames
            let replayEnd = selected.compactMap { frame -> Data? in
                guard let value = try? JSONValue.parse(frame),
                      value.uniqueValue(named: "type")?.stringValue?.rawValue == "resynced" else { return nil }
                return frame
            }.last
            let endHigh = replayEnd.flatMap { try? JSONValue.parse($0) }
                .flatMap { uint64($0.uniqueValue(named: "seq")) } ?? since
            let accepted = response([
                ("v", .number(JSONNumber(lexeme: "1"))), ("type", .string(ExactText("ok"))),
                ("ref", .string(ExactText(ref))), ("paging_version", .number(JSONNumber(lexeme: "1"))),
                ("snapshot_id", .string(ExactText(activeSnapshotID))),
                ("high_water", .number(JSONNumber(lexeme: String(activeSnapshotHighWater)))),
                ("checkpoint_accepted", .bool(true)), ("replay_started", .bool(true))
            ])
            var delivered = 0
            for frame in [accepted] + selected.filter({
                guard let value = try? JSONValue.parse($0),
                      let type = value.uniqueValue(named: "type")?.stringValue?.rawValue else { return false }
                return type == "delivery" || type == "lifecycle" || type == "resynced"
            }).filter({
                guard let value = try? JSONValue.parse($0),
                      value.uniqueValue(named: "type")?.stringValue?.rawValue == "resynced" else {
                    guard let value = try? JSONValue.parse($0) else { return true }
                    return (uint64(value.uniqueValue(named: "seq")) ?? 0) > since
                }
                return true
            }) {
                if delivered == interruptAfterFrames {
                    throw InstallationTransportError.unexpectedServerFrame
                }
                try await consume(frame)
                delivered += 1
            }
            if replayEnd == nil {
                try await consume(data(#"{"v":1,"type":"resynced","seq":\#(endHigh)}"#))
            }
        }

        func resync(_ request: Data,
                    consume: @Sendable (Data) async throws -> Void) async throws {
            requests.append(request)
            if resyncFailureOnCall == requests.count { throw resyncFailure }
            let selected = !replayFrames.isEmpty ? replayFrames.removeFirst() : frames
            for (index, frame) in selected.enumerated() {
                if index == interruptAfterFrames {
                    throw InstallationTransportError.unexpectedServerFrame
                }
                try await consume(frame)
            }
        }
        func acknowledge(_ request: Data) async throws {
            acknowledgements.append(request)
            if rejectFirstAcknowledgement {
                rejectFirstAcknowledgement = false
                throw InstallationTransportError.acknowledgementBehind
            }
        }
        func takePostCheckpointInboxEvents(through sequence: UInt64?,
                                           waitForTarget: Bool) async throws -> [Data] {
            if waitForTarget, let sequence,
               !postCheckpointEvents.contains(where: { eventSequence($0).map { $0 >= sequence } ?? false }) {
                throw InstallationTransportError.unexpectedServerFrame
            }
            guard let sequence else {
                let events = postCheckpointEvents
                postCheckpointEvents.removeAll()
                return events
            }
            var selected: [Data] = []
            var remaining: [Data] = []
            for frame in postCheckpointEvents {
                if let eventSequence = eventSequence(frame), eventSequence <= sequence {
                    selected.append(frame)
                } else {
                    remaining.append(frame)
                }
            }
            postCheckpointEvents = remaining
            return selected
        }
        func sendOriginalOperation(_ frame: Data, operationID: UUID) async throws -> OriginalOperationResult {
            sent.append((frame, operationID))
            if case .accepted = result, let postCheckpointEventAfterAccept {
                postCheckpointEvents.append(postCheckpointEventAfterAccept)
            }
            return result
        }

        private func response(_ members: [(String, JSONValue)]) -> Data {
            let value = JSONValue.object(members.map { JSONMember($0.0, $0.1) })
            return Data((value.jsonString + "\n").utf8)
        }

        private func uint64(_ value: JSONValue?) -> UInt64? {
            guard let value, case let .number(number) = value else { return nil }
            return UInt64(number.lexeme)
        }

        private func eventSequence(_ frame: Data) -> UInt64? {
            guard let value = try? JSONValue.parse(frame) else { return nil }
            return uint64(value.uniqueValue(named: "seq"))
        }
    }

    private func data(_ text: String) -> Data { Data((text + "\n").utf8) }

    private func setup() throws -> (ProfileContext, AttentionDomainStore, Session) {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person-A"),
                                       deviceID: ExactText("installation-A"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        return (context,
                try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence()),
                Session(identity))
    }

    func testForeignDeliveryAndTerminalCommitBeforeOneContiguousACK() async throws {
        let (context, store, session) = try setup()
        let message = "{\"answer_ui\":null,\"title\":\"Hello\"}"
        session.frames = [
            data(#"{"v":1,"type":"ok","ref":"native-sync"}"#),
            data(#"{"v":1,"type":"delivery","seq":1,"sender_id":"sender","message_id":"m1","origin":"other-installation","as":"message","message":\#(message)}"#),
            data(#"{"v":1,"type":"lifecycle","seq":2,"sender_id":"sender","message_id":"m1","origin":"other-installation","state":"answered","at":1}"#),
            data(#"{"v":1,"type":"resynced","seq":2}"#)
        ]
        let core = try NativeRelayCore(store: store, context: context, session: session)
        let high = try await core.resyncAndDrainOutbox()
        XCTAssertEqual(high, 2)
        XCTAssertEqual(try store.snapshot(context: context).cursor, 2)
        let key = RequestKey(accountScope: context.identity.personID,
                             senderID: ExactText("sender"), messageID: ExactText("m1"))
        XCTAssertEqual(try store.snapshot(context: context).remoteStates[key]?.state, .answered)
        XCTAssertEqual(String(decoding: try XCTUnwrap(session.acknowledgements.first), as: UTF8.self),
                       #"{"v":1,"type":"ack","seq":2,"ref":"native-ack"}"# + "\n")
    }

    func testStartupCapsCombinedItemsAndOnlyScrollFetchesStableNextPage() async throws {
        let (context, store, session) = try setup()
        session.snapshotHighWater = 25
        session.nextItemCursor = "cursor-20"
        session.frames = [data(#"{"v":1,"type":"resynced","seq":25}"#)]

        func pageItem(_ sequence: Int) throws -> JSONValue {
            let acceptance = try JSONValue.parse(data(#"{"v":1,"type":"delivery","seq":\#(sequence),"sender_id":"sender","message_id":"m\#(sequence)","origin":"source-device","as":"message","message":{"title":"Message \#(sequence)"}}"#))
            return .object([JSONMember("acceptance", acceptance)])
        }
        session.initialItems = try (1...20).map(pageItem)
        session.olderPages["cursor-20"] = [try pageItem(21)]

        let core = try NativeRelayCore(store: store, context: context, session: session)
        let high = try await core.resyncAndDrainOutbox()
        XCTAssertEqual(high, 25)

        let afterStartup = try store.snapshot(context: context)
        XCTAssertEqual(afterStartup.requests.count, 20)
        XCTAssertEqual(afterStartup.cursor, 25)
        XCTAssertEqual(afterStartup.inboxCheckpoint?.loadedKeys.count, 20)
        XCTAssertEqual(afterStartup.inboxCurrentKeys?.count, 20)
        XCTAssertTrue(afterStartup.outbox.isEmpty)
        XCTAssertTrue(afterStartup.intents.isEmpty)
        let startupTypes = try session.requests.map(JSONValue.parse).compactMap {
            $0.uniqueValue(named: "type")?.stringValue?.rawValue
        }
        XCTAssertEqual(startupTypes, ["inbox_start", "inbox_checkpoint_ack", "inbox_attach"])
        let checkpoint = try XCTUnwrap(try session.requests.map(JSONValue.parse).first {
            $0.uniqueValue(named: "type")?.stringValue?.rawValue == "inbox_checkpoint_ack"
        })
        XCTAssertEqual(checkpoint.uniqueValue(named: "pending_manifest_complete"), .bool(true))
        XCTAssertEqual(checkpoint.uniqueValue(named: "reconciled_batches"), .array([]))
        XCTAssertTrue(session.acknowledgements.isEmpty,
                      "An empty H+1 replay has no ordinary event cursor to ACK.")

        let fetched = try await core.fetchNextInboxPage()
        XCTAssertTrue(fetched)
        let afterScroll = try store.snapshot(context: context)
        XCTAssertEqual(afterScroll.requests.count, 21)
        XCTAssertEqual(afterScroll.cursor, 25, "A page read cannot advance the event ACK cursor.")
        XCTAssertEqual(afterScroll.inboxCheckpoint?.loadedKeys.count, 21)
        XCTAssertEqual(afterScroll.inboxCurrentKeys?.count, 21)
        XCTAssertEqual(try session.requests.map(JSONValue.parse).compactMap {
            $0.uniqueValue(named: "type")?.stringValue?.rawValue
        }, ["inbox_start", "inbox_checkpoint_ack", "inbox_attach", "inbox_page"])
    }

    func testCheckpointMarksCachedRowsUnrefreshedUntilTheirStablePageArrives() async throws {
        let (context, store, session) = try setup()
        let payload = try JSONValue.parse(Data(#"{"title":"Prompt","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"yes","label":"Yes","kind":"value","value":{"ok":true}}]}}"#.utf8))
        func key(_ sequence: Int) -> RequestKey {
            RequestKey(accountScope: context.identity.personID,
                       senderID: ExactText("sender"), messageID: ExactText("m\(sequence)"))
        }
        func pageItem(_ sequence: Int) throws -> JSONValue {
            let acceptance = try JSONValue.parse(data(#"{"v":1,"type":"delivery","seq":\#(sequence),"sender_id":"sender","message_id":"m\#(sequence)","origin":"source-device","as":"message","message":\#(payload.jsonString)}"#))
            return .object([JSONMember("acceptance", acceptance)])
        }

        for sequence in 1...21 {
            _ = try store.apply(RelayEvent(sequence: UInt64(sequence),
                body: .delivery(StoredRequest(key: key(sequence), originalPayload: payload), .message)),
                context: context)
        }
        session.snapshotHighWater = 21
        session.nextItemCursor = "cursor-20"
        session.initialItems = try (1...20).map(pageItem)
        session.olderPages["cursor-20"] = [try pageItem(21)]
        session.frames = [data(#"{"v":1,"type":"resynced","seq":21}"#)]

        let port = AttentionDomainPort(store: store)
        let staleSelector = try XCTUnwrap(port.inspect(context: port.context, request: key(21)).requests.first?.selector)
        let core = try NativeRelayCore(store: store, context: context, session: session)
        _ = try await core.resyncAndDrainOutbox()

        let bounded = try store.snapshot(context: context)
        XCTAssertEqual(bounded.inboxCurrentKeys?.count, 20)
        XCTAssertEqual(try port.inspect(context: port.context, request: key(1)).requests.first?.inboxStateIsCurrent, true)
        XCTAssertEqual(try port.inspect(context: port.context, request: key(21)).requests.first?.inboxStateIsCurrent, false)
        XCTAssertThrowsError(try port.submit(SubmitIntent(context: port.context, selector: staleSelector,
            intentID: UUID(), inputs: [.compatibilityValue(action: ExactText("yes"))]))) {
            XCTAssertEqual($0 as? AttentionStoreError, .inboxStateUnrefreshed)
        }

        let fetched = try await core.fetchNextInboxPage()
        XCTAssertTrue(fetched)
        XCTAssertEqual(try store.snapshot(context: context).inboxCurrentKeys?.count, 21)
        let refreshedSelector = try XCTUnwrap(port.inspect(context: port.context, request: key(21)).requests.first?.selector)
        _ = try port.submit(SubmitIntent(context: port.context, selector: refreshedSelector,
            intentID: UUID(), inputs: [.compatibilityValue(action: ExactText("yes"))]))
        XCTAssertEqual(try store.snapshot(context: context).outbox.count, 1)
    }

    func testUnloadedPostCheckpointTerminalSurvivesRestartAndMergesOnItsPage() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person-A"),
                                       deviceID: ExactText("installation-A"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let persistence = MemoryAttentionStatePersistence()
        let firstStore = try AttentionDomainStore(context: context, persistence: persistence)
        let payload = try JSONValue.parse(Data(#"{"title":"Request","answer_ui":null}"#.utf8))
        func key(_ sequence: Int) -> RequestKey {
            RequestKey(accountScope: identity.personID,
                       senderID: ExactText("sender"), messageID: ExactText("m\(sequence)"))
        }
        func pageItem(_ sequence: Int, terminal: JSONValue? = nil) throws -> JSONValue {
            let acceptance = try JSONValue.parse(data(#"{"v":1,"type":"delivery","seq":\#(sequence),"sender_id":"sender","message_id":"m\#(sequence)","origin":"other-installation","as":"message","message":\#(payload.jsonString)}"#))
            var members = [JSONMember("acceptance", acceptance)]
            if let terminal { members.append(JSONMember("terminal", terminal)) }
            return .object(members)
        }
        let firstSession = Session(identity)
        firstSession.snapshotHighWater = 21
        firstSession.nextItemCursor = "cursor-20"
        firstSession.initialItems = try (1...20).map { try pageItem($0) }
        firstSession.frames = [
            data(#"{"v":1,"type":"lifecycle","seq":22,"sender_id":"sender","message_id":"m21","origin":"other-installation","state":"answered","at":22}"#),
            data(#"{"v":1,"type":"resynced","seq":22}"#)
        ]

        let firstCore = try NativeRelayCore(store: firstStore, context: context, session: firstSession)
        let firstHigh = try await firstCore.resyncAndDrainOutbox()
        XCTAssertEqual(firstHigh, 22)
        let deferred = try firstStore.snapshot(context: context)
        XCTAssertEqual(deferred.cursor, 22)
        XCTAssertEqual(deferred.pendingRelayOverlays[22]?.sequence, 22)
        XCTAssertNil(deferred.requests[key(21)])

        let restartedContext = ProfileContext(identity: identity, transportMode: .relay)
        let restarted = try AttentionDomainStore(context: restartedContext, persistence: persistence)
        let secondSession = Session(identity)
        secondSession.snapshotHighWater = 22
        secondSession.nextItemCursor = "cursor-20"
        secondSession.initialItems = try (1...20).map { try pageItem($0) }
        let terminal = try JSONValue.parse(data(#"{"v":1,"type":"lifecycle","seq":22,"sender_id":"sender","message_id":"m21","origin":"other-installation","state":"answered","at":22}"#))
        secondSession.olderPages["cursor-20"] = [try pageItem(21, terminal: terminal)]
        secondSession.frames = [data(#"{"v":1,"type":"resynced","seq":22}"#)]
        let secondCore = try NativeRelayCore(store: restarted, context: restartedContext, session: secondSession)
        _ = try await secondCore.resyncAndDrainOutbox()
        XCTAssertNil(try restarted.snapshot(context: restartedContext).requests[key(21)])

        let fetched = try await secondCore.fetchNextInboxPage()
        XCTAssertTrue(fetched)
        let hydrated = try restarted.snapshot(context: restartedContext)
        XCTAssertEqual(hydrated.cursor, 22, "Hydration cannot re-ACK an already contiguous sequence.")
        XCTAssertEqual(hydrated.remoteStates[key(21)]?.state, .answered)
        XCTAssertEqual(hydrated.remoteStates[key(21)]?.eventSequence, 22)
        XCTAssertEqual(hydrated.appliedEvents[22]?.sequence, 22)
        XCTAssertNil(hydrated.pendingRelayOverlays[22])
        XCTAssertTrue(hydrated.inboxCurrentKeys?.contains(key(21)) == true)
    }

    func testServerAdmittedLargeMessageReachesTheNativeInboxBeforeACK() async throws {
        let (context, store, session) = try setup()
        let body = String(repeating: "x", count: 1_048_600)
        session.frames = [
            data(#"{"v":1,"type":"ok","ref":"native-sync"}"#),
            data(#"{"v":1,"type":"delivery","seq":1,"sender_id":"sender","message_id":"large","origin":"other-installation","as":"message","message":{"title":"Long request","body":"\#(body)"}}"#),
            data(#"{"v":1,"type":"resynced","seq":1}"#)
        ]

        let core = try NativeRelayCore(store: store, context: context, session: session)
        let cursor = try await core.resyncAndDrainOutbox()
        XCTAssertEqual(cursor, 1)
        let port = AttentionDomainPort(store: store)
        let visible = try port.observe(context: port.context)
        XCTAssertEqual(visible.requests.first?.body?.rawValue, body)
        XCTAssertEqual(session.acknowledgements.count, 1)
    }

    func testLargeInterruptedReplayResumesFromDurableCursorAndThenShowsInbox() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person-A"),
                                       deviceID: ExactText("installation-A"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let persistence = MemoryAttentionStatePersistence()
        let store = try AttentionDomainStore(context: context, persistence: persistence)
        let body = String(repeating: "x", count: 1_048_600)
        let events = (1...9).map { sequence in
            data(#"{"v":1,"type":"delivery","seq":\#(sequence),"sender_id":"sender","message_id":"m\#(sequence)","origin":"other-installation","as":"message","message":{"title":"Long request \#(sequence)","body":"\#(body)"}}"#)
        }
        let start = data(#"{"v":1,"type":"ok","ref":"native-sync"}"#)
        let end = data(#"{"v":1,"type":"resynced","seq":9}"#)
        let firstSession = Session(identity)
        firstSession.frames = [start] + events + [end]
        firstSession.interruptAfterFrames = 6
        let firstCore = try NativeRelayCore(store: store, context: context, session: firstSession)
        do {
            _ = try await firstCore.resyncAndDrainOutbox()
            XCTFail("An interrupted replay cannot be confirmed as complete.")
        } catch InstallationTransportError.unexpectedServerFrame {
            XCTAssertEqual(try store.snapshot(context: context).cursor, 5)
        }
        XCTAssertTrue(firstSession.acknowledgements.isEmpty)
        let hidden = AttentionDomainPort(store: store)
        XCTAssertTrue(try hidden.observe(context: hidden.context).requests.isEmpty,
                      "A partial replay must stay out of the visible inbox.")

        let restartedContext = ProfileContext(identity: identity, transportMode: .relay)
        let restarted = try AttentionDomainStore(context: restartedContext, persistence: persistence)
        let secondSession = Session(identity)
        secondSession.frames = [start] + Array(events.dropFirst(5)) + [end]
        let secondCore = try NativeRelayCore(store: restarted,
                                             context: restartedContext,
                                             session: secondSession)
        let high = try await secondCore.resyncAndDrainOutbox()
        XCTAssertEqual(high, 9)
        let visible = AttentionDomainPort(store: restarted)
        XCTAssertEqual(try visible.observe(context: visible.context).requests.count, 9)
        XCTAssertEqual(secondSession.acknowledgements.count, 1)
        XCTAssertEqual(try restarted.snapshot(context: restartedContext).replayBarrier, nil)
    }

    func testGapNeverAcknowledgesOrPublishesPartialReplay() async throws {
        let (context, store, session) = try setup()
        session.frames = [
            data(#"{"v":1,"type":"ok","ref":"native-sync"}"#),
            data(#"{"v":1,"type":"delivery","seq":2,"sender_id":"sender","message_id":"m1","origin":"other","as":"knock","message":{}}"#),
            data(#"{"v":1,"type":"resynced","seq":2}"#)
        ]
        let core = try NativeRelayCore(store: store, context: context, session: session)
        do {
            _ = try await core.resyncAndDrainOutbox()
            XCTFail("A sequence gap must be refused.")
        } catch NativeRelayCoreError.invalidReplay {
            // No cursor or server ACK was advanced.
        }
        XCTAssertTrue(session.acknowledgements.isEmpty)
        XCTAssertEqual(try store.snapshot(context: context).cursor, 0)
        let visible = AttentionDomainPort(store: store)
        XCTAssertTrue(try visible.observe(context: visible.context).requests.isEmpty,
                      "A gapped stream must not publish a partial inbox.")
    }

    func testRejectedPostCheckpointACKReattachesFromDurableCursorAndOnlyACKsNewEvents() async throws {
        let (context, store, session) = try setup()
        session.snapshotHighWater = 0
        session.replayFrames = [
            [data(#"{"v":1,"type":"delivery","seq":1,"sender_id":"sender","message_id":"m1","origin":"other-installation","as":"message","message":{"answer_ui":null,"title":"Hello"}}"#),
             data(#"{"v":1,"type":"resynced","seq":1}"#)],
            [data(#"{"v":1,"type":"delivery","seq":2,"sender_id":"sender","message_id":"m2","origin":"other-installation","as":"message","message":{"answer_ui":null,"title":"Next"}}"#),
             data(#"{"v":1,"type":"resynced","seq":2}"#)]
        ]
        session.rejectFirstAcknowledgement = true

        let core = try NativeRelayCore(store: store, context: context, session: session)
        let high = try await core.resyncAndDrainOutbox()
        XCTAssertEqual(high, 2)
        XCTAssertEqual(try store.snapshot(context: context).cursor, 2)
        let requestValues = try session.requests.map(JSONValue.parse)
        XCTAssertEqual(requestValues.compactMap { $0.uniqueValue(named: "type")?.stringValue?.rawValue }, [
            "inbox_start", "inbox_attach", "inbox_attach"
        ])
        XCTAssertEqual(requestValues.dropFirst().compactMap {
            $0.uniqueValue(named: "since")?.integerValue
        }, [0, 1], "Recovery reattaches from the actual local cursor after the checkpoint, not zero.")
        XCTAssertEqual(session.acknowledgements.count, 2)
        XCTAssertEqual(String(decoding: session.acknowledgements[0], as: UTF8.self),
                       #"{"v":1,"type":"ack","seq":1,"ref":"native-ack"}"# + "\n")
        XCTAssertEqual(String(decoding: session.acknowledgements[1], as: UTF8.self),
                       #"{"v":1,"type":"ack","seq":2,"ref":"native-ack"}"# + "\n")
    }

    func testFixtureAndWrongInstallationCannotCreateRelayCore() throws {
        let (context, store, session) = try setup()
        session.authenticatedIdentity = ProfileIdentity(trustedRelayAuthority: context.identity.trustedRelayAuthority,
                                                        personID: context.identity.personID,
                                                        deviceID: ExactText("someone-else"))
        XCTAssertThrowsError(try NativeRelayCore(store: store, context: context, session: session)) {
            XCTAssertEqual($0 as? NativeRelayCoreError, .wrongInstallation)
        }
        let fixture = ProfileContext(identity: context.identity, transportMode: .fixture)
        XCTAssertThrowsError(try NativeRelayCore(store: store, context: fixture, session: session)) {
            XCTAssertEqual($0 as? NativeRelayCoreError, .fixtureProfile)
        }
        XCTAssertFalse(DeviceCertificateBinding.matches(Data([0x30, 0x00]),
                                                       expectedDeviceID: String(repeating: "0", count: 64)))
    }

    func testUncertainOriginalOperationRetriesExactDurableFrameAfterRestart() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person-C"),
                                       deviceID: ExactText("installation-C"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let persistence = MemoryAttentionStatePersistence()
        let store = try AttentionDomainStore(context: context, persistence: persistence)
        let key = RequestKey(accountScope: identity.personID,
                             senderID: ExactText("sender"), messageID: ExactText("m2"))
        let payload = try JSONValue.parse(Data(#"{"answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"yes","label":"Yes","kind":"value","value":{"ok":true}}]}}"#.utf8))
        _ = try store.apply(RelayEvent(sequence: 1,
                                       body: .delivery(StoredRequest(key: key, originalPayload: payload), .message)),
                            context: context)
        let port = AttentionDomainPort(store: store)
        let selector = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first?.selector)
        let receipt = try port.submit(SubmitIntent(context: port.context, selector: selector,
                                                  intentID: UUID(),
                                                  inputs: [.compatibilityValue(action: ExactText("yes"))]))
        let firstSession = Session(identity)
        let firstCore = try NativeRelayCore(store: store, context: context, session: firstSession)
        let firstAttempt = try await firstCore.sendPendingOriginalOperations()
        XCTAssertEqual(firstAttempt, 1)
        XCTAssertEqual(firstSession.sent.first?.1, receipt.opID)
        XCTAssertEqual(try store.snapshot(context: context).outbox.count, 1)

        let restartedContext = ProfileContext(identity: identity, transportMode: .relay)
        let restarted = try AttentionDomainStore(context: restartedContext, persistence: persistence)
        let secondSession = Session(identity)
        secondSession.result = .accepted(operationID: receipt.opID, terminalSequence: 9)
        let secondCore = try NativeRelayCore(store: restarted,
                                             context: restartedContext,
                                             session: secondSession)
        let secondAttempt = try await secondCore.sendPendingOriginalOperations()
        XCTAssertEqual(secondAttempt, 1)
        XCTAssertEqual(secondSession.sent.first?.0, firstSession.sent.first?.0)
        XCTAssertEqual(try restarted.snapshot(context: restartedContext).cursor, 1,
                       "An operation receipt at sequence 9 cannot jump the durable relay cursor.")
        XCTAssertTrue(try restarted.snapshot(context: restartedContext).outbox.isEmpty)
    }

    func testCheckpointReconcilesAcceptedOriginalAndAppliesItsActualTerminalSequenceOnce() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person-A"),
                                       deviceID: ExactText("installation-A"))
        let originalContext = ProfileContext(identity: identity, transportMode: .relay)
        let persistence = MemoryAttentionStatePersistence()
        let originalStore = try AttentionDomainStore(context: originalContext, persistence: persistence)
        let key = RequestKey(accountScope: identity.personID,
                             senderID: ExactText("sender"), messageID: ExactText("accepted-awaiting"))
        let payload = try JSONValue.parse(Data(#"{"title":"Prompt","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"yes","label":"Yes","kind":"value","value":{"ok":true}}]}}"#.utf8))
        _ = try originalStore.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: payload), .message)), context: originalContext)
        let port = AttentionDomainPort(store: originalStore)
        let selector = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first?.selector)
        let receipt = try port.submit(SubmitIntent(context: port.context, selector: selector,
            intentID: UUID(), inputs: [.compatibilityValue(action: ExactText("yes"))]))
        try originalStore.recordAcceptedOperation(receipt.intentID, operationID: receipt.opID,
            terminalSequence: 2, context: originalContext)
        let exactOriginal = try XCTUnwrap(originalStore.lookupIntent(receipt.intentID, context: originalContext))

        let restartedContext = ProfileContext(identity: identity, transportMode: .relay)
        let restarted = try AttentionDomainStore(context: restartedContext, persistence: persistence)
        XCTAssertEqual(try restarted.acceptedOperationsAwaitingTerminalReplay(context: restartedContext)
            .map(\.operationID), [receipt.opID])
        let session = Session(identity)
        session.snapshotHighWater = 10
        let committedResult = try JSONValue.parse(data(#"{"op_id":"\#(receipt.opID.uuidString.lowercased())","status":"committed","result":{"v":1,"type":"ok","seq":2,"duplicate":true},"terminal":{"v":1,"type":"lifecycle","seq":2,"sender_id":"sender","message_id":"accepted-awaiting","origin":"other-installation","state":"answered","at":2}}"#))
        session.reconciliationOverrides[receipt.opID] = committedResult
        session.frames = [data(#"{"v":1,"type":"resynced","seq":10}"#)]
        let core = try NativeRelayCore(store: restarted, context: restartedContext, session: session)

        let high = try await core.resyncAndDrainOutbox()
        XCTAssertEqual(high, 10)

        let settled = try restarted.snapshot(context: restartedContext)
        XCTAssertEqual(settled.cursor, 10)
        XCTAssertEqual(settled.remoteStates[key]?.state, .answered)
        XCTAssertEqual(settled.appliedEvents[2]?.sequence, 2)
        XCTAssertTrue(settled.inboxCurrentKeys?.contains(key) == true,
                      "An exact terminal receipt makes its cached message current at H.")
        XCTAssertTrue(try restarted.acceptedOperationsAwaitingTerminalReplay(context: restartedContext).isEmpty)
        let reconciliation = try XCTUnwrap(try session.requests.map(JSONValue.parse).first {
            $0.uniqueValue(named: "type")?.stringValue?.rawValue == "inbox_reconcile"
        })
        let reconciledOriginal = try XCTUnwrap(reconciliation.uniqueValue(named: "operations")?.arrayValues?.first)
        XCTAssertEqual(reconciledOriginal.uniqueValue(named: "op_id")?.stringValue?.rawValue,
                       receipt.opID.uuidString.lowercased())
        XCTAssertEqual(try XCTUnwrap(reconciledOriginal.uniqueValue(named: "type")?.stringValue?.rawValue), "answer")
        XCTAssertEqual(reconciledOriginal, exactOriginal.operation)
        XCTAssertEqual(try XCTUnwrap(settled.inboxCheckpoint?.batches.first?.results?.first?.terminal?.sequence), 2)

        let recoveredContext = ProfileContext(identity: identity, transportMode: .relay)
        let recovered = try AttentionDomainStore(context: recoveredContext, persistence: persistence)
        XCTAssertEqual(try recovered.acceptedOperationsAwaitingTerminalReplay(context: recoveredContext).count, 0)
        XCTAssertEqual(try recovered.snapshot(context: recoveredContext).appliedEvents[2]?.sequence, 2)
    }

    func testAcceptedOriginalOperationReplayIsJoinedToItsSavedBinding() async throws {
        let (context, store, session) = try setup()
        let key = RequestKey(accountScope: context.identity.personID,
                             senderID: ExactText("sender"), messageID: ExactText("answer-request"))
        let payload = try JSONValue.parse(Data(#"{"title":"Prompt","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"yes","label":"Yes","kind":"value","value":{"ok":true}}]}}"#.utf8))
        _ = try store.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: payload), .message),
            conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("session"))),
            context: context)
        let port = AttentionDomainPort(store: store)
        let selector = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first?.selector)
        let receipt = try port.submit(SubmitIntent(context: port.context, selector: selector,
            intentID: UUID(), inputs: [.compatibilityValue(action: ExactText("yes"))]))
        let submission = try XCTUnwrap(store.snapshot(context: context).outbox.first)
        session.result = .accepted(operationID: receipt.opID, terminalSequence: 2)
        session.supportsPostCheckpointInboxEvents = true
        session.postCheckpointEventAfterAccept = data(#"{"v":1,"type":"lifecycle","seq":2,"sender_id":"sender","message_id":"answer-request","origin":"other-installation","state":"answered","at":2}"#)
        session.replayFrames = [
            [data(#"{"v":1,"type":"ok","ref":"native-sync"}"#),
             data(#"{"v":1,"type":"resynced","seq":1}"#)]
        ]
        let events = DiagnosticEventCollector()
        let core = try NativeRelayCore(store: store, context: context, session: session,
                                       onDiagnostic: { events.append($0) })

        _ = try await core.resyncAndDrainOutbox()

        let replay = events.events.filter {
            $0.phase == .ordinaryReplay && $0.operationID == submission.operationID
        }
        XCTAssertTrue(replay.contains {
            $0.transition == .began && $0.receiptState == .acceptedAwaitingReplay &&
                $0.requestTag != nil && $0.requestRevision == 1
        })
        XCTAssertTrue(replay.contains {
            $0.transition == .completed && $0.receiptState == .terminal &&
                $0.requestTag != nil && $0.requestRevision == 1
        })
        XCTAssertEqual(session.replayCallCount, 1,
                       "The same connection carries post-barrier events; it does not attach a second cached replay.")
        XCTAssertEqual(session.acknowledgements.count, 1)
        let terminalAcknowledgement = try JSONValue.parse(try XCTUnwrap(session.acknowledgements.first))
        XCTAssertEqual(terminalAcknowledgement.uniqueValue(named: "seq"),
                       .number(JSONNumber(lexeme: "2")),
                       "The post-H terminal is durably applied at sequence 2 before ordinary ACK.")
        XCTAssertEqual(try store.snapshot(context: context).cursor, 2)
        XCTAssertEqual(try store.snapshot(context: context).remoteStates[key]?.state, .answered)
    }

    func testAcceptedOperationReplayFailureKeepsExactReceiptAndCauseRetrievable() async throws {
        let (context, store, session) = try setup()
        let key = RequestKey(accountScope: context.identity.personID,
                             senderID: ExactText("sender"), messageID: ExactText("answer-request"))
        let payload = try JSONValue.parse(Data(#"{"title":"Prompt","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"yes","label":"Yes","kind":"value","value":{"ok":true}}]}}"#.utf8))
        _ = try store.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: payload), .message),
            conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("session"))),
            context: context)
        let port = AttentionDomainPort(store: store)
        let selector = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first?.selector)
        let receipt = try port.submit(SubmitIntent(context: port.context, selector: selector,
            intentID: UUID(), inputs: [.compatibilityValue(action: ExactText("yes"))]))
        session.result = .accepted(operationID: receipt.opID, terminalSequence: 2)
        session.replayFrames = [
            [data(#"{"v":1,"type":"ok","ref":"native-sync"}"#),
             data(#"{"v":1,"type":"resynced","seq":1}"#)]
        ]
        session.resyncFailureOnCall = 2
        let events = DiagnosticEventCollector()
        let core = try NativeRelayCore(store: store, context: context, session: session,
                                       onDiagnostic: { events.append($0) })

        do {
            _ = try await core.resyncAndDrainOutbox()
            XCTFail("The follow-on replay failure must remain visible to its accepted operation.")
        } catch InstallationTransportError.unexpectedServerFrame {}

        let submission = try XCTUnwrap(store.snapshot(context: context).intents[receipt.intentID])
        let replayFailure = events.events.first {
            $0.phase == .ordinaryReplay && $0.transition == .failed &&
                $0.operationID == submission.operationID
        }
        XCTAssertEqual(replayFailure?.causeCode, "unexpected_relay_frame")
        XCTAssertEqual(replayFailure?.requestRevision, 1)
        XCTAssertNotNil(replayFailure?.requestTag)
        XCTAssertEqual(replayFailure?.receiptState, .acceptedAwaitingReplay)
        XCTAssertEqual(try store.snapshot(context: context).cursor, 1)
        XCTAssertTrue(try store.snapshot(context: context).outbox.isEmpty,
                      "The accepted operation is not silently requeued as a new answer.")
    }
}
