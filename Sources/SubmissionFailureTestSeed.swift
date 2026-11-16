#if DEBUG
import AttentionDomain
import Foundation

/// UI-test seed for the failed submission states. With
/// `--harklight-test-relay-failed-choice` or `--harklight-test-relay-failed-reply`
/// the app presents an in-memory relay-context store in which the bundled
/// review-01 request has a definitively failed answer, recorded through the
/// same store calls production uses. The relay lifecycle is never activated,
/// so nothing connects anywhere. Debug builds only; with neither argument the
/// app launches as usual.
enum SubmissionFailureTestSeed {
    enum Kind: Equatable {
        case choice, reply
    }

    static let choiceArgument = "--harklight-test-relay-failed-choice"
    static let replyArgument = "--harklight-test-relay-failed-reply"
    static let replyText = "Book the Avenida, and ask for a quiet room"

    /// The requested seed, or nil for an ordinary launch. Both arguments
    /// together are ambiguous and select neither.
    static func requestedKind(in arguments: [String]) -> Kind? {
        switch (arguments.contains(choiceArgument), arguments.contains(replyArgument)) {
        case (true, false): .choice
        case (false, true): .reply
        default: nil
        }
    }

    @MainActor
    static func makeStore(_ kind: Kind) throws -> LivePresentationStore {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("seed.invalid"),
                                       personID: ExactText("submission-failure-seed"),
                                       deviceID: ExactText("seed-device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let fixtures = try FixtureSet.loadBundled(from: .main)
        guard let fixture = fixtures.requests.first(where: { $0.key.messageID == ExactText("review-01") }) else {
            throw AttentionStoreError.intentMissing
        }
        let key = RequestKey(accountScope: identity.personID, senderID: fixture.key.senderID,
                             messageID: fixture.key.messageID)
        _ = try repository.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: fixture.originalPayload), .message)),
            context: context)

        let port = AttentionDomainPort(store: repository)
        guard let selector = try port.inspect(context: port.context, request: key).requests.first?.selector else {
            throw AttentionStoreError.intentMissing
        }
        let input = ExactText("review")
        let inputs: [TypedInputRecord] = switch kind {
        case .choice: [.responseValue(input: input, action: ExactText("cover-a"))]
        case .reply: [.responseText(input: input, action: ExactText("note"), text: ExactText(replyText))]
        }
        // A Reply box send keeps no saved draft; the failed answer carries the text.
        let receipt = try port.submit(SubmitIntent(context: port.context, selector: selector, intentID: UUID(),
                                                   inputs: inputs, persistAnswerDraft: kind == .choice))
        try repository.recordAnswerNotDelivered(receipt.intentID, operationID: receipt.opID, context: context)

        return try LivePresentationStore(store: repository, context: context,
            clearedRetractionDefaults: UserDefaults(suiteName: "harklight-submission-failure-seed") ?? .standard)
    }
}
#endif
