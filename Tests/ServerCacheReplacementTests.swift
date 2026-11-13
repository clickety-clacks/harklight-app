import AttentionDomain
import CryptoKit
import Foundation
import HarklightNativeRelay
import XCTest

final class ServerCacheReplacementTests: XCTestCase {
    func testBothInitialAndOlderServerPagesMayContainMoreThanTwentyItems() throws {
        let context = context()
        let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let items = (1...42).map { index in
            InboxSnapshotItem(acceptance: RelayEvent(sequence: UInt64(index),
                body: .delivery(request(key("row-\(index)", context: context), title: "Row \(index)"), .message)),
                terminal: nil)
        }
        _ = try repository.beginInboxCandidate(startupID: "large-pages", since: 0, batches: [], context: context)
        try repository.saveInboxInitialPage(snapshotID: "large-pages", highWater: 42,
            items: Array(items.prefix(21)), nextCursor: "older", receiptCursor: nil, context: context)
        _ = try repository.prepareInboxCheckpointAcknowledgement(context: context)
        _ = try repository.acceptInboxCheckpoint(snapshotID: "large-pages", highWater: 42, context: context)
        try repository.saveInboxOlderPage(snapshotID: "large-pages", highWater: 42, cursor: "older",
            items: Array(items.suffix(21)), nextCursor: nil, context: context)
        XCTAssertEqual(try repository.snapshot(context: context).requests.count, 42)
    }

