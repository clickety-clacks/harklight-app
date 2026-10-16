import AttentionDomain
import Foundation
import HarklightNativeRelay
import XCTest

final class NativeRelayCoreTests: XCTestCase {
    private final class Session: AuthenticatedInstallationSession, @unchecked Sendable {
        var authenticatedIdentity: ProfileIdentity
        var frames: [Data] = []
        var requests: [Data] = []
        var acknowledgements: [Data] = []
        var sent: [(Data, UUID)] = []
        var result: OriginalOperationResult = .unresolved
        var replayFrames: [[Data]] = []
        var rejectFirstAcknowledgement = false
        var interruptAfterFrames: Int?

        init(_ identity: ProfileIdentity) { authenticatedIdentity = identity }
        func resync(_ request: Data,
                    consume: @Sendable (Data) async throws -> Void) async throws {
            requests.append(request)
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
        func sendOriginalOperation(_ frame: Data, operationID: UUID) async throws -> OriginalOperationResult {
            sent.append((frame, operationID))
            return result
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

    func testLostServerACKReplaysDurableEventFromServerCursorBeforeRetryingACK() async throws {
        let (context, store, session) = try setup()
        let key = RequestKey(accountScope: context.identity.personID,
                             senderID: ExactText("sender"), messageID: ExactText("m1"))
        let payload = try JSONValue.parse(Data(#"{"answer_ui":null,"title":"Hello"}"#.utf8))
        _ = try store.apply(RelayEvent(sequence: 1,
                                       body: .delivery(StoredRequest(key: key, originalPayload: payload), .message)),
                            context: context)
        session.replayFrames = [
            [data(#"{"v":1,"type":"ok","ref":"native-sync"}"#),
             data(#"{"v":1,"type":"resynced","seq":1}"#)],
            [data(#"{"v":1,"type":"ok","ref":"native-sync"}"#),
             data(#"{"v":1,"type":"delivery","seq":1,"sender_id":"sender","message_id":"m1","origin":"other-installation","as":"message","message":{"answer_ui":null,"title":"Hello"}}"#),
             data(#"{"v":1,"type":"resynced","seq":1}"#)]
        ]
        session.rejectFirstAcknowledgement = true

        let core = try NativeRelayCore(store: store, context: context, session: session)
        let high = try await core.resyncAndDrainOutbox()
        XCTAssertEqual(high, 1)
        XCTAssertEqual(try store.snapshot(context: context).cursor, 1)
        XCTAssertEqual(session.requests.map { String(decoding: $0, as: UTF8.self) }, [
            #"{"v":1,"type":"resync","since":1,"ref":"native-sync"}"# + "\n",
            #"{"v":1,"type":"resync","since":0,"ref":"native-sync"}"# + "\n"
        ])
        XCTAssertEqual(session.acknowledgements.count, 2)
        XCTAssertEqual(session.acknowledgements[0], session.acknowledgements[1])
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
}
