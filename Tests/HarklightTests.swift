import XCTest
@testable import Harklight
import AttentionDomain
import HarklightNativeRelay

private final class V2ScenePushTransport: ClientAPITransport, @unchecked Sendable {
    private let lock = NSLock()
    private var opened = 0
    private var closed = 0
    private var batches = 0
    private var entryReads = 0
    private var handoffFeature = false
    private var handoffPage: String?
    private var entryFailure: URLError.Code?
    private var cancelEntryRead = false
    private var pausedAccount = false
    private var pauseOnEntryRead = false
    private var internalEntryError = false
    func failEntryReadsInternally() { lock.withLock { internalEntryError = true } }
    func pauseDuringEntryRead() { lock.withLock { pauseOnEntryRead = true } }

    func failEntryReads(_ code: URLError.Code, cancelling: Bool = false) {
        lock.withLock { entryFailure = code; cancelEntryRead = cancelling }
    }

    func setPaused() { lock.withLock { pausedAccount = true } }
    func disableHandoff() { lock.withLock { handoffFeature = false } }
    func recoverEntryReads() { lock.withLock { entryFailure = nil; cancelEntryRead = false; internalEntryError = false } }

    func advertiseHandoff(page: String) {
        lock.withLock { handoffFeature = true; handoffPage = page }
    }
    private var focusPayloads: [JSONValue] = []
    private var fileReads: [String] = []
    private var showReads = 0
    private let holdShowLookup: AsyncStream<Void>?

    init(holdShowLookup: AsyncStream<Void>? = nil) {
        self.holdShowLookup = holdShowLookup
    }

    var showLookupCount: Int { lock.withLock { showReads } }

    var reportedFocus: [JSONValue] { lock.withLock { focusPayloads } }
    var reportedFocusScreens: [String] {
        reportedFocus.compactMap { $0.uniqueValue(named: "screen")?.stringValue?.rawValue }
    }
    var requestedFiles: [String] { lock.withLock { fileReads } }

    var counts: (opened: Int, closed: Int, batches: Int, entryReads: Int) {
        lock.withLock { (opened, closed, batches, entryReads) }
    }

    func send(_ request: APIRequest) async throws -> APIResponse {
        if request.path.hasSuffix("/entries"), lock.withLock({ internalEntryError }) {
            lock.withLock { entryReads += 1 }
            throw APIError(status: 500, token: .internalError, retryable: false, requestID: "test")
        }
        if request.path.hasSuffix("/entries"), lock.withLock({ pauseOnEntryRead }) {
            lock.withLock { entryReads += 1 }
            throw APIError(status: 403, token: .accountPaused, retryable: false, requestID: nil)
        }
        if request.path.hasSuffix("/entries"), let failure = lock.withLock({ entryFailure }) {
            let cancel = lock.withLock { entryReads += 1; return cancelEntryRead }
            if cancel { withUnsafeCurrentTask { $0?.cancel() } }
            throw URLError(failure)
        }
        let body: String
        switch request.path {
        case "/v2/devices/me/focus":
            if let data = request.body, let json = try? JSONValue.parse(data) {
                lock.withLock { focusPayloads.append(json) }
            }
            body = "{}"
        case "/v2/me":
            body = #"{"account":{"state":"active"},"features":{},"limits":{},"server":{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"principal":{"person_id":"person","device_id":"device"}}"#
        case "/v2/settings":
            body = #"{"rev":1,"settings":{"rev":1,"priority_levels":[],"push":{"state":"ready","revision":1,"environment":"sandbox","binding_id":"00000000-0000-0000-0000-000000000001"}}}"#
        case "/v2/items/later":
            throw URLError(.networkConnectionLost)
        case "/v2/items/other-account":
            lock.withLock { showReads += 1 }
            throw APIError(status: 404, token: .notFound, retryable: false, requestID: nil)
        case "/v2/items/gone":
            body = #"{"rev":2,"item":{"item_id":"gone","rev":2,"sender":"sender","request_revision":1,"message":{"title":"Gone"},"files":[],"seen":false,"rank":{"key":"a","section":"current"},"chat":{"available":false,"started":false},"terminal":{"state":"retracted","at_ms":1,"by_this_person":false}}}"#
        case "/v2/items/newest":
            lock.withLock { showReads += 1 }
            if let holdShowLookup { for await _ in holdShowLookup {} }
            try Task.checkCancellation()
            body = #"{"rev":2,"item":{"item_id":"newest","rev":2,"sender":"sender","request_revision":1,"message":{"title":"Newest"},"files":[],"seen":false,"rank":{"key":"b","section":"current"},"chat":{"available":true,"started":true}}}"#
        case "/v2/items/item/entries":
            lock.withLock { entryReads += 1 }
            body = #"{"rev":2,"entries":[],"older":false}"#
        default:
            body = #"{"rev":0,"items":[],"counts":{"unresolved":0}}"#
        }
        let responseBody = request.path == "/v2/me" && lock.withLock({ handoffFeature })
            ? body.replacingOccurrences(of: "\"features\":{}", with: "\"features\":{\"handoff_captions\":true}")
            : request.path == "/v2/items/item/entries" ? lock.withLock { handoffPage ?? body } : body
        let accountBody = request.path == "/v2/me" && lock.withLock({ pausedAccount })
            ? responseBody.replacingOccurrences(of: "\"state\":\"active\"", with: "\"state\":\"paused\"") : responseBody
        return APIResponse(status: 200, requestID: "test", body: Data(accountBody.utf8))
    }

    func download(_ request: APIRequest, to destination: URL) async throws -> APIResponse {
        guard request.method == .get, request.path == "/v2/files/download%2F1" else {
            throw URLError(.unsupportedURL)
        }
        lock.withLock { fileReads.append(request.path) }
        try Data("abc".utf8).write(to: destination)
        return APIResponse(status: 200, requestID: "test", body: Data(), contentType: "text/plain; charset=utf-8")
    }

    func changeBatch(after: Rev) async throws -> FeedBatch {
        lock.withLock { batches += 1 }
        return FeedBatch(changes: [], rev: after, more: false)
    }

    func changeFeed(after: Rev) -> AsyncThrowingStream<FeedEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self.closed += 1 }
            }
            lock.withLock { opened += 1 }
            continuation.yield(.opened(requestID: "test"))
        }
    }
}

final class HarklightTests: XCTestCase {
    private var savedRules = AnswerScreenRules.today

    override func setUp() {
        savedRules = AnswerScreenRules.current
        AnswerScreenRules.current = .today
    }

    override func tearDown() { AnswerScreenRules.current = savedRules }

