import AttentionDomain
import Foundation
import XCTest

/// Controls the persistence seam while still exercising the production file adapter.
private final class PageFilePersistence: AttentionStatePersistence, @unchecked Sendable {
    enum Failure { case beforeReplacement, afterReplacement }
    let file: FileAttentionStatePersistence
    private let lock = NSLock()
    private var nextAction: (@Sendable () throws -> Void)?
    private var failure: Failure?

    init(directory: URL) { file = FileAttentionStatePersistence(directoryURL: directory) }

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
        // Model an adapter reporting failure with the replacement already readable.
        // This does not simulate a power failure or prove directory-fsync durability.
        if phase == .afterReplacement { throw AttentionStoreError.persistence("After replacement") }
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
    let store: AttentionDomainStore
    static let highWater: UInt64 = 10_000

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        persistence = PageFilePersistence(directory: directory)
        context = ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("page-test"),
            personID: ExactText("person"), deviceID: ExactText("device")), transportMode: .relay)
        store = try AttentionDomainStore(context: context, persistence: persistence)
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
    func reopen() throws -> AttentionStoreSnapshot {
        try AttentionDomainStore(context: context, persistence: persistence).snapshot(context: context)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

final class InboxPagePersistenceTests: XCTestCase {
    func testPageAndCheckpointRecoverTogetherInServerOrderWithDeferredOverlay() throws {
        let f = try PageFixture()
        defer { f.remove() }
        let terminal = RelayEvent(sequence: PageFixture.highWater + 1,
            body: .terminal(f.key(2), .answered, nil))
        guard case .deferred = f.store.applyRelayEvent(terminal, context: f.context) else {
            return XCTFail("The terminal for an unloaded page must be retained")
        }
        try f.save([f.item(3), f.item(2)])
        let saved = try f.reopen()
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
        XCTAssertNil(try f.reopen().inboxCheckpoint?.nextCursor)
    }

    func testPageConflictChecksLeaveDurableCheckpointUnchanged() throws {
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

    func testLegacyCheckpointOrderIsRecoveredBeforeAppendingTheNextPage() throws {
        let f = try PageFixture()
        defer { f.remove() }
        try f.save([f.item(3)])
        let data = try XCTUnwrap(f.persistence.load(identity: f.context.identity))
        var plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
        var checkpoint = try XCTUnwrap(plist["inboxCheckpoint"] as? [String: Any])
        checkpoint.removeValue(forKey: "sourceOrder")
        plist["inboxCheckpoint"] = checkpoint
        try f.persistence.file.commit(PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0),
                                      identity: f.context.identity)
        let restored = try AttentionDomainStore(context: f.context, persistence: f.persistence)
        try restored.saveInboxOlderPage(snapshotID: "snapshot", highWater: PageFixture.highWater,
            cursor: "last", items: [f.item(2)], nextCursor: nil, context: f.context)
        XCTAssertEqual(try f.reopen().inboxSourceOrder, [f.key(3), f.key(1), f.key(2)])
    }

    func testFailureBeforeReplacementKeepsOldCheckpointAndRetryCommitsOnce() throws {
        let f = try PageFixture()
        defer { f.remove() }
        let before = try f.store.snapshot(context: f.context)
        f.persistence.failNextCommit(.beforeReplacement)
        XCTAssertThrowsError(try f.save())
        for snapshot in [try f.store.snapshot(context: f.context), try f.reopen()] {
            XCTAssertEqual(snapshot.revision, before.revision)
            XCTAssertEqual(snapshot.inboxCheckpoint, before.inboxCheckpoint)
            XCTAssertNil(snapshot.requests[f.key(2)])
        }
        try f.save()
        XCTAssertEqual(try f.reopen().inboxSourceOrder, [f.key(1), f.key(2)])
        XCTAssertThrowsError(try f.save())
    }

    func testErrorAfterReplacementReloadsWholePageAndPreservesLaterWrite() throws {
        let f = try PageFixture()
        defer { f.remove() }
        f.persistence.failNextCommit(.afterReplacement)
        XCTAssertThrowsError(try f.save())
        for snapshot in [try f.store.snapshot(context: f.context), try f.reopen()] {
            XCTAssertEqual(snapshot.inboxSourceOrder, [f.key(1), f.key(2)])
            XCTAssertEqual(snapshot.inboxCheckpoint?.nextCursor, "last")
            XCTAssertNotNil(snapshot.requests[f.key(2)])
        }
        XCTAssertThrowsError(try f.save())
        _ = try f.store.updateConversationDraftText(ExactText("after uncertain save"), for: f.binding, context: f.context)
        let reopened = try f.reopen()
        XCTAssertEqual(reopened.conversationThreads[f.key(1)]?.drafts[1]?.text, ExactText("after uncertain save"))
        XCTAssertEqual(reopened.inboxSourceOrder, [f.key(1), f.key(2)])
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
        let saved = try f.reopen()
        XCTAssertNotNil(saved.requests[f.key(2)])
        XCTAssertEqual(saved.conversationThreads[f.key(1)]?.drafts[1]?.text, ExactText("concurrent draft"))
        XCTAssertEqual(saved.inboxCheckpoint?.nextCursor, "last")
    }

    func testInterleavedPageDraftOutboxAndRelayWritesSurviveBothOrders() throws {
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
                let saved = try f.reopen()
                XCTAssertEqual(saved.inboxSourceOrder, [f.key(1), f.key(2)])
                XCTAssertEqual(saved.inboxCheckpoint?.nextCursor, "last")
                XCTAssertEqual(saved.cursor, PageFixture.highWater + (mutation == 2 ? 1 : 0))
                XCTAssertEqual(try f.store.conversationSnapshot(context: f.context).cursor, 0)
                if mutation == 0 { XCTAssertEqual(saved.conversationThreads[f.key(1)]?.drafts[1]?.text, ExactText("kept")) }
                if mutation == 1 { XCTAssertEqual(saved.outbox.map(\.intentID), [operationID]) }
                if mutation == 2 {
                    XCTAssertEqual(saved.remoteStates[f.key(2)]?.state, .answered)
                    XCTAssertTrue(saved.pendingRelayOverlays.isEmpty)
                }
            }
        }
    }

    /// Paired-source evidence: no artificial disk delay, no speed threshold.
    /// The persistence-entry handshake starts a read at the actual file-save phase.
    func testMeasureReaderIntervalDuringRealPageFileCommit() throws {
        let seed = try PageFixture()
        defer { seed.remove() }
        var cursor = "older"
        for start in stride(from: 2, through: 382, by: 20) {
            let next = "page-\(start)"
            try seed.save((start..<(start + 20)).map { seed.item($0, payloadBytes: 4096) }, cursor: cursor, next: next)
            cursor = next
        }
        let bytes = try XCTUnwrap(seed.persistence.load(identity: seed.context.identity))
        for sample in 0..<8 {
            let f = try PageFixture()
            defer { f.remove() }
            try f.persistence.file.commit(bytes, identity: f.context.identity)
            let store = try AttentionDomainStore(context: f.context, persistence: f.persistence)
            let entered = DispatchSemaphore(value: 0), readStarted = DispatchSemaphore(value: 0)
            f.persistence.onNextCommit {
                entered.signal()
                guard readStarted.wait(timeout: .now() + 10) == .success else {
                    throw AttentionStoreError.persistence("Measurement reader did not start")
                }
            }
            let writer = PageResult<Void>(), reader = PageResult<Double>()
            let pageCursor = cursor
            DispatchQueue.global().async {
                writer.run {
                    try store.saveInboxOlderPage(snapshotID: "snapshot", highWater: PageFixture.highWater,
                        cursor: pageCursor, items: (402..<422).map { f.item($0, payloadBytes: 4096) }, nextCursor: nil, context: f.context)
                }
            }
            XCTAssertEqual(entered.wait(timeout: .now() + 10), .success)
            DispatchQueue.global().async {
                reader.run {
                    let start = DispatchTime.now().uptimeNanoseconds
                    readStarted.signal()
                    let cursor = try store.relayCursor(context: f.context)
                    let elapsed = DispatchTime.now().uptimeNanoseconds - start
                    XCTAssertEqual(cursor, PageFixture.highWater)
                    return Double(elapsed) / 1_000_000
                }
            }
            let milliseconds = try reader.value()
            try writer.value()
            XCTAssertEqual(try AttentionDomainStore(context: f.context, persistence: f.persistence)
                .snapshot(context: f.context).requests.count, 421)
            print("PAGE_READER_INTERVAL sample=\(sample) seed_bytes=\(bytes.count) retained=401 page=20 cursor_read_ms=\(milliseconds)")
        }
    }
}
