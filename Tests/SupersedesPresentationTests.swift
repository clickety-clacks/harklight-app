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
    }

    func testSupersededTargetKeepsEveryReplacementIdentity() throws {
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

        let liveStore = try AttentionDomainStore(context: context,
                                                 persistence: MemoryAttentionStatePersistence())
        for event in events { try liveStore.apply(event, context: context) }
        let liveSnapshot = try liveStore.snapshot(context: context)
        XCTAssertEqual(liveSnapshot.cursor, 5, "Both live terminals must commit so sync can continue.")
        XCTAssertEqual(liveSnapshot.remoteStates[firstTarget]?.supersededByMessageKeys, [replacement])
        XCTAssertEqual(liveSnapshot.remoteStates[secondTarget]?.supersededByMessageKeys, [replacement])
        XCTAssertEqual(liveSnapshot.remoteStates[replacement]?.supersedesOriginTarget, firstTarget,
                       "The forward keeps the first target as its inbox origin.")

        let replayStore = try AttentionDomainStore(context: context,
                                                   persistence: MemoryAttentionStatePersistence())
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
        let store = try AttentionDomainStore(context: context,
                                             persistence: MemoryAttentionStatePersistence())
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

    func testLoadingOlderAccountStateBackfillsReplacementIdentity() throws {
        let context = profile()
        let persistence = MemoryAttentionStatePersistence()
        let store = try AttentionDomainStore(context: context, persistence: persistence)
        let target = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("agent"), messageID: ExactText("old"))
        let replacement = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("agent"), messageID: ExactText("new"))
        let targetPayload = try JSONValue.parse(Data(#"{"title":"Message"}"#.utf8))
        let replacementPayload = try JSONValue.parse(Data(#"{"title":"Replacement","supersedes":["old"]}"#.utf8))
        try store.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: target, originalPayload: targetPayload), .message)),
            context: context)
        try store.apply(RelayEvent(sequence: 2,
            body: .delivery(StoredRequest(key: replacement, originalPayload: replacementPayload), .message)),
            context: context)
        try store.apply(RelayEvent(sequence: 3,
            body: .terminal(target, .superseded, nil)), context: context)

        let encoded = try XCTUnwrap(persistence.load(identity: context.identity))
        let propertyList = try PropertyListSerialization.propertyList(from: encoded,
            options: [], format: nil)
        func removingReplacementField(_ value: Any) -> Any {
            if var dictionary = value as? [String: Any] {
                dictionary.removeValue(forKey: "supersededByMessageKeys")
                return dictionary.mapValues(removingReplacementField)
            }
            if let array = value as? [Any] {
                return array.map(removingReplacementField)
            }
            return value
        }
        let olderAccountState = removingReplacementField(propertyList)
        let olderEncoding = try PropertyListSerialization.data(fromPropertyList: olderAccountState,
            format: .binary, options: 0)
        try persistence.commit(olderEncoding, identity: context.identity)

        let restoredStore = try AttentionDomainStore(context: context, persistence: persistence)
        let restored = try LivePresentationStore(store: restoredStore, context: context)
        XCTAssertEqual(restored.request(for: target)?.supersededByMessageKeys, [replacement])
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
        XCTAssertEqual(live.request(for: target)?.supersededByMessageKeys, [replacement],
                       "A paged target also retains its forward replacement link.")
    }

    func testPageBackfillsEveryReplacementLoadedAfterTargetTerminal() throws {
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
        let first = key("replacement-one")
        let second = key("replacement-two")
        _ = try store.beginInboxCandidate(startupID: "snapshot", since: 0,
                                          batches: [], context: context)
        try store.saveInboxInitialPage(snapshotID: "snapshot", highWater: 5,
            items: [
                InboxSnapshotItem(acceptance: RelayEvent(sequence: 1, body: .delivery(
                    StoredRequest(key: target, originalPayload: try payload("Target")), .message)),
                    terminal: RelayEvent(sequence: 5, body: .terminal(target, .superseded, nil))),
                InboxSnapshotItem(acceptance: RelayEvent(sequence: 2, body: .delivery(
                    StoredRequest(key: first, originalPayload: try payload("First", supersedes: "target")),
                    .message))),
                InboxSnapshotItem(acceptance: RelayEvent(sequence: 4, body: .delivery(
                    StoredRequest(key: second, originalPayload: try payload("Second", supersedes: "target")),
                    .message)))
            ], nextCursor: nil, receiptCursor: nil, context: context)

        let live = try LivePresentationStore(store: store, context: context)
        XCTAssertEqual(live.request(for: target)?.supersededByMessageKeys, [first, second],
                       "A page without full event history retains all accepted replacements.")
    }

    func testInboxPageAppliesOneForwardForSeveralTargetsInFirstTerminalOrder() throws {
        let context = profile()
        let store = try AttentionDomainStore(context: context,
                                             persistence: MemoryAttentionStatePersistence())
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
        _ = try store.beginInboxCandidate(startupID: "multi-target-page", since: 0,
                                          batches: [], context: context)
        let firstAcceptance = RelayEvent(sequence: 1, body: .delivery(
            StoredRequest(key: firstTarget, originalPayload: try payload("First")), .message))
        let secondAcceptance = RelayEvent(sequence: 2, body: .delivery(
            StoredRequest(key: secondTarget, originalPayload: try payload("Second")), .message))
        let replacementAcceptance = RelayEvent(sequence: 3, body: .delivery(
            StoredRequest(key: replacement,
                originalPayload: try payload("Replacement", supersedes: ["first", "second"])),
            .message))

        // Inbox display order is newest first, opposite the terminal sequence.
        try store.saveInboxInitialPage(snapshotID: "multi-target-snapshot", highWater: 5,
            items: [
                InboxSnapshotItem(acceptance: replacementAcceptance),
                InboxSnapshotItem(acceptance: secondAcceptance,
                    terminal: RelayEvent(sequence: 5,
                        body: .terminal(secondTarget, .superseded, nil))),
                InboxSnapshotItem(acceptance: firstAcceptance,
                    terminal: RelayEvent(sequence: 4,
                        body: .terminal(firstTarget, .superseded, nil)))
            ], nextCursor: nil, receiptCursor: nil, context: context)

        let snapshot = try store.snapshot(context: context)
        XCTAssertEqual(snapshot.remoteStates[firstTarget]?.supersededByMessageKeys, [replacement])
        XCTAssertEqual(snapshot.remoteStates[secondTarget]?.supersededByMessageKeys, [replacement])
        XCTAssertEqual(snapshot.remoteStates[replacement]?.supersedesOriginTarget, firstTarget,
                       "Page display order must not replace the first terminal as the origin.")
    }
}
