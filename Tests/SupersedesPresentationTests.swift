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
        let domain = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
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
        let domain = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let target = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("agent"), messageID: ExactText("old"))
        let replacement = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("agent"), messageID: ExactText("new"))
        let targetPayload = try JSONValue.parse(Data(#"{"title":"Message","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"yes","label":"Yes","kind":"value","value":"yes"}]}}"#.utf8))
        let replacementPayload = try JSONValue.parse(Data(#"{"title":"Replacement","supersedes":["old"],"answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"yes","label":"Yes","kind":"value","value":"yes"}]}}"#.utf8))
        try domain.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: target, originalPayload: targetPayload), .message)), context: context)
        try domain.apply(RelayEvent(sequence: 2,
            body: .delivery(StoredRequest(key: replacement, originalPayload: replacementPayload), .message)), context: context)
        try domain.apply(RelayEvent(sequence: 3,
            body: .terminal(target, .superseded, nil)), context: context)

        let model = try LivePresentationStore(store: domain, context: context)
        XCTAssertEqual(model.inboxRows.map(\.key), [replacement])
        XCTAssertFalse(model.resolvedRequests.contains { $0.key == target })
        XCTAssertEqual(model.request(for: target)?.lifecycleStatus, .superseded)
        XCTAssertEqual(model.request(for: target)?.supersededByMessageKeys, [replacement])
        XCTAssertEqual(model.request(for: replacement)?.supersedesMessageIDs.map(\.rawValue), ["old"])
        XCTAssertEqual(model.relatedMessageLabel(for: replacement, fallback: "Replacement message"),
                       "Replacement")
        XCTAssertEqual(model.relatedMessageLabel(for: target, fallback: "Replacement message"), "Message",
                       "A hidden superseded message still supplies its title.")
        let unavailable = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("agent"), messageID: ExactText("not-loaded"))
        XCTAssertEqual(model.relatedMessageLabel(for: unavailable, fallback: "Replacement message"),
                       "Replacement message")
        let otherSender = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("other"), messageID: replacement.messageID)
        XCTAssertEqual(model.relatedMessageLabel(for: otherSender, fallback: "Replacement message"),
                       "Replacement message", "Title lookup must use the complete message identity.")
    }

    func testRelatedMessageWithNoTitleUsesPlainFallback() throws {
        let context = profile()
        let domain = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let key = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("agent"), messageID: ExactText("untitled"))
        for (sequence, payload) in [#"{"body":"No title"}"#, #"{"title":"","body":"Empty title"}"#].enumerated() {
            let messageKey = RequestKey(accountScope: key.accountScope, senderID: key.senderID,
                                       messageID: ExactText(key.messageID.rawValue + String(sequence)))
            try domain.apply(RelayEvent(sequence: UInt64(sequence + 1),
                body: .delivery(StoredRequest(key: messageKey,
                    originalPayload: try JSONValue.parse(Data(payload.utf8))), .message)), context: context)
            let model = try LivePresentationStore(store: domain, context: context)
            XCTAssertEqual(model.relatedMessageLabel(for: messageKey, fallback: "Replacement message"),
                           "Replacement message")
        }
    }

    func testSupersededTargetKeepsEveryReplacementIdentity() throws {
        let context = profile()
        let store = try ClientRepository(context: context,
                                             persistence: MemoryPendingActionPersistence())
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

        let target = key("old")
        let firstReplacement = key("replacement-one")
        let secondReplacement = key("replacement-two")
        try store.apply(RelayEvent(sequence: 1, body: .delivery(
            StoredRequest(key: target, originalPayload: try payload("Old")), .message)),
            context: context)
        try store.apply(RelayEvent(sequence: 2, body: .delivery(
            StoredRequest(key: firstReplacement,
                originalPayload: try payload("Replacement one", supersedes: "old")), .message)),
            context: context)
        try store.apply(RelayEvent(sequence: 3, body: .terminal(target, .superseded, nil)),
            context: context)
        try store.apply(RelayEvent(sequence: 4, body: .delivery(
            StoredRequest(key: secondReplacement,
                originalPayload: try payload("Replacement two", supersedes: "old")), .message)),
            context: context)
        try store.apply(RelayEvent(sequence: 5, body: .terminal(target, .superseded, nil)),
            context: context)

        let live = try LivePresentationStore(store: store, context: context)
        XCTAssertEqual(live.request(for: target)?.supersededByMessageKeys,
                       [firstReplacement, secondReplacement])
        XCTAssertEqual(live.request(for: target)?.lifecycleStatus, .superseded)
    }

    func testOneForwardSupersedingSeveralTargetsLinksAllAndKeepsFirstOriginLiveAndReplay() throws {
        let context = profile()
        func key(_ message: String) -> RequestKey {
            RequestKey(accountScope: context.identity.personID,
                       senderID: ExactText("agent"), messageID: ExactText(message))
        }
        func payload(_ title: String, supersedes: [String] = []) throws -> JSONValue {
            var members = [JSONMember("title", .string(ExactText(title)))]
            if !supersedes.isEmpty {
                members.append(JSONMember("supersedes", .array(
                    supersedes.map { .string(ExactText($0)) })))
            }
            return .object(members)
        }

        let firstTarget = key("first")
        let secondTarget = key("second")
        let replacement = key("replacement")
        let events = [
            RelayEvent(sequence: 1, body: .delivery(
                StoredRequest(key: firstTarget, originalPayload: try payload("First")), .message)),
            RelayEvent(sequence: 2, body: .delivery(
                StoredRequest(key: secondTarget, originalPayload: try payload("Second")), .message)),
            RelayEvent(sequence: 3, body: .delivery(
                StoredRequest(key: replacement,
                    originalPayload: try payload("Replacement", supersedes: ["first", "second"])),
                .message)),
            RelayEvent(sequence: 4, body: .terminal(firstTarget, .superseded, nil)),
            RelayEvent(sequence: 5, body: .terminal(secondTarget, .superseded, nil))
        ]

        let liveStore = try ClientRepository(context: context,
                                                 persistence: MemoryPendingActionPersistence())
        for event in events { try liveStore.apply(event, context: context) }
        let liveSnapshot = try liveStore.snapshot(context: context)
        XCTAssertEqual(liveSnapshot.cursor, 5, "Both live terminals must commit so sync can continue.")
        XCTAssertEqual(liveSnapshot.remoteStates[firstTarget]?.supersededByMessageKeys, [replacement])
        XCTAssertEqual(liveSnapshot.remoteStates[secondTarget]?.supersededByMessageKeys, [replacement])
        XCTAssertEqual(liveSnapshot.remoteStates[replacement]?.supersedesOriginTarget, firstTarget,
                       "The forward keeps the first target as its inbox origin.")

        let replayStore = try ClientRepository(context: context,
                                                   persistence: MemoryPendingActionPersistence())
        try replayStore.beginReplay(through: 5, context: context)
        for event in events { try replayStore.apply(event, context: context) }
        try replayStore.finishReplay(at: 5, context: context)
        let replaySnapshot = try replayStore.snapshot(context: context)
        XCTAssertEqual(replaySnapshot.cursor, 5, "Both replayed terminals must commit.")
        XCTAssertEqual(replaySnapshot.remoteStates[firstTarget]?.supersededByMessageKeys, [replacement])
        XCTAssertEqual(replaySnapshot.remoteStates[secondTarget]?.supersededByMessageKeys, [replacement])
        XCTAssertEqual(replaySnapshot.remoteStates[replacement]?.supersedesOriginTarget, firstTarget,
                       "Replay must retain the first target as the forward origin.")
    }

    func testReplacementIdentityRemainsNavigableBeforeItsContentLoads() throws {
        let context = profile()
        let store = try ClientRepository(context: context,
                                             persistence: MemoryPendingActionPersistence())
        let target = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("agent"), messageID: ExactText("old"))
        let replacement = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("agent"), messageID: ExactText("new"))
        let payload = try JSONValue.parse(Data(#"{"title":"Message"}"#.utf8))
        _ = store.applyRelayEvent(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: target, originalPayload: payload), .message)),
            context: context)
        _ = store.applyRelayEvent(RelayEvent(sequence: 2, body: .originReference(replacement)),
            context: context)
        _ = store.applyRelayEvent(RelayEvent(sequence: 3,
            body: .terminal(target, .superseded, nil)), context: context)

        let live = try LivePresentationStore(store: store, context: context)
        XCTAssertNil(live.request(for: replacement), "Replacement content has not loaded on this phone.")
        XCTAssertEqual(live.request(for: target)?.supersededByMessageKeys, [replacement],
                       "The accepted replacement identity remains available for a graceful destination.")
    }

    func testCrossIDSupersedesKeepsTheTargetSlotAndThreadAcrossAChain() throws {
        let context = profile()
        let store = try ClientRepository(context: context,
                                             persistence: MemoryPendingActionPersistence())
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
        XCTAssertEqual(live.request(for: target)?.supersededByMessageKeys, [replacementOne])
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
        XCTAssertEqual(live.request(for: replacementOne)?.supersededByMessageKeys, [replacementTwo])
        XCTAssertEqual(secondReplacement.inboxPriority, .high)
        XCTAssertEqual(secondReplacement.inboxThread, ExactText("release"))
        XCTAssertEqual(secondReplacement.inboxDueAtMilliseconds, 5000)
        let chainedEntries = InboxThreadListProjection.grouped(live.inboxRows.map(InboxItem.request))
        guard case let .thread(chainedThread, chainedMembers) = chainedEntries.first else {
            return XCTFail("The chained replacement should keep the same adjacent thread slot.")
        }
        XCTAssertEqual(chainedThread, ExactText("release"))
        XCTAssertEqual(chainedMembers.map(\.id), [.request(earlier), .request(replacementTwo)])

    }

    func testSupersedesOriginTargetDoesNotCrossSenderIdentity() throws {
        let context = profile()
        let store = try ClientRepository(context: context,
                                             persistence: MemoryPendingActionPersistence())
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

}
