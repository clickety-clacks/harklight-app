import AttentionDomain
import Foundation
import HarklightNativeRelay
import XCTest

/// Controls the persistence seam while still exercising the production file adapter.
private final class PageFilePersistence: PendingActionPersistence, @unchecked Sendable {
    enum Failure { case beforeReplacement }
    let file: FilePendingActionPersistence
    private let lock = NSLock()
    private var nextAction: (@Sendable () throws -> Void)?
    private var failure: Failure?

    init(directory: URL) { file = FilePendingActionPersistence(directoryURL: directory) }

    func onNextCommit(_ action: @escaping @Sendable () throws -> Void) {
        lock.withLock { nextAction = action }
    }

    func failNextCommit(_ phase: Failure) { lock.withLock { failure = phase } }
    func load(identity: ProfileIdentity) throws -> Data? { try file.load(identity: identity) }

    func commit(_ data: Data, identity: ProfileIdentity) throws {
        let (action, phase) = lock.withLock {
            let captured = (nextAction, failure)
            nextAction = nil
            failure = nil
            return captured
        }
        try action?()
        if phase == .beforeReplacement { throw AttentionStoreError.persistence("Before replacement") }
        try file.commit(data, identity: identity)
    }
}

private final class PageResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    let done = DispatchSemaphore(value: 0)
    func run(_ body: () throws -> Value) {
        let value = Result { try body() }
        lock.withLock { result = value }
        done.signal()
    }
    func value() throws -> Value {
        guard done.wait(timeout: .now() + 10) == .success else {
            throw AttentionStoreError.persistence("Concurrent store operation did not finish")
        }
        return try lock.withLock { try result!.get() }
    }
}

