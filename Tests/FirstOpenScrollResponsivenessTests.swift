import AttentionDomain
import Foundation
import XCTest
@testable import Harklight

private final class DelayedUserDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var nextWriteDelay: TimeInterval?
    private var writeCount = 0
    private var delayedWriteWasOnMainThread: Bool?

    override func data(forKey defaultName: String) -> Data? {
        lock.withLock { values[defaultName] }
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        let delay = lock.withLock {
            let delay = nextWriteDelay
            nextWriteDelay = nil
            if delay != nil { delayedWriteWasOnMainThread = Thread.isMainThread }
            return delay
        }
        if let delay { Thread.sleep(forTimeInterval: delay) }
        lock.withLock {
            values[defaultName] = value as? Data
            writeCount += 1
        }
    }

    func delayNextWrite(by interval: TimeInterval) {
        lock.withLock { nextWriteDelay = interval }
    }

    var writes: Int { lock.withLock { writeCount } }
    var delayedWriteThreadWasMain: Bool? { lock.withLock { delayedWriteWasOnMainThread } }
}

private final class DelayedAttentionPersistence: PendingActionPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var nextWriteDelay: TimeInterval?
    private var writeCount = 0
    private var delayedWriteWasOnMainThread: Bool?
    private var delayedWriteDidStart = false

    func load(identity: ProfileIdentity) throws -> Data? { lock.withLock { data } }

    func commit(_ data: Data, identity: ProfileIdentity) throws {
        let delay = lock.withLock {
            let delay = nextWriteDelay
            nextWriteDelay = nil
            if delay != nil {
                delayedWriteWasOnMainThread = Thread.isMainThread
                delayedWriteDidStart = true
            }
            return delay
        }
        if let delay { Thread.sleep(forTimeInterval: delay) }
        lock.withLock {
            self.data = data
            writeCount += 1
        }
    }

    func delayNextWrite(by interval: TimeInterval) {
        lock.withLock {
            nextWriteDelay = interval
            delayedWriteDidStart = false
        }
    }

    var writes: Int { lock.withLock { writeCount } }
    var delayedWriteThreadWasMain: Bool? { lock.withLock { delayedWriteWasOnMainThread } }
    var hasDelayedWriteStarted: Bool { lock.withLock { delayedWriteDidStart } }
}

@MainActor
final class FirstOpenScrollResponsivenessTests: XCTestCase {
    private let persistenceDelay: TimeInterval = 0.5

