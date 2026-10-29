import AttentionDomain
import XCTest
@testable import Harklight

@MainActor
final class SupersedesPresentationTests: XCTestCase {
    private func profile() -> ProfileContext {
        ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("supersedes-test"),
            personID: ExactText("person"), deviceID: ExactText("reader")), transportMode: .relay)
    }

    func testDeliveryIDsAreOrderedDeduplicatedAndUnaffectedByLaterRevisionPayloads() throws {
        let context = profile()
        let domain = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        let key = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("agent"), messageID: ExactText("new"))
        let original = try JSONValue.parse(Data(#"{"title":"New message","supersedes":["old",7,"older","old"]}"#.utf8))
        try domain.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: original), .message),
            conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("origin"),
                                                     eventID: ExactText("delivery-event"))), context: context)

        let model = try LivePresentationStore(store: domain, context: context)
        XCTAssertEqual(model.request(for: key)?.supersedesMessageIDs.map(\.rawValue), ["old", "older"])

        let revisionKey = ConversationBinding(request: key, revision: 2)
        let revision = ConversationTurn(id: ExactText("revision-event"), binding: revisionKey,
            author: .origin, sessionHandle: ExactText("origin"), text: ExactText("Updated wording"), kind: .revision)
        let revisedPayload = try JSONValue.parse(Data(#"{"title":"Updated wording","supersedes":["revision-only"]}"#.utf8))
        try domain.applyConversation(ConversationEvent(sequence: 1, binding: revisionKey,
            fact: .revision(revision, payload: revisedPayload)), context: context)
        try model.refreshFromDurableStore()
        XCTAssertEqual(model.request(for: key)?.requestRevision, 2)
        XCTAssertEqual(model.request(for: key)?.supersedesMessageIDs.map(\.rawValue), ["old", "older"])

        let malformed = try JSONValue.parse(Data(#"{"supersedes":"old"}"#.utf8))
        let malformedRequest = StoredRequest(key: key, originalPayload: malformed)
        XCTAssertEqual(malformedRequest.supersedesMessageIDs, [])
    }

    func testSupersededTargetIsHiddenFromListProjectionsButRemainsReadableByKey() throws {
        let context = profile()
        let domain = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        let target = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("agent"), messageID: ExactText("old"))
        let replacement = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("agent"), messageID: ExactText("new"))
        let payload = try JSONValue.parse(Data(#"{"title":"Message","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"yes","label":"Yes","kind":"value","value":"yes"}]}}"#.utf8))
        try domain.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: target, originalPayload: payload), .message)), context: context)
        try domain.apply(RelayEvent(sequence: 2,
            body: .delivery(StoredRequest(key: replacement, originalPayload: payload), .message)), context: context)
        try domain.apply(RelayEvent(sequence: 3,
            body: .terminal(target, .superseded, nil)), context: context)

        let model = try LivePresentationStore(store: domain, context: context)
        XCTAssertEqual(model.inboxRows.map(\.key), [replacement])
        XCTAssertFalse(model.resolvedRequests.contains { $0.key == target })
        XCTAssertEqual(model.request(for: target)?.lifecycleStatus, .superseded)
    }

    func testCrossIDSupersedesKeepsTheTargetSlotAndThreadAcrossAChain() throws {
        let context = profile()
        let store = try AttentionDomainStore(context: context,
                                             persistence: MemoryAttentionStatePersistence())
        func key(_ sender: String, _ message: String) -> RequestKey {
            RequestKey(accountScope: context.identity.personID,
                       senderID: ExactText(sender), messageID: ExactText(message))
        }
        func payload(_ title: String, supersedes: String? = nil, byWhen: Int? = nil) throws -> JSONValue {
            var members = [JSONMember("title", .string(ExactText(title)))]
            if let supersedes {
                members.append(JSONMember("supersedes", .array([.string(ExactText(supersedes))])))
            }
            if let byWhen {
                members.append(JSONMember("by_when", .number(JSONNumber(lexeme: String(byWhen)))))
            }
            return .object(members)
        }
        let earlier = key("agent", "earlier")
        let target = key("agent", "target")
        let later = key("other-agent", "later")
        let replacementOne = key("agent", "replacement-one")
        let replacementTwo = key("agent", "replacement-two")
        for (sequence, requestKey, title) in [(1, earlier, "Earlier"), (2, target, "Target"),
                                               (3, later, "Later")] {
            try store.apply(RelayEvent(sequence: UInt64(sequence), body: .delivery(
                StoredRequest(key: requestKey, originalPayload: try payload(title)), .message)),
                context: context)
        }
        try store.setInboxView(InboxView(revision: ExactText("view-1"), entries: [
            InboxViewEntry(key: earlier, priority: .normal, thread: ExactText("release"),
                           dueAtMilliseconds: 1000),
            InboxViewEntry(key: target, priority: .high, thread: ExactText("release"),
                           dueAtMilliseconds: 2000),
            InboxViewEntry(key: later, priority: .low, thread: ExactText("other"),
                           dueAtMilliseconds: 3000)
        ]), context: context)

        try store.apply(RelayEvent(sequence: 4, body: .delivery(
            StoredRequest(key: replacementOne,
                originalPayload: try payload("Replacement one", supersedes: "target", byWhen: 4000)),
            .message)), context: context)
        try store.apply(RelayEvent(sequence: 5, body: .terminal(target, .superseded, nil)), context: context)
        let live = try LivePresentationStore(store: store, context: context)
        let firstReplacement = try XCTUnwrap(live.request(for: replacementOne))
        XCTAssertEqual(firstReplacement.inboxPriority, .high)
        XCTAssertEqual(firstReplacement.inboxThread, ExactText("release"))
        XCTAssertEqual(firstReplacement.inboxDueAtMilliseconds, 4000,
                       "A replacement keeps the target slot but uses its own deadline.")
        let firstEntries = InboxThreadListProjection.grouped(live.inboxRows.map(InboxItem.request))
        guard case let .thread(thread, members) = firstEntries.first else {
            return XCTFail("The replacement should join the adjacent members of its inherited thread.")
        }
        XCTAssertEqual(thread, ExactText("release"))
        XCTAssertEqual(members.map(\.id), [.request(earlier), .request(replacementOne)])

        try store.apply(RelayEvent(sequence: 6, body: .delivery(
            StoredRequest(key: replacementTwo,
                originalPayload: try payload("Replacement two", supersedes: "replacement-one", byWhen: 5000)),
            .message)), context: context)
        try store.apply(RelayEvent(sequence: 7,
            body: .terminal(replacementOne, .superseded, nil)), context: context)
        try live.refreshFromDurableStore()

        let secondReplacement = try XCTUnwrap(live.request(for: replacementTwo))
        XCTAssertEqual(secondReplacement.inboxPriority, .high)
        XCTAssertEqual(secondReplacement.inboxThread, ExactText("release"))
        XCTAssertEqual(secondReplacement.inboxDueAtMilliseconds, 5000)
        let chainedEntries = InboxThreadListProjection.grouped(live.inboxRows.map(InboxItem.request))
        guard case let .thread(chainedThread, chainedMembers) = chainedEntries.first else {
            return XCTFail("The chained replacement should keep the same adjacent thread slot.")
        }
        XCTAssertEqual(chainedThread, ExactText("release"))
        XCTAssertEqual(chainedMembers.map(\.id), [.request(earlier), .request(replacementTwo)])

        let cursor = try store.relayCursor(context: context)
        _ = try store.beginInboxCandidate(startupID: "page-refresh", since: cursor,
                                          batches: [], context: context)
        let replacementAcceptance = RelayEvent(sequence: 6,
            body: .delivery(StoredRequest(key: replacementTwo,
                originalPayload: try payload("Replacement two", supersedes: "replacement-one", byWhen: 5000)),
                .message))
        try store.saveInboxInitialPage(snapshotID: "page-refresh-snapshot", highWater: 7,
            items: [InboxSnapshotItem(acceptance: replacementAcceptance)], nextCursor: nil,
            receiptCursor: nil, context: context)
        XCTAssertEqual(try store.snapshot(context: context).remoteStates[replacementTwo]?.supersedesOriginTarget,
                       target, "Refreshing a page must retain the slot relation learned from relay events.")
    }

    func testSupersedesOriginTargetDoesNotCrossSenderIdentity() throws {
        let context = profile()
        let store = try AttentionDomainStore(context: context,
                                             persistence: MemoryAttentionStatePersistence())
        func key(_ sender: String, _ message: String) -> RequestKey {
            RequestKey(accountScope: context.identity.personID,
                       senderID: ExactText(sender), messageID: ExactText(message))
        }
        func payload(_ title: String, supersedes: String? = nil) throws -> JSONValue {
            var members = [JSONMember("title", .string(ExactText(title)))]
            if let supersedes {
                members.append(JSONMember("supersedes", .array([.string(ExactText(supersedes))])))
            }
            return .object(members)
        }

        let differentSenderTarget = key("other-agent", "same-id")
        let replacement = key("agent", "replacement")
        try store.apply(RelayEvent(sequence: 1, body: .delivery(
            StoredRequest(key: differentSenderTarget, originalPayload: try payload("Other sender")), .message)),
            context: context)
        try store.setInboxView(InboxView(revision: ExactText("view-1"), entries: [
            InboxViewEntry(key: differentSenderTarget, priority: .now, thread: ExactText("other-thread"))
        ]), context: context)
        try store.apply(RelayEvent(sequence: 2, body: .delivery(
            StoredRequest(key: replacement,
                originalPayload: try payload("Replacement", supersedes: "same-id")), .message)),
            context: context)
        try store.apply(RelayEvent(sequence: 3,
            body: .terminal(differentSenderTarget, .superseded, nil)), context: context)

        let live = try LivePresentationStore(store: store, context: context)
        let presented = try XCTUnwrap(live.request(for: replacement))
        XCTAssertNil(presented.inboxPriority)
        XCTAssertNil(presented.inboxThread)
    }

    func testCrossIDSupersedesOriginTargetCanBeRecoveredFromSnapshotSequences() throws {
        let context = profile()
        let store = try AttentionDomainStore(context: context,
                                             persistence: MemoryAttentionStatePersistence())
        func key(_ message: String) -> RequestKey {
            RequestKey(accountScope: context.identity.personID,
                       senderID: ExactText("agent"), messageID: ExactText(message))
        }
        func payload(_ title: String, supersedes: String? = nil) throws -> JSONValue {
            var members = [JSONMember("title", .string(ExactText(title)))]
            if let supersedes {
                members.append(JSONMember("supersedes", .array([.string(ExactText(supersedes))])))
            }
            return .object(members)
        }

        let target = key("target")
        let replacement = key("replacement")
        let targetAcceptance = RelayEvent(sequence: 2, body: .delivery(
            StoredRequest(key: target, originalPayload: try payload("Target")), .message))
        let replacementAcceptance = RelayEvent(sequence: 10, body: .delivery(
            StoredRequest(key: replacement,
                originalPayload: try payload("Replacement", supersedes: "target")), .message))
        let targetTerminal = RelayEvent(sequence: 11, body: .terminal(target, .superseded, nil))
        try store.setInboxView(InboxView(revision: ExactText("view-1"), entries: [
            InboxViewEntry(key: target, priority: .high, thread: ExactText("release"))
        ]), context: context)
        _ = try store.beginInboxCandidate(startupID: "snapshot", since: 0,
                                          batches: [], context: context)
        try store.saveInboxInitialPage(snapshotID: "snapshot", highWater: 11,
            items: [
                InboxSnapshotItem(acceptance: replacementAcceptance),
                InboxSnapshotItem(acceptance: targetAcceptance, terminal: targetTerminal)
            ], nextCursor: nil, receiptCursor: nil, context: context)

        let live = try LivePresentationStore(store: store, context: context)
        XCTAssertEqual(try XCTUnwrap(live.request(for: replacement)).inboxPriority, .high)
        XCTAssertEqual(try XCTUnwrap(live.request(for: replacement)).inboxThread, ExactText("release"))
    }
}
