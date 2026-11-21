import AttentionDomain
import Foundation
import HarklightNativeRelay
import Security
import XCTest
@testable import Harklight

final class V2RevocationRecoveryTests: XCTestCase {
    @MainActor
    func testRevocationKeepsQueuedTextAndFlushedDraftBeforeAndAfterReenrolment() async throws {
        let namespace = "v2-revocation-test-" + UUID().uuidString
        let enrollment = NativeEnrollmentStore(service: namespace)
        let join = NativeGuidedJoinStore(namespace: namespace)
        let record = NativeEnrollmentRecord(host: "relay.example", enrollmentPort: 18444, relayPort: 18443,
            trustedRootDER: Data([1]), identityLabel: "test", deviceID: UUID().uuidString,
            approvalCode: "TEST", statusSecret: "test", expiresAt: nil, statusExpiresAt: nil, personID: "person")
        let keychainKey: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                         kSecAttrService as String: namespace]
        defer { _ = SecItemDelete(keychainKey as CFDictionary) }
        var entry = keychainKey
        entry[kSecAttrAccount as String] = "current-installation"
        entry[kSecValueData as String] = try JSONEncoder().encode(record)
        XCTAssertEqual(SecItemAdd(entry as CFDictionary, nil), errSecSuccess)

        let identity = ProfileIdentity(trustedRelayAuthority: ExactText(record.profileAuthority),
                                       personID: ExactText("person"), deviceID: ExactText(record.deviceID))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let persistence = MemoryPendingActionPersistence()
        let store = try ClientRepository(context: context, persistence: persistence)
        let model = ServerModelV2Store(fileURL: nil)
        let item = #"{"item_id":"item","rev":1,"sender":"sender","request_revision":1,"message":{"title":"Question","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"reply","label":"Reply","kind":"text"}]}},"files":[],"seen":false,"rank":{"key":"a","section":"current"},"chat":{"available":true,"started":true}}"#
        try model.apply([ServerModelV2Store.Change(rev: 1, kind: "item", data: Data(item.utf8))], cursor: 1)
        try store.restoreCachedServerState(ServerModelV2Projection.cachedState(model.snapshot, identity: identity),
                                           context: context)
        let key = RequestKey(accountScope: identity.personID, senderID: ExactText("sender"), messageID: ExactText("item"))
        let binding = ConversationBinding(request: key, revision: 1)
        try store.saveConversationDraft(ConversationDraft(binding: binding, text: ExactText("Queued chat")), context: context)
        _ = try store.queueChatMessage(binding, context: context)
        let live = try LivePresentationStore(store: store, context: context)
        live.updateCompatibilityText("Still typing", action: ExactText("reply"), for: key, requestRevision: 1)
        XCTAssertEqual(try store.unsentText(context: context), [ExactText("Queued chat")])

        let launch = NativeAppLaunch(arguments: [], enrollmentStore: enrollment, joinStore: join,
            initialState: .live(live), initialEnrollmentRecord: record, archivedPersistence: { persistence })
        launch.applyV2AccountAccess(.revoked, for: context)
        XCTAssertTrue(live.isReadOnly)
        let text = [ExactText("Queued chat"), ExactText("Still typing")]
        XCTAssertEqual(launch.revokedRecoveryText, text)
        XCTAssertEqual(try store.unsentText(context: context), text, "The staged draft was flushed before leaving the view.")
        let firstArchive = try XCTUnwrap(join.archivedDepartures().first)
        XCTAssertEqual(try launch.recoveredUnsentText(for: firstArchive), text)

        XCTAssertTrue(launch.beginV2Reenrolment())
        XCTAssertNil(try enrollment.load())
        let archive = try XCTUnwrap(launch.revokedRecoveryArchives.first)
        XCTAssertEqual(try launch.recoveredUnsentText(for: archive), text)
        XCTAssertEqual(launch.guidedJoin.screen, .welcome)

        // Reopening while approval is pending reloads the same read-only
        // destination from the archive catalog, without an active account.
        var pending = record
        pending.personID = nil
        pending.v2Revoked = nil
        let relaunched = NativeAppLaunch(arguments: [], enrollmentStore: enrollment, joinStore: join,
            initialState: .enrollmentPending(pending), archivedPersistence: { persistence })
        await relaunched.restoreInstallation()
        guard case .enrollmentPending = relaunched.state else { return XCTFail("Expected pending enrollment.") }
        let recovered = try XCTUnwrap(relaunched.revokedRecoveryArchives.first)
        XCTAssertEqual(recovered.archiveID, archive.archiveID)
        XCTAssertEqual(try relaunched.recoveredUnsentText(for: recovered), text)
        let replacement = ProfileIdentity(trustedRelayAuthority: identity.trustedRelayAuthority,
            personID: identity.personID, deviceID: ExactText("replacement-device"))
        let replacementContext = ProfileContext(identity: replacement, transportMode: .relay)
        let replacementStore = try ClientRepository(context: replacementContext, persistence: persistence)
        XCTAssertEqual(try replacementStore.unsentText(context: replacementContext), [])
    }
}