    func testDetailReadPersistenceDoesNotBlockTheMainActor() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .fixture)
        let persistence = DelayedAttentionPersistence()
        let domain = try ClientRepository(context: context, persistence: persistence)
        let request = RequestKey(accountScope: identity.personID,
            senderID: ExactText("sender"), messageID: ExactText("request"))
        let binding = ConversationBinding(request: request, revision: 1)
        let session = ExactText("session")
        let question = ConversationTurn(id: ExactText("question"), binding: binding,
            author: .person, sessionHandle: session, text: ExactText("Question"), kind: .discussion)
        let reply = ConversationTurn(id: ExactText("reply"), binding: binding,
            author: .origin, sessionHandle: session, text: ExactText("Reply"),
            inReplyTo: question.id, kind: .reply)
        try domain.applyConversation(ConversationEvent(sequence: 1, binding: binding,
            fact: .request(sessionHandle: session, payload: .null)), context: context)
        try domain.applyConversation(ConversationEvent(sequence: 2, binding: binding,
            fact: .turn(question)), context: context)
        try domain.applyConversation(ConversationEvent(sequence: 3, binding: binding,
            fact: .turn(reply)), context: context)
        try domain.finishConversationReplay(at: 3, chatReadPositions: [], context: context)
        let store = try LivePresentationStore(localFixtureStore: domain, context: context)

        let writesBefore = persistence.writes
        persistence.delayNextWrite(by: persistenceDelay)
        let mainActorDelay = await measureMainActorDelay {
            store.markConversationRead(request, through: reply.id)
        }
        await waitForWriteCount(persistence, atLeast: writesBefore + 1)
        try store.refreshFromDurableStore()
        XCTAssertFalse(store.hasUnreadAgentReply(request),
                       "A local example records a shown reply as read at once.")

        XCTAssertLessThan(mainActorDelay, persistenceDelay * 1_000 * 0.5,
                          "Opening a visible reply must not hold the detail scroll's main actor.")
        XCTAssertEqual(persistence.delayedWriteThreadWasMain, false,
                       "The attention plist encoding and persistence belong off main.")
        print(String(format: "detail persistence main-actor block: %.3f ms (controlled write delay: %.0f ms; writer on main: %@)",
                     mainActorDelay, persistenceDelay * 1000,
                     String(describing: persistence.delayedWriteThreadWasMain)))
    }

    func testConversationCatchUpPersistenceDoesNotBlockDetailAdoption() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let persistence = DelayedAttentionPersistence()
        let domain = try ClientRepository(context: context, persistence: persistence)
        let request = RequestKey(accountScope: identity.personID,
            senderID: ExactText("sender"), messageID: ExactText("request"))
        let payload = try JSONValue.parse(Data(#"{"title":"Conversation"}"#.utf8))
        try domain.apply(RelayEvent(sequence: 1, body: .delivery(
            StoredRequest(key: request, originalPayload: payload), .message)), context: context)
        let binding = ConversationBinding(request: request, revision: 1)
        let session = ExactText("session")
        let question = ConversationTurn(id: ExactText("question"), binding: binding,
            author: .person, sessionHandle: session, text: ExactText("Question"), kind: .discussion)
        try domain.applyConversation(ConversationEvent(sequence: 1, binding: binding,
            fact: .request(sessionHandle: session, payload: payload)), context: context)
        try domain.applyConversation(ConversationEvent(sequence: 2, binding: binding,
            fact: .turn(question)), context: context)
        let presentation = try LivePresentationStore(store: domain, context: context,
            replyItemAreaDefaults: DelayedUserDefaults())
        let reply = ConversationTurn(id: ExactText("reply"), binding: binding,
            author: .origin, sessionHandle: session, text: ExactText("Reply"),
            inReplyTo: question.id, kind: .reply)

        persistence.delayNextWrite(by: persistenceDelay)
        let catchUp = Task.detached {
            try domain.applyConversation(ConversationEvent(sequence: 3, binding: binding,
                fact: .turn(reply)), context: context)
        }
        await waitUntil { persistence.hasDelayedWriteStarted }
        let mainActorDelay = await measureMainActorDelay {
            try? presentation.refreshFromDurableStore()
        }
        try await catchUp.value
        try presentation.refreshFromDurableStore()

        XCTAssertLessThan(mainActorDelay, persistenceDelay * 1_000 * 0.5,
                          "Detail adoption must read the committed snapshot while catch-up persists.")
        XCTAssertEqual(persistence.delayedWriteThreadWasMain, false,
                       "Conversation catch-up persistence must run away from the detail's main actor.")
        XCTAssertTrue(presentation.hasUnreadAgentReply(request))
        print(String(format: "conversation catch-up adoption main-actor block: %.3f ms (controlled plist delay: %.0f ms; writer on main: %@)",
                     mainActorDelay, persistenceDelay * 1000,
                     String(describing: persistence.delayedWriteThreadWasMain)))
    }

    func testFirstOpenConversationAdoptionWithGrowingHistoryStaysWithinScrollBudget() async throws {
        let scrollBudgetMilliseconds = 16.7
        let payload = try JSONValue.parse(Data(#"{"title":"Backlog conversation"}"#.utf8))

        for count in [64, 256, 512] {
            let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                personID: ExactText("person-\(count)"), deviceID: ExactText("device"))
            let context = ProfileContext(identity: identity, transportMode: .relay)
            let persistence = DelayedAttentionPersistence()
            let domain = try ClientRepository(context: context, persistence: persistence)
            let request = RequestKey(accountScope: identity.personID,
                senderID: ExactText("sender"), messageID: ExactText("request"))
            let binding = ConversationBinding(request: request, revision: 1)
            let session = ExactText("session")
            let delivery = RelayEvent(sequence: 1, body: .delivery(
                StoredRequest(key: request, originalPayload: payload), .message))
            let question = ConversationTurn(id: ExactText("question"), binding: binding,
                author: .person, sessionHandle: session, text: ExactText("Question"),
                kind: .discussion)

            let history = Task.detached {
                try domain.apply(delivery, context: context)
                try domain.applyConversation(ConversationEvent(sequence: 1, binding: binding,
                    fact: .request(sessionHandle: session, payload: payload)), context: context)
                try domain.applyConversation(ConversationEvent(sequence: 2, binding: binding,
                    fact: .turn(question)), context: context)
                for index in 1...count {
                    let reply = ConversationTurn(id: ExactText("reply-\(index)"), binding: binding,
                        author: .origin, sessionHandle: session, text: ExactText("Reply \(index)"),
                        inReplyTo: question.id, kind: .reply)
                    try domain.applyConversation(ConversationEvent(sequence: UInt64(index + 2),
                        binding: binding, fact: .turn(reply)), context: context)
                }
            }
            try await history.value

            let port = AttentionDomainPort(store: domain)
            let defaults = DelayedUserDefaults()
            let diagnostics = NativeClientDiagnosticJournal(fileURL: nil)
            let activation = try await LivePresentationStore.makeForActivation(
                store: domain, context: context, diagnostics: diagnostics,
                replyItemAreaDefaults: defaults)
            let model = activation.presentation
            let initialAdoption = activation.mainActorWorkMilliseconds
            let initialPreparationWall = activation.activationPreparationMilliseconds

            var revisionWaits: [Double] = []
            var revisionPreparationTimes: [Double] = []
            for offset in 1...16 {
                let reply = ConversationTurn(id: ExactText("catch-up-reply-\(offset)"),
                    binding: binding, author: .origin, sessionHandle: session,
                    text: ExactText("Catch-up reply \(offset)"), inReplyTo: question.id,
                    kind: .reply)
                let sequence = UInt64(count + offset + 2)
                let revision = Task.detached {
                    try domain.applyConversation(ConversationEvent(sequence: sequence,
                        binding: binding, fact: .turn(reply)), context: context)
                }
                try await revision.value
                let snapshot = try await Task.detached {
                    try port.observe(context: port.context)
                }.value
                let startedAt = DispatchTime.now().uptimeNanoseconds
                revisionWaits.append(try await model.adoptForLiveUpdates(snapshot))
                revisionPreparationTimes.append(
                    Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
            }

            let maximumRevisionWait = try XCTUnwrap(revisionWaits.max())
            XCTAssertLessThan(initialAdoption, scrollBudgetMilliseconds,
                              "Initial detail adoption with \(count) retained replies must fit a 60 Hz frame.")
            XCTAssertLessThan(maximumRevisionWait, scrollBudgetMilliseconds,
                              "Catch-up adoption with \(count + 16) replies must fit a 60 Hz frame.")
            XCTAssertEqual(model.replyItemAreaStore?.ledger.entriesByParent[request]?.unseenReplies.count,
                           16, "Catch-up replies must retain their existing unread behavior.")
            print(String(format: "conversation adoption history %d: initial MainActor %.3f ms / prep %.3f ms; max catch-up MainActor %.3f ms / prep %.3f ms",
                         count, initialAdoption, initialPreparationWall, maximumRevisionWait,
                         try XCTUnwrap(revisionPreparationTimes.max())))
        }
    }

    func testInboxReplyArrivalPersistenceDoesNotBlockTheMainActor() async throws {
        let defaults = DelayedUserDefaults()
        let key = "first-open-replies-\(UUID().uuidString)"
        let store = ReplyItemAreaStore(defaults: defaults, defaultsKey: key)
        let account = ExactText("account")
        store.reconcile([], accountScopes: [account])
        await waitForReplyLedger(defaults, key: key, entryCount: 0)

        let parent = RequestKey(accountScope: account,
            senderID: ExactText("sender"), messageID: ExactText("request"))
        let arrival = ReplyItemObservation(parent: parent, turnID: ExactText("reply"),
            conversationSequence: 1, isSeen: false, text: "Reply")
        let writesBefore = defaults.writes
        defaults.delayNextWrite(by: persistenceDelay)
        let mainActorDelay = await measureMainActorDelay {
            store.reconcile([arrival])
        }
        await waitForWriteCount(defaults, atLeast: writesBefore + 1)
        await waitForReplyLedger(defaults, key: key, entryCount: 1)

        XCTAssertLessThan(mainActorDelay, persistenceDelay * 1_000 * 0.5,
                          "Reply-arrival persistence must not hold the list's main actor.")
        XCTAssertEqual(defaults.delayedWriteThreadWasMain, false,
                       "Reply ledger encoding and UserDefaults writes belong off main.")
        print(String(format: "list reply persistence main-actor block: %.3f ms (controlled write delay: %.0f ms; writer on main: %@)",
                     mainActorDelay, persistenceDelay * 1000,
                     String(describing: defaults.delayedWriteThreadWasMain)))
    }

    private func measureMainActorDelay(_ operation: () -> Void) async -> Double {
        let marker = Task { @MainActor in DispatchTime.now().uptimeNanoseconds }
        let startedAt = DispatchTime.now().uptimeNanoseconds
        operation()
        let markerAt = await marker.value
        return Double(markerAt - startedAt) / 1_000_000
    }

    private func waitForWriteCount(_ defaults: DelayedUserDefaults, atLeast count: Int) async {
        await waitUntil { defaults.writes >= count }
    }

    private func waitForWriteCount(_ persistence: DelayedAttentionPersistence, atLeast count: Int) async {
        await waitUntil { persistence.writes >= count }
    }

    private func waitForReplyLedger(_ defaults: DelayedUserDefaults, key: String,
                                   entryCount: Int) async {
        await waitUntil {
            guard let data = defaults.data(forKey: key),
                  let ledger = try? JSONDecoder().decode(ReplyItemLedger.self, from: data) else {
                return false
            }
            return ledger.entriesByParent.count == entryCount
        }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for the background persistence result.")
    }
}