    @MainActor
    private func handoffFailureFixture(directory: URL?, errors: any ErrorLogging)
        throws -> (ClientAPIv2Connection, V2ScenePushTransport) {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let transport = V2ScenePushTransport()
        let connection = try ClientAPIv2Connection(transport: transport, repository: repository, context: context,
            directory: directory, errors: errors)
        let item = try JSONValue.parse(Data(#"{"item_id":"item","rev":1,"sender":"sender","request_revision":1,"message":{"title":"Hello"},"files":[],"seen":false,"chat":{"available":true,"started":true},"rank":{"key":"a","section":"current"}}"#.utf8))
        try connection.model.apply([.init(rev: 1, kind: "item", data: Data(item.jsonString.utf8))], cursor: 1)
        let entry = #"{"entry_id":"sent","item_id":"item","rev":2,"position":1,"kind":"reply","author":"person","request_revision":1,"text":"Hello","files":[],"delivery":{"delivered":true}}"#
        let page = "{\"rev\":2,\"entries\":[" + entry + "],\"older\":false}"
        try connection.model.apply(APIEntriesPage(json: JSONValue.parse(Data(page.utf8))), of: ExactText("item"))
        transport.advertiseHandoff(page: page.replacingOccurrences(of: "\"delivered\":true", with: "\"delivered\":true,\"legacy_caption\":true"))
        return (connection, transport)
    }

    @MainActor
    func testBestEffortHandoffReadFailureIsSilentAndRecoversOnOrdinaryPass() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("errors.json")
        let build = ErrorLogBuild(version: "test", build: "1", commit: "test")
        let errors = ErrorLogStore(fileURL: logURL, build: build)
        let (connection, transport) = try handoffFailureFixture(directory: directory, errors: errors)
        transport.failEntryReadsInternally()
        _ = try await connection.refreshMe()
        XCTAssertEqual(transport.counts.entryReads, 1)
        XCTAssertEqual(connection.model.snapshot.handoffCaptionRefreshItems, [ExactText("item")])
        XCTAssertFalse(errors.records.contains { !$0.isResolved }, "A best-effort re-read must not raise an Inbox failure or Try again.")
        XCTAssertNil(ErrorLogDisplay.inContext(records: errors.records, surface: .inbox, now: .now))
        errors.flush()
        let reopenedErrors = ErrorLogStore(fileURL: logURL, build: build)
        XCTAssertFalse(reopenedErrors.records.contains { !$0.isResolved })
        transport.recoverEntryReads()
        _ = try await connection.refreshMe()
        XCTAssertEqual(transport.counts.entryReads, 2, "The next ordinary pass retries pending metadata.")
        XCTAssertTrue(connection.model.snapshot.handoffCaptionRefreshItems.isEmpty)
        XCTAssertFalse(errors.records.contains { !$0.isResolved })
        XCTAssertNil(ErrorLogDisplay.inContext(records: errors.records, surface: .inbox, now: .now))
        errors.flush()
        XCTAssertFalse(ErrorLogStore(fileURL: logURL, build: build).records.contains { !$0.isResolved })
    }

    @MainActor
    func testHandoffFlagSaveFailureResolvesEvenWhileEntryReadRemainsPending() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let errors = ErrorLogStore(fileURL: nil, build: .init(version: "test", build: "1", commit: "test"))
        let (connection, transport) = try handoffFailureFixture(directory: directory, errors: errors)
        let modelURL = directory.appendingPathComponent("server-model-v2.json")
        try FileManager.default.removeItem(at: modelURL)
        try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: false)
        _ = try await connection.refreshMe()
        XCTAssertTrue(errors.records.contains { $0.operation == "handoff_caption_save" && !$0.isResolved })
        try FileManager.default.removeItem(at: modelURL)
        transport.failEntryReadsInternally()
        _ = try await connection.refreshMe()
        XCTAssertEqual(connection.model.snapshot.handoffCaptionRefreshItems, [ExactText("item")])
        XCTAssertFalse(errors.records.contains { $0.operation == "handoff_caption_save" && !$0.isResolved },
                       "A successful flag save resolves independently of the best-effort item read.")
        XCTAssertFalse(errors.records.contains { $0.operation == "handoff_projection" && !$0.isResolved })
    }

    @MainActor
    func testAbsentHandoffFeatureSkipsMutationAndSealedFlagSaveReportsNothing() async throws {
        let empty = ServerModelV2Store(fileURL: nil)
        try empty.setHandoffCaptionsEnabled(false)
        XCTAssertEqual(empty.saveCount, 0, "An absent feature is already false; it needs no mutation.")
        let errors = ErrorLogStore(fileURL: nil, build: .init(version: "test", build: "1", commit: "test"))
        let (connection, transport) = try handoffFailureFixture(directory: nil, errors: errors)
        transport.disableHandoff()
        _ = try await connection.refreshMe()
        let saved = connection.model.saveCount
        _ = try await connection.refreshMe()
        XCTAssertEqual(connection.model.saveCount, saved, "An unchanged absent feature causes no further model write.")
        XCTAssertEqual(transport.counts.entryReads, 0)
        connection.model.seal()
        try connection.model.setHandoffCaptionsEnabled(false) // Unchanged skips even the sealed mutation.
        transport.advertiseHandoff(page: #"{"rev":0,"entries":[],"older":false}"#)
        _ = try await connection.refreshMe()
        XCTAssertFalse(errors.records.contains { $0.operation == "handoff_caption_save" },
                       "The optional flag saver must ignore the sealed model's CancellationError.")
        XCTAssertEqual(connection.model.saveCount, saved)
    }

    @MainActor
    func testOptionalHandoffRefreshDoesNotFailCachedOpenOrRunWhilePausedOrCancelled() async throws {
        func connection(_ transport: V2ScenePushTransport) throws -> ClientAPIv2Connection {
            let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                personID: ExactText("person"), deviceID: ExactText("device"))
            let context = ProfileContext(identity: identity, transportMode: .relay)
            let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
            let connection = try ClientAPIv2Connection(transport: transport, repository: repository,
                context: context, directory: nil, errors: NoopErrorLog())
            for (index, id) in ["item", "second"].enumerated() {
                let item = "{\"item_id\":\"" + id + "\",\"rev\":1,\"sender\":\"sender\",\"request_revision\":1,\"message\":{\"title\":\"Hello\"},\"files\":[],\"seen\":false,\"chat\":{\"available\":true,\"started\":true},\"rank\":{\"key\":\"" + String(index) + "\",\"section\":\"current\"}}"
                try connection.model.apply([.init(rev: 1, kind: "item", data: Data(item.utf8))], cursor: 1)
                let entry = "{\"entry_id\":\"" + id + "-sent\",\"item_id\":\"" + id + "\",\"rev\":2,\"position\":1,\"kind\":\"reply\",\"author\":\"person\",\"request_revision\":1,\"text\":\"Hello\",\"files\":[],\"delivery\":{\"delivered\":true}}"
                let page = "{\"rev\":2,\"entries\":[" + entry + "],\"older\":false}"
                try connection.model.apply(APIEntriesPage(json: JSONValue.parse(Data(page.utf8))), of: ExactText(id))
            }
            try connection.model.setHandoffCaptionsEnabled(true)
            transport.advertiseHandoff(page: #"{"rev":2,"entries":[],"older":false}"#)
            return connection
        }
        let offlineTransport = V2ScenePushTransport()
        let offline = try connection(offlineTransport)
        offlineTransport.failEntryReads(.notConnectedToInternet)
        try await offline.loadEntriesIfNeeded(itemID: ExactText("item"))
        XCTAssertEqual(offlineTransport.counts.entryReads, 0, "Opening complete cached content needs no optional network read.")
        XCTAssertEqual(offline.model.snapshot.handoffCaptionRefreshItems.count, 2)

        let pausedTransport = V2ScenePushTransport()
        let paused = try connection(pausedTransport)
        pausedTransport.setPaused()
        pausedTransport.failEntryReads(.notConnectedToInternet)
        _ = try await paused.refreshMe()
        XCTAssertEqual(pausedTransport.counts.entryReads, 0)
        try await paused.loadEntriesIfNeeded(itemID: ExactText("item"))
        XCTAssertEqual(pausedTransport.counts.entryReads, 0, "A paused account can still open its complete cached Chat.")

        let pausingTransport = V2ScenePushTransport()
        let pausing = try connection(pausingTransport)
        pausingTransport.pauseDuringEntryRead()
        _ = try await pausing.refreshMe()
        XCTAssertEqual(pausingTransport.counts.entryReads, 1, "Stop when the first entry read pauses the account.")

        let cancelledTransport = V2ScenePushTransport()
        let cancelled = try connection(cancelledTransport)
        cancelledTransport.failEntryReads(.cancelled, cancelling: true)
        let task = Task { try await cancelled.refreshMe() }
        do { _ = try await task.value; XCTFail("Cancellation should end the optional refresh.") }
        catch is CancellationError {}
        XCTAssertEqual(cancelledTransport.counts.entryReads, 1, "Do not attempt the second item after URL cancellation.")
        XCTAssertEqual(cancelled.model.snapshot.handoffCaptionRefreshItems.count, 2)
        let transportCancelled = V2ScenePushTransport()
        let closed = try connection(transportCancelled)
        transportCancelled.failEntryReads(.cancelled)
        _ = try await closed.refreshMe() // /me succeeded; transport-only cancellation stops optional work.
        XCTAssertEqual(transportCancelled.counts.entryReads, 1)
    }

    @MainActor
    func testHandoffUpgradeRereadsCachedEntriesOnceAndOlderAppCacheAlsoRefreshes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let transport = V2ScenePushTransport()
        let connection = try ClientAPIv2Connection(transport: transport, repository: repository, context: context,
            directory: directory, errors: NoopErrorLog())
        _ = try await connection.refreshMe()
        let item = try JSONValue.parse(Data(#"{"item_id":"item","rev":1,"sender":"sender","request_revision":1,"message":{"title":"Hello"},"files":[],"seen":false,"chat":{"available":true,"started":true,"read_position":"sent","last_origin_reply":"reply","unread_replies":1,"reply_group":"earlier_chat_replies","reply_rank_key":"b"},"rank":{"key":"a","section":"current"}}"#.utf8))
        try connection.model.apply([.init(rev: 1, kind: "item", data: Data(item.jsonString.utf8))], cursor: 1)
        let entry = #"{"entry_id":"sent","item_id":"item","rev":2,"position":1,"kind":"reply","author":"person","request_revision":1,"text":"Hello","files":[],"delivery":{"delivered":true}}"#
        let reply = #"{"entry_id":"reply","item_id":"item","rev":3,"position":2,"kind":"reply","author":"origin","request_revision":1,"text":"Agent reply","files":[]}"#
        let page = "{\"rev\":3,\"entries\":[" + entry + "," + reply + "],\"older\":false}"
        try connection.model.apply(APIEntriesPage(json: JSONValue.parse(Data(page.utf8))), of: ExactText("item"))
        connection.publishModel()
        let key = RequestKey(accountScope: identity.personID, senderID: ExactText("sender"), messageID: ExactText("item"))
        let binding = ConversationBinding(request: key, revision: 1)
        try repository.saveConversationDraft(ConversationDraft(binding: binding, text: ExactText("Unsent draft")), context: context)
        let rowsBefore = try connection.presentation.cachedState(connection.model.snapshot, identity: identity).inboxView?.listItems
        transport.advertiseHandoff(page: page.replacingOccurrences(of: "\"delivered\":true", with: "\"delivered\":true,\"legacy_caption\":true"))
        _ = try await connection.refreshMe()
        XCTAssertEqual(transport.counts.entryReads, 1)
        XCTAssertEqual(connection.model.snapshot.entries[ExactText("item")]?[ExactText("sent")]?.delivery?.legacyCaption, true)
        _ = try await connection.refreshMe()
        XCTAssertEqual(transport.counts.entryReads, 1, "A successful same-revision refresh is durable and runs once.")
        let reopened = try ClientAPIv2Connection(transport: transport, repository: repository, context: context,
            directory: directory, errors: NoopErrorLog())
        _ = try await reopened.refreshMe()
        XCTAssertEqual(transport.counts.entryReads, 1)
        // An older App could save /me with the feature already true but could
        // not decode or mark contract projections. Retain the rest of its model.
        let modelURL = directory.appendingPathComponent("server-model-v2.json")
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: modelURL)) as? [String: Any])
        var model = try XCTUnwrap(saved["model"] as? [String: Any])
        model.removeValue(forKey: "handoffCaptionEntries")
        model.removeValue(forKey: "handoffCaptionsEnabled")
        func olderProjection(_ value: Any) -> Any {
            if let object = value as? [String: Any] {
                return object.filter { $0.key != "legacyCaption" }.mapValues(olderProjection)
            }
            if let array = value as? [Any] { return array.map(olderProjection) }
            return value
        }
        saved["model"] = olderProjection(model)
        try JSONSerialization.data(withJSONObject: saved).write(to: modelURL)
        let upgradedApp = try ClientAPIv2Connection(transport: transport, repository: repository, context: context,
            directory: directory, errors: NoopErrorLog())
        XCTAssertEqual(upgradedApp.model.snapshot.handoffCaptionRefreshItems, [ExactText("item")])
        XCTAssertNil(upgradedApp.model.snapshot.entries[ExactText("item")]?[ExactText("sent")]?.delivery?.legacyCaption)
        _ = try await upgradedApp.refreshMe()
        XCTAssertEqual(transport.counts.entryReads, 2)
        XCTAssertTrue(upgradedApp.model.snapshot.handoffCaptionRefreshItems.isEmpty)
        XCTAssertEqual(upgradedApp.model.heldCursor, 1)
        let projected = try upgradedApp.presentation.cachedState(upgradedApp.model.snapshot, identity: identity)
        XCTAssertEqual(projected.conversations.values.first?.accountReadThroughConversationSequence, 1)
        XCTAssertEqual(projected.inboxView?.listItems, rowsBefore)
        XCTAssertEqual(projected.inboxView?.listItems?.map(\.kind), [.message, .reply])
        XCTAssertEqual(try repository.conversationSnapshot(context: context).threads[key]?.drafts[1]?.text,
                       ExactText("Unsent draft"))
    }

    @MainActor
    func testV2PreviewDownloadsTheProjectedFileRefAndVerifiesItsBytes() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let transport = V2ScenePushTransport()
        let store = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let connection = try ClientAPIv2Connection(transport: transport, repository: store, context: context,
                                                    directory: nil, errors: NoopErrorLog())
        let lifecycle = NativeRelayLifecycle()
        lifecycle.installV2Connection(connection, context: context)
        let item = Data(#"{"item_id":"item","rev":1,"sender":"sender","request_revision":1,"message":{"title":"Attachment"},"files":[],"seen":false,"rank":{"key":"a","section":"current"},"chat":{"available":true,"started":true}}"#.utf8)
        let page = Data(#"{"rev":2,"older":false,"entries":[{"entry_id":"entry","item_id":"item","rev":2,"position":1,"kind":"reply","author":"origin","request_revision":1,"files":[{"file_id":"download/1","name":"file.txt","size":3,"sha256":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad","content_type":"text/plain"}]}]}"#.utf8)
        try connection.model.apply([.init(rev: 1, kind: "item", data: item)], cursor: 1)
        try connection.model.apply(APIEntriesPage(json: JSONValue.parse(page)), of: ExactText("item"))
        let projection = ServerModelV2Projection.cachedState(connection.model.snapshot, identity: identity)
        let key = RequestKey(accountScope: identity.personID, senderID: ExactText("sender"), messageID: ExactText("item"))
        let attachment = try XCTUnwrap(projection.conversations[key]?.turns.first?.files.first)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("valid.txt")
        try await lifecycle.fetchConversationFile(attachment, to: destination, expected: context)
        XCTAssertEqual(try Data(contentsOf: destination), Data("abc".utf8))
        XCTAssertEqual(transport.requestedFiles, ["/v2/files/download%2F1"])

        let bad = ConversationFile(id: attachment.id, name: attachment.name, byteCount: 4,
            sha256: attachment.sha256, content: attachment.content)
        let mismatch = folder.appendingPathComponent("invalid.txt")
        do {
            try await lifecycle.fetchConversationFile(bad, to: mismatch, expected: context)
            XCTFail("A response with the wrong byte count cannot be previewed.")
        } catch ConversationError.fileMismatch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: mismatch.path))
        }

        let wrongType = ConversationFile(id: attachment.id, name: attachment.name, byteCount: attachment.byteCount,
            sha256: attachment.sha256, content: .v2Download(FileDownloadID(attachment.id), contentType: "image/png"))
        let wrongTypeDestination = folder.appendingPathComponent("wrong-type.png")
        do {
            try await lifecycle.fetchConversationFile(wrongType, to: wrongTypeDestination, expected: context)
            XCTFail("A response with the wrong Content-Type cannot be previewed even when the bytes match.")
        } catch ConversationError.fileMediaTypeMismatch {
            let entries = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            XCTAssertEqual(entries, ["valid.txt"], "Rejected and temporary files must be removed.")
        }
        await lifecycle.deactivate()
    }

    @MainActor
    func testPushWakeRequiresTheActiveAccount() async throws {
        let server = String(repeating: "a", count: 32)
        let binding = ExactText("00000000-0000-0000-0000-000000000001")
        let record = NativeEnrollmentRecord(
            host: "relay.example", enrollmentPort: 18444, relayPort: 18443,
            trustedRootDER: Data([1]), identityLabel: "test", deviceID: "device",
            approvalCode: "TEST", statusSecret: "test", expiresAt: nil, statusExpiresAt: nil,
            personID: "person")
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText(record.profileAuthority),
                                       personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let transport = V2ScenePushTransport()
        let store = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let connection = try ClientAPIv2Connection(transport: transport, repository: store, context: context,
                                                    directory: nil, errors: NoopErrorLog())
        try await connection.refreshMe()
        _ = try await connection.push.status()
        func payload(person: String, serverID: String = server) throws -> JSONValue {
            try JSONValue.parse(Data(#"{"attention":{"v":2,"type":"sync","server":"\#(serverID)","locator":{"v":2,"binding_id":"\#(binding.rawValue)","person_id":"\#(person)","device_id":"device","item_id":"item","rev":1}}}"#.utf8))
        }

        let on = NativeRelayLifecycle(
            v2NotificationPermission: NativeNotificationPermission(status: { .authorized },
                                                                   request: { true }, register: {}))
        on.installV2Connection(connection, context: context)
        let otherAccount = await on.refreshV2ForPush(try payload(person: "other"))
        let otherServer = await on.refreshV2ForPush(try payload(person: "person", serverID: String(repeating: "b", count: 32)))
        XCTAssertFalse(otherAccount)
        XCTAssertFalse(otherServer)
        XCTAssertEqual(transport.counts.batches, 0)
        _ = await on.refreshV2ForPush(try payload(person: "person"))
        XCTAssertEqual(transport.counts.batches, 1)
        XCTAssertEqual(transport.counts.opened, 0, "A background push fetches a batch without opening a feed.")
        await on.deactivate()
    }

    @MainActor
    func testOpeningAnUnloadedV2ThreadRefetchesAfterAReset() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let transport = V2ScenePushTransport()
        let store = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let connection = try ClientAPIv2Connection(transport: transport, repository: store, context: context,
                                                    directory: nil, errors: NoopErrorLog())
        let lifecycle = NativeRelayLifecycle()
        lifecycle.installV2Connection(connection, context: context)
        let key = RequestKey(accountScope: identity.personID, senderID: ExactText("sender"), messageID: ExactText("item"))
        let item = try APIItem(json: JSONValue.parse(Data(#"{"item_id":"item","rev":1,"sender":"sender","request_revision":1,"message":{"title":"Question"},"files":[],"seen":false,"rank":{"key":"a","section":"current"},"chat":{"available":true,"started":true}}"#.utf8)))
        try connection.model.rebaseline(items: [item], counts: APICounts(unresolved: 1), position: 2)
        await lifecycle.loadV2EntriesOnOpen(key, expected: context)
        await lifecycle.loadV2EntriesOnOpen(key, expected: context)
        XCTAssertEqual(transport.counts.entryReads, 1)
        try connection.model.rebaseline(items: [item], counts: APICounts(unresolved: 1), position: 1)
        await lifecycle.loadV2EntriesOnOpen(key, expected: context)
        XCTAssertEqual(transport.counts.entryReads, 2)
        XCTAssertTrue(connection.model.snapshot.loadedEntryItems.contains(key.messageID))
        await lifecycle.deactivate()
    }

    @MainActor
    func testNewV2ShowSupersedesADeferredShowBeforeItsLookupCompletes() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let (lookup, gate) = AsyncStream<Void>.makeStream()
        defer { gate.finish() }
        let transport = V2ScenePushTransport(holdShowLookup: lookup)
        let connection = try ClientAPIv2Connection(transport: transport, repository: repository,
            context: context, directory: nil, errors: NoopErrorLog())
        let coordinator = NativePushedViewCoordinator()
        let lifecycle = NativeRelayLifecycle(v2ShowCoordinator: coordinator)
        let attempt = UUID()
        lifecycle.installV2Connection(connection, context: context, attempt: attempt)
        try connection.model.apply([.init(rev: 1, kind: "item", data: Data(#"{"item_id":"older","rev":1,"sender":"sender","request_revision":1,"message":{"title":"Older"},"files":[],"seen":false,"rank":{"key":"a","section":"current"},"chat":{"available":true,"started":true}}"#.utf8))], cursor: 1)
        var navigations: [String] = []
        coordinator.setApplyHandler { navigations.append($0.messageID) }
        // The first show is deferred because the scene is not active.
        lifecycle.receiveV2Show(ClientAPIShow(showID: "one", deviceID: "device", itemID: "older",
            target: .chat, heldMilliseconds: 0), receivedAt: Date(), attempt: attempt)
        lifecycle.receiveV2Show(ClientAPIShow(showID: "two", deviceID: "device", itemID: "newest",
            target: .message, heldMilliseconds: 0), receivedAt: Date(), attempt: attempt)

        let lookupDeadline = ContinuousClock.now + .seconds(2)
        while transport.showLookupCount == 0, ContinuousClock.now < lookupDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(transport.showLookupCount, 1)
        coordinator.scenePhaseChanged(.active)
        await Task.yield()
        XCTAssertTrue(navigations.isEmpty, "The older show must stay superseded during lookup.")

        gate.finish()
        let navigationDeadline = ContinuousClock.now + .seconds(2)
        while navigations.isEmpty, ContinuousClock.now < navigationDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(navigations, ["newest"])
        XCTAssertEqual(connection.model.heldCursor, 1)
        XCTAssertEqual(connection.model.snapshot.items[ExactText("newest")]?.seen, false)
        await lifecycle.deactivate()
    }

    @MainActor
    func testV2ShowWaitsAfterTransientLookupAndAppliesWhenTheItemArrives() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let repo = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let connection = try ClientAPIv2Connection(transport: V2ScenePushTransport(), repository: repo,
            context: context, directory: nil, errors: NoopErrorLog())
        let coordinator = NativePushedViewCoordinator()
        let lifecycle = NativeRelayLifecycle(v2ShowCoordinator: coordinator)
        let attempt = UUID()
        lifecycle.installV2Connection(connection, context: context, attempt: attempt)
        var shows: [ViewShowFrame] = []
        coordinator.setApplyHandler { shows.append($0) }
        coordinator.scenePhaseChanged(.active)
        let show = ClientAPIShow(showID: "show", deviceID: "device", itemID: "later",
                                 target: .message, heldMilliseconds: 0)
        lifecycle.receiveV2Show(show, receivedAt: Date(), attempt: attempt)
        let deadline = ContinuousClock.now + .seconds(2)
        while shows.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(shows.first?.unavailable, .notHere)

        let item = Data(#"{"item_id":"later","rev":1,"sender":"sender","request_revision":1,"message":{"title":"Question"},"files":[],"seen":false,"rank":{"key":"a","section":"current"},"chat":{"available":true,"started":true}}"#.utf8)
        try connection.model.apply([.init(rev: 1, kind: "item", data: item)], cursor: 1)
        lifecycle.deliverV2ShowIfHydrated(attempt: attempt)
        let arrival = ContinuousClock.now + .seconds(2)
        while shows.count < 2, ContinuousClock.now < arrival { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(shows.last?.messageID, "later")
        XCTAssertNil(shows.last?.unavailable)
        let key = RequestKey(accountScope: identity.personID, senderID: ExactText("sender"), messageID: ExactText("later"))
        XCTAssertTrue(coordinator.isPassive(key))
        XCTAssertEqual(connection.model.snapshot.items[key.messageID]?.seen, false)
        await lifecycle.deactivate()
    }

    @MainActor
    func testV2ShowRejectsAnotherDeviceAndReportsUnavailableItemsWithoutOpeningThem() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let repo = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let transport = V2ScenePushTransport()
        let connection = try ClientAPIv2Connection(transport: transport, repository: repo,
            context: context, directory: nil, errors: NoopErrorLog())
        let coordinator = NativePushedViewCoordinator()
        let lifecycle = NativeRelayLifecycle(v2ShowCoordinator: coordinator)
        let attempt = UUID()
        lifecycle.installV2Connection(connection, context: context, attempt: attempt)
        var shows: [ViewShowFrame] = []
        coordinator.setApplyHandler { shows.append($0) }
        coordinator.scenePhaseChanged(.active)

        lifecycle.receiveV2Show(ClientAPIShow(showID: "misaddressed", deviceID: "other-device",
            itemID: "other-account", target: .message, heldMilliseconds: 0), receivedAt: Date(), attempt: attempt)
        let cached = Data(#"{"item_id":"other-account","rev":1,"sender":"sender","request_revision":1,"message":{"title":"Evicted"},"files":[],"seen":false,"rank":{"key":"b","section":"current"},"chat":{"available":false,"started":false}}"#.utf8)
        try connection.model.apply([.init(rev: 1, kind: "item", data: cached)], cursor: 1)
        lifecycle.receiveV2Show(ClientAPIShow(showID: "unknown", deviceID: "device",
            itemID: "other-account", target: .message, heldMilliseconds: 0), receivedAt: Date(), attempt: attempt)
        let deadline = ContinuousClock.now + .seconds(2)
        while shows.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(transport.showLookupCount, 1)
        XCTAssertEqual(shows.map(\.unavailable), [.notSent])
        XCTAssertNil(coordinator.passivePair)

        lifecycle.receiveV2Show(ClientAPIShow(showID: "retracted", deviceID: "device",
            itemID: "gone", target: .chat, heldMilliseconds: 0), receivedAt: Date(), attempt: attempt)
        let retractionDeadline = ContinuousClock.now + .seconds(2)
        while shows.count < 2, ContinuousClock.now < retractionDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(shows.last?.unavailable, .retracted)
        XCTAssertNil(coordinator.passivePair)
        XCTAssertEqual(connection.model.snapshot.items[ExactText("gone")]?.seen, false)
        await lifecycle.deactivate()
    }

    @MainActor
    func testV2FocusReportsBackgroundReadinessAndSceneTransitions() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let transport = V2ScenePushTransport()
        let connection = try ClientAPIv2Connection(transport: transport, repository: repository,
                                                    context: context, directory: nil, errors: NoopErrorLog())
        let reporter = NativeFocusReporter()
        let lifecycle = NativeRelayLifecycle(v2FocusReporter: reporter)
        let attempt = UUID()
        let focus = ClientAPIFocusChannel(transport: transport, errors: NoopErrorLog()) { _, _ in }
        func expect(_ screens: [String]) async throws {
            let deadline = ContinuousClock.now + .seconds(2)
            while transport.reportedFocusScreens.count < screens.count, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertEqual(transport.reportedFocusScreens, screens)
        }
        lifecycle.v2FocusScenePhaseChanged(.background)
        lifecycle.installV2Connection(connection, context: context, attempt: attempt)
        lifecycle.installV2FocusChannel(focus, attempt: attempt)
        try await expect(["not_in_front"])
        lifecycle.v2FocusScenePhaseChanged(.active)
        try await expect(["not_in_front", "inbox"])
        reporter.selectionChanged(to: .settings)
        try await expect(["not_in_front", "inbox", "settings"])
        lifecycle.v2FocusScenePhaseChanged(.background)
        try await expect(["not_in_front", "inbox", "settings", "not_in_front"])
        await lifecycle.deactivate()
    }

    @MainActor
    func testFYIDetailFocusUsesOnlyTheActiveLiveProfile() async throws {
        let liveIdentity = ProfileIdentity(trustedRelayAuthority: ExactText("live.example"),
            personID: ExactText("person"), deviceID: ExactText("device"))
        let active = ProfileContext(identity: liveIdentity, transportMode: .relay)
        let repository = try ClientRepository(context: active, persistence: MemoryPendingActionPersistence())
        let transport = V2ScenePushTransport()
        let connection = try ClientAPIv2Connection(transport: transport, repository: repository,
            context: active, directory: nil, errors: NoopErrorLog())
        let reporter = NativeFocusReporter()
        let lifecycle = NativeRelayLifecycle(v2FocusReporter: reporter)
        let attempt = UUID()
        lifecycle.installV2Connection(connection, context: active, attempt: attempt)
        lifecycle.installV2FocusChannel(ClientAPIFocusChannel(transport: transport,
            errors: NoopErrorLog()) { _, _ in }, attempt: attempt)
        lifecycle.v2FocusScenePhaseChanged(.active)

        let live = try LivePresentationStore(store: repository, context: active)
        let archiveIdentity = ProfileIdentity(trustedRelayAuthority: ExactText("archive.example"),
            personID: liveIdentity.personID, deviceID: liveIdentity.deviceID)
        let archived = ProfileContext(identity: archiveIdentity, transportMode: .relay)
        let archiveRepository = try ClientRepository(context: archived,
            persistence: MemoryPendingActionPersistence())
        let archive = try LivePresentationStore(disconnectedStore: archiveRepository, context: archived)
        let obsolete = ProfileContext(identity: liveIdentity, transportMode: .relay)
        let obsoleteRepository = try ClientRepository(context: obsolete,
            persistence: MemoryPendingActionPersistence())
        let obsoleteLive = try LivePresentationStore(store: obsoleteRepository, context: obsolete)
        let key = RequestKey(accountScope: liveIdentity.personID, senderID: ExactText("sender"),
                             messageID: ExactText("same-item"))

        func expectFocus(_ report: FocusReport) async {
            let count = transport.reportedFocus.count
            reporter.selectionChanged(to: report)
            XCTAssertEqual(reporter.currentFocus, report)
            let deadline = ContinuousClock.now + .seconds(2)
            while ContinuousClock.now < deadline {
                if transport.reportedFocus.count > count, transport.reportedFocusScreens.last == report.screen.rawValue {
                    break
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
            let payload = transport.reportedFocus.last
            XCTAssertGreaterThan(transport.reportedFocus.count, count)
            XCTAssertEqual(payload?.uniqueValue(named: "screen")?.stringValue?.rawValue, report.screen.rawValue)
            XCTAssertEqual(payload?.uniqueValue(named: "item_id")?.stringValue?.rawValue, report.messageID)
        }

        let item = FocusReport.message(senderID: "sender", messageID: "same-item")
        let liveFocus = NativeFocusSelection.fyiDetailReport(for: key, in: live, relay: lifecycle)
        XCTAssertEqual(liveFocus, item)
        await expectFocus(liveFocus)

        XCTAssertFalse(NativeFocusSelection.canReportFYIItem(in: archive, relay: lifecycle))
        XCTAssertFalse(NativeFocusSelection.canReportFYIItem(in: obsoleteLive, relay: lifecycle))

        let countBeforeArchive = transport.reportedFocus.count
        reporter.setReportsVisiblePresentation(false)
        reporter.selectionChanged(to: .fyi)
        lifecycle.v2FocusScenePhaseChanged(.background)
        lifecycle.v2FocusScenePhaseChanged(.active)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(transport.reportedFocus.count, countBeforeArchive)

        reporter.setReportsVisiblePresentation(true)
        let deadline = ContinuousClock.now + .seconds(2)
        while transport.reportedFocus.count == countBeforeArchive, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(transport.reportedFocusScreens.last, "fyi")
        live.enterReadOnlyMode()
        XCTAssertFalse(NativeFocusSelection.canReportFYIItem(in: live, relay: lifecycle))

        await lifecycle.deactivate()
    }

    @MainActor
    func testV2ConnectionFollowsSceneActivity() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let transport = V2ScenePushTransport()
        let store = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let connection = try ClientAPIv2Connection(transport: transport, repository: store, context: context,
                                                    directory: nil, errors: NoopErrorLog())
        let lifecycle = NativeRelayLifecycle()
        lifecycle.installV2Connection(connection, context: context)
        XCTAssertEqual(transport.counts.opened, 0)

        func until(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(2)
            while !condition(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(condition())
        }
        lifecycle.sceneActivityChanged(isActive: true)
        try await until { transport.counts.opened == 1 }
        lifecycle.sceneActivityChanged(isActive: false)
        lifecycle.sceneActivityChanged(isActive: true)
        try await until { transport.counts.opened == 2 && transport.counts.closed == 1 }
        await lifecycle.deactivate()
        XCTAssertEqual(transport.counts.closed, 2)
    }

    @MainActor
    func testSearchProjectionUsesOnlyMatchingRowsInTheSelectedMessageTab() {
        let inboxMatch = InboxRequestRow(
            key: RequestKey(accountScope: ExactText("person"), senderID: ExactText("sender"),
                            messageID: ExactText("inbox-match")),
            title: "Archive this collection", sender: "Planning assistant", status: "Pending",
            bodyText: "Keep a copy of the sketches.")
        let inboxOther = InboxRequestRow(
            key: RequestKey(accountScope: ExactText("person"), senderID: ExactText("sender"),
                            messageID: ExactText("inbox-other")),
            title: "Choose a date", sender: "Planning assistant", status: "Pending",
            bodyText: "Pick a time.")
        let repliedMatch = InboxRequestRow(
            key: RequestKey(accountScope: ExactText("person"), senderID: ExactText("sender"),
                            messageID: ExactText("replied-match")),
            title: "Archive the old draft", sender: "Planning assistant", status: "Answered",
            bodyText: "This one is already resolved.", hasUserAction: true)
        let rows: [InboxItem] = [.request(inboxMatch), .request(inboxOther), .request(repliedMatch)]

        let inboxResults = InboxListProjection.filteredRows(
            rows, in: .inbox, search: " archive ")
        XCTAssertEqual(inboxResults.map(\.id), [.request(inboxMatch.key)])
        XCTAssertEqual(InboxListProjection.filteredRows(
            rows, in: .inbox, search: "planning assistant").map(\.id),
            [.request(inboxMatch.key), .request(inboxOther.key)])
        XCTAssertEqual(InboxListProjection.filteredRows(
            rows, in: .inbox, search: "copy of the sketches").map(\.id),
            [.request(inboxMatch.key)])

        let repliedResults = InboxListProjection.filteredRows(
            rows, in: .replied, search: "archive")
        XCTAssertEqual(repliedResults.map(\.id), [.request(repliedMatch.key)])
    }

    @MainActor
    func testThreadProjectionFoldsOnlyAdjacentExactSenderAndThreadEntries() {
        func item(_ id: String, senderID: String = "sender", thread: String? = "thread",
                  hasEntry: Bool = true, resolved: Bool = false) -> InboxItem {
            .request(InboxRequestRow(
                key: RequestKey(accountScope: ExactText("person"), senderID: ExactText(senderID),
                                messageID: ExactText(id)),
                title: "Message \(id)", sender: "Same display name", status: "",
                isResolved: resolved, thread: thread.map(ExactText.init),
                hasInboxViewEntry: hasEntry))
        }

        let rows = [
            item("a1"), item("a2"),
            item("different-thread", thread: "other"),
            item("different-sender", senderID: "other-sender"),
            item("no-view-entry", hasEntry: false),
            item("after-missing-entry"),
            item("resolved", resolved: true),
            item("after-resolved")
        ]
        let entries = InboxThreadListProjection.grouped(rows)

        XCTAssertEqual(entries.count, 7)
        guard case let .thread(thread, members) = entries[0] else {
            return XCTFail("The first adjacent pair should be folded.")
        }
        XCTAssertEqual(thread, ExactText("thread"))
        XCTAssertEqual(members.map(\.id), [.request(RequestKey(accountScope: ExactText("person"),
            senderID: ExactText("sender"), messageID: ExactText("a1"))),
            .request(RequestKey(accountScope: ExactText("person"), senderID: ExactText("sender"),
                                messageID: ExactText("a2")))])
        XCTAssertTrue(entries.dropFirst().allSatisfy { if case .row = $0 { return true }; return false },
                      "A different thread, sender, missing entry, resolved row or singleton is a plain row.")
    }

    @MainActor
    func testSearchDoesNotJoinThreadRowsAcrossAFilteredBarrier() {
        func item(_ id: String, thread: String, title: String) -> InboxItem {
            .request(InboxRequestRow(
                key: RequestKey(accountScope: ExactText("person"), senderID: ExactText("sender"),
                                messageID: ExactText(id)),
                title: title, sender: "Planning assistant", status: "",
                thread: ExactText(thread), hasInboxViewEntry: true))
        }
        let first = item("first", thread: "t", title: "Match one")
        let barrier = item("barrier", thread: "other", title: "Gap")
        let last = item("last", thread: "t", title: "Match two")
        let rows = [first, barrier, last]

        let entries = InboxListProjection.visibleEntries(rows, in: .inbox, search: "match")
        XCTAssertEqual(entries.flatMap(\.members).map(\.id),
                       InboxListProjection.filteredRows(rows, in: .inbox, search: "match").map(\.id))
        XCTAssertTrue(entries.allSatisfy { if case .row = $0 { return true }; return false },
                      "Filtering cannot make separated members adjacent for folding.")
    }

    @MainActor
    func testNormalProjectionKeepsDistinctRowsInServerSequence() {
        func row(_ id: String, resolved: Bool = false) -> InboxRequestRow {
            InboxRequestRow(
                key: RequestKey(accountScope: ExactText("person"), senderID: ExactText("sender"),
                                messageID: ExactText(id)),
                title: "Message \(id)", sender: "Assistant", status: "",
                isResolved: resolved, hasUserAction: resolved,
                hasInboxViewEntry: true)
        }
        let first = row("first")
        let parent = row("parent")
        let last = row("last")
        let replyRef = InboxViewListItem(kind: .reply, key: parent.key,
            conversationSequence: 9, openAtConversationSequence: 7,
            unseenCount: 2, score: 0.91, scoreKind: .current)
        let serverOrder = [
            InboxViewListItem(kind: .message, key: first.key),
            replyRef,
            InboxViewListItem(kind: .message, key: last.key)
        ]
        let rows: [InboxItem] = [.request(first), .request(parent), .request(last)]

        let normalRows = InboxNormalListProjection.entries(
            rows: rows, serverItems: serverOrder, in: .inbox, search: "")
        XCTAssertEqual(normalRows.map(\.id), [
            .message(.row(.request(first.key))), .reply(parent.key), .message(.row(.request(last.key)))
        ], "Normal rows follow the mixed server sequence, without sorting by score or parent.")
        guard case let .reply(projectedReply) = normalRows[1] else {
            return XCTFail("The reply group should keep its own list identity.")
        }
        XCTAssertEqual(projectedReply.score, 0.91)
        XCTAssertEqual(projectedReply.openAtConversationSequence, 7)
    }

    @MainActor
    func testNormalReplyRowsFollowReplyAttentionStateAndFallbackDoesNotInventThem() {
        let parent = InboxRequestRow(
            key: RequestKey(accountScope: ExactText("person"), senderID: ExactText("sender"),
                            messageID: ExactText("parent")),
            title: "Answered parent", sender: "Assistant", status: "Answered",
            hasUserAction: true, hasInboxViewEntry: true)
        let replyRef = InboxViewListItem(kind: .reply, key: parent.key,
            conversationSequence: 9, openAtConversationSequence: 9,
            unseenCount: 0, score: 0.8, scoreKind: .historical)
        let rows: [InboxItem] = [.request(parent)]

        let allSeen = InboxNormalListProjection.entries(
            rows: rows, serverItems: [replyRef], in: .replied, search: "")
        XCTAssertEqual(allSeen.map(\.id), [.reply(parent.key)],
                       "The reply group remains in the seen tab independently of parent lifecycle.")
        let replyWithoutLoadedParent = InboxNormalListProjection.entries(
            rows: [], serverItems: [replyRef], in: .replied, search: "")
        XCTAssertEqual(replyWithoutLoadedParent.map(\.id), [.reply(parent.key)],
                       "A reply group remains a row when its parent message is outside the loaded page.")
        let searchedReplyWithoutLoadedParent = InboxNormalListProjection.entries(
            rows: [], serverItems: [replyRef], in: .replied, search: "sender")
        XCTAssertEqual(searchedReplyWithoutLoadedParent.map(\.id), [.reply(parent.key)],
                       "An unloaded reply parent can still be found by its stable sender identity.")
        let legacyRows = InboxNormalListProjection.entries(
            rows: rows, serverItems: nil, in: .replied, search: "")
        XCTAssertFalse(legacyRows.contains { row in
            if case .reply = row { return true }
            return false
        }, "An older server without list_items cannot create a persistent reply row.")
        XCTAssertTrue(InboxNormalListProjection.entries(
            rows: rows, serverItems: [], in: .replied, search: "").isEmpty,
            "A supported empty projection is not treated as an older server fallback.")
    }

    @MainActor
    func testLiveInboxRowCarriesBaselinePriorityWithoutScore() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("baseline-reader"),
                                       deviceID: ExactText("baseline-device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let store = try ClientRepository(context: context,
                                         persistence: MemoryPendingActionPersistence())
        let key = RequestKey(accountScope: identity.personID,
                             senderID: ExactText("agent"), messageID: ExactText("baseline"))
        let payload = try JSONValue.parse(Data(#"{"title":"Baseline message","urgency":"low"}"#.utf8))
        try store.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: payload), .message)), context: context)
        try store.setInboxView(InboxView(revision: ExactText("baseline-view"),
            algorithm: ExactText("baseline"), basis: ExactText("selected"),
            entries: [InboxViewEntry(key: key, priority: .now)]), context: context)

        let live = try LivePresentationStore(store: store, context: context)
        let row = try XCTUnwrap(live.inboxRows.first { $0.key == key })
        XCTAssertEqual(row.inboxPriority, .now,
                       "The list must receive the Server priority through the live row projection.")
        XCTAssertNil(row.inboxScore)
        XCTAssertEqual(InboxPriorityDisplay.forEntry(score: row.inboxScore,
                                                    priority: row.inboxPriority), .urgent)
    }

    @MainActor
    func testModelFallbackViewDisplaysServerPriorityWithoutScore() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("fallback-reader"),
                                       deviceID: ExactText("fallback-device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let store = try ClientRepository(context: context,
                                         persistence: MemoryPendingActionPersistence())
        let key = RequestKey(accountScope: identity.personID,
                             senderID: ExactText("agent"), messageID: ExactText("fallback"))
        let payload = try JSONValue.parse(Data(#"{"title":"Fallback message","urgency":"now"}"#.utf8))
        try store.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: payload), .message)), context: context)
        try store.setInboxView(InboxView(revision: ExactText("fallback-view"),
            algorithm: ExactText("jev-set"), basis: ExactText("fallback"),
            entries: [InboxViewEntry(key: key, priority: .high)]), context: context)

        let port = AttentionDomainPort(store: store)
        let presentation = try port.observe(context: port.context)
        let request = try XCTUnwrap(presentation.requests.first)
        XCTAssertTrue(presentation.showsBasicOrderMarker)
        XCTAssertNil(request.inboxScore)
        XCTAssertEqual(request.inboxPriority, .high)
        XCTAssertEqual(InboxPriorityDisplay.forEntry(score: request.inboxScore,
                                                    priority: request.inboxPriority), .high,
                       "A model fallback uses the Server priority, not the message urgency.")
    }

    @MainActor
    func testMessageFieldsUseServerViewAndIgnoreMalformedOptionalMembersIndependently() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("field-reader"),
                                       deviceID: ExactText("field-device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let store = try ClientRepository(context: context,
                                             persistence: MemoryPendingActionPersistence())
        let key = RequestKey(accountScope: identity.personID,
                             senderID: ExactText("agent"), messageID: ExactText("fields"))
        let payload = try JSONValue.parse(Data(#"{"title":"Choose","urgency":"now","stake":"The review deadline slips.","by_when":1793300000000,"choice_styles":{"accept":"destructive","reply":"primary","ordinary":"loud","missing":"primary","later":"secondary"},"answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"accept","label":"Accept","kind":"value","value":true},{"id":"reply","label":"Reply","kind":"text"},{"id":"ordinary","label":"Ordinary","kind":"value","value":false},{"id":"later","label":"Later","kind":"value","value":false}]}}"#.utf8))
        try store.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: payload), .message)), context: context)
        try store.setInboxView(InboxView(revision: ExactText("view-1"),
            algorithm: ExactText("jev-set"), basis: ExactText("fallback"), entries: [
            InboxViewEntry(key: key, priority: .normal, score: 0.75,
                           thread: ExactText("review"),
                           dueAtMilliseconds: 1793300000000, reason: ExactText("server order"))
        ]), context: context)

        let port = AttentionDomainPort(store: store)
        let presentation = try port.observe(context: port.context)
        XCTAssertTrue(presentation.showsBasicOrderMarker,
                      "Fallback basis must surface one inbox-level basic-order marker.")
        XCTAssertTrue(try port.inspect(context: port.context, request: key)
            .showsBasicOrderMarker,
                      "Filtering presentation to a detail must retain the inbox-level basis.")
        let request = try XCTUnwrap(presentation.requests.first)
        XCTAssertEqual(request.inboxPriority, .normal,
                       "The visible level comes from the post-attenuation view, not urgency.")
        XCTAssertEqual(request.inboxScore, 0.75)
        XCTAssertEqual(InboxPriorityDisplay.forEntry(score: request.inboxScore, priority: request.inboxPriority), .high)
        XCTAssertEqual(request.inboxThread, ExactText("review"))
        XCTAssertEqual(request.inboxDueAtMilliseconds, 1_793_300_000_000)
        XCTAssertEqual(request.inboxReason, ExactText("server order"))
        XCTAssertEqual(request.stakeText, ExactText("The review deadline slips."))
        XCTAssertEqual(request.byWhenMilliseconds, 1_793_300_000_000)
        XCTAssertEqual(request.attentionTier, .middle,
                       "A legacy attention tier is not projected to the app.")
        guard case let .compatibility(actions) = request.projection else {
            return XCTFail("A malformed optional style must leave the answer interface usable.")
        }
        XCTAssertEqual(actions.map(\.style), [.destructive, .primary, nil, .secondary])

        try store.setInboxView(InboxView(revision: ExactText("view-2"),
            algorithm: ExactText("jev-set"), basis: ExactText("selected"),
            entries: [InboxViewEntry(key: key, priority: .now)]), context: context)
        let legacyRequest = try XCTUnwrap(port.observe(context: port.context).requests.first)
        XCTAssertEqual(legacyRequest.inboxPriority, .now)
        XCTAssertNil(legacyRequest.inboxScore)
        XCTAssertEqual(InboxPriorityDisplay.forEntry(score: legacyRequest.inboxScore,
                                                    priority: legacyRequest.inboxPriority), .urgent,
                       "The Server priority supplies the level when its score is absent.")
        XCTAssertFalse(try port.observe(context: port.context).showsBasicOrderMarker,
                       "Selected basis must not show the fallback-only marker.")

        let malformed = try JSONValue.parse(Data(#"{"title":"Still readable","stake":7,"by_when":"tomorrow","choice_styles":"unknown","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"yes","label":"Yes","kind":"value","value":true}]}}"#.utf8))
        let tolerant = StoredRequest(key: RequestKey(accountScope: identity.personID,
            senderID: ExactText("agent"), messageID: ExactText("malformed")), originalPayload: malformed)
        XCTAssertNil(tolerant.stakeText)
        XCTAssertNil(tolerant.byWhenMilliseconds)
        XCTAssertTrue(tolerant.choiceStyles.isEmpty)
        if case .compatibility = tolerant.interface {
            // The optional fields did not make the message or answer controls unavailable.
        } else {
            XCTFail("An invalid optional field must not invalidate answer controls.")
        }
    }

    func testDuePhraseUsesLocalCalendarDayAndTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: "en_US_POSIX")
        let now = ISO8601DateFormatter().date(from: "2026-10-29T12:00:00Z")!
        func milliseconds(_ value: String) -> Int {
            Int(ISO8601DateFormatter().date(from: value)!.timeIntervalSince1970 * 1_000)
        }

        XCTAssertTrue(InboxDuePhrase.label(for: milliseconds("2026-10-29T15:30:00Z"),
            now: now, calendar: calendar, locale: locale).hasPrefix("Due today at "))
        XCTAssertTrue(InboxDuePhrase.label(for: milliseconds("2026-10-30T15:30:00Z"),
            now: now, calendar: calendar, locale: locale).hasPrefix("Due tomorrow at "))
        XCTAssertTrue(InboxDuePhrase.label(for: milliseconds("2026-10-28T15:30:00Z"),
            now: now, calendar: calendar, locale: locale).hasPrefix("Was due yesterday at "))
    }

    @MainActor
    func testNotificationDestinationSelectsTheRequestTabAndClearsSearch() {
        let replied = InboxRequestRow(
            key: RequestKey(accountScope: ExactText("person"), senderID: ExactText("sender"),
                            messageID: ExactText("answered")),
            title: "Answered request", sender: "Planning assistant", status: "Answered",
            hasUserAction: true)
        let destination = InboxNotificationDestination(
            route: NativeInboxNavigation(serial: 1, request: replied.key),
            rows: [.request(replied)])

        XCTAssertEqual(destination.selection, .request(replied.key))
        XCTAssertEqual(destination.selectedTab, .replied)
        XCTAssertEqual(destination.workspaceTab, .replied)
        XCTAssertEqual(destination.search, "")
    }

    @MainActor
    func testPendingNotificationOpensExactMessageOrChatAfterValidation() throws {
        let locator = notificationLocator(target: "chat")
        let route = NativeInboxNavigation(serial: 50, request: nil)
        let intent = NativeNotificationIntent(serial: 50, locator: locator)

        let pending = InboxNotificationDestination(route: route, rows: [])
        let presentation = InboxNotificationPendingPresentation(
            route: route, intent: intent, statusMessage: "Checking this notification.")

        XCTAssertEqual(pending.selection, .notificationPending(50))
        XCTAssertEqual(pending.workspaceTab, .inbox)
        XCTAssertEqual(presentation.locator, locator)
        XCTAssertEqual(presentation.target, .chat)
        XCTAssertEqual(presentation.state, .opening)
        XCTAssertEqual(presentation.listRowState, .opening(.chat))
        XCTAssertTrue(presentation.listRowState.showsProgress)

        let resolved = InboxNotificationDestination(
            route: NativeInboxNavigation(serial: 50, request: locator.request, opensChat: true),
            rows: [])
        XCTAssertEqual(resolved.selection, .request(locator.request))
        XCTAssertNotEqual(pending.selection, resolved.selection,
                          "Unvalidated locator content must not appear as the loaded request.")
    }

    @MainActor
    func testPendingNotificationShowsRetryAndUnavailableStates() throws {
        let locator = notificationLocator(target: "message")
        let route = NativeInboxNavigation(serial: 70, request: nil)
        let intent = NativeNotificationIntent(serial: 70, locator: locator)

        let states: [(String, InboxNotificationPendingPresentation.State,
                      InboxNotificationPendingPresentation.ListRowState)] = [
            ("Could not verify notification. Checking again while open.",
             .checkingAgain, .checkingAgain),
            ("This message link couldn't be opened.", .invalid, .invalid),
            ("Could not check this notification's account.",
             .accountUnavailable, .accountUnavailable),
            ("This notification's message has not loaded yet.",
             .messageUnavailable, .messageUnavailable),
            ("The sender retracted this message.", .retracted, .retracted),
        ]
        for (message, expected, expectedRowState) in states {
            let presentation = InboxNotificationPendingPresentation(
                route: route, intent: intent, statusMessage: message)
            XCTAssertEqual(presentation.state, expected, message)
            XCTAssertEqual(presentation.listRowState, expectedRowState, message)
            XCTAssertEqual(presentation.listRowState.showsProgress,
                           expectedRowState == .checkingAgain, message)
        }

        let staleIntent = NativeNotificationIntent(serial: 69, locator: locator)
        let invalid = InboxNotificationPendingPresentation(
            route: route, intent: staleIntent, statusMessage: "Checking this notification.")
        XCTAssertEqual(invalid.state, .invalid,
                       "A different notification's locator must never be shown as this target.")
        XCTAssertEqual(invalid.listRowState, .invalid)
        XCTAssertFalse(invalid.listRowState.showsProgress)
    }

    private func notificationLocator(target: String) -> NativeNotificationLocator {
        NativeNotificationLocator(v2Request: RequestKey(accountScope: ExactText("person"), senderID: ExactText("sender"),
            messageID: ExactText("target-message")), bindingID: ExactText("binding"), deviceID: ExactText("device"),
            serverID: String(repeating: "a", count: 32), target: target)
    }

    func testDismissingPendingNotificationSuppressesItsLateResolution() {
        let pending = InboxSelection.notificationPending(50)
        let exactRoute = NativeInboxNavigation(
            serial: 50,
            request: RequestKey(accountScope: ExactText("person"),
                                senderID: ExactText("sender"),
                                messageID: ExactText("target-message")),
            opensChat: true)

        XCTAssertEqual(InboxNotificationNavigationPolicy.dismissalSerial(from: pending, to: nil), 50)
        XCTAssertNil(InboxNotificationNavigationPolicy.dismissalSerial(from: pending, to: pending))
        XCTAssertFalse(InboxNotificationNavigationPolicy.shouldApply(
            exactRoute, afterDismissedSerial: 50))
        XCTAssertTrue(InboxNotificationNavigationPolicy.shouldApply(
            NativeInboxNavigation(serial: 51, request: nil), afterDismissedSerial: 50))
    }

    func testMessageDeepLinkDecodesEachIdentityAsOnePathSegment() {
        let url = URL(string: "harklight://message/app%3Aone/message%2Fwith%25")!
        let deepLink = NativeMessageDeepLink(url: url)

        XCTAssertEqual(deepLink?.senderID, "app:one")
        XCTAssertEqual(deepLink?.messageID, "message/with%")
        XCTAssertNil(NativeMessageDeepLink(url: URL(string: "harklight://message/app%3Aone/message/extra")!))
        XCTAssertNil(NativeMessageDeepLink(url: URL(string: "harklight://join#invitation")!))
    }

    func testNoCommentDraftSelectionRoundTripsAndLegacyDraftsDefaultToUnselected() throws {
        struct LegacyDraft: Encodable {
            let inputs: [ExactText: InputDraft]
            let compatibility: CompatibilityDraft
        }

        let legacyData = try JSONEncoder().encode(
            LegacyDraft(inputs: [:], compatibility: CompatibilityDraft()))
        let legacyDraft = try JSONDecoder().decode(RequestDraft.self, from: legacyData)
        XCTAssertFalse(legacyDraft.noCommentSelected)

        var selected = RequestDraft(inputs: [:])
        selected.noCommentSelected = true
        XCTAssertTrue(selected.hasEdits)
        let roundTripped = try JSONDecoder().decode(RequestDraft.self,
                                                    from: JSONEncoder().encode(selected))
        XCTAssertEqual(roundTripped, selected)
    }

    @MainActor
    func testNativeLaunchKeepsFictionalFixtureBehindExplicitTestArgument() {
        let ordinary = NativeAppLaunch(arguments: ["Harklight"])
        guard case .enrollmentRequired = ordinary.state else {
            return XCTFail("An ordinary app launch must not present the bundled fictional account.")
        }
        let fixture = NativeAppLaunch(arguments: ["Harklight", "--reset-attention-fixture"])
        guard case .fixture = fixture.state else {
            return XCTFail("The fixture remains available to the explicit UI-test launch.")
        }
    }


    @MainActor
    func testOnlyRequestsWithAUserActionAppearInReplied() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("inbox-replied-\(UUID().uuidString)"),
                                       deviceID: ExactText("device-A"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let store = try ClientRepository(context: context,
                                             persistence: MemoryPendingActionPersistence())
        let existingKey = RequestKey(accountScope: identity.personID,
                                     senderID: ExactText("app:test"),
                                     messageID: ExactText("preexisting"))
        let existingPayload = try JSONValue.parse(Data(#"{"sender_id":"app:test","message_id":"preexisting","title":"Older request","body":"Please reply"}"#.utf8))
        _ = try store.apply(RelayEvent(sequence: 1,
                                       body: .delivery(StoredRequest(key: existingKey,
                                                                     originalPayload: existingPayload), .message)),
                            context: context)
        let resolvedKey = RequestKey(accountScope: identity.personID,
                                     senderID: ExactText("app:test"),
                                     messageID: ExactText("preexisting-answered"))
        let resolvedPayload = try JSONValue.parse(Data(#"{"sender_id":"app:test","message_id":"preexisting-answered","title":"Older answered request","body":"Already answered"}"#.utf8))
        _ = try store.apply(RelayEvent(sequence: 2,
                                       body: .delivery(StoredRequest(key: resolvedKey,
                                                                     originalPayload: resolvedPayload), .message)),
                            context: context)
        _ = try store.apply(RelayEvent(sequence: 3,
                                       body: .terminal(resolvedKey, .answered, nil)),
                            context: context)

        let visible = try LivePresentationStore(store: store, context: context)
        let existingRow = try XCTUnwrap(visible.inboxRows.first { $0.key == existingKey })
        XCTAssertFalse(existingRow.belongsToReplied,
                       "An untouched open request remains in Inbox even if it was present at launch.")
        XCTAssertTrue(try XCTUnwrap(visible.inboxRows.first { $0.key == resolvedKey }).belongsToReplied,
                      "An answered request belongs to Replied.")
        let existingRequest = try XCTUnwrap(visible.presentation.requests.first { $0.key == existingKey })
        XCTAssertTrue(LiveRequestDetail(request: existingRequest, store: visible).canAnswer)
        XCTAssertTrue(try store.snapshot(context: context).outbox.isEmpty,
                      "Classifying Inbox and Replied must not create a relay operation.")

        let newKey = RequestKey(accountScope: identity.personID,
                                senderID: ExactText("app:test"),
                                messageID: ExactText("arrived-after-start"))
        let newPayload = try JSONValue.parse(Data(#"{"sender_id":"app:test","message_id":"arrived-after-start","title":"New request","body":"Please reply"}"#.utf8))
        _ = try store.apply(RelayEvent(sequence: 4,
                                       body: .delivery(StoredRequest(key: newKey,
                                                                     originalPayload: newPayload), .message)),
                            context: context)
        try visible.refreshFromDurableStore()

        let newRow = try XCTUnwrap(visible.inboxRows.first { $0.key == newKey })
        XCTAssertFalse(newRow.belongsToReplied,
                       "A message received after launch remains in Inbox until an action is taken.")
        XCTAssertFalse(try XCTUnwrap(visible.inboxRows.first { $0.key == existingKey }).belongsToReplied)
        let existingProjection = try XCTUnwrap(visible.presentation.requests.first { $0.key == existingKey })
        guard case let .compatibility(actions) = existingProjection.projection,
              let reply = actions.first else {
            return XCTFail("The open request should expose its reply action.")
        }
        visible.selectAction(reply.id, input: nil, for: existingKey)
        XCTAssertFalse(try XCTUnwrap(visible.inboxRows.first { $0.key == existingKey }).belongsToReplied,
                       "Selecting Reply keeps the request in Inbox until submission.")
        XCTAssertTrue(try store.snapshot(context: context).outbox.isEmpty,
                      "Choosing Reply must remain a draft until the user submits it.")
    }

    @MainActor
    func testUnknownV2AnswerFormatOffersPlainReplyAndExplainsTheFallback() throws {
        let savedRules = AnswerScreenRules.current
        AnswerScreenRules.current = AnswerScreenRules(limits: .builtIn, degradesUnshowableScreens: true)
        defer { AnswerScreenRules.current = savedRules }
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person-A"),
                                       deviceID: ExactText("device-A"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let store = try ClientRepository(context: context,
                                             persistence: MemoryPendingActionPersistence())
        let key = RequestKey(accountScope: identity.personID,
                             senderID: ExactText("app:test"), messageID: ExactText("unsupported"))
        let payload = try JSONValue.parse(Data(#"{"title":"Future answer","answer_ui":{"schema":"future.answer/9"}}"#.utf8))
        _ = try store.apply(RelayEvent(sequence: 1,
                                       body: .delivery(StoredRequest(key: key, originalPayload: payload), .message)),
                            context: context)
        let visible = try LivePresentationStore(store: store, context: context)
        let request = try XCTUnwrap(visible.presentation.requests.first)
        guard case let .compatibility(actions) = request.projection else {
            return XCTFail("The v2 client should offer plain reply for an unknown custom screen.")
        }
        XCTAssertEqual(actions.map(\.id), [ExactText("reply")])
        XCTAssertTrue(request.customAnswerScreenNotShown)
        XCTAssertTrue(LiveRequestDetail(request: request, store: visible).canAnswer)
    }



    func testNormativeFixturesAdmitTwoDifferentSenderScenesAndWholeFallback() throws {
        let fixtures = try loadFixtures()

        XCTAssertEqual(fixtures.requests.map(\.key.messageID.rawValue), ["review-01", "facilities-01", "unknown-01"])
        XCTAssertEqual(fixtures.requests.map(\.title.rawValue), ["Studio review", "Facilities desk", "Unfamiliar interface"])

        guard case let .sender(review) = fixtures.requests[0].interface,
              case let .sender(facilities) = fixtures.requests[1].interface else {
            return XCTFail("The two cleared sender documents must be admitted.")
        }
        XCTAssertEqual(review.inputs.count, 1)
        XCTAssertEqual(facilities.inputs.count, 2)
        XCTAssertEqual(facilities.inputs.map(\.id.rawValue), ["location", "note"])
        XCTAssertEqual(facilities.illustrations.map(\.id.rawValue), ["floor-plan", "closed-plan"])
        guard case .unsupported(.unfamiliar) = fixtures.requests[2].interface else {
            return XCTFail("An unfamiliar sender profile must be wholly unsupported.")
        }
        XCTAssertEqual(fixtures.requests[2].originalPayload.value(named: "answer_ui"), fixtures.requests[2].answerDescription)
    }

    func testProjectionCarriesAdmittedGraphicsSubmissionLabelAndFixtureAcceptanceOrder() throws {
        let fixtures = try loadFixtures()
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("fixture-only:test"),
                                       personID: fixtures.accountScope,
                                       deviceID: ExactText("device-a"))
        let context = ProfileContext(identity: identity, transportMode: .fixture)
        let store = try makeStore(fixtures: fixtures,
                                  context: context,
                                  persistence: MemoryPendingActionPersistence())
        let port = AttentionDomainPort(store: store)
        let snapshot = try port.observe(context: port.context)

        XCTAssertEqual(snapshot.requests.map(\.key), Array(fixtures.requests.reversed()).map(\.key))
        XCTAssertEqual(snapshot.requests.map(\.acceptanceOrder), [UInt64(3), 2, 1],
                       "The inbox presents the most recently accepted request first.")

        let review = try XCTUnwrap(fixtures.requests.first(where: {
            $0.key.messageID == ExactText("review-01")
        }))
        let reviewProjection = try XCTUnwrap(snapshot.requests.first(where: { $0.key == review.key }))
        guard case let .sender(document) = review.interface,
              case let .sender(projection) = reviewProjection.projection else {
            return XCTFail("Expected the reviewed sender document projection.")
        }
        XCTAssertEqual(projection.illustrations, document.illustrations)
        XCTAssertEqual(projection.submissionLabel, document.submissionLabel)

        let responseInput = try XCTUnwrap(document.inputs.first { input in
            if case .response = input.kind { return true }
            return false
        })
        guard case let .response(actions) = responseInput.kind,
              let projectedInput = projection.inputs.first(where: { $0.id == responseInput.id }),
              case let .response(projectedActions) = projectedInput.kind else {
            return XCTFail("Expected the response actions to retain their admitted projection.")
        }
        XCTAssertTrue(actions.contains(where: { $0.illustrationID != nil }))
        XCTAssertEqual(projectedActions.map(\.illustrationID), actions.map(\.illustrationID))
    }


    func testMalformedAuthorizedResultPointProjectsTheWholeNeutralScene() throws {
        let fixtures = try loadFixtures()
        let fixture = try XCTUnwrap(fixtures.requests.first(where: { $0.key.messageID == ExactText("facilities-01") }))
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay-test"),
                                       personID: fixtures.accountScope,
                                       deviceID: ExactText("device-a"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let store = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let request = StoredRequest(key: fixture.key, originalPayload: fixture.originalPayload)
        _ = try store.apply(RelayEvent(sequence: 1, body: .delivery(request, .message)), context: context)
        let invalidAnswer = JSONValue.object([
            JSONMember("point", .object([
                JSONMember("x", .number(JSONNumber(lexeme: "240"))),
                JSONMember("y", .string(ExactText("610")))
            ]))
        ])
        _ = try store.apply(RelayEvent(sequence: 2,
                                       body: .terminal(fixture.key, .answered, invalidAnswer)),
                            context: context)

        let port = AttentionDomainPort(store: store)
        let presented = try XCTUnwrap(port.observe(context: port.context).requests.first)
        XCTAssertEqual(presented.lifecycleStatus, .answered)
        guard case let .sender(projection) = presented.projection else {
            return XCTFail("Expected the admitted sender projection.")
        }
        XCTAssertTrue(resultPointNodes(in: projection.scene).isEmpty,
                      "An invalid coordinate binding must select the complete neutral scene.")
    }

    @MainActor
    func testEveryNormativeValidSubmissionPreservesExactTypesAndText() throws {
        let fixtures = try loadFixtures()

        for vector in fixtures.validSubmissions {
            guard let requestID = vector.uniqueValue(named: "request")?.stringValue,
                  let request = fixtures.requests.first(where: { $0.key.messageID == requestID }),
                  let state = vector.uniqueValue(named: "state")?.objectMembers,
                  let expected = vector.uniqueValue(named: "answer") else {
                return XCTFail("A normative valid submission vector is malformed.")
            }
            let store = PrototypeStore(fixtures: fixtures)
            try apply(state: state, to: request, store: store)
            XCTAssertTrue(store.canSend(for: request.key), requestID.rawValue)
            XCTAssertTrue(store.sendSelectedAnswer(for: request.key), requestID.rawValue)
            XCTAssertEqual(store.statusLabel(for: request.key), "Pending", requestID.rawValue)
            guard case let .pending(submission)? = store.session(for: request.key)?.lifecycle else {
                return XCTFail("Send did not capture a pending fixture answer.")
            }
            XCTAssertEqual(submission.answer, expected, requestID.rawValue)
            XCTAssertEqual(try JSONValue.parse(Data(submission.answer.jsonString.utf8)), expected)
        }

        let coverA = try XCTUnwrap(fixtures.validSubmissions.first(where: {
            $0.uniqueValue(named: "request")?.stringValue == ExactText("review-01") &&
                $0.uniqueValue(named: "state")?.value(named: "review")?.value(named: "action")?.stringValue == ExactText("cover-a")
        })?.uniqueValue(named: "answer"))
        XCTAssertEqual(coverA.jsonString, "{\"draft\":\"A\",\"revision\":9007199254740993,\"extra\":{\"flag\":false,\"empty\":null}}")

        let coverB = try XCTUnwrap(fixtures.validSubmissions.first(where: {
            $0.uniqueValue(named: "request")?.stringValue == ExactText("review-01") &&
                $0.uniqueValue(named: "state")?.value(named: "review")?.value(named: "action")?.stringValue == ExactText("cover-b")
        })?.uniqueValue(named: "answer"))
        let magnitude = try XCTUnwrap(coverB.uniqueValue(named: "magnitude"))
        XCTAssertEqual(magnitude.jsonString, "1e1000", "The original fixture exponent remains compact: \(coverB.jsonString)")
    }

    func testLegacyActionsCompatibilityRetainsValuesAndExactText() throws {
        let fixtures = try loadFixtures()
        XCTAssertFalse(fixtures.legacyValueConformanceVectors.isEmpty)
        XCTAssertFalse(fixtures.legacyTextConformanceVectors.isEmpty)

        for value in fixtures.legacyValueConformanceVectors {
            let action = AnswerAction(id: ExactText("compat-value"), label: ExactText("Value"), kind: .value, value: value)
            let answer = try XCTUnwrap(AnswerComposer.compose(action: action, editedText: ExactText("ignored")))
            XCTAssertEqual(answer, value)
            XCTAssertEqual(try JSONValue.parse(Data(answer.jsonString.utf8)), value)
        }
        for text in fixtures.legacyTextConformanceVectors {
            let action = AnswerAction(id: ExactText("compat-text"), label: ExactText("Text"), kind: .text, value: nil)
            let answer = try XCTUnwrap(AnswerComposer.compose(action: action, editedText: text))
            XCTAssertEqual(answer, .string(text))
            XCTAssertEqual(try JSONValue.parse(Data(answer.jsonString.utf8)), answer)
        }
    }

    func testSessionChoicesAndReplyDescriptorPreservesBothAnswerKinds() throws {
        // Matches the answer_ui emitted for two choices by harklight-agent.
        let descriptor = try JSONValue.parse(Data(#"{"schema":"attention-client.actions/1","actions":[{"id":"choice-1","label":"Approve","kind":"value","value":"Approve"},{"id":"choice-2","label":"Hold","kind":"value","value":"Hold"},{"id":"reply","label":"Reply","kind":"text"}]}"#.utf8))

        guard case let .compatibility(form) = RequestInterface.recognize(descriptor) else {
            return XCTFail("The session action descriptor must be answerable.")
        }
        XCTAssertEqual(form.actions.map(\.id), [ExactText("choice-1"), ExactText("choice-2"), ExactText("reply")])
        XCTAssertEqual(form.actions.map(\.kind), [.value, .value, .text])
        XCTAssertEqual(form.actions.map(\.label), [ExactText("Approve"), ExactText("Hold"), ExactText("Reply")])
        XCTAssertEqual(AnswerComposer.compose(action: form.actions[0], editedText: ExactText("ignored")),
                       .string(ExactText("Approve")))
        XCTAssertEqual(AnswerComposer.compose(action: form.actions[1], editedText: ExactText("ignored")),
                       .string(ExactText("Hold")))
        XCTAssertEqual(AnswerComposer.compose(action: form.actions[2], editedText: ExactText("  Another option?\n")),
                       .string(ExactText("  Another option?\n")))
    }

    func testSenderUI1ConformanceCorpusMatchesReferenceParser() throws {
        let url = try XCTUnwrap(Bundle(for: HarklightTests.self)
            .url(forResource: "attention-client-ui1-conformance-v3", withExtension: "json"))
        let corpus = try JSONValue.parse(Data(contentsOf: url))
        let cases = try XCTUnwrap(corpus.uniqueValue(named: "cases")?.arrayValues)
        XCTAssertFalse(cases.isEmpty)

        var caseIDs = Set<String>()
        var acceptedIDs = Set<String>()
        var rejectedCount = 0
        var sentMinusZeroCaseCount = 0
        for vector in cases {
            let caseID = try XCTUnwrap(vector.uniqueValue(named: "id")?.stringValue?.rawValue)
            XCTAssertTrue(caseIDs.insert(caseID).inserted, "Duplicate conformance case id \(caseID).")
            let document = try XCTUnwrap(vector.uniqueValue(named: "document"))
            let deliveredFileNames = try XCTUnwrap(vector.uniqueValue(named: "delivered_file_names")?.arrayValues)
                .map { try XCTUnwrap($0.stringValue) }
            let names = Set(deliveredFileNames)
            XCTAssertEqual(names.count, deliveredFileNames.count, "\(caseID) repeats a delivered file name.")

            switch try XCTUnwrap(vector.uniqueValue(named: "verdict")?.stringValue?.rawValue) {
            case "accept":
                acceptedIDs.insert(caseID)
                XCTAssertNoThrow(try SenderDocument.parse(document, deliveredFileNames: names),
                                 "The reference parser rejected accepted case \(caseID).")
                XCTAssertNil(vector.uniqueValue(named: "fault"), "Accepted case \(caseID) has a fault.")
                if caseID == "accept-all-primitives-inputs-scenes-constructors-and-optionals" {
                    let acceptedDocument = try SenderDocument.parse(document, deliveredFileNames: names)
                    let primitives = acceptedDocument.illustrations.flatMap(\.primitives)
                    XCTAssertTrue(primitives.contains { if case .rect = $0 { true } else { false } })
                    XCTAssertTrue(primitives.contains { if case .circle = $0 { true } else { false } })
                    XCTAssertTrue(primitives.contains { if case .line = $0 { true } else { false } })
                    XCTAssertTrue(primitives.contains { if case .text = $0 { true } else { false } })
                    XCTAssertTrue(primitives.contains { if case .image = $0 { true } else { false } })
                    XCTAssertTrue(acceptedDocument.inputs.contains {
                        if case .response = $0.kind { true } else { false }
                    })
                    XCTAssertTrue(acceptedDocument.inputs.contains {
                        if case .text = $0.kind { true } else { false }
                    })
                    XCTAssertTrue(acceptedDocument.inputs.contains {
                        if case .point = $0.kind { true } else { false }
                    })

                    func sceneKinds(_ node: SceneNode) -> Set<String> {
                        switch node.kind {
                        case let .stack(_, children):
                            return children.reduce(into: Set(["stack"])) {
                                $0.formUnion(sceneKinds($1))
                            }
                        case let .grid(_, children):
                            return children.reduce(into: Set(["grid"])) {
                                $0.formUnion(sceneKinds($1))
                            }
                        case .text:
                            return ["text"]
                        case .illustration:
                            return ["illustration"]
                        case .input:
                            return ["input"]
                        case .resultPoint:
                            return ["resultPoint"]
                        }
                    }
                    var acceptedSceneKinds = sceneKinds(acceptedDocument.open)
                    if let answeredWithResult = acceptedDocument.answeredWithResult {
                        acceptedSceneKinds.formUnion(sceneKinds(answeredWithResult))
                    }
                    XCTAssertEqual(acceptedSceneKinds,
                                   Set(["stack", "grid", "text", "illustration", "input", "resultPoint"]))
                    XCTAssertNotNil(acceptedDocument.resolvedByState[.answered])
                    XCTAssertNotNil(acceptedDocument.answeredWithResult)

                    func resultKinds(_ constructor: ResultConstructor) -> Set<String> {
                        switch constructor {
                        case .literal:
                            return ["literal"]
                        case .input:
                            return ["input"]
                        case let .array(values):
                            return values.reduce(into: Set(["array"])) {
                                $0.formUnion(resultKinds($1))
                            }
                        case let .object(members):
                            return members.reduce(into: Set(["object"])) {
                                $0.formUnion(resultKinds($1.value))
                            }
                        }
                    }
                    XCTAssertEqual(resultKinds(acceptedDocument.result),
                                   Set(["literal", "input", "array", "object"]))

                    guard case .sender = RequestInterface.recognize(document, deliveredFileNames: names, rules: .today) else {
                        return XCTFail("A delivered picture document should be recognized as sender UI.")
                    }
                    guard case .unsupported(.unfamiliar) = RequestInterface.recognize(document, rules: .today) else {
                        return XCTFail("A picture document without its delivered file names must remain unsupported.")
                    }
                    let payload = JSONValue.object([JSONMember("answer_ui", document)])
                    let request = StoredRequest(key: RequestKey(accountScope: ExactText("person"),
                                                                senderID: ExactText("agent"),
                                                                messageID: ExactText("picture")),
                                                originalPayload: payload)
                    guard case .sender = request.interface(deliveredFileNames: names, rules: .today) else {
                        return XCTFail("Stored request recognition must use its delivered file names.")
                    }
                    guard case .unsupported(.unfamiliar) = request.interface(deliveredFileNames: [], rules: .today) else {
                        return XCTFail("Stored request recognition must not invent missing delivered files.")
                    }
                }
            case "reject":
                rejectedCount += 1
                let fault = try XCTUnwrap(vector.uniqueValue(named: "fault"))
                XCTAssertEqual(fault.objectMembers?.count, 2, "Rejected case \(caseID) must name exactly one fault.")
                XCTAssertFalse(try XCTUnwrap(fault.uniqueValue(named: "location")?.stringValue?.rawValue).isEmpty,
                               "Rejected case \(caseID) has no fault location.")
                XCTAssertFalse(try XCTUnwrap(fault.uniqueValue(named: "condition")?.stringValue?.rawValue).isEmpty,
                               "Rejected case \(caseID) has no fault condition.")
                XCTAssertThrowsError(try SenderDocument.parse(document, deliveredFileNames: names),
                                     "The reference parser accepted rejected case \(caseID).")
            default:
                XCTFail("Unknown verdict in case \(caseID).")
            }

            if let sentDocument = vector.uniqueValue(named: "sent_document") {
                sentMinusZeroCaseCount += 1
                XCTAssertEqual(document.jsonString.utf8.count, 65_536, "Delivered size differs in \(caseID).")
                XCTAssertEqual(sentDocument.jsonString.utf8.count, 65_537, "Sent size differs in \(caseID).")
                XCTAssertEqual(sentDocument.jsonString.components(separatedBy: "-0").count - 1, 1,
                               "The sent form must differ by one negative-zero token in \(caseID).")
                XCTAssertEqual(sentDocument.jsonString.replacingOccurrences(of: "-0", with: "0"),
                               document.jsonString,
                               "The sent and delivered forms differ beyond the Server's -0 re-encoding in \(caseID).")
            }
        }

        XCTAssertGreaterThanOrEqual(rejectedCount, 1)
        XCTAssertEqual(sentMinusZeroCaseCount, 1)
        XCTAssertTrue(acceptedIDs.contains("accept-all-primitives-inputs-scenes-constructors-and-optionals"))
        XCTAssertTrue(acceptedIDs.contains("accept-no-input-parser-document"))
        XCTAssertTrue(acceptedIDs.contains("accept-image-integer-boundaries"))
        XCTAssertTrue(acceptedIDs.contains("accept-delivered-size-65536"))
        XCTAssertTrue(acceptedIDs.contains("accept-server-reencoded-minus-zero-edge"))
        XCTAssertTrue(caseIDs.contains("reject-image-primitive-limit-513"))
    }

    func testPictureChoiceAndPointResultsKeepTheirExactExistingValues() throws {
        let url = try XCTUnwrap(Bundle(for: HarklightTests.self)
            .url(forResource: "attention-client-ui1-conformance-v3", withExtension: "json"))
        let corpus = try JSONValue.parse(Data(contentsOf: url))
        let cases = try XCTUnwrap(corpus.uniqueValue(named: "cases")?.arrayValues)
        let pictureCase = try XCTUnwrap(cases.first {
            $0.uniqueValue(named: "id")?.stringValue?.rawValue ==
                "accept-all-primitives-inputs-scenes-constructors-and-optionals"
        })
        let deliveredNames = try XCTUnwrap(pictureCase.uniqueValue(named: "delivered_file_names")?.arrayValues)
            .compactMap(\.stringValue)
        let documentValue = try XCTUnwrap(pictureCase.uniqueValue(named: "document"))
        let document = try SenderDocument.parse(documentValue, deliveredFileNames: Set(deliveredNames))

        let exactNote = ExactText("  Exact note\n🗺  ")
        var drafts: [ExactText: InputDraft] = [
            ExactText("cover"): InputDraft(selectedActionID: ExactText("cover-b")),
            ExactText("note"): InputDraft(text: exactNote),
            ExactText("location"): InputDraft(point: PointValue(x: 500, y: 500),
                                                horizontalText: ExactText("500"),
                                                verticalText: ExactText("500"))
        ]
        let pictureAnswer = try XCTUnwrap(document.compose(drafts: drafts))
        let expectedPictureAnswer = try JSONValue.parse(Data(
            #"{"cover":{"cover":"B","issue":18446744073709551617},"note":"  Exact note\n🗺  ","location":{"x":500,"y":500},"details":[true,{"x":500,"y":500}]}"#.utf8))
        XCTAssertEqual(pictureAnswer, expectedPictureAnswer)
        XCTAssertTrue(pictureAnswer.jsonString.contains("18446744073709551617"))
        XCTAssertEqual(document.answeredWithResult.flatMap {
            document.resultPoint(in: $0, answer: pictureAnswer)
        }, PointValue(x: 500, y: 500))

        drafts[ExactText("cover")] = InputDraft(selectedActionID: ExactText("note-action"),
                                                 textByActionID: [ExactText("note-action"): exactNote])
        let noteAnswer = try XCTUnwrap(document.compose(drafts: drafts))
        let expectedNoteAnswer = try JSONValue.parse(Data(
            #"{"cover":"  Exact note\n🗺  ","note":"  Exact note\n🗺  ","location":{"x":500,"y":500},"details":[true,{"x":500,"y":500}]}"#.utf8))
        XCTAssertEqual(noteAnswer, expectedNoteAnswer)
    }

    func testImageReferencesResolveOnlyAgainstTheOriginalRequestTurnFiles() throws {
        let answerUI = try JSONValue.parse(Data(#"{"schema":"attention-client.ui/1","requires":["scene/1","result/1","illustration/1","image/1"],"illustrations":[{"id":"art","label":"Artwork","width":100,"height":100,"primitives":[{"kind":"image","x":0,"y":0,"width":100,"height":100,"file":"cover-a.jpg"}]}],"inputs":[],"open":{"kind":"illustration","id":"art"},"resolved":{"kind":"text","text":"Complete","style":"body"},"submission":{"label":"Done","result":{"kind":"literal","value":null}}}"#.utf8))
        let requestPayload = JSONValue.object([
            JSONMember("title", .string(ExactText("Choose a cover"))),
            JSONMember("answer_ui", answerUI)
        ])
        let key = RequestKey(accountScope: ExactText("person"),
                             senderID: ExactText("sender"),
                             messageID: ExactText("picture-request"))
        let context = ProfileContext(
            identity: ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                      personID: ExactText("person"),
                                      deviceID: ExactText("reader")),
            transportMode: .relay)
        let store = try ClientRepository(context: context,
                                            persistence: MemoryPendingActionPersistence())
        let requestFile = ConversationFile(id: ExactText("request-file"),
                                           name: ExactText("cover-a.jpg"),
                                           byteCount: 8,
                                           sha256: ExactText(String(repeating: "a", count: 64)),
                                           content: .uploaded(ExactText("upload-a")))
        let laterTerminalFile = ConversationFile(id: ExactText("terminal-file"),
                                                name: ExactText("terminal-only.jpg"),
                                                byteCount: 8,
                                                sha256: ExactText(String(repeating: "b", count: 64)),
                                                content: .uploaded(ExactText("upload-b")))

        _ = try store.apply(RelayEvent(
            sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: requestPayload), .message),
            conversation: RelayConversationMetadata(revision: 1,
                sessionHandle: ExactText("origin-session"),
                eventID: ExactText("request-turn"),
                author: .origin,
                files: [requestFile])),
            context: context)

        let port = AttentionDomainPort(store: store)
        var presented = try XCTUnwrap(port.observe(context: port.context).requests.first)
        XCTAssertEqual(presented.deliveredFiles, [requestFile])
        guard case .sender = presented.projection else {
            return XCTFail("The request image should resolve against its delivered file.")
        }

        _ = try store.apply(RelayEvent(
            sequence: 2,
            body: .terminal(key, .answered, nil),
            conversation: RelayConversationMetadata(revision: 1,
                eventID: ExactText("terminal-turn"),
                author: .origin,
                files: [laterTerminalFile])),
            context: context)

        presented = try XCTUnwrap(port.observe(context: port.context).requests.first)
        XCTAssertEqual(presented.deliveredFiles, [requestFile],
                       "Files attached to a later terminal turn are not request image resources.")
        guard case .sender = presented.projection else {
            return XCTFail("The original delivered picture remains recognized after the terminal event.")
        }
    }

    @MainActor
    func testSenderImageFitCentersWithoutCropping() {
        let fitted = SenderIllustrationCanvas.imageDestinationRect(
            imageSize: CGSize(width: 1_600, height: 1_000),
            in: CGRect(x: 0, y: 0, width: 400, height: 400))
        XCTAssertEqual(fitted, CGRect(x: 0, y: 75, width: 400, height: 250))

        let smallImage = SenderIllustrationCanvas.imageDestinationRect(
            imageSize: CGSize(width: 100, height: 200),
            in: CGRect(x: 20, y: 10, width: 400, height: 250))
        XCTAssertEqual(smallImage, CGRect(x: 157.5, y: 10, width: 125, height: 250))
    }

    @MainActor
    func testInvalidTypedStatesAndUnsupportedDocumentsCreateNoReceipt() throws {
        let fixtures = try loadFixtures()
        let review = try XCTUnwrap(fixtures.requests.first)
        guard case let .sender(reviewDocument) = review.interface else { return XCTFail("Missing review document") }
        let response = try XCTUnwrap(reviewDocument.inputs.first)
        let actions: [SenderAction]
        if case let .response(values) = response.kind { actions = values } else { return XCTFail("Expected response input") }
        let noteAction = try XCTUnwrap(actions.first(where: { $0.id == ExactText("note") }))
        let coverAction = try XCTUnwrap(actions.first(where: { $0.id == ExactText("cover-a") }))

        var missingSelection = RequestDraft(interface: review.interface)
        XCTAssertNil(reviewDocument.compose(drafts: missingSelection.inputs))

        missingSelection.inputs[response.id]?.selectedActionID = noteAction.id
        XCTAssertNil(reviewDocument.compose(drafts: missingSelection.inputs),
                     "A selected text action needs an explicit text record.")

        var extraText = RequestDraft(interface: review.interface)
        extraText.inputs[response.id]?.selectedActionID = coverAction.id
        extraText.inputs[response.id]?.textByActionID[coverAction.id] = ExactText("override")
        XCTAssertNil(reviewDocument.compose(drafts: extraText.inputs),
                     "Literal responses cannot carry text overrides.")

        let facilities = try XCTUnwrap(fixtures.requests.first(where: { $0.key.messageID == ExactText("facilities-01") }))
        guard case let .sender(facilitiesDocument) = facilities.interface else { return XCTFail("Missing facilities document") }
        let store = PrototypeStore(fixtures: fixtures)
        store.updateText("", for: facilities.key, inputID: ExactText("note"), actionID: nil)
        XCTAssertFalse(store.canSend(for: facilities.key), "The absent point cannot be initialized implicitly.")
        store.setPoint(PointValue(x: 240, y: 610), for: facilities.key, inputID: ExactText("location"))
        store.updateCoordinate("1001", horizontal: true, for: facilities.key, inputID: ExactText("location"))
        XCTAssertFalse(store.canSend(for: facilities.key), "Out-of-range coordinate text remains invalid.")
        store.updateCoordinate("240", horizontal: true, for: facilities.key, inputID: ExactText("location"))
        store.updateCoordinate("610.0", horizontal: false, for: facilities.key, inputID: ExactText("location"))
        XCTAssertFalse(store.canSend(for: facilities.key), "Fractional coordinate text is not rounded.")

        var missingNote = RequestDraft(interface: facilities.interface)
        missingNote.inputs[ExactText("location")]?.point = PointValue(x: 240, y: 610)
        missingNote.inputs[ExactText("location")]?.horizontalText = ExactText("240")
        missingNote.inputs[ExactText("location")]?.verticalText = ExactText("610")
        missingNote.inputs[ExactText("note")]?.text = nil
        XCTAssertNil(facilitiesDocument.compose(drafts: missingNote.inputs))

        for count in [70_000, 2 * 1024 * 1024 + 1] {
            let largeAnswerStore = PrototypeStore(fixtures: fixtures)
            largeAnswerStore.selectAction(noteAction.id, inputID: response.id, for: review.key)
            let text = String(repeating: "x", count: count)
            largeAnswerStore.updateText(text, for: review.key, inputID: response.id, actionID: noteAction.id)
            XCTAssertTrue(largeAnswerStore.canSend(for: review.key))
            XCTAssertTrue(largeAnswerStore.sendSelectedAnswer(for: review.key))
            guard case let .pending(submission)? = largeAnswerStore.session(for: review.key)?.lifecycle else {
                return XCTFail("Send did not capture the large answer.")
            }
            XCTAssertEqual(submission.answer, .string(ExactText(text)))
            XCTAssertGreaterThan(submission.wireFrame.count, count)
            XCTAssertEqual(submission.wireFrame, Data((submission.operation.jsonString + "\n").utf8))
        }

        let unknown = try XCTUnwrap(fixtures.requests.last)
        XCTAssertFalse(store.canSend(for: unknown.key))
        XCTAssertFalse(store.sendSelectedAnswer(for: unknown.key))
    }

    func testPointVectorsSharePointerAndAccessibleQuantization() throws {
        let fixtures = try loadFixtures()
        for vector in fixtures.pointVectors {
            if let rawBounds = vector.uniqueValue(named: "bounds")?.arrayValues,
               let rawPointer = vector.uniqueValue(named: "pointer")?.arrayValues,
               let expected = vector.uniqueValue(named: "expected") {
                let bounds = CGRect(x: try number(rawBounds[0]),
                                    y: try number(rawBounds[1]),
                                    width: try number(rawBounds[2]),
                                    height: try number(rawBounds[3]))
                let point = try XCTUnwrap(PointTransform.select(pointerX: try number(rawPointer[0]),
                                                                pointerY: try number(rawPointer[1]),
                                                                bounds: bounds,
                                                                dragging: false))
                XCTAssertEqual(point.jsonValue, expected)
            } else if let normalized = vector.uniqueValue(named: "normalized")?.arrayValues,
                      let expected = vector.uniqueValue(named: "expected") {
                let point = PointValue(x: PointTransform.quantize(try decimal(normalized[0])),
                                       y: PointTransform.quantize(try decimal(normalized[1])))
                XCTAssertEqual(point.jsonValue, expected)
            } else if vector.uniqueValue(named: "initialPointerOutside") != nil {
                XCTAssertNil(PointTransform.select(pointerX: -1, pointerY: 101, bounds: CGRect(x: 0, y: 0, width: 100, height: 100), dragging: false))
            } else if let captured = vector.uniqueValue(named: "capturedDragNormalized")?.arrayValues {
                let point = PointTransform.select(pointerX: try decimal(captured[0]),
                                                  pointerY: try decimal(captured[1]),
                                                  bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                                  dragging: true)
                XCTAssertEqual(point, PointValue(x: 0, y: 1000))
            } else if vector.uniqueValue(named: "assistiveAction") != nil {
                XCTAssertEqual(PointValue(x: 500, y: 500).jsonValue,
                               JSONValue.object([JSONMember("x", .number(JSONNumber(lexeme: "500"))),
                                                 JSONMember("y", .number(JSONNumber(lexeme: "500")))]))
            } else {
                XCTFail("Unrecognized point conformance vector.")
            }
        }
        XCTAssertEqual(PointTransform.quantize(0.2405), 241)
        XCTAssertEqual(PointTransform.quantize(0.2404), 240)
    }

    @MainActor
    func testPointDraftSurvivesGestureCancelledByPoseBoundsChange() throws {
        let fixtures = try loadFixtures()
        let facilities = try XCTUnwrap(fixtures.requests.first(where: {
            $0.key.messageID == ExactText("facilities-01")
        }))
        let store = PrototypeStore(fixtures: fixtures)
        let startingPoint = PointValue(x: 197, y: 0)
        let startingNote = "Valve check near east door"
        store.setPoint(startingPoint, for: facilities.key, inputID: ExactText("location"))
        store.updateText(startingNote, for: facilities.key, inputID: ExactText("note"), actionID: nil)

        let compactBounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let expandedBounds = CGRect(x: 0, y: 0, width: 1_000, height: 1_000)

        var ordinaryCapture = PointGestureCapture()
        XCTAssertEqual(ordinaryCapture.update(at: CGPoint(x: 19.7, y: 0), in: compactBounds), startingPoint)
        XCTAssertEqual(ordinaryCapture.update(at: CGPoint(x: 50, y: 50), in: compactBounds),
                       PointValue(x: 500, y: 500))
        XCTAssertEqual(ordinaryCapture.finish(at: CGPoint(x: 64, y: 58.4), in: compactBounds),
                       PointValue(x: 640, y: 584),
                       "A gesture that stays in one pose should continue to support point selection and dragging.")

        var capture = PointGestureCapture()
        let initialSelection = capture.update(at: CGPoint(x: 19.7, y: 0), in: compactBounds)
        XCTAssertEqual(initialSelection, startingPoint)

        store.setPoint(try XCTUnwrap(initialSelection), for: facilities.key, inputID: ExactText("location"))
        capture.cancelIfBoundsChanged(to: expandedBounds)
        XCTAssertNil(capture.update(at: CGPoint(x: 640, y: 584), in: expandedBounds),
                     "A pointer session started in the old pose must not be reinterpreted in the resized editor.")
        XCTAssertNil(capture.finish(at: CGPoint(x: 640, y: 584), in: expandedBounds),
                     "A cancelled gesture ending after a pose change must not commit its final location.")

        var cancelledWithoutEnd = PointGestureCapture()
        XCTAssertEqual(cancelledWithoutEnd.update(at: CGPoint(x: 19.7, y: 0), in: compactBounds), startingPoint)
        cancelledWithoutEnd.cancelIfBoundsChanged(to: expandedBounds)
        cancelledWithoutEnd.gestureDidEnd()
        XCTAssertEqual(cancelledWithoutEnd.update(at: CGPoint(x: 19.7, y: 0), in: expandedBounds),
                       PointValue(x: 20, y: 0),
                       "The first new touch after a cancelled fold gesture must select a point.")
        XCTAssertEqual(cancelledWithoutEnd.finish(at: CGPoint(x: 64, y: 58.4), in: expandedBounds),
                       PointValue(x: 64, y: 58),
                       "Dragging must work on the first gesture after cancellation.")

        let locationDraft = try XCTUnwrap(store.inputDraft(for: facilities.key, inputID: ExactText("location")))
        let noteDraft = try XCTUnwrap(store.inputDraft(for: facilities.key, inputID: ExactText("note")))
        XCTAssertEqual(locationDraft.effectivePoint, startingPoint)
        XCTAssertEqual(noteDraft.text, ExactText(startingNote))

        var captureWithoutTouch = PointGestureCapture()
        XCTAssertNil(captureWithoutTouch.finish(at: CGPoint(x: 640, y: 584), in: expandedBounds),
                     "An end event without a captured touch must not create a new point.")
    }

    func testTerminalSceneRequiresKnownAnswerAndValidWholeBinding() throws {
        let fixtures = try loadFixtures()
        let request = try XCTUnwrap(fixtures.requests.first(where: { $0.key.messageID == ExactText("facilities-01") }))
        guard case let .sender(document) = request.interface else { return XCTFail("Missing facilities document") }
        XCTAssertEqual(document.terminalScene(state: .answered, authorizedAnswer: nil), document.resolved)

        let answer = try XCTUnwrap(fixtures.validSubmissions.first(where: {
            $0.uniqueValue(named: "request")?.stringValue == ExactText("facilities-01")
        })?.uniqueValue(named: "answer"))
        let known = document.terminalScene(state: .answered, authorizedAnswer: answer)
        XCTAssertEqual(known, try XCTUnwrap(document.answeredWithResult))
        let resultPoints = collectResultPoints(in: known)
        XCTAssertEqual(resultPoints.count, 1)
        XCTAssertEqual(document.resultPoint(in: resultPoints[0], answer: answer), PointValue(x: 240, y: 610))

        XCTAssertEqual(document.terminalScene(state: .answered, authorizedAnswer: .null), document.resolved)
        let malformed = JSONValue.object([
            JSONMember("point", .object([
                JSONMember("x", .number(JSONNumber(lexeme: "240"))),
                JSONMember("y", .number(JSONNumber(lexeme: "610"))),
                JSONMember("extra", .number(JSONNumber(lexeme: "1")))
            ]))
        ])
        XCTAssertEqual(document.terminalScene(state: .answered, authorizedAnswer: malformed), document.resolved)
        XCTAssertEqual(document.terminalScene(state: .cleared, authorizedAnswer: answer),
                       try XCTUnwrap(document.resolvedByState[.cleared]))
    }

    func testStaticAnsweredTerminalOverrideIsAdmitted() throws {
        let fixtures = try loadFixtures()
        let request = try XCTUnwrap(fixtures.requests.first(where: { $0.key.messageID == ExactText("facilities-01") }))
        let original = try XCTUnwrap(request.answerDescription)
        let states = try XCTUnwrap(original.uniqueValue(named: "resolvedByState"))
        let cleared = try XCTUnwrap(states.uniqueValue(named: "cleared"))
        let updatedStates = appendMember(states, JSONMember("answered", cleared))
        let updated = replacingMember(original, key: "resolvedByState", value: updatedStates)

        guard case let .sender(document) = RequestInterface.recognize(updated) else {
            return XCTFail("A valid static answered override must not make the whole document unfamiliar.")
        }
        let answered = try XCTUnwrap(document.resolvedByState[.answered])
        XCTAssertEqual(document.terminalScene(state: .answered, authorizedAnswer: nil), answered)
        XCTAssertNotEqual(answered.id, document.resolved.id)
    }

    @MainActor
    func testInvalidPointCoordinateRemainsEditableUntilCorrected() throws {
        let fixtures = try loadFixtures()
        let request = try XCTUnwrap(fixtures.requests.first(where: { $0.key.messageID == ExactText("facilities-01") }))
        let store = PrototypeStore(fixtures: fixtures)
        let note = ExactText("  Near the door\n  ")

        store.setPoint(PointValue(x: 240, y: 610), for: request.key, inputID: ExactText("location"))
        store.updateText(note.rawValue, for: request.key, inputID: ExactText("note"), actionID: nil)
        XCTAssertTrue(store.canSend(for: request.key))

        store.updateCoordinate("1001", horizontal: true, for: request.key, inputID: ExactText("location"))
        let invalid = try XCTUnwrap(store.inputDraft(for: request.key, inputID: ExactText("location")))
        XCTAssertTrue(invalid.hasInitializedPoint)
        XCTAssertTrue(invalid.hasInvalidCoordinateEntry)
        XCTAssertNil(invalid.effectivePoint)
        XCTAssertEqual(store.coordinateText(for: request.key, inputID: ExactText("location"), horizontal: true), "1001")
        XCTAssertFalse(store.canSend(for: request.key))
        XCTAssertEqual(store.textDraft(for: request.key, inputID: ExactText("note"), actionID: nil), note)

        store.updateCoordinate("240", horizontal: true, for: request.key, inputID: ExactText("location"))
        let corrected = try XCTUnwrap(store.inputDraft(for: request.key, inputID: ExactText("location")))
        XCTAssertTrue(corrected.hasInitializedPoint)
        XCTAssertFalse(corrected.hasInvalidCoordinateEntry)
        XCTAssertEqual(corrected.effectivePoint, PointValue(x: 240, y: 610))
        XCTAssertTrue(store.canSend(for: request.key))
        XCTAssertEqual(store.textDraft(for: request.key, inputID: ExactText("note"), actionID: nil), note)
    }

    @MainActor
    func testDraftContinuityCancelAndSimulatedLifecycleRemainPerRequest() throws {
        let fixtures = try loadFixtures()
        let store = PrototypeStore(fixtures: fixtures)
        let review = try XCTUnwrap(fixtures.requests.first)
        let facilities = try XCTUnwrap(fixtures.requests.first(where: { $0.key.messageID == ExactText("facilities-01") }))
        let exactText = ExactText("  Cafe\u{301} 👩🏽‍💻\n  ")

        store.selectAction(ExactText("note"), inputID: ExactText("review"), for: review.key)
        store.updateText(exactText.rawValue, for: review.key, inputID: ExactText("review"), actionID: ExactText("note"))
        store.selectAction(ExactText("cover-a"), inputID: ExactText("review"), for: review.key)
        store.selectAction(ExactText("note"), inputID: ExactText("review"), for: review.key)
        XCTAssertTrue(store.textDraft(for: review.key, inputID: ExactText("review"), actionID: ExactText("note")).rawValue.utf8.elementsEqual(exactText.rawValue.utf8))

        store.setPoint(PointValue(x: 240, y: 610), for: facilities.key, inputID: ExactText("location"))
        store.updateText("  Near the door\n  ", for: facilities.key, inputID: ExactText("note"), actionID: nil)
        store.selectRequest(facilities.key)
        store.selectRequest(review.key)
        XCTAssertEqual(store.inputDraft(for: facilities.key, inputID: ExactText("location"))?.effectivePoint, PointValue(x: 240, y: 610))
        XCTAssertEqual(store.textDraft(for: facilities.key, inputID: ExactText("note"), actionID: nil), ExactText("  Near the door\n  "))

        store.cancelDraft(for: facilities.key)
        XCTAssertNil(store.inputDraft(for: facilities.key, inputID: ExactText("location"))?.effectivePoint)
        XCTAssertEqual(store.textDraft(for: facilities.key, inputID: ExactText("note"), actionID: nil), ExactText(""))
        XCTAssertEqual(store.textDraft(for: review.key, inputID: ExactText("review"), actionID: ExactText("note")), exactText)

        store.setPoint(PointValue(x: 240, y: 610), for: facilities.key, inputID: ExactText("location"))
        store.updateText("  Near the door\n  ", for: facilities.key, inputID: ExactText("note"), actionID: nil)
        XCTAssertTrue(store.sendSelectedAnswer(for: facilities.key))
        XCTAssertFalse(store.sendSelectedAnswer(for: facilities.key))
        XCTAssertEqual(store.openRequests.count, 3)
        XCTAssertTrue(store.simulateTerminal(for: facilities.key, scenario: .ownOperationAccepted))
        XCTAssertEqual(store.openRequests.count, 2)
        guard case let .terminal(terminal, submission)? = store.session(for: facilities.key)?.lifecycle else {
            return XCTFail("The selected demo outcome did not close the fixture.")
        }
        XCTAssertEqual(terminal.ownOutcome, .accepted)
        XCTAssertEqual(terminal.authorizedAnswer, submission.answer)
        XCTAssertEqual(store.statusLabel(for: facilities.key), "Answered")
        XCTAssertFalse(store.canSend(for: facilities.key))
    }

    @MainActor
    func testClearedRequestWithoutResultRaisesUnresolvedSendWarning() throws {
        let fixtures = try loadFixtures()
        let store = PrototypeStore(fixtures: fixtures)
        let facilities = try XCTUnwrap(fixtures.requests.first(where: { $0.key.messageID == ExactText("facilities-01") }))
        let presentation = try XCTUnwrap(store.presentationStore)
        XCTAssertNil(presentation.unresolvedSendWarning,
                     "An untouched inbox has no unresolved send.")

        store.setPoint(PointValue(x: 240, y: 610), for: facilities.key, inputID: ExactText("location"))
        store.updateText("Near the door", for: facilities.key, inputID: ExactText("note"), actionID: nil)
        XCTAssertTrue(store.sendSelectedAnswer(for: facilities.key))
        try presentation.refreshFromDurableStore()
        XCTAssertNil(presentation.unresolvedSendWarning,
                     "An in-flight send carries its status line, not a warning.")

        XCTAssertTrue(store.simulateTerminal(for: facilities.key, scenario: .cleared))
        try presentation.refreshFromDurableStore()
        XCTAssertEqual(presentation.unresolvedSendWarning,
                       "Submission unconfirmed · saved draft retained",
                       "A send whose request closed without a confirmed result raises the warning.")
    }

    func testDuplicateGrammarKeysAndUnknownInactiveBranchFailWholeDocument() throws {
        let fixtures = try loadFixtures()
        let facilities = try XCTUnwrap(fixtures.requests.first(where: { $0.key.messageID == ExactText("facilities-01") }))
        let original = try XCTUnwrap(facilities.answerDescription)
        guard case let .object(members) = original else { return XCTFail("Expected document object") }

        let duplicateSchema = JSONValue.object(members + [JSONMember("schema", .string(ExactText("attention-client.ui/1")))])
        guard case .unsupported(.unfamiliar) = RequestInterface.recognize(duplicateSchema) else {
            return XCTFail("Duplicate grammar keys cannot use last-key-wins parsing.")
        }

        let states = try XCTUnwrap(original.uniqueValue(named: "resolvedByState"))
        let invalidExpired = appendMember(states, JSONMember("future", .bool(true)))
        let invalidDocument = replacingMember(original, key: "resolvedByState", value: invalidExpired)
        guard case .unsupported(.unfamiliar) = RequestInterface.recognize(invalidDocument) else {
            return XCTFail("An unknown member in an inactive terminal tree invalidates the whole document.")
        }

        let unknownCapability = appendingArrayValue(original.uniqueValue(named: "requires"), .string(ExactText("future/1")))
        let withUnknownCapability = replacingMember(original, key: "requires", value: unknownCapability)
        guard case .unsupported(.unfamiliar) = RequestInterface.recognize(withUnknownCapability) else {
            return XCTFail("Unknown capabilities must not be partially admitted.")
        }
    }

    func testExactIdentifiersPreserveUnicodeNormalization() {
        let decomposed = ExactText("Cafe\u{301}")
        let composed = ExactText("Café")
        XCTAssertNotEqual(decomposed, composed)
        XCTAssertEqual(Set([decomposed, composed]).count, 2)
    }

    func testDurablePortRecoversDraftAndSameIntentAfterRestart() throws {
        let fixtures = try loadFixtures()
        let fixture = try XCTUnwrap(fixtures.requests.first(where: { $0.key.messageID == ExactText("facilities-01") }))
        guard case let .sender(document) = fixture.interface else { return XCTFail("Expected the facilities sender document.") }
        let pointInput = try XCTUnwrap(document.inputs.first(where: { if case .point = $0.kind { return true }; return false }))
        let noteInput = try XCTUnwrap(document.inputs.first(where: { if case .text = $0.kind { return true }; return false }))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("attention-domain-restart-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = FilePendingActionPersistence(directoryURL: directory)
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("fixture-only:test"),
                                       personID: fixtures.accountScope,
                                       deviceID: ExactText("device-a"))
        let firstContext = ProfileContext(identity: identity, transportMode: .relay)
        let firstStore = try makeStore(fixtures: fixtures, context: firstContext, persistence: persistence)
        let firstPort = AttentionDomainPort(store: firstStore)
        let firstView = try firstPort.inspect(context: firstPort.context, request: fixture.key)
        let firstSelector = try XCTUnwrap(firstView.requests.first?.selector)
        let firstAcceptanceOrder = try XCTUnwrap(firstView.requests.first?.acceptanceOrder)

        var draft = RequestDraft(interface: fixture.interface)
        draft.inputs[pointInput.id]?.point = PointValue(x: 240, y: 610)
        draft.inputs[pointInput.id]?.horizontalText = ExactText("240")
        draft.inputs[pointInput.id]?.verticalText = ExactText("610")
        draft.inputs[noteInput.id]?.text = ExactText("  Near the door\n  ")
        try firstPort.saveDraft(context: firstPort.context, selector: firstSelector, completeDraft: draft)

        // Reopening restores user input from the same pending-action file; relay events rebuild the question.
        let restartedContext = ProfileContext(identity: identity, transportMode: .relay)
        let restartedStore = try makeStore(fixtures: fixtures, context: restartedContext, persistence: persistence)
        let restartedPort = AttentionDomainPort(store: restartedStore)
        let restartedSnapshot = try restartedPort.observe(context: restartedPort.context)
        XCTAssertEqual(restartedSnapshot.requests.first(where: { $0.key == fixture.key })?.lifecycleStatus, .open)
        XCTAssertEqual(restartedSnapshot.requests.first(where: { $0.key == fixture.key })?.acceptanceOrder,
                       firstAcceptanceOrder)
        XCTAssertEqual(try restartedStore.snapshot(context: restartedContext).drafts[fixture.key], draft)

        let records: [TypedInputRecord] = [
            .point(input: pointInput.id, point: PointValue(x: 240, y: 610)),
            .text(input: noteInput.id, text: ExactText("  Near the door\n  "))
        ]
        let selector = try XCTUnwrap(restartedPort.inspect(context: restartedPort.context, request: fixture.key).requests.first?.selector)
        let intentID = UUID()
        let receipt = try restartedPort.submit(SubmitIntent(context: restartedPort.context,
                                                            selector: selector,
                                                            intentID: intentID,
                                                            inputs: records))
        let expected = try XCTUnwrap(fixtures.validSubmissions.first(where: {
            $0.uniqueValue(named: "request")?.stringValue == fixture.key.messageID &&
                $0.uniqueValue(named: "state")?.value(named: "note")?.value(named: "text")?.stringValue == ExactText("  Near the door\n  ")
        })?.uniqueValue(named: "answer"))
        XCTAssertEqual(receipt.exactAnswer, expected)
        XCTAssertEqual(receipt.inputs, records)
        XCTAssertEqual(receipt.localState, .queuedForRelay)
        XCTAssertTrue(try restartedStore.snapshot(context: restartedContext).outbox.isEmpty,
                      "Recoverable local input does not authorize sending without a current server projection.")

        // No caller-visible response was delivered. A second host resumes by intent ID and
        // obtains the original operation UUID and exact answer without creating another row.
        let lookup = try XCTUnwrap(restartedPort.lookupIntent(context: restartedPort.context, intentID: intentID))
        XCTAssertEqual(lookup.opID, receipt.opID)
        XCTAssertEqual(lookup.exactAnswer, receipt.exactAnswer)
        XCTAssertEqual(lookup.inputs, records)
        let submitWonFence = try XCTUnwrap(restartedPort.fenceUncommittedIntent(
            context: restartedPort.context, requestKey: fixture.key, intentID: intentID))
        XCTAssertEqual(submitWonFence.opID, receipt.opID)

        let postCommitContext = ProfileContext(identity: identity, transportMode: .relay)
        let postCommitStore = try makeStore(fixtures: fixtures, context: postCommitContext, persistence: persistence)
        let postCommitPort = AttentionDomainPort(store: postCommitStore)
        let recoveredRequest = try XCTUnwrap(postCommitPort.inspect(context: postCommitPort.context,
                                                                    request: fixture.key).requests.first)
        XCTAssertEqual(recoveredRequest.draft, draft)
        XCTAssertEqual(recoveredRequest.intentReceipt?.intentID, intentID)
        XCTAssertEqual(recoveredRequest.intentReceipt?.opID, receipt.opID)
        XCTAssertEqual(recoveredRequest.intentReceipt?.exactAnswer, receipt.exactAnswer)

        let retrySelector = try XCTUnwrap(recoveredRequest.selector)
        let retried = try postCommitPort.submit(SubmitIntent(context: postCommitPort.context,
                                                            selector: retrySelector,
                                                            intentID: intentID,
                                                            inputs: records))
        XCTAssertEqual(retried.opID, receipt.opID)
        XCTAssertEqual(try postCommitStore.snapshot(context: postCommitContext).intents.count, 1)
        XCTAssertTrue(try postCommitStore.snapshot(context: postCommitContext).outbox.isEmpty,
                      "A store lookup alone does not execute the delivery worker.")

        let changed: [TypedInputRecord] = [
            .point(input: pointInput.id, point: PointValue(x: 240, y: 610)),
            .text(input: noteInput.id, text: ExactText("Near another door"))
        ]
        XCTAssertThrowsError(try postCommitPort.submit(SubmitIntent(context: postCommitPort.context,
                                                                   selector: retrySelector,
                                                                   intentID: intentID,
                                                                   inputs: changed))) { error in
            XCTAssertEqual(error as? AttentionStoreError, .intentConflict)
        }
        XCTAssertEqual(try postCommitStore.snapshot(context: postCommitContext).intents.count, 1)
        XCTAssertTrue(try postCommitStore.snapshot(context: postCommitContext).outbox.isEmpty,
                      "A store lookup alone does not execute the delivery worker.")
    }

    func testDurableFenceRejectsLateOriginalSubmitAfterRestartAndChangedDraft() throws {
        let fixtures = try loadFixtures()
        let fixture = try XCTUnwrap(fixtures.requests.first(where: { $0.key.messageID == ExactText("facilities-01") }))
        guard case let .sender(document) = fixture.interface else { return XCTFail("Expected facilities sender document.") }
        let point = try XCTUnwrap(document.inputs.first(where: { if case .point = $0.kind { return true }; return false }))
        let note = try XCTUnwrap(document.inputs.first(where: { if case .text = $0.kind { return true }; return false }))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("attention-fence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = FilePendingActionPersistence(directoryURL: directory)
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("fixture-only:test"),
                                       personID: fixtures.accountScope, deviceID: ExactText("device-a"))
        let context = ProfileContext(identity: identity, transportMode: .fixture)
        let store = try makeStore(fixtures: fixtures, context: context, persistence: persistence)
        let port = AttentionDomainPort(store: store)
        let originalID = UUID()
        let original: [TypedInputRecord] = [
            .point(input: point.id, point: PointValue(x: 240, y: 610)),
            .text(input: note.id, text: ExactText("Original note"))
        ]

        // The first HTTP body is held before the route lock. An absent lookup is
        // not a result; the durable fence is the ordering proof.
        XCTAssertNil(try port.lookupIntent(context: port.context, intentID: originalID))
        XCTAssertNil(try port.fenceUncommittedIntent(context: port.context,
                                                     requestKey: fixture.key, intentID: originalID))
        XCTAssertNil(try port.fenceUncommittedIntent(context: port.context,
                                                     requestKey: fixture.key, intentID: originalID))

        let restarted = AttentionDomainPort(store: try makeStore(fixtures: fixtures,
            context: ProfileContext(identity: identity, transportMode: .fixture), persistence: persistence))
        let reopened = try XCTUnwrap(restarted.inspect(context: restarted.context, request: fixture.key).requests.first?.selector)
        XCTAssertThrowsError(try restarted.submit(SubmitIntent(context: restarted.context,
                                                                selector: reopened, intentID: originalID,
                                                                inputs: original))) { error in
            XCTAssertEqual(error as? AttentionStoreError, .intentConflict)
        }
        let changed: [TypedInputRecord] = [
            .point(input: point.id, point: PointValue(x: 625, y: 500)),
            .text(input: note.id, text: ExactText("Changed after fence"))
        ]
        let nextID = UUID()
        let next = try restarted.submit(SubmitIntent(context: restarted.context,
                                                    selector: reopened, intentID: nextID, inputs: changed))
        XCTAssertEqual(next.inputs, changed)
        XCTAssertEqual(try restarted.lookupIntent(context: restarted.context, intentID: nextID)?.opID,
                       next.opID)
    }

    func testPreCommitFailureRecoversSavedDraftWithoutCreatingAnIntent() throws {
        let fixtures = try loadFixtures()
        let fixture = try XCTUnwrap(fixtures.requests.first(where: { $0.key.messageID == ExactText("facilities-01") }))
        guard case let .sender(document) = fixture.interface else { return XCTFail("Expected the facilities sender document.") }
        let pointInput = try XCTUnwrap(document.inputs.first(where: { if case .point = $0.kind { return true }; return false }))
        let noteInput = try XCTUnwrap(document.inputs.first(where: { if case .text = $0.kind { return true }; return false }))
        let persistence = MemoryPendingActionPersistence()
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("fixture-only:test"),
                                       personID: fixtures.accountScope,
                                       deviceID: ExactText("device-precommit"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let store = try makeStore(fixtures: fixtures, context: context, persistence: persistence)
        let port = AttentionDomainPort(store: store)
        let selector = try XCTUnwrap(port.inspect(context: port.context, request: fixture.key).requests.first?.selector)
        var draft = RequestDraft(interface: fixture.interface)
        draft.inputs[pointInput.id]?.point = PointValue(x: 240, y: 610)
        draft.inputs[pointInput.id]?.horizontalText = ExactText("240")
        draft.inputs[pointInput.id]?.verticalText = ExactText("610")
        draft.inputs[noteInput.id]?.text = ExactText("Saved before submit")
        try port.saveDraft(context: port.context, selector: selector, completeDraft: draft)

        let records: [TypedInputRecord] = [
            .point(input: pointInput.id, point: PointValue(x: 240, y: 610)),
            .text(input: noteInput.id, text: ExactText("Saved before submit"))
        ]
        persistence.failNextCommit()
        XCTAssertThrowsError(try port.submit(SubmitIntent(context: port.context,
                                                          selector: selector,
                                                          intentID: UUID(),
                                                          inputs: records))) { error in
            guard let storeError = error as? AttentionStoreError,
                  case .persistence = storeError else {
                return XCTFail("Expected the injected durable commit failure; got \(error).")
            }
        }

        let restartedContext = ProfileContext(identity: identity, transportMode: .relay)
        let restartedStore = try makeStore(fixtures: fixtures, context: restartedContext, persistence: persistence)
        let restartedPort = AttentionDomainPort(store: restartedStore)
        let inspected = try XCTUnwrap(restartedPort.inspect(context: restartedPort.context,
                                                            request: fixture.key).requests.first)
        XCTAssertEqual(inspected.draft, draft)
        XCTAssertNil(inspected.intentReceipt, "A failed submit commit must not expose a partial intent receipt.")
        let retrySelector = try XCTUnwrap(inspected.selector)
        let retried = try restartedPort.submit(SubmitIntent(context: restartedPort.context,
                                                            selector: retrySelector,
                                                            intentID: UUID(),
                                                            inputs: records))
        XCTAssertEqual(retried.inputs, records)
        XCTAssertEqual(try restartedStore.snapshot(context: restartedContext).intents.count, 1)
        XCTAssertTrue(try restartedStore.snapshot(context: restartedContext).outbox.isEmpty,
                      "Retrying a queue commit still requires the separate currentness-checked send.")
    }

    func testAccountAndGenerationBindingHideCollidingRequests() throws {
        let fixtures = try loadFixtures()
        let source = try XCTUnwrap(fixtures.requests.first(where: { $0.key.messageID == ExactText("facilities-01") }))
        let persistence = MemoryPendingActionPersistence()
        let personA = ExactText("person-A")
        let personB = ExactText("person-B")
        let contextA = ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("relay-test"), personID: personA, deviceID: ExactText("device-a")), transportMode: .fixture)
        let contextB = ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("relay-test"), personID: personB, deviceID: ExactText("device-b")), transportMode: .fixture)
        let keyA = RequestKey(accountScope: personA, senderID: source.key.senderID, messageID: source.key.messageID)
        let keyB = RequestKey(accountScope: personB, senderID: source.key.senderID, messageID: source.key.messageID)
        let storeA = try makeStore(fixtures: fixtures, context: contextA, persistence: persistence, replacing: [source.key: keyA])
        let storeB = try makeStore(fixtures: fixtures, context: contextB, persistence: persistence, replacing: [source.key: keyB])
        let portA = AttentionDomainPort(store: storeA)
        let portB = AttentionDomainPort(store: storeB)
        let selectorA = try XCTUnwrap(portA.inspect(context: portA.context, request: keyA).requests.first?.selector)
        let intentID = UUID()
        guard case let .sender(document) = source.interface else { return XCTFail("Expected a sender document.") }
        let point = try XCTUnwrap(document.inputs.first(where: { if case .point = $0.kind { return true }; return false }))
        let note = try XCTUnwrap(document.inputs.first(where: { if case .text = $0.kind { return true }; return false }))
        let records: [TypedInputRecord] = [
            .point(input: point.id, point: PointValue(x: 240, y: 610)),
            .text(input: note.id, text: ExactText("private to A"))
        ]
        _ = try portA.submit(SubmitIntent(context: portA.context, selector: selectorA, intentID: intentID, inputs: records))

        XCTAssertNil(try portB.lookupIntent(context: portB.context, intentID: intentID))
        XCTAssertThrowsError(try portB.saveDraft(context: portB.context,
                                                 selector: selectorA,
                                                 completeDraft: RequestDraft(interface: source.interface)))
        XCTAssertEqual(try storeB.snapshot(context: contextB).drafts[keyB], RequestDraft(interface: source.interface))

        let restartedContextA = ProfileContext(identity: contextA.identity, transportMode: .fixture)
        let restartedStoreA = try makeStore(fixtures: fixtures,
                                            context: restartedContextA,
                                            persistence: persistence,
                                            replacing: [source.key: keyA])
        let restartedPortA = AttentionDomainPort(store: restartedStoreA)
        XCTAssertThrowsError(try restartedPortA.lookupIntent(context: portA.context, intentID: intentID)) {
            XCTAssertEqual($0 as? AttentionStoreError, .staleProfile)
        }
        XCTAssertNotNil(try restartedPortA.lookupIntent(context: restartedPortA.context, intentID: intentID))
        XCTAssertThrowsError(try restartedPortA.saveDraft(context: restartedPortA.context,
                                                          selector: selectorA,
                                                          completeDraft: RequestDraft(interface: source.interface)))
    }

    func testDraftIsNotReportedSavedWhenDurableCommitFails() throws {
        let fixtures = try loadFixtures()
        let fixture = try XCTUnwrap(fixtures.requests.first(where: { $0.key.messageID == ExactText("facilities-01") }))
        guard case let .sender(document) = fixture.interface else { return XCTFail("Expected a sender document.") }
        let note = try XCTUnwrap(document.inputs.first(where: { if case .text = $0.kind { return true }; return false }))
        let persistence = MemoryPendingActionPersistence()
        let context = ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("fixture-only:test"),
                                                               personID: fixtures.accountScope,
                                                               deviceID: ExactText("device-a")),
                                     transportMode: .fixture)
        let store = try makeStore(fixtures: fixtures, context: context, persistence: persistence)
        let selector = try store.selector(for: fixture.key, context: context)
        let before = try store.snapshot(context: context).drafts[fixture.key]
        var attempted = RequestDraft(interface: fixture.interface)
        attempted.inputs[note.id]?.text = ExactText("not yet durable")

        persistence.failNextCommit()
        XCTAssertThrowsError(try store.saveDraft(attempted, selector: selector, context: context))
        XCTAssertEqual(try store.snapshot(context: context).drafts[fixture.key], before)
    }

    func testReplayBarrierAndTerminalProjectionKeepOneLifecycleStatus() throws {
        let fixtures = try loadFixtures()
        let fixture = try XCTUnwrap(fixtures.requests.first(where: { $0.key.messageID == ExactText("facilities-01") }))
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay-test"),
                                       personID: fixtures.accountScope,
                                       deviceID: ExactText("device-a"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let store = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let relayRequest = StoredRequest(key: fixture.key, originalPayload: fixture.originalPayload)
        try store.beginReplay(through: 2, context: context)
        XCTAssertEqual(try store.apply(RelayEvent(sequence: 1, body: .delivery(relayRequest, .message)), context: context), 1)
        XCTAssertEqual(try store.apply(RelayEvent(sequence: 2, body: .terminal(fixture.key, .answered, nil)), context: context), 2)
        let whileReplaying = try store.snapshot(context: context)
        XCTAssertEqual(whileReplaying.cursor, 2)
        XCTAssertNil(whileReplaying.requests[fixture.key], "New replay requests must not flash into the prior coherent presentation.")
        XCTAssertNil(whileReplaying.remoteStates[fixture.key]?.state, "Replay must not publish a partially reconstructed terminal view.")
        try store.finishReplay(at: 2, context: context)
        XCTAssertNotNil(try store.snapshot(context: context).requests[fixture.key])
        XCTAssertEqual(try store.snapshot(context: context).remoteStates[fixture.key]?.state, .answered)

        XCTAssertThrowsError(try store.apply(RelayEvent(sequence: 4, body: .terminal(fixture.key, .answered, nil)), context: context)) {
            XCTAssertEqual($0 as? AttentionStoreError, .eventGap(expected: 3, received: 4))
        }
        XCTAssertEqual(try store.apply(RelayEvent(sequence: 3,
            body: .terminal(fixture.key, .cleared, nil)), context: context), 3)
        XCTAssertEqual(try store.snapshot(context: context).remoteStates[fixture.key]?.state, .cleared,
                       "The next server terminal replaces the prior cached terminal.")
    }

    func testOwnOperationReceiptDoesNotJumpCursorOrBecomeSharedOutcome() throws {
        let fixtures = try loadFixtures()
        let fixture = try XCTUnwrap(fixtures.requests.first(where: { $0.key.messageID == ExactText("facilities-01") }))
        guard case let .sender(document) = fixture.interface else { return XCTFail("Expected a facilities sender document.") }
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay-test"),
                                       personID: fixtures.accountScope,
                                       deviceID: ExactText("device-a"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let store = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let request = StoredRequest(key: fixture.key, originalPayload: fixture.originalPayload)
        XCTAssertEqual(try store.apply(RelayEvent(sequence: 1, body: .delivery(request, .message)), context: context), 1)
        let port = AttentionDomainPort(store: store)
        let selector = try XCTUnwrap(port.inspect(context: port.context, request: fixture.key).requests.first?.selector)
        let point = try XCTUnwrap(document.inputs.first(where: { if case .point = $0.kind { return true }; return false }))
        let note = try XCTUnwrap(document.inputs.first(where: { if case .text = $0.kind { return true }; return false }))
        let records: [TypedInputRecord] = [
            .point(input: point.id, point: PointValue(x: 240, y: 610)),
            .text(input: note.id, text: ExactText("  Near the door\n  "))
        ]
        let receipt = try port.submit(SubmitIntent(context: port.context,
                                                  selector: selector,
                                                  intentID: UUID(),
                                                  inputs: records))
        var visible = try XCTUnwrap(port.observe(context: port.context).requests.first)
        XCTAssertEqual(visible.lifecycleStatus, .pending)
        XCTAssertEqual(visible.receiptFacts?.ownOutcome, .unconfirmed)
        XCTAssertEqual(visible.intentReceipt?.opID, receipt.opID)
        try store.recordAcceptedOperation(receipt.intentID,
                                          operationID: receipt.opID,
                                          terminalSequence: 42,
                                          context: context)
        visible = try XCTUnwrap(port.observe(context: port.context).requests.first)
        XCTAssertEqual(visible.lifecycleStatus, .pending)
        XCTAssertEqual(visible.receiptFacts?.ownOutcome, .accepted)
        XCTAssertEqual(try store.snapshot(context: context).cursor, 1,
                       "An operation receipt at 42 cannot jump the contiguous event cursor from 1.")
        XCTAssertTrue(try store.snapshot(context: context).outbox.isEmpty)

        try store.beginReplay(through: 2, context: context)
        _ = try store.apply(RelayEvent(sequence: 2, body: .terminal(fixture.key, .answered, nil)), context: context)
        XCTAssertEqual(try port.observe(context: port.context).requests.first?.lifecycleStatus, .pending,
                       "The prior coherent view remains published until resync.")
        XCTAssertTrue(try store.serverCacheSnapshot(context: context).intents.isEmpty,
                      "The prior UI receipt cannot return a completed operation to the durable queue.")
        XCTAssertTrue(try store.inboxOperationInventory(context: context).isEmpty)
        XCTAssertThrowsError(try store.queueOriginalOperationForUserTap(receipt.intentID, context: context))
        try store.finishReplay(at: 2, context: context)
        let presented = try XCTUnwrap(port.observe(context: port.context).requests.first)
        XCTAssertEqual(presented.lifecycleStatus, .answered)
        XCTAssertNil(presented.accountAnswerOutcome)
        XCTAssertNil(presented.receiptFacts,
                     "An account terminal without a shared outcome does not expose this device's receipt.")
        XCTAssertNil(presented.intentReceipt)
        guard case let .sender(projection) = presented.projection else { return XCTFail("Expected a sender projection.") }
        XCTAssertEqual(projection.illustrations, document.illustrations)
        XCTAssertEqual(projection.submissionLabel, document.submissionLabel)
        let projectedPoints = resultPointNodes(in: projection.scene)
        XCTAssertTrue(projectedPoints.isEmpty,
                      "A device-local accepted answer is not shown as the shared account outcome.")
        XCTAssertEqual(try store.snapshot(context: context).cursor, 2)
    }

    func testPortProjectionSeparatesTerminalEvidenceFromSingleStatus() throws {
        let fixtures = try loadFixtures()
        let fixture = try XCTUnwrap(fixtures.requests.first(where: { $0.key.messageID == ExactText("facilities-01") }))
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("fixture-only:test"),
                                       personID: fixtures.accountScope,
                                       deviceID: ExactText("device-a"))
        let context = ProfileContext(identity: identity, transportMode: .fixture)

        for outcome in [OwnOutcome.accepted, .unconfirmed] {
            let persistence = MemoryPendingActionPersistence()
            let store = try makeStore(fixtures: fixtures, context: context, persistence: persistence)
            let port = AttentionDomainPort(store: store)
            let selector = try XCTUnwrap(port.inspect(context: port.context, request: fixture.key).requests.first?.selector)
            guard case let .sender(document) = fixture.interface else { return XCTFail("Expected sender document.") }
            let point = try XCTUnwrap(document.inputs.first(where: { if case .point = $0.kind { return true }; return false }))
            let note = try XCTUnwrap(document.inputs.first(where: { if case .text = $0.kind { return true }; return false }))
            let records: [TypedInputRecord] = [
                .point(input: point.id, point: PointValue(x: 240, y: 610)),
                .text(input: note.id, text: ExactText("A careful note"))
            ]
            let receipt = try port.submit(SubmitIntent(context: port.context, selector: selector, intentID: UUID(), inputs: records))
            let terminal = FixtureTerminal(state: .answered,
                                           evidenceLabel: outcome == .accepted ? "simulated original operation accepted" : "simulated closure without original operation evidence",
                                           authorizedAnswer: outcome == .accepted ? receipt.exactAnswer : nil,
                                           ownOutcome: outcome)
            try store.recordFixtureTerminal(terminal, for: fixture.key, context: context)
            let restartedPort = AttentionDomainPort(store: store)
            let presented = try XCTUnwrap(restartedPort.observe(context: restartedPort.context).requests.first(where: { $0.key == fixture.key }))
            XCTAssertEqual(presented.lifecycleStatus, .answered)
            XCTAssertEqual(presented.receiptFacts?.ownOutcome, outcome)
            XCTAssertEqual(presented.receiptFacts?.originalOperationUncertainty, outcome == .unconfirmed)
            guard case let .sender(projection) = presented.projection else { return XCTFail("Expected a sender visual projection.") }
            let projectedPoints = resultPointNodes(in: projection.scene)
            if outcome == .accepted {
                XCTAssertEqual(projectedPoints.count, 1)
                guard case let .resultPoint(_, _, point) = try XCTUnwrap(projectedPoints.first?.kind) else {
                    return XCTFail("Expected the authorized result point to be projected.")
                }
                XCTAssertEqual(point, PointValue(x: 240, y: 610))
            } else {
                XCTAssertTrue(projectedPoints.isEmpty,
                              "An unconfirmed closure must retain the neutral sender scene without answer points.")
            }
            let reopenedSelector = try XCTUnwrap(restartedPort.inspect(context: restartedPort.context,
                                                                        request: fixture.key).requests.first?.selector)
            XCTAssertThrowsError(try restartedPort.saveDraft(context: restartedPort.context,
                                                             selector: reopenedSelector,
                                                             completeDraft: RequestDraft(interface: fixture.interface)))
        }
    }

    @MainActor
    func testAnsweredAndNoCommentShowTheFormsClosingScene() throws {
        let fixtures = try loadFixtures()
        let fixture = try XCTUnwrap(fixtures.requests.first(where: { $0.key.messageID == ExactText("facilities-01") }))
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("fixture-only:test"),
                                       personID: fixtures.accountScope,
                                       deviceID: ExactText("device-a"))
        let context = ProfileContext(identity: identity, transportMode: .fixture)
        guard case let .sender(document) = fixture.interface else { return XCTFail("Expected sender document.") }
        let point = try XCTUnwrap(document.inputs.first(where: { if case .point = $0.kind { return true }; return false }))
        let note = try XCTUnwrap(document.inputs.first(where: { if case .text = $0.kind { return true }; return false }))

        for (state, status) in [(TerminalState.answered, AppLifecycleStatus.answered), (.noComment, .noComment)] {
            let store = try makeStore(fixtures: fixtures, context: context,
                                      persistence: MemoryPendingActionPersistence())
            let port = AttentionDomainPort(store: store)
            let selector = try XCTUnwrap(port.inspect(context: port.context, request: fixture.key).requests.first?.selector)
            _ = try port.submit(SubmitIntent(context: port.context, selector: selector, intentID: UUID(), inputs: [
                .point(input: point.id, point: PointValue(x: 240, y: 610)),
                .text(input: note.id, text: ExactText("A careful note"))
            ]))
            let pending = try XCTUnwrap(port.observe(context: port.context).requests.first(where: { $0.key == fixture.key }))
            XCTAssertNil(LiveRequestDetail.closingSceneProjection(pending.projection,
                                                                  lifecycleStatus: pending.lifecycleStatus),
                         "A request still waiting for its outcome shows no closing scene.")

            try store.recordFixtureTerminal(FixtureTerminal(state: state,
                                                            evidenceLabel: "simulated closing state",
                                                            authorizedAnswer: nil,
                                                            ownOutcome: .unconfirmed),
                                            for: fixture.key, context: context)
            let presented = try XCTUnwrap(AttentionDomainPort(store: store).observe(context: port.context)
                .requests.first(where: { $0.key == fixture.key }))
            XCTAssertEqual(presented.lifecycleStatus, status)
            let sender = try XCTUnwrap(LiveRequestDetail.closingSceneProjection(presented.projection,
                                                                               lifecycleStatus: presented.lifecycleStatus),
                                       "\(state) shows the form's closing scene beneath its card.")
            // Neither state has its own scene in this form, so both fall back
            // to the declared resolved scene.
            XCTAssertNil(document.resolvedByState[state])
            XCTAssertTrue(sceneTexts(in: sender.scene).contains("Location request closed"),
                          "\(state) uses the form's fallback resolved scene.")
        }
    }

    private func sceneTexts(in node: ProjectedSceneNode) -> [String] {
        switch node.kind {
        case let .text(value, _):
            return [value.rawValue]
        case let .stack(_, children), let .grid(_, children):
            return children.flatMap(sceneTexts(in:))
        case .illustration, .input, .resultPoint:
            return []
        }
    }

    private func resultPointNodes(in node: ProjectedSceneNode) -> [ProjectedSceneNode] {
        switch node.kind {
        case .resultPoint:
            return [node]
        case let .stack(_, children), let .grid(_, children):
            return children.flatMap(resultPointNodes(in:))
        case .text, .illustration, .input:
            return []
        }
    }

    private func makeStore(fixtures: FixtureSet,
                           context: ProfileContext,
                           persistence: any PendingActionPersistence,
                           replacing replacements: [RequestKey: RequestKey] = [:]) throws -> ClientRepository {
        let store = try ClientRepository(context: context, persistence: persistence)
        let requests = fixtures.requests.map { request in
            StoredRequest(key: replacements[request.key] ?? RequestKey(accountScope: context.identity.personID,
                                                                      senderID: request.key.senderID,
                                                                      messageID: request.key.messageID),
                          originalPayload: request.originalPayload)
        }
        if context.transportMode == .relay {
            for (index, request) in requests.enumerated() {
                _ = try store.apply(RelayEvent(sequence: UInt64(index + 1),
                    body: .delivery(request, .message)), context: context)
            }
        } else {
            try store.registerFixtureRequests(requests, context: context)
        }
        return store
    }

    private func loadFixtures() throws -> FixtureSet {
        try FixtureSet.loadBundled(from: Bundle(for: HarklightTests.self))
    }

    @MainActor
    private func apply(state: [JSONMember], to request: FixtureRequest, store: PrototypeStore) throws {
        guard case let .sender(document) = request.interface else {
            throw FixtureVectorError.invalid
        }
        for member in state {
            guard let input = document.input(withID: member.key) else { throw FixtureVectorError.invalid }
            switch input.kind {
            case let .response(actions):
                guard let actionID = member.value.uniqueValue(named: "action")?.stringValue,
                      actions.contains(where: { $0.id == actionID }) else { throw FixtureVectorError.invalid }
                store.selectAction(actionID, inputID: input.id, for: request.key)
                if let text = member.value.uniqueValue(named: "text")?.stringValue {
                    store.updateText(text.rawValue, for: request.key, inputID: input.id, actionID: actionID)
                }
            case .text:
                guard let text = member.value.uniqueValue(named: "text")?.stringValue else { throw FixtureVectorError.invalid }
                store.updateText(text.rawValue, for: request.key, inputID: input.id, actionID: nil)
            case .point:
                guard let rawPoint = member.value.uniqueValue(named: "point"),
                      let x = rawPoint.uniqueValue(named: "x")?.integerValue,
                      let y = rawPoint.uniqueValue(named: "y")?.integerValue else { throw FixtureVectorError.invalid }
                store.setPoint(PointValue(x: x, y: y), for: request.key, inputID: input.id)
            }
        }
    }

    private func number(_ value: JSONValue) throws -> Double {
        guard case let .number(number) = value, let result = Double(number.lexeme) else { throw FixtureVectorError.invalid }
        return result
    }

    private func decimal(_ value: JSONValue) throws -> Double {
        guard let string = value.stringValue, let result = Double(string.rawValue) else { throw FixtureVectorError.invalid }
        return result
    }

    private func collectResultPoints(in node: SceneNode) -> [SceneNode] {
        switch node.kind {
        case .resultPoint:
            return [node]
        case let .stack(_, children), let .grid(_, children):
            return children.flatMap(collectResultPoints(in:))
        case .text, .illustration, .input:
            return []
        }
    }

    private func appendMember(_ object: JSONValue, _ member: JSONMember) -> JSONValue {
        guard case let .object(members) = object else { return object }
        return .object(members + [member])
    }

    private func replacingMember(_ object: JSONValue, key: String, value: JSONValue) -> JSONValue {
        guard case let .object(members) = object else { return object }
        return .object(members.map { $0.key == ExactText(key) ? JSONMember(key: $0.key, value: value) : $0 })
    }

    private func appendingArrayValue(_ array: JSONValue?, _ value: JSONValue) -> JSONValue {
        guard case let .array(values) = array else { return .array([value]) }
        return .array(values + [value])
    }
}

private enum FixtureVectorError: Error {
    case invalid
}