    func testHeldConversationFactSurvivesCacheRestartAndInboxReplacement() async throws {
        let context = context()
        let key = key("older-chat", context: context)
        let binding = ConversationBinding(request: key, revision: 1)
        let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let turn = ConversationTurn(id: ExactText("held-reply"), binding: binding, author: .origin,
            sessionHandle: ExactText("session"), text: ExactText("Before the older page"), kind: .reply)
        try repository.applyConversation(ConversationEvent(sequence: 1, binding: binding,
            fact: .turn(turn)), context: context)
        XCTAssertNil(try repository.conversationSnapshot(context: context).threads[key])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("cache.json")
        let cache = FileServerStateCache(identity: context.identity, fileURL: path)
        try await cache.save(ServerStateCacheSnapshot.make(identity: context.identity,
            from: repository.serverCacheSnapshot(context: context),
            conversations: repository.conversationSnapshot(context: context)))
        let stored = try await FileServerStateCache(identity: context.identity, fileURL: path).load()
        let restored = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        try restored.restoreCachedServerState(XCTUnwrap(stored).attentionDomainState(for: context.identity), context: context)
        _ = try restored.beginInboxCandidate(startupID: "after-reset", since: 0, batches: [], context: context)
        try restored.saveInboxInitialPage(snapshotID: "after-reset", highWater: 1,
            items: [], nextCursor: "older", receiptCursor: nil, context: context)
        XCTAssertEqual(try restored.conversationSnapshot(context: context).cursor, 1,
                       "An ordinary inbox replacement cannot reset the separate conversation stream.")
        _ = try restored.prepareInboxCheckpointAcknowledgement(context: context)
        _ = try restored.acceptInboxCheckpoint(snapshotID: "after-reset", highWater: 1, context: context)
        let acceptance = RelayEvent(sequence: 1,
            body: .delivery(request(key, title: "Older chat"), .message),
            conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("session")))
        try restored.saveInboxOlderPage(snapshotID: "after-reset", highWater: 1, cursor: "older",
            items: [InboxSnapshotItem(acceptance: acceptance, terminal: nil)], nextCursor: nil, context: context)
        let conversation = try restored.conversationSnapshot(context: context)
        XCTAssertEqual(conversation.cursor, 1)
        XCTAssertEqual(conversation.threads[key]?.turns.map(\.id), [turn.id])
        XCTAssertEqual(conversation.threads[key]?.turns.first?.text, turn.text)
    }

    func testSnapshotReplacesChangedPayloadAndAcceptanceOrderWithoutStoppingOtherRows() throws {
        let context = context()
        let first = key("first", context: context)
        let second = key("second", context: context)
        let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        _ = try repository.apply(RelayEvent(sequence: 1,
            body: .delivery(request(first, title: "Cached"), .message)), context: context)
        _ = try repository.beginInboxCandidate(startupID: UUID().uuidString,
            since: 1, batches: [], context: context)

        try repository.saveInboxInitialPage(snapshotID: UUID().uuidString,
            highWater: 3, items: [
                InboxSnapshotItem(acceptance: RelayEvent(sequence: 2,
                    body: .delivery(request(first, title: "Server"), .message))),
                InboxSnapshotItem(acceptance: RelayEvent(sequence: 3,
                    body: .delivery(request(second, title: "Other request"), .message)))
            ], nextCursor: nil, receiptCursor: nil, context: context)

        let state = try repository.snapshot(context: context)
        XCTAssertEqual(state.requests[first]?.originalPayload, request(first, title: "Server").originalPayload)
        XCTAssertEqual(state.requests[first]?.acceptanceOrder, 2)
        XCTAssertEqual(state.requests[second]?.acceptanceOrder, 3)
        XCTAssertTrue(state.inboxCandidate?.hasInitialPage == true)
    }

    func testRevisedRenderedCacheCannotRejectOriginalInboxDeliveryAfterRestart() async throws {
        let context = context()
        let key = key("revised", context: context)
        let original = request(key, title: "Original")
        let revised = request(key, title: "Revised")
        let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        _ = try repository.apply(RelayEvent(sequence: 1,
            body: .delivery(original, .message)), context: context)
        for (sequence, payload) in [(UInt64(1), original.originalPayload), (UInt64(2), revised.originalPayload)] {
            try repository.applyConversation(ConversationEvent(sequence: sequence,
                binding: ConversationBinding(request: key, revision: sequence),
                fact: .request(sessionHandle: ExactText("session"), payload: payload)), context: context)
        }
        let rendered = try repository.snapshot(context: context)
        XCTAssertEqual(rendered.requests[key]?.originalPayload, revised.originalPayload)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("server-cache.json")
        let cache = FileServerStateCache(identity: context.identity, fileURL: url)
        try await cache.save(ServerStateCacheSnapshot.make(identity: context.identity,
            from: rendered, conversations: repository.conversationSnapshot(context: context)))
        let reopenedCache = FileServerStateCache(identity: context.identity, fileURL: url)
        let loaded = try await reopenedCache.load()
        let cached = try XCTUnwrap(loaded)
        XCTAssertEqual(cached.requests.first?.request.originalPayload, revised.originalPayload,
                       "The rendered cache can differ from the original supplied by inbox_start.")
        let restarted = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        try restarted.restoreCachedServerState(cached.attentionDomainState(for: context.identity), context: context)
        _ = try restarted.beginInboxCandidate(startupID: "after-revised-cache", since: 1,
            batches: [], context: context)
        try restarted.saveInboxInitialPage(snapshotID: "original-delivery", highWater: 1,
            items: [InboxSnapshotItem(acceptance: RelayEvent(sequence: 1,
                body: .delivery(original, .message)))], nextCursor: nil, receiptCursor: nil, context: context)
        XCTAssertEqual(try restarted.snapshot(context: context).requests[key]?.originalPayload, original.originalPayload)
        for (sequence, payload) in [(UInt64(1), original.originalPayload), (UInt64(2), revised.originalPayload)] {
            try restarted.applyConversation(ConversationEvent(sequence: sequence,
                binding: ConversationBinding(request: key, revision: sequence),
                fact: .request(sessionHandle: ExactText("session"), payload: payload)), context: context)
        }
        XCTAssertEqual(try restarted.snapshot(context: context).requests[key]?.originalPayload, revised.originalPayload)
    }

    func testRefreshKeepsCacheUntilServerRespondsThenReplacesItEvenWhenEmpty() throws {
        let context = context()
        let cachedKey = key("cached", context: context)
        let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        _ = try repository.apply(RelayEvent(sequence: 1,
            body: .delivery(request(cachedKey, title: "Last server value"), .message)), context: context)

        _ = try repository.beginInboxCandidate(startupID: "unanswered-start", since: 1,
            batches: [], context: context)
        XCTAssertNotNil(try repository.snapshot(context: context).requests[cachedKey])
        try repository.discardInboxCandidate(context: context)
        XCTAssertNotNil(try repository.snapshot(context: context).requests[cachedKey],
                        "A request without a server response cannot erase cached content.")

        _ = try repository.beginInboxCandidate(startupID: "empty-server-snapshot", since: 1,
            batches: [], context: context)
        try repository.saveInboxInitialPage(snapshotID: "empty", highWater: 1,
            items: [], nextCursor: nil, receiptCursor: nil, context: context)
        XCTAssertTrue(try repository.snapshot(context: context).requests.isEmpty,
                      "The server's empty replacement must not fall back to the old cache.")
    }

    func testPendingActionPersistenceDoesNotRestoreServerRequests() throws {
        let context = context()
        let persistence = MemoryPendingActionPersistence()
        let repository = try ClientRepository(context: context, persistence: persistence)
        _ = try repository.apply(RelayEvent(sequence: 1,
            body: .delivery(request(key("one", context: context), title: "Server only"), .message)),
            context: context)

        let restarted = try ClientRepository(context: context, persistence: persistence)
        let state = try restarted.snapshot(context: context)
        XCTAssertTrue(state.requests.isEmpty)
        XCTAssertTrue(state.remoteStates.isEmpty)
        XCTAssertEqual(state.cursor, 0)
    }

    func testCacheFromAnotherServerPersonOrDeviceIsDiscarded() async throws {
        let original = context().identity
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cache.json")
        let snapshot = ServerStateCacheSnapshot(identity: original, cursor: 10, conversationCursor: 4,
            requests: [], conversations: [], inboxView: nil, currentRequestKeys: [])
        let identities = [
            ProfileIdentity(trustedRelayAuthority: ExactText("other.example"), personID: original.personID, deviceID: original.deviceID),
            ProfileIdentity(trustedRelayAuthority: original.trustedRelayAuthority, personID: ExactText("another-person"), deviceID: original.deviceID),
            ProfileIdentity(trustedRelayAuthority: original.trustedRelayAuthority, personID: original.personID, deviceID: ExactText("another-device"))
        ]
        for identity in identities {
            let writer = FileServerStateCache(identity: original, fileURL: file)
            try await writer.save(snapshot)
            let reader = FileServerStateCache(identity: identity, fileURL: file)
            let loaded = try await reader.load()
            XCTAssertNil(loaded)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            XCTAssertThrowsError(try snapshot.attentionDomainState(for: identity))
        }
    }

    func testUpgradeMovesOnlyUnsentUserInputOnceAndDiscardsServerState() throws {
        let context = context()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identityBytes = JSONValue.array([
            .string(context.identity.trustedRelayAuthority),
            .string(context.identity.personID),
            .string(context.identity.deviceID)
        ]).canonicalJSON
        let hash = SHA256.hash(data: Data(identityBytes.utf8)).map { String(format: "%02x", $0) }.joined()
        let retired = directory.appendingPathComponent("\(hash).plist")
        let source = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let payload = try JSONValue.parse(Data(#"{"title":"Question","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"reply","label":"Reply","kind":"text"},{"id":"yes","label":"Yes","kind":"value","value":true},{"id":"seen","label":"Seen","kind":"value","value":{"acknowledgment":"seen"}}]}}"#.utf8))
        let inputs: [[TypedInputRecord]] = [
            [.compatibilityText(action: ExactText("reply"), text: ExactText("Unsent exact text"))],
            [.compatibilityValue(action: ExactText("yes"))],
            [.compatibilityValue(action: ExactText("seen"))],
            [.compatibilityValue(action: ExactText("yes"))]
        ]
        for (index, input) in inputs.enumerated() {
            let requestKey = key("input-\(index)", context: context)
            _ = try source.apply(RelayEvent(sequence: UInt64(index + 1),
                body: .delivery(StoredRequest(key: requestKey, originalPayload: payload), .message)), context: context)
            let port = AttentionDomainPort(store: source)
            let selector = try XCTUnwrap(port.inspect(context: port.context, request: requestKey).requests.first?.selector)
            let receipt = try port.submit(SubmitIntent(context: port.context, selector: selector,
                intentID: UUID(), inputs: input))
            if index == inputs.count - 1 {
                try source.recordAcceptedOperation(receipt.intentID, operationID: receipt.opID,
                    terminalSequence: 5, context: context)
            }
        }
        let snapshot = try source.snapshot(context: context)
        let expectedPending = snapshot.intents.filter { $0.value.disposition == .pending }
        let draftKey = key("unfinished", context: context)
        let unfinished = RequestDraft(inputs: [:], compatibility: CompatibilityDraft(
            selectedActionID: ExactText("reply"), textByActionID: [ExactText("reply"): ExactText("Still typing")]))
        let active = Dictionary(uniqueKeysWithValues: snapshot.intents.values.map { ($0.requestKey, $0.intentID) })
        let old = UpgradeInputFixture(profileIdentity: context.identity, drafts: [draftKey: unfinished],
            intents: snapshot.intents, intentByRequest: active)
        let oldBytes = try PropertyListEncoder().encode(old)
        try oldBytes.write(to: retired)
        let persistence = FilePendingActionPersistence(directoryURL: directory)
        let repository = try ClientRepository(context: context, persistence: persistence)
        let upgraded = try repository.snapshot(context: context)
        XCTAssertTrue(upgraded.requests.isEmpty)
        XCTAssertTrue(upgraded.remoteStates.isEmpty)
        XCTAssertEqual(upgraded.cursor, 0)
        XCTAssertTrue(upgraded.conversationThreads.isEmpty)
        XCTAssertEqual(upgraded.drafts[draftKey], unfinished)
        XCTAssertEqual(upgraded.intents, expectedPending,
                       "Typed answer, choice and Seen retain their exact operation IDs and bytes.")
        XCTAssertTrue(upgraded.outbox.isEmpty, "Moved input is not sent before current server validation.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: retired.path))

        // A crash after queue commit but before old-file removal cannot reimport it.
        try repository.discardUnsentOperation(try XCTUnwrap(expectedPending.keys.first), context: context)
        let remaining = try repository.snapshot(context: context).intents
        try oldBytes.write(to: retired)
        let restarted = try ClientRepository(context: context, persistence: persistence)
        XCTAssertEqual(try restarted.snapshot(context: context).intents, remaining)
        XCTAssertFalse(FileManager.default.fileExists(atPath: retired.path))
    }

    func testUpgradeKeepsDiscussionAndRevisionAnswerInputUntilServerThreadReturns() throws {
        let context = context()
        let requestKey = key("upgrade-chat", context: context)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identityBytes = JSONValue.array([
            .string(context.identity.trustedRelayAuthority), .string(context.identity.personID),
            .string(context.identity.deviceID)
        ]).canonicalJSON
        let hash = SHA256.hash(data: Data(identityBytes.utf8)).map { String(format: "%02x", $0) }.joined()
        let retired = directory.appendingPathComponent("\(hash).plist")
        let source = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        try source.applyConversation(ConversationEvent(sequence: 1,
            binding: ConversationBinding(request: requestKey, revision: 1),
            fact: .request(sessionHandle: ExactText("retired-session"),
                payload: request(requestKey, title: "Retired question").originalPayload)), context: context)
        var oldThread = try XCTUnwrap(source.conversationSnapshot(context: context).threads[requestKey])
        let submittingID = UUID()
        let unknownID = UUID()
        let inputs: [UInt64: ConversationDraft] = [
            1: ConversationDraft(binding: ConversationBinding(request: requestKey, revision: 1),
                text: ExactText("Submitted but not confirmed"), disposition: .submitting(submittingID)),
            2: ConversationDraft(binding: ConversationBinding(request: requestKey, revision: 2),
                text: ExactText("Still editing")),
            3: ConversationDraft(binding: ConversationBinding(request: requestKey, revision: 3),
                text: ExactText("Unknown result"), disposition: .outcomeUnknown(unknownID))
        ]
        let answer = RequestDraft(inputs: [:], compatibility: CompatibilityDraft(
            selectedActionID: ExactText("reply"), textByActionID: [ExactText("reply"): ExactText("Unsent archived answer")]))
        oldThread.drafts = inputs
        oldThread.answerDrafts = [1: answer, 2: answer]
        oldThread.terminal = .answered
        oldThread.accountReadThroughConversationSequence = 99
        let old = UpgradeInputFixture(profileIdentity: context.identity, drafts: [:], intents: [:],
            intentByRequest: [:], conversation: UpgradeConversationFixture(threads: [requestKey: oldThread]))
        let bytes = try PropertyListEncoder().encode(old)
        try bytes.write(to: retired)
        let persistence = FilePendingActionPersistence(directoryURL: directory)
        let upgraded = try ClientRepository(context: context, persistence: persistence)
        XCTAssertTrue(try upgraded.snapshot(context: context).requests.isEmpty)
        XCTAssertTrue(try upgraded.conversationSnapshot(context: context).threads.isEmpty,
                      "User input cannot manufacture server request state during upgrade.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: retired.path))

        // Restart before any server response: the one-time transfer must already
        // have committed the discussion queue to its own file.
        let restarted = try ClientRepository(context: context, persistence: persistence)
        _ = try restarted.apply(RelayEvent(sequence: 1,
            body: .delivery(request(requestKey, title: "Current server question"), .message),
            conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("current-session"))),
            context: context)
        var thread = try XCTUnwrap(restarted.conversationSnapshot(context: context).threads[requestKey])
        XCTAssertEqual(thread.drafts, inputs)
        XCTAssertEqual(thread.answerDrafts, oldThread.answerDrafts)
        XCTAssertEqual(thread.sessionHandle, ExactText("current-session"))
        XCTAssertNil(thread.terminal)
        XCTAssertNil(thread.accountReadThroughConversationSequence)
        XCTAssertEqual(try restarted.snapshot(context: context).requests[requestKey]?.originalPayload,
                       request(requestKey, title: "Current server question").originalPayload)
        XCTAssertTrue(try restarted.snapshot(context: context).outbox.isEmpty)

        // The server's exact accepted operation settles only that discussion.
        let turn = ConversationTurn(id: ExactText("accepted-discussion"),
            binding: ConversationBinding(request: requestKey, revision: 1), author: .person,
            sessionHandle: ExactText("current-session"), text: inputs[1]!.text,
            operationID: submittingID, kind: .discussion)
        try restarted.applyConversation(ConversationEvent(sequence: 1, binding: turn.binding,
            fact: .turn(turn)), context: context)
        thread = try XCTUnwrap(restarted.conversationSnapshot(context: context).threads[requestKey])
        XCTAssertNil(thread.drafts[1])
        XCTAssertEqual(thread.drafts[2], inputs[2])
        XCTAssertEqual(thread.drafts[3], inputs[3])
        XCTAssertEqual(thread.answerDrafts, oldThread.answerDrafts)
    }

    func testQueuedAnswerSurvivesRestartButCannotOverrideServerAnswer() throws {
        let context = context()
        let key = key("answer", context: context)
        let payload = try JSONValue.parse(Data(#"{"title":"Question","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"yes","label":"Yes","kind":"value","value":"yes"}]}}"#.utf8))
        let request = StoredRequest(key: key, originalPayload: payload)
        let persistence = MemoryPendingActionPersistence()
        let first = try ClientRepository(context: context, persistence: persistence)
        _ = try first.apply(RelayEvent(sequence: 1, body: .delivery(request, .message)), context: context)
        let port = AttentionDomainPort(store: first)
        let selector = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first?.selector)
        let receipt = try port.submit(SubmitIntent(context: port.context, selector: selector,
            intentID: UUID(), inputs: [.compatibilityValue(action: ExactText("yes"))]))
        let queued = try XCTUnwrap(first.lookupIntent(receipt.intentID, context: context))

        let restarted = try ClientRepository(context: context, persistence: persistence)
        let restored = try XCTUnwrap(restarted.lookupIntent(receipt.intentID, context: context))
        XCTAssertEqual(restored.operationID, queued.operationID)
        XCTAssertEqual(restored.wireFrame, queued.wireFrame)
        XCTAssertTrue(try restarted.snapshot(context: context).requests.isEmpty)
        _ = try restarted.beginInboxCandidate(startupID: UUID().uuidString, since: 0,
            batches: [], context: context)
        let snapshotID = UUID().uuidString
        let answered = RelayEvent(sequence: 2, body: .terminal(key, .answered, nil),
            accountAnswerOutcome: .reply(ExactText("Server answer")))
        try restarted.saveInboxInitialPage(snapshotID: snapshotID, highWater: 2,
            items: [InboxSnapshotItem(acceptance: RelayEvent(sequence: 1,
                body: .delivery(request, .message)), terminal: answered)],
            nextCursor: nil, receiptCursor: nil, context: context)
        _ = try restarted.prepareInboxCheckpointAcknowledgement(context: context)
        _ = try restarted.acceptInboxCheckpoint(snapshotID: snapshotID, highWater: 2, context: context)

        XCTAssertThrowsError(try restarted.queueOriginalOperationForUserTap(receipt.intentID, context: context)) {
            XCTAssertEqual($0 as? AttentionStoreError, .intentMissing)
        }
        XCTAssertNil(try restarted.lookupIntent(receipt.intentID, context: context))
        XCTAssertTrue(try restarted.snapshot(context: context).outbox.isEmpty)
        let currentPort = AttentionDomainPort(store: restarted)
        let shown = try XCTUnwrap(currentPort.inspect(context: currentPort.context, request: key).requests.first)
        XCTAssertEqual(shown.accountAnswerOutcome, .reply(ExactText("Server answer")))
        XCTAssertNil(shown.submittedAnswer, "A queued local answer is not the server's answer.")
    }

    func testCompleteServerSnapshotDropsMissingAnswerButPartialPageDoesNot() throws {
        let context = context()
        let missing = key("missing", context: context)
        let other = key("other", context: context)
        let payload = try JSONValue.parse(Data(#"{"title":"Question","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"yes","label":"Yes","kind":"value","value":true}]}}"#.utf8))
        let persistence = MemoryPendingActionPersistence()
        let first = try ClientRepository(context: context, persistence: persistence)
        _ = try first.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: missing, originalPayload: payload), .message)), context: context)
        let port = AttentionDomainPort(store: first)
        let selector = try XCTUnwrap(port.inspect(context: port.context, request: missing).requests.first?.selector)
        let receipt = try port.submit(SubmitIntent(context: port.context, selector: selector,
            intentID: UUID(), inputs: [.compatibilityValue(action: ExactText("yes"))]))
        let restarted = try ClientRepository(context: context, persistence: persistence)
        _ = try restarted.beginInboxCandidate(startupID: "fresh", since: 0, batches: [], context: context)
        try restarted.saveInboxInitialPage(snapshotID: "fresh", highWater: 2,
            items: [InboxSnapshotItem(acceptance: RelayEvent(sequence: 2,
                body: .delivery(StoredRequest(key: other, originalPayload: payload), .message)))],
            nextCursor: "older", receiptCursor: nil, context: context)
        _ = try restarted.prepareInboxCheckpointAcknowledgement(context: context)
        _ = try restarted.acceptInboxCheckpoint(snapshotID: "fresh", highWater: 2, context: context)
        XCTAssertNotNil(try restarted.lookupIntent(receipt.intentID, context: context),
                        "An unloaded page does not prove the request is gone.")
        try restarted.saveInboxOlderPage(snapshotID: "fresh", highWater: 2,
            cursor: "older", items: [], nextCursor: nil, context: context)
        XCTAssertNil(try restarted.lookupIntent(receipt.intentID, context: context))
        XCTAssertTrue(try restarted.snapshot(context: context).outbox.isEmpty)
        let again = try ClientRepository(context: context, persistence: persistence)
        XCTAssertNil(try again.lookupIntent(receipt.intentID, context: context))
    }

    func testChangedServerInterfaceRebuildsDraftAndAllowsReply() throws {
        let replacement = try JSONValue.parse(Data(#"{"title":"New reply","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"reply","label":"Reply","kind":"text"}]}}"#.utf8))
        try assertChangedInterfaceCanSubmit(replacement,
            inputs: [.compatibilityText(action: ExactText("reply"), text: ExactText("Fresh reply"))])
    }

    func testChangedServerInterfaceRebuildsDraftAndAllowsSeen() throws {
        let replacement = try JSONValue.parse(Data(#"{"title":"New notice","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"seen","label":"Seen","kind":"value","value":{"acknowledgment":"seen"}}]}}"#.utf8))
        try assertChangedInterfaceCanSubmit(replacement,
            inputs: [.compatibilityValue(action: ExactText("seen"))])
    }

    private func assertChangedInterfaceCanSubmit(_ payload: JSONValue,
                                                 inputs: [TypedInputRecord]) throws {
        for viaPage in [false, true] {
            let context = context()
            let key = key("changed-draft", context: context)
            let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
            if viaPage {
                _ = try repository.beginInboxCandidate(startupID: UUID().uuidString, since: 0,
                    batches: [], context: context)
            }
            let oldPayload = try JSONValue.parse(Data(#"{"title":"Old form","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"old-text","label":"Old","kind":"text"}]}}"#.utf8))
            _ = try repository.apply(RelayEvent(sequence: 1,
                body: .delivery(StoredRequest(key: key, originalPayload: oldPayload), .message)), context: context)
            let port = AttentionDomainPort(store: repository)
            let oldSelector = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first?.selector)
            let oldDraft = RequestDraft(inputs: [:], compatibility: CompatibilityDraft(
                selectedActionID: ExactText("old-text"), textByActionID: [ExactText("old-text"): ExactText("Earlier edit")]))
            try repository.saveDraft(oldDraft, selector: oldSelector, context: context)
            let replacement = StoredRequest(key: key, originalPayload: payload)
            let event = RelayEvent(sequence: 2, body: .delivery(replacement, .message))
            if viaPage {
                try repository.saveInboxInitialPage(snapshotID: UUID().uuidString, highWater: 2,
                    items: [InboxSnapshotItem(acceptance: event)], nextCursor: nil, receiptCursor: nil, context: context)
            } else {
                _ = try repository.apply(event, context: context)
            }
            XCTAssertEqual(try repository.snapshot(context: context).drafts[key],
                           RequestDraft(interface: replacement.interface))
            let shown = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first)
            let selector = try XCTUnwrap(shown.selector)
            let receipt = try port.submit(SubmitIntent(context: port.context, selector: selector,
                intentID: UUID(), inputs: inputs))
            XCTAssertEqual(receipt.inputs, inputs, "The fresh current interface must accept the new tap.")
            XCTAssertNotNil(try repository.lookupIntent(receipt.intentID, context: context))
        }
    }

    func testServerRetractionReplacesEarlierOperationRefusalTimestamp() throws {
        let context = context()
        let key = key("retraction", context: context)
        let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let payload = try JSONValue.parse(Data(#"{"title":"Question","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"yes","label":"Yes","kind":"value","value":"yes"}]}}"#.utf8))
        _ = try repository.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: payload), .message),
            conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("session"))), context: context)
        let port = AttentionDomainPort(store: repository)
        let selector = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first?.selector)
        let receipt = try port.submit(SubmitIntent(context: port.context, selector: selector,
            intentID: UUID(), inputs: [.compatibilityValue(action: ExactText("yes"))]))
        try repository.recordAnswerRefusedByRetraction(receipt.intentID, operationID: receipt.opID,
            retractedAtMilliseconds: 100, context: context)
        _ = try repository.apply(RelayEvent(sequence: 2, body: .terminal(key, .cleared, nil),
            conversation: RelayConversationMetadata(revision: nil, terminalReason: ExactText("retracted"),
                retractedAtMilliseconds: 200)), context: context)
        XCTAssertEqual(try repository.conversationSnapshot(context: context).threads[key]?.reportedRetractedAtMilliseconds, 200)
    }

    func testReadRequestWaitsForServerAndNextSnapshotReplacesReadPosition() throws {
        let context = context()
        let key = key("chat", context: context)
        let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        _ = try repository.apply(RelayEvent(sequence: 1,
            body: .delivery(request(key, title: "Chat"), .message),
            conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("session"))), context: context)
        let binding = ConversationBinding(request: key, revision: 1)
        let turn = ConversationTurn(id: ExactText("reply"), binding: binding, author: .origin,
            sessionHandle: ExactText("session"), text: ExactText("Reply"), kind: .reply)
        _ = try repository.applyConversation(ConversationEvent(sequence: 1,
            binding: binding, fact: .turn(turn)), context: context)
        try repository.finishConversationReplay(at: 1, chatReadPositions: [], context: context)
        let pending = try XCTUnwrap(repository.markConversationRead(key, through: turn.id, context: context))
        var thread = try XCTUnwrap(repository.conversationSnapshot(context: context).threads[key])
        XCTAssertEqual(thread.accountReadThroughConversationSequence, 0)
        XCTAssertTrue(thread.hasUnreadAgentReply)

        try repository.acceptConversationReadPosition(pending, serverPosition: 1, context: context)
        thread = try XCTUnwrap(repository.conversationSnapshot(context: context).threads[key])
        XCTAssertFalse(thread.hasUnreadAgentReply)
        try repository.finishConversationReplay(at: 1, chatReadPositions: [], context: context)
        thread = try XCTUnwrap(repository.conversationSnapshot(context: context).threads[key])
        XCTAssertEqual(thread.accountReadThroughConversationSequence, 0)
        XCTAssertTrue(thread.hasUnreadAgentReply, "No local read maximum overrides the server snapshot.")
    }

    private func context() -> ProfileContext {
        ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device")), transportMode: .relay)
    }

    private func key(_ value: String, context: ProfileContext) -> RequestKey {
        RequestKey(accountScope: context.identity.personID, senderID: ExactText("sender"), messageID: ExactText(value))
    }

    private func request(_ key: RequestKey, title: String) -> StoredRequest {
        StoredRequest(key: key, originalPayload: .object([JSONMember("title", .string(ExactText(title)))]))
    }
}

/// Only the historical user-input field names matter. These deliberately
/// invalid server fields prove the upgrade never decodes server-owned records.
private struct UpgradeInputFixture: Encodable {
    let schemaVersion = 2
    let profileIdentity: ProfileIdentity
    let drafts: [RequestKey: RequestDraft]
    let intents: [UUID: Submission]
    let intentByRequest: [RequestKey: UUID]
    let requests = "discarded server cache"
    let remoteStates = "discarded server status"
    var conversation: UpgradeConversationFixture? = nil
    let cursor = 999
}

private struct UpgradeConversationFixture: Encodable {
    let threads: [RequestKey: ConversationThread]
    let cursor = "discarded server cursor"
    let events = "discarded server events"
    let chatReadPositions = "discarded server read positions"
}
