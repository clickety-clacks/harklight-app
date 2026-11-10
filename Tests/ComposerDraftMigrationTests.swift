import Foundation
import XCTest
@testable import AttentionDomain
@testable import Harklight

@MainActor
final class ComposerDraftMigrationTests: XCTestCase {
    func testLegacyMigrationPersistsArchivedAnswersAndEveryChatRecoveryEntry() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("migration-person"), deviceID: ExactText("migration-device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let key = RequestKey(accountScope: identity.personID,
            senderID: ExactText("sender"), messageID: ExactText("migration-request"))
        let revisionOne = try JSONValue.parse(Data(#"{"title":"First wording","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"old-choice","label":"Old choice","kind":"text"}]}}"#.utf8))
        let revisionTwo = try JSONValue.parse(Data(#"{"title":"Second wording","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"middle-choice","label":"Middle choice","kind":"text"}]}}"#.utf8))
        let revisionThree = try JSONValue.parse(Data(#"{"title":"Current wording","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"current-choice","label":"Current choice","kind":"text"}]}}"#.utf8))

        let refusedOperation = UUID()
        let uncertainOperation = UUID()
        let refused = CarriedOverConversationSend(id: "refused-v1",
            requestRevision: 1, text: ExactText("Refused chat from version one"),
            operationID: refusedOperation, failureOperationID: refusedOperation,
            currentAttemptUnsettled: false,
            failure: ComposerSendFailure(outcome: .notSent,
                summary: "The message was not sent.", detail: "Correlated refusal."))
        let uncertain = CarriedOverConversationSend(id: "uncertain-v2",
            requestRevision: 2, text: ExactText("Uncertain chat from version two"),
            operationID: uncertainOperation, failureOperationID: uncertainOperation,
            currentAttemptUnsettled: true,
            failure: ComposerSendFailure(outcome: .unconfirmed,
                summary: "This message may not have gone through.", detail: "No correlated reply."))
        let uploadedFile = ConversationFile(id: ExactText("file-1"),
            name: ExactText("plan.pdf"), byteCount: 42,
            sha256: ExactText(String(repeating: "a", count: 64)),
            content: .uploaded(ExactText("uploaded-file-1")))

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComposerDraftMigration-\(UUID().uuidString)", isDirectory: true)
        let legacyRoot = root.appendingPathComponent("legacy", isDirectory: true)
        let draftRoot = root.appendingPathComponent("drafts", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacyPersistence = FileAttentionStatePersistence(directoryURL: legacyRoot)
        let legacyStore = try AttentionDomainStore(context: context, persistence: legacyPersistence)
        try await legacyStore.apply(RelayEvent(sequence: 1, body: .delivery(
            StoredRequest(key: key, originalPayload: revisionOne), .message)), context: context)

        let conversationRevisions = [(UInt64(1), revisionOne),
                                     (UInt64(2), revisionTwo),
                                     (UInt64(3), revisionThree)]
        for (sequence, payload) in conversationRevisions {
            try await legacyStore.applyConversation(ConversationEvent(sequence: sequence,
                binding: ConversationBinding(request: key, revision: sequence),
                fact: .request(sessionHandle: ExactText("session"), payload: payload)),
                context: context)
        }

        let oldAnswerID = ExactText("old-choice")
        let middleAnswerID = ExactText("middle-choice")
        let oldAnswerDraft = RequestDraft(inputs: [:], compatibility: CompatibilityDraft(
            selectedActionID: oldAnswerID,
            textByActionID: [oldAnswerID: ExactText("Archived answer from version one")]))
        let middleAnswerDraft = RequestDraft(inputs: [:], compatibility: CompatibilityDraft(
            selectedActionID: middleAnswerID,
            textByActionID: [middleAnswerID: ExactText("Current answer from version two")]))

        // Recreate the earlier build's revision-keyed chat drafts in its
        // persisted profile. The current store normally advances one composer
        // draft across revisions, so using its save API cannot model that old
        // on-disk shape.
        let oldRevisionOneDraft = ConversationDraft(
            binding: ConversationBinding(request: key, revision: 1),
            text: ExactText("Unsent chat draft from version one"), files: [uploadedFile],
            draftRequestRevision: 1, carriedOverSends: [refused])
        let oldRevisionTwoDraft = ConversationDraft(
            binding: ConversationBinding(request: key, revision: 2),
            text: ExactText("Newest typed chat draft"), draftRequestRevision: 2,
            carriedOverSends: [uncertain])
        let oldRevisionThreeDraft = ConversationDraft(
            binding: ConversationBinding(request: key, revision: 3))
        let legacyState = try XCTUnwrap(legacyPersistence.load(identity: identity))
        var legacyProfile = try XCTUnwrap(JSONSerialization.jsonObject(with: legacyState) as? [String: Any])
        let encodedConversation = try XCTUnwrap(legacyProfile["conversation"])
        let conversationData = try JSONSerialization.data(withJSONObject: encodedConversation)
        var archivedConversation = try JSONDecoder().decode(ConversationState.self, from: conversationData)
        var archivedThread = try XCTUnwrap(archivedConversation.threads[key])
        archivedThread.drafts = [1: oldRevisionOneDraft, 2: oldRevisionTwoDraft,
                                 3: oldRevisionThreeDraft]
        archivedThread.answerDrafts = [1: oldAnswerDraft, 2: middleAnswerDraft]
        archivedConversation.threads[key] = archivedThread
        let updatedConversation = try JSONEncoder().encode(archivedConversation)
        legacyProfile["conversation"] = try JSONSerialization.jsonObject(with: updatedConversation)
        try legacyPersistence.commit(try JSONSerialization.data(withJSONObject: legacyProfile),
                                     identity: identity)

        let files = try ConversationFileStorage(identity: identity,
            root: root.appendingPathComponent("conversation-files", isDirectory: true))
        let persistence = ComposerDraftPersistence(rootDirectory: draftRoot,
            legacyAttentionDirectoryURL: legacyRoot)
        await persistence.beginLegacyAttentionMigration(context: context, conversationFiles: files)

        let chatAddress = ComposerDraftAddress(identity: identity, request: key,
            revision: 3, kind: .conversation)
        let answerAddress = ComposerDraftAddress(identity: identity, request: key,
            revision: 3, kind: .answer)
        let migratedChat = try await persistence.load(ConversationDraft.self, at: chatAddress)
        let migratedAnswer = try await persistence.load(AnswerComposerDraft.self, at: answerAddress)

        XCTAssertEqual(migratedChat?.text, ExactText("Newest typed chat draft"))
        XCTAssertEqual(migratedChat?.draftRequestRevision, 2)
        XCTAssertEqual(migratedChat?.files, [])
        XCTAssertEqual(migratedChat?.carriedOverSends.count, 2)
        let migratedRefused = try XCTUnwrap(migratedChat?.carriedOverSends.first { $0.id == refused.id })
        XCTAssertEqual(migratedRefused.requestRevision, 1)
        XCTAssertEqual(migratedRefused.text, refused.text)
        XCTAssertEqual(migratedRefused.operationID, refusedOperation)
        XCTAssertEqual(migratedRefused.failureOperationID, refusedOperation)
        XCTAssertFalse(migratedRefused.currentAttemptUnsettled)
        XCTAssertEqual(migratedRefused.failure.outcome, .notSent)
        let migratedUncertain = try XCTUnwrap(migratedChat?.carriedOverSends.first { $0.id == uncertain.id })
        XCTAssertEqual(migratedUncertain.requestRevision, 2)
        XCTAssertEqual(migratedUncertain.text, uncertain.text)
        XCTAssertEqual(migratedUncertain.operationID, uncertainOperation)
        XCTAssertTrue(migratedUncertain.currentAttemptUnsettled)
        XCTAssertEqual(migratedUncertain.failure.outcome, .unconfirmed)
        let earlierTypedChat = try XCTUnwrap(migratedChat?.earlierEntries.first {
            $0.kind == .conversation && $0.requestRevision == 1
        })
        XCTAssertEqual(earlierTypedChat.text, ExactText("Unsent chat draft from version one"))
        XCTAssertEqual(earlierTypedChat.files, [uploadedFile],
                       "An earlier chat draft retains its uploaded attachment identity.")

        XCTAssertEqual(migratedAnswer?.contentRequestRevision, 2)
        XCTAssertEqual(migratedAnswer?.content.compatibility.textByActionID[middleAnswerID],
                       ExactText("Current answer from version two"))
        XCTAssertEqual(migratedAnswer?.selectedChoices.first?.choiceID, middleAnswerID)
        XCTAssertEqual(migratedAnswer?.selectedChoices.first?.requestRevision, 2)
        let archivedAnswer = try XCTUnwrap(migratedAnswer?.earlierEntries.first {
            $0.kind == .answer && $0.requestRevision == 1
        })
        XCTAssertEqual(archivedAnswer.answerDraft?.compatibility.textByActionID[oldAnswerID],
                       ExactText("Archived answer from version one"))
        XCTAssertTrue(archivedAnswer.text.rawValue.contains("Old choice"))
        XCTAssertEqual(archivedAnswer.answerChoices.first?.choiceID, oldAnswerID)
        XCTAssertEqual(archivedAnswer.answerChoices.first?.requestRevision, 1)

        XCTAssertNil(try legacyPersistence.load(identity: identity),
                     "The old store is removed after every migrated composer entry is durably read back.")
        let reopened = ComposerDraftPersistence(rootDirectory: draftRoot)
        let reopenedChat = try await reopened.load(ConversationDraft.self, at: chatAddress)
        let reopenedAnswer = try await reopened.load(AnswerComposerDraft.self, at: answerAddress)
        XCTAssertEqual(reopenedChat, migratedChat)
        XCTAssertEqual(reopenedAnswer, migratedAnswer)
    }

    func testLegacyProfileRemainsWhenComposerDraftMigrationCannotPersist() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("migration-failure-person"), deviceID: ExactText("migration-failure-device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let key = RequestKey(accountScope: identity.personID,
            senderID: ExactText("sender"), messageID: ExactText("migration-failure-request"))
        let payload = try JSONValue.parse(Data(#"{"title":"Draft request"}"#.utf8))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComposerDraftMigrationFailure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacyRoot = root.appendingPathComponent("legacy", isDirectory: true)
        let legacyPersistence = FileAttentionStatePersistence(directoryURL: legacyRoot)
        let legacyStore = try AttentionDomainStore(context: context, persistence: legacyPersistence)
        try await legacyStore.apply(RelayEvent(sequence: 1, body: .delivery(
            StoredRequest(key: key, originalPayload: payload), .message)), context: context)
        let binding = ConversationBinding(request: key, revision: 1)
        try await legacyStore.applyConversation(ConversationEvent(sequence: 1, binding: binding,
            fact: .request(sessionHandle: ExactText("session"), payload: payload)), context: context)
        try await legacyStore.saveConversationDraft(ConversationDraft(binding: binding,
            text: ExactText("Keep this draft if import fails.")), context: context)
        let originalLegacyProfile = try XCTUnwrap(legacyPersistence.load(identity: identity))

        let blockedDraftRoot = root.appendingPathComponent("not-a-directory")
        try Data("occupied by a file".utf8).write(to: blockedDraftRoot)
        let composerPersistence = ComposerDraftPersistence(rootDirectory: blockedDraftRoot,
            legacyAttentionDirectoryURL: legacyRoot)
        let files = try ConversationFileStorage(identity: identity,
            root: root.appendingPathComponent("conversation-files", isDirectory: true))
        await composerPersistence.beginLegacyAttentionMigration(context: context,
            conversationFiles: files)

        let migrationFailure = await composerPersistence.legacyAttentionMigrationFailure()
        XCTAssertNotNil(migrationFailure,
                        "A failed destination write is surfaced as a migration failure.")
        XCTAssertEqual(try legacyPersistence.load(identity: identity), originalLegacyProfile,
                       "The old source profile remains byte-for-byte intact until every entry persists.")
    }

    func testRetryAndCorrelatedSettlementAffectOnlyTheSelectedCarriedSend() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("retry-person"), deviceID: ExactText("retry-device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let key = RequestKey(accountScope: identity.personID,
            senderID: ExactText("sender"), messageID: ExactText("retry-request"))
        let payload = try JSONValue.parse(Data(#"{"title":"Chat request"}"#.utf8))
        let persistence = MemoryAttentionStatePersistence()
        let store = try AttentionDomainStore(context: context, persistence: persistence)
        try await store.apply(RelayEvent(sequence: 1, body: .delivery(
            StoredRequest(key: key, originalPayload: payload), .message)), context: context)
        let binding = ConversationBinding(request: key, revision: 1)
        try await store.applyConversation(ConversationEvent(sequence: 1, binding: binding,
            fact: .request(sessionHandle: ExactText("session"), payload: payload)), context: context)

        let acceptedOperation = UUID()
        let conflictOperation = UUID()
        let acceptedSend = CarriedOverConversationSend(id: "accepted-entry",
            requestRevision: 1, text: ExactText("Retry this older message"),
            operationID: acceptedOperation, failureOperationID: acceptedOperation,
            currentAttemptUnsettled: true,
            failure: ComposerSendFailure(outcome: .unconfirmed,
                summary: "This message may not have gone through.", detail: "Original attempt."))
        let conflictSend = CarriedOverConversationSend(id: "conflict-entry",
            requestRevision: 1, text: ExactText("Keep this separate message"),
            operationID: conflictOperation, failureOperationID: conflictOperation,
            currentAttemptUnsettled: false,
            failure: ComposerSendFailure(outcome: .notSent,
                summary: "The message was not sent.", detail: "Original refusal."))
        try await store.saveConversationDraft(ConversationDraft(binding: binding,
            text: ExactText("Newest composer text"), carriedOverSends: [acceptedSend, conflictSend]),
            context: context)

        let beforeRetry = try await store.currentConversationSnapshot(context: context)
        let threadBeforeRetry = try XCTUnwrap(beforeRetry.threads[key])
        XCTAssertEqual(threadBeforeRetry.currentRevision, binding.revision)
        XCTAssertTrue(threadBeforeRetry.allowsDiscussion)
        let draftBeforeRetry = try XCTUnwrap(threadBeforeRetry.drafts[binding.revision])
        XCTAssertEqual(draftBeforeRetry.binding, binding)
        XCTAssertEqual(draftBeforeRetry.carriedOverSends.map(\.id).sorted(),
                       [acceptedSend.id, conflictSend.id].sorted(),
                       "Both separately retryable sends must be stored before a Retry begins.")

        let retryID = try await store.prepareCarriedOverDiscussion(binding,
            entryID: acceptedSend.id, context: context)
        XCTAssertEqual(retryID, acceptedOperation,
                       "A manual Retry reuses the selected send's original operation id.")
        try await store.markCarriedOverDiscussionTransmissionStarting(binding,
            entryID: acceptedSend.id, operation: retryID, context: context)
        try await store.markCarriedOverDiscussionAccepted(binding,
            entryID: acceptedSend.id, operation: retryID,
            turn: ExactText("accepted-turn"), context: context)

        var saved = try await store.currentConversationSnapshot(context: context)
            .threads[key]?.drafts[1]
        XCTAssertEqual(saved?.text, ExactText("Newest composer text"))
        XCTAssertNil(saved?.carriedOverSends.first { $0.id == acceptedSend.id },
                     "Correlated acceptance settles only the selected carried send.")
        XCTAssertEqual(saved?.carriedOverSends.first { $0.id == conflictSend.id }, conflictSend)

        let conflictRetryID = try await store.prepareCarriedOverDiscussion(binding,
            entryID: conflictSend.id, context: context)
        XCTAssertEqual(conflictRetryID, conflictOperation)
        try await store.markCarriedOverDiscussionConflict(binding,
            entryID: conflictSend.id, operation: conflictRetryID, context: context)
        saved = try await store.currentConversationSnapshot(context: context)
            .threads[key]?.drafts[1]
        let conflicted = try XCTUnwrap(saved?.carriedOverSends.first { $0.id == conflictSend.id })
        XCTAssertEqual(conflicted.failureOperationID, conflictOperation)
        XCTAssertNotEqual(conflicted.operationID, conflictOperation,
                          "Only a correlated operation_conflict permits a new operation id.")
        XCTAssertFalse(conflicted.currentAttemptUnsettled)
        XCTAssertEqual(conflicted.text, conflictSend.text)
        XCTAssertEqual(saved?.text, ExactText("Newest composer text"))
    }
}
