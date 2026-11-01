import AttentionDomain
import Foundation
import XCTest
@testable import Harklight

final class MessageMetadataPresentationTests: XCTestCase {
    func testOnlyUniqueRecognizedTopLevelMembersProduceMetadata() throws {
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("metadata-reader"),
            deviceID: ExactText("metadata-device")), transportMode: .relay)

        func stored(_ messageID: String, _ json: String) throws -> StoredRequest {
            let key = RequestKey(accountScope: context.identity.personID,
                                 senderID: ExactText("agent"),
                                 messageID: ExactText(messageID))
            return StoredRequest(key: key,
                                 originalPayload: try JSONValue.parse(Data(json.utf8)))
        }

        let explicit = try stored("explicit", #"{"message_type":"fyi","message_kind":"blocker","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"seen","label":"Seen","kind":"value","value":{"acknowledgment":"seen"}}]}}"#)
        XCTAssertEqual(explicit.messageType, .fyi)
        XCTAssertEqual(explicit.messageKind, .blocker)
        XCTAssertTrue(explicit.hasExplicitInformationalSeenAction)

        let legacySeen = try stored("legacy-seen", #"{"answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"seen","label":"Seen","kind":"value","value":{"acknowledgment":"seen"}}]}}"#)
        XCTAssertNil(legacySeen.messageType,
                     "A Seen-only answer form does not imply an FYI type.")
        XCTAssertNil(legacySeen.messageKind)
        XCTAssertTrue(legacySeen.hasExplicitInformationalSeenAction)

        let answerShapeOnly = try stored("answer-shape", #"{"answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"reply","label":"Reply","kind":"text"}]}}"#)
        XCTAssertNil(answerShapeOnly.messageType,
                     "A reply control does not imply a request type.")
        XCTAssertNil(answerShapeOnly.messageKind)

        let unknownValues = try stored("unknown", #"{"message_type":"notice","message_kind":"update"}"#)
        XCTAssertNil(unknownValues.messageType)
        XCTAssertNil(unknownValues.messageKind)

        let duplicates = try stored("duplicates", #"{"message_type":"fyi","message_type":"request","message_kind":"success","message_kind":"blocker"}"#)
        XCTAssertNil(duplicates.messageType)
        XCTAssertNil(duplicates.messageKind)
    }

    @MainActor
    func testPortProjectsMetadataWithoutChangingSeenOrReplyControls() throws {
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("metadata-reader"),
            deviceID: ExactText("metadata-device")), transportMode: .relay)
        let store = try AttentionDomainStore(context: context,
                                             persistence: MemoryAttentionStatePersistence())
        let seenKey = RequestKey(accountScope: context.identity.personID,
                                 senderID: ExactText("agent"),
                                 messageID: ExactText("typed-fyi"))
        let replyKey = RequestKey(accountScope: context.identity.personID,
                                  senderID: ExactText("agent"),
                                  messageID: ExactText("typed-request"))
        let seenPayload = try JSONValue.parse(Data(#"{"title":"Work complete","message_type":"fyi","message_kind":"success","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"seen","label":"Seen","kind":"value","value":{"acknowledgment":"seen"}}]}}"#.utf8))
        let replyPayload = try JSONValue.parse(Data(#"{"title":"Please decide","message_type":"request","message_kind":"blocker","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"reply","label":"Reply","kind":"text"}]}}"#.utf8))
        try store.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: seenKey, originalPayload: seenPayload), .message)),
            context: context)
        try store.apply(RelayEvent(sequence: 2,
            body: .delivery(StoredRequest(key: replyKey, originalPayload: replyPayload), .message)),
            context: context)

        let port = AttentionDomainPort(store: store)
        let requests = try port.observe(context: port.context).requests
        XCTAssertEqual(requests.map(\.key), [replyKey, seenKey],
                       "Metadata does not affect the established request order.")

        let seen = try XCTUnwrap(requests.first { $0.key == seenKey })
        XCTAssertEqual(seen.messageType, .fyi)
        XCTAssertEqual(seen.messageKind, .success)
        XCTAssertEqual(seen.informationalSeenStatus, .available)
        guard case let .compatibility(seenActions) = seen.projection else {
            return XCTFail("The explicit Seen descriptor must remain available.")
        }
        XCTAssertEqual(seenActions.map(\.id), [ExactText("seen")])
        let originalSeen = try JSONValue.parse(Data(seen.originalContentJSON.utf8))
        let seenDescriptor = try XCTUnwrap(originalSeen.uniqueValue(named: "answer_ui"))
        let seenAction = try XCTUnwrap(seenDescriptor.uniqueValue(named: "actions")?.arrayValues?.first)
        XCTAssertEqual(seenAction.uniqueValue(named: "id")?.stringValue, ExactText("seen"))
        XCTAssertEqual(seenAction.uniqueValue(named: "value"),
                       try JSONValue.parse(Data(#"{"acknowledgment":"seen"}"#.utf8)))

        let reply = try XCTUnwrap(requests.first { $0.key == replyKey })
        XCTAssertEqual(reply.messageType, .request)
        XCTAssertEqual(reply.messageKind, .blocker)
        guard case let .compatibility(replyActions) = reply.projection else {
            return XCTFail("The explicit Reply descriptor must remain available.")
        }
        XCTAssertEqual(replyActions.map(\.id), [ExactText("reply")])
    }

    func testVisibleLabelsIconsAccentsAndReducedMotionRule() {
        XCTAssertEqual(String(localized: MessageTypePresentation.title(for: .fyi)), "FYI")
        XCTAssertEqual(String(localized: MessageTypePresentation.title(for: .request)), "Request")
        XCTAssertNotEqual(MessageTypePresentation.symbolName(for: .fyi),
                           MessageTypePresentation.symbolName(for: .request))

        let blocker = MessageKindPresentation(kind: .blocker)
        let success = MessageKindPresentation(kind: .success)
        XCTAssertEqual(String(localized: blocker.title), "Blocker")
        XCTAssertEqual(String(localized: success.title), "Success")
        XCTAssertNotEqual(blocker.symbolName, success.symbolName)
        XCTAssertNotEqual(blocker.accent, success.accent)
        XCTAssertNil(blocker.celebratoryFlairSymbolName)
        XCTAssertNotNil(success.celebratoryFlairSymbolName)
        XCTAssertTrue(success.shouldAnimateFlair(reduceMotion: false))
        XCTAssertFalse(success.shouldAnimateFlair(reduceMotion: true))
        XCTAssertFalse(blocker.shouldAnimateFlair(reduceMotion: false))
    }
}