private struct PageFixture: Sendable {
    let directory: URL
    let persistence: PageFilePersistence
    let context: ProfileContext
    let store: ClientRepository
    static let highWater: UInt64 = 10_000

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        persistence = PageFilePersistence(directory: directory)
        context = ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("page-test"),
            personID: ExactText("person"), deviceID: ExactText("device")), transportMode: .relay)
        store = try ClientRepository(context: context, persistence: persistence)
        _ = try store.beginInboxCandidate(startupID: "startup", since: 0, batches: [], context: context)
        try store.saveInboxInitialPage(snapshotID: "snapshot", highWater: Self.highWater,
            items: [item(1)], nextCursor: "older", receiptCursor: nil, context: context)
        _ = try store.prepareInboxCheckpointAcknowledgement(context: context)
        _ = try store.acceptInboxCheckpoint(snapshotID: "snapshot", highWater: Self.highWater, context: context)
    }

    func key(_ number: Int) -> RequestKey {
        RequestKey(accountScope: context.identity.personID, senderID: ExactText("sender"),
                   messageID: ExactText("m\(number)"))
    }
    var binding: ConversationBinding { ConversationBinding(request: key(1), revision: 1) }
    func item(_ number: Int, payloadBytes: Int = 0) -> InboxSnapshotItem {
        let payload = JSONValue.object([JSONMember("title", .string(ExactText("Message \(number)"))),
            JSONMember("body", .string(ExactText("\(number):" + String(repeating: "x", count: payloadBytes))))])
        return InboxSnapshotItem(acceptance: RelayEvent(sequence: UInt64(number),
            body: .delivery(StoredRequest(key: key(number), originalPayload: payload), .message),
            conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("session-\(number)"),
                                                     eventID: ExactText("event-\(number)"))))
    }
    func save(_ items: [InboxSnapshotItem]? = nil, cursor: String = "older", next: String? = "last") throws {
        try store.saveInboxOlderPage(snapshotID: "snapshot", highWater: Self.highWater,
            cursor: cursor, items: items ?? [item(2)], nextCursor: next, context: context)
    }
    func current() throws -> AttentionStoreSnapshot {
        try store.snapshot(context: context)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

final class InboxPageUpdateTests: XCTestCase {
    func testPagedRowsUseServerOrderAndApplyDeferredTerminal() throws {
        let f = try PageFixture()
        defer { f.remove() }
        let terminal = RelayEvent(sequence: PageFixture.highWater + 1,
            body: .terminal(f.key(2), .answered, nil))
        guard case .deferred = f.store.applyRelayEvent(terminal, context: f.context) else {
            return XCTFail("The terminal for an unloaded page must be retained")
        }
        try f.save([f.item(3), f.item(2)])
        let saved = try f.current()
        XCTAssertEqual(saved.inboxSourceOrder, [f.key(1), f.key(3), f.key(2)])
        XCTAssertEqual(saved.inboxCheckpoint?.loadedKeys, Set([f.key(1), f.key(2), f.key(3)]))
        XCTAssertEqual(saved.inboxCheckpoint?.nextCursor, "last")
        XCTAssertEqual(saved.inboxCurrentKeys, Set([f.key(1), f.key(2), f.key(3)]))
        XCTAssertEqual(saved.remoteStates[f.key(2)]?.state, .answered)
        XCTAssertNil(saved.pendingRelayOverlays[terminal.sequence])
        XCTAssertEqual(saved.cursor, terminal.sequence)
        XCTAssertEqual(try f.store.conversationSnapshot(context: f.context).cursor, 0)
        let bytes = try f.persistence.load(identity: f.context.identity)
        XCTAssertThrowsError(try f.save([f.item(3), f.item(2)]))
        XCTAssertEqual(try f.persistence.load(identity: f.context.identity), bytes)
        try f.save([], cursor: "last", next: nil)
        XCTAssertNil(try f.current().inboxCheckpoint?.nextCursor)
    }

    func testInvalidPageLeavesAcceptedProjectionUnchanged() throws {
        let f = try PageFixture()
        defer { f.remove() }
        let bytes = try f.persistence.load(identity: f.context.identity)
        XCTAssertThrowsError(try f.save((2...22).map { f.item($0) }))
        XCTAssertThrowsError(try f.save([f.item(2), f.item(2)]))
        XCTAssertThrowsError(try f.save([f.item(1)]))
        XCTAssertThrowsError(try f.save([], next: "last"))
        XCTAssertThrowsError(try f.save(next: "older"))
        XCTAssertThrowsError(try f.save(cursor: "wrong"))
        XCTAssertThrowsError(try f.store.saveInboxOlderPage(snapshotID: "other", highWater: PageFixture.highWater,
            cursor: "older", items: [f.item(2)], nextCursor: nil, context: f.context))
        XCTAssertThrowsError(try f.store.saveInboxOlderPage(snapshotID: "snapshot", highWater: 99,
            cursor: "older", items: [f.item(2)], nextCursor: nil, context: f.context))
        let foreign = RequestKey(accountScope: ExactText("other"), senderID: ExactText("sender"), messageID: ExactText("m2"))
        XCTAssertThrowsError(try f.save([InboxSnapshotItem(acceptance: RelayEvent(sequence: 2,
            body: .originReference(foreign)))]))
        XCTAssertEqual(try f.persistence.load(identity: f.context.identity), bytes)
    }


    func testFailureBeforeReplacementKeepsOldCheckpointAndRetryCommitsOnce() throws {
        let f = try PageFixture()
        defer { f.remove() }
        let before = try f.store.snapshot(context: f.context)
        f.persistence.failNextCommit(.beforeReplacement)
        XCTAssertThrowsError(try f.save())
        for snapshot in [try f.store.snapshot(context: f.context), try f.current()] {
            XCTAssertEqual(snapshot.revision, before.revision)
            XCTAssertEqual(snapshot.inboxCheckpoint, before.inboxCheckpoint)
            XCTAssertNil(snapshot.requests[f.key(2)])
        }
        try f.save()
        XCTAssertEqual(try f.current().inboxSourceOrder, [f.key(1), f.key(2)])
        XCTAssertThrowsError(try f.save())
    }


    func testCommittedReadersProceedWhilePagePersistenceAndAnotherWriterWait() throws {
        let f = try PageFixture()
        defer { f.remove() }
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        f.persistence.onNextCommit {
            entered.signal()
            guard release.wait(timeout: .now() + 10) == .success else {
                throw AttentionStoreError.persistence("Page gate was not released")
            }
        }
        let page = PageResult<Void>(), draft = PageResult<Void>(), reader = PageResult<AttentionStoreSnapshot>()
        DispatchQueue.global().async { page.run { try f.save() } }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        let writerStarted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            writerStarted.signal()
            draft.run { _ = try f.store.updateConversationDraftText(ExactText("concurrent draft"), for: f.binding, context: f.context) }
        }
        XCTAssertEqual(writerStarted.wait(timeout: .now() + 5), .success)
        DispatchQueue.global().async { reader.run { try f.store.snapshot(context: f.context) } }
        // Completion before the persistence gate opens proves reader progress;
        // a bounded wait is a failure guard, not a sleep used to infer ordering.
        let readCompleted = reader.done.wait(timeout: .now() + 5)
        XCTAssertEqual(readCompleted, .success)
        if readCompleted == .success { reader.done.signal() }
        let pageFinishedEarly = page.done.wait(timeout: .now()) == .success
        XCTAssertFalse(pageFinishedEarly, "A page must not report success before persistence finishes")
        if pageFinishedEarly { page.done.signal() }
        release.signal()
        let old = try reader.value()
        XCTAssertNil(old.requests[f.key(2)])
        XCTAssertEqual(old.inboxCheckpoint?.nextCursor, "older")
        try page.value()
        try draft.value()
        let saved = try f.current()
        XCTAssertNotNil(saved.requests[f.key(2)])
        XCTAssertEqual(saved.conversationThreads[f.key(1)]?.drafts[1]?.text, ExactText("concurrent draft"))
        XCTAssertEqual(saved.inboxCheckpoint?.nextCursor, "last")
    }

    func testInterleavedPageDraftOutboxAndRelayUpdatesPreserveBothChanges() throws {
        for pageFirst in [true, false] {
            for mutation in 0..<3 {
                let f = try PageFixture()
                defer { f.remove() }
                let selector = try f.store.selector(for: f.key(1), context: f.context)
                let operationID = UUID()
                let write: @Sendable () throws -> Void = {
                    switch mutation {
                    case 0:
                        _ = try f.store.updateConversationDraftText(ExactText("kept"), for: f.binding, context: f.context)
                    case 1:
                        _ = try f.store.submitNoComment(intentID: operationID, selector: selector, context: f.context)
                    default:
                        let event = RelayEvent(sequence: PageFixture.highWater + 1, body: .terminal(f.key(2), .answered, nil))
                        switch f.store.applyRelayEvent(event, context: f.context) {
                        case .committed, .deferred: break
                        default: throw AttentionStoreError.persistence("Relay update was rejected")
                        }
                    }
                }
                let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
                f.persistence.onNextCommit {
                    entered.signal()
                    guard release.wait(timeout: .now() + 10) == .success else {
                        throw AttentionStoreError.persistence("Interleaving gate was not released")
                    }
                }
                let first = PageResult<Void>(), second = PageResult<Void>()
                DispatchQueue.global().async { first.run { if pageFirst { try f.save() } else { try write() } } }
                XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
                let secondStarted = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    secondStarted.signal()
                    second.run { if pageFirst { try write() } else { try f.save() } }
                }
                XCTAssertEqual(secondStarted.wait(timeout: .now() + 5), .success)
                release.signal()
                try first.value()
                try second.value()
                let saved = try f.current()
                XCTAssertEqual(saved.inboxSourceOrder, [f.key(1), f.key(2)])
                XCTAssertEqual(saved.inboxCheckpoint?.nextCursor, "last")
                XCTAssertEqual(saved.cursor, PageFixture.highWater + (mutation == 2 ? 1 : 0))
                XCTAssertEqual(try f.store.conversationSnapshot(context: f.context).cursor, 0)
                if mutation == 0 { XCTAssertEqual(saved.conversationThreads[f.key(1)]?.drafts[1]?.text, ExactText("kept")) }
                if mutation == 1 {
                    XCTAssertEqual(Set(saved.intents.keys), [operationID])
                    XCTAssertEqual(saved.intents[operationID]?.answerKind, .noComment)
                    XCTAssertTrue(saved.outbox.isEmpty, "Concurrent page work must not authorize a queued operation to send.")
                }
                if mutation == 2 {
                    XCTAssertEqual(saved.remoteStates[f.key(2)]?.state, .answered)
                    XCTAssertTrue(saved.pendingRelayOverlays.isEmpty)
                }
            }
        }
    }


    func testServerCacheRestoresLoadedBodiesAndTerminalWithoutRestoringCheckpointAuthority() async throws {
        let f = try PageFixture()
        defer { f.remove() }
        let terminal = RelayEvent(sequence: PageFixture.highWater + 1,
            body: .terminal(f.key(2), .answered, nil), accountAnswerOutcome: .reply(ExactText("Server reply")))
        guard case .deferred = f.store.applyRelayEvent(terminal, context: f.context) else {
            return XCTFail("The unloaded request's terminal must wait for its server body.")
        }
        try f.save([f.item(3), f.item(2)], next: nil)
        let snapshot = try ServerStateCacheSnapshot.make(identity: f.context.identity,
            from: f.store.snapshot(context: f.context), conversations: f.store.conversationSnapshot(context: f.context))
        let file = f.directory.appendingPathComponent("server-cache.json")
        let cache = FileServerStateCache(identity: f.context.identity, fileURL: file)
        try await cache.save(snapshot)
        let reader = FileServerStateCache(identity: f.context.identity, fileURL: file)
        let loadedValue = try await reader.load()
        let loaded = try XCTUnwrap(loadedValue)
        let restarted = try ClientRepository(context: f.context, persistence: f.persistence)
        XCTAssertTrue(try restarted.snapshot(context: f.context).requests.isEmpty)
        try restarted.restoreCachedServerState(loaded.attentionDomainState(for: f.context.identity), context: f.context)
        let restored = try restarted.snapshot(context: f.context)
        XCTAssertEqual(Set(restored.requests.keys), Set([f.key(1), f.key(2), f.key(3)]))
        XCTAssertEqual(restored.remoteStates[f.key(2)]?.accountAnswerOutcome, .reply(ExactText("Server reply")))
        XCTAssertEqual(restored.inboxCurrentKeys, Set([f.key(1), f.key(2), f.key(3)]))
        XCTAssertNil(restored.inboxCheckpoint, "Restored content does not confirm a new connection.")
        XCTAssertEqual(restored.cursor, terminal.sequence)
    }

    func testDiscardedServerCacheCannotBeRebuiltFromThePendingActionFile() async throws {
        let f = try PageFixture()
        defer { f.remove() }
        let cache = FileServerStateCache(identity: f.context.identity,
            fileURL: f.directory.appendingPathComponent("server-cache.json"))
        let snapshot = try ServerStateCacheSnapshot.make(identity: f.context.identity,
            from: f.store.snapshot(context: f.context), conversations: f.store.conversationSnapshot(context: f.context))
        try await cache.save(snapshot)
        try await cache.discard()
        let cached = try await cache.load()
        XCTAssertNil(cached)
        let restarted = try ClientRepository(context: f.context, persistence: f.persistence)
        XCTAssertTrue(try restarted.snapshot(context: f.context).requests.isEmpty)
        XCTAssertNil(try restarted.snapshot(context: f.context).inboxCheckpoint)
    }

}
