import AttentionDomain
import Foundation
import HarklightNativeRelay
import Security
import XCTest
@testable import Harklight

@MainActor
final class RealRelayActionEligibilityTests: XCTestCase {
    func testRealRelayConfirmationEnablesCachedSeenAndReply() async throws {
        struct Fixture: Decodable {
            let serverCommit: String
            let relayURL: URL
            let personID: String
            let deviceID: String
            let senderID: String
        }
        let bundle = Bundle(for: Self.self)
        guard let manifest = bundle.url(forResource: "cache-actions-relay", withExtension: "json") else {
            throw XCTSkip("Requires a newly created isolated cache-actions server; a skip is not route-2 evidence.")
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: manifest))
        XCTAssertEqual(fixture.relayURL.host, "localhost")
        let caURL = try XCTUnwrap(bundle.url(forResource: "cache-actions-ca", withExtension: "pem"))
        let identityURL = try XCTUnwrap(bundle.url(forResource: "cache-actions-client", withExtension: "p12"))
        let rootDER = try XCTUnwrap(NativeEnrollmentSettings.certificateDER(
            from: String(contentsOf: caURL, encoding: .utf8)))
        var imported: CFArray?
        XCTAssertEqual(SecPKCS12Import(try Data(contentsOf: identityURL) as CFData,
            [kSecImportExportPassphrase as String: "public-fixture-only"] as CFDictionary, &imported), errSecSuccess)
        let importedIdentity = try XCTUnwrap((imported as? [[String: Any]])?.first?[kSecImportItemIdentity as String])
        let clientIdentity = importedIdentity as! SecIdentity
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("localhost"),
            personID: ExactText(fixture.personID), deviceID: ExactText(fixture.deviceID))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheURL = directory.appendingPathComponent("server-cache.json")
        let journal = NativeClientDiagnosticJournal(fileURL: nil)
        let lifecycle = NativeRelayLifecycle.shared
        await lifecycle.deactivate()
        defer {
            let attachment = XCTAttachment(string: "server=\(fixture.serverCommit)\n" + journal.shareText)
            attachment.name = "Real relay cache confirmation"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        do {
            // First connection obtains the cache from the real server. The second
            // connection restores it into a fresh domain and presentation store.
            for coldLaunch in [false, true] {
                let context = ProfileContext(identity: identity, transportMode: .relay)
                let cache = FileServerStateCache(fileURL: cacheURL)
                let domain = try AttentionDomainStore(context: context,
                    persistence: MemoryAttentionStatePersistence(), persistsOnlyLocalState: true)
                if coldLaunch {
                    let saved = try await cache.load()
                    try domain.restoreCachedServerState(try XCTUnwrap(saved).attentionDomainState(), context: context)
                }
                let live = try LivePresentationStore(store: domain, context: context, diagnostics: journal)
                let seen = RequestKey(accountScope: identity.personID,
                    senderID: ExactText(fixture.senderID), messageID: ExactText("seen"))
                let reply = RequestKey(accountScope: identity.personID,
                    senderID: ExactText(fixture.senderID), messageID: ExactText("reply"))
                if coldLaunch {
                    XCTAssertFalse(live.canSendToCurrentServer)
                    XCTAssertFalse(try XCTUnwrap(live.inboxRows.first { $0.key == seen }).canMarkSeen)
                    XCTAssertFalse(try XCTUnwrap(live.inboxRows.first { $0.key == reply }).canNoComment)
                }
                try await lifecycle.activate(store: domain, context: context, relayURL: fixture.relayURL,
                    clientIdentity: clientIdentity, trustedRootDER: rootDER,
                    diagnostics: journal, serverStateCache: cache)
                live.startObserving()
                defer { live.stopObserving() }
                let namespace = "Harklight.real-cache-actions." + UUID().uuidString
                let launch = NativeAppLaunch(arguments: [],
                    enrollmentStore: NativeEnrollmentStore(service: namespace),
                    joinStore: NativeGuidedJoinStore(namespace: namespace), initialState: .live(live))
                await launch.refreshLive()
                XCTAssertNil(live.connectionWarning, "Real relay confirmation must complete before checking actions.")
                XCTAssertTrue(lifecycle.hasConfirmedServerSnapshot(for: context))
                XCTAssertFalse(live.isRefreshing)
                let deadline = ContinuousClock.now + .seconds(10)
                while live.request(for: seen)?.inboxStateIsCurrent != true ||
                        live.request(for: reply)?.inboxStateIsCurrent != true {
                    guard ContinuousClock.now < deadline else { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertNil(live.observationError)
                let seenRow = try XCTUnwrap(live.inboxRows.first { $0.key == seen })
                let replyRow = try XCTUnwrap(live.inboxRows.first { $0.key == reply })
                XCTAssertTrue(seenRow.canMarkSeen, "Seen must become usable after real confirmation; coldLaunch=\(coldLaunch)")
                XCTAssertTrue(replyRow.canNoComment, "No comment must become usable after real confirmation; coldLaunch=\(coldLaunch)")
                let request = try XCTUnwrap(live.request(for: reply))
                let editor = live.replyEditorSession(for: request)
                editor.selectAction(ExactText("reply"), inputID: nil)
                editor.updateText("Synthetic route two reply", target: ReplyEditorTarget(inputID: nil, actionID: "reply"))
                XCTAssertTrue(editor.canSubmitFromSnapshot)
                XCTAssertTrue(live.canSendToCurrentServer)
                XCTAssertTrue(LiveRequestDetail(request: request, store: live).canSubmitCurrentAnswer)
                if coldLaunch {
                    let seenRequest = try XCTUnwrap(live.request(for: seen))
                    XCTAssertTrue(live.submitFromUser(seen, explicitCompatibilityAction: ExactText("seen"),
                        requestRevision: seenRequest.requestRevision))
                    let seenDeadline = ContinuousClock.now + .seconds(15)
                    while live.request(for: seen)?.informationalSeenStatus != .confirmed,
                          ContinuousClock.now < seenDeadline {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    XCTAssertEqual(live.request(for: seen)?.informationalSeenStatus, .confirmed,
                        "A real accepted Seen response must become confirmed.")
                    XCTAssertTrue(live.submitFromUser(reply, answerDraft: editor.draft,
                        requestRevision: editor.requestRevision))
                    let replyDeadline = ContinuousClock.now + .seconds(15)
                    while live.request(for: reply)?.lifecycleStatus != .answered,
                          ContinuousClock.now < replyDeadline {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    XCTAssertEqual(live.request(for: reply)?.lifecycleStatus, .answered,
                        "A real accepted reply must become answered.")
                }
                live.stopObserving()
                await lifecycle.deactivate()
            }
        } catch {
            await lifecycle.deactivate()
            throw error
        }
    }
}
