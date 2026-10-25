import XCTest
import AttentionDomain
@testable import Harklight

@MainActor
final class SampleLibraryTests: XCTestCase {
    func testAnnotationUndoReversesTheLatestActionAcrossTools() throws {
        let library = SampleLibrary()
        library.populate()
        let response = try XCTUnwrap(library.responses["sample-point-0"])
        response.addStroke([SampleMark(x: 0.1, y: 0.1), SampleMark(x: 0.8, y: 0.8)])
        response.addMark(SampleMark(x: 0.4, y: 0.4))
        response.undoAnnotation()
        XCTAssertTrue(response.marks.isEmpty)
        XCTAssertEqual(response.strokes.count, 1)
        response.undoAnnotation()
        XCTAssertTrue(response.strokes.isEmpty)
    }
    func testAddingExamplesPopulatesEveryKindAndPreservesEditsOnRepeat() throws {
        let library = SampleLibrary()
        library.populate()
        XCTAssertFalse(library.messages.isEmpty)
        for kind in SampleKind.allCases {
            XCTAssertGreaterThanOrEqual(library.messages.filter { $0.kind == kind }.count, 3)
        }
        let first = try XCTUnwrap(library.messages.first { $0.id == "sample-approval-0" })
        let response = try XCTUnwrap(library.responses[first.id])
        response.choose("keep", multiple: false)
        response.text = "Keep this draft"
        response.chatDraft = "A local conversation"
        response.sendLocalChat()
        let firstFixture = try XCTUnwrap(library.fixture)
        let originalPayloads = try firstFixture.domain.snapshot(context: firstFixture.context)
            .requests.mapValues(\.originalPayload)
        let ids = library.messages.map(\.id)
        library.populate()
        XCTAssertNil(library.loadError)
        XCTAssertEqual(library.messages.map(\.id), ids)
        XCTAssertTrue(library.responses[first.id] === response)
        XCTAssertEqual(response.text, "Keep this draft")
        XCTAssertEqual(response.choices, ["keep"])
        XCTAssertEqual(response.chat.last?.text, "A local conversation")
        let repeatedPayloads = try firstFixture.domain.snapshot(context: firstFixture.context)
            .requests.mapValues(\.originalPayload)
        XCTAssertEqual(repeatedPayloads, originalPayloads,
            "Stable sample identities must retain their exact registered payloads when examples are added again.")
    }

    func testSampleActionsLeaveRealRequestsAndIdentityUntouched() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"), personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let domain = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        let key = RequestKey(accountScope: identity.personID, senderID: ExactText("sender"), messageID: ExactText("real-message"))
        let payload = try JSONValue.parse(Data(#"{"sender_id":"sender","message_id":"real-message","created_at":1,"title":"Keep this real message"}"#.utf8))
        _ = try domain.apply(RelayEvent(sequence: 1, body: .delivery(StoredRequest(key: key, originalPayload: payload), .message)), context: context)
        let presentation = try LivePresentationStore(store: domain, context: context)
        let before = presentation.presentation
        let library = SampleLibrary()
        library.populate()
        for response in library.responses.values {
            response.choose("example", multiple: false)
            response.finished = true
            response.chatDraft = "Never deliver this"
            response.attachments = ["Local photo"]
            response.sendLocalChat()
        }
        library.populate()
        try presentation.refreshFromDurableStore()
        XCTAssertEqual(presentation.presentation, before)
        XCTAssertEqual(presentation.selectedRequest?.key, key)
    }

    func testEveryExampleTraversesDomainProjectionAndOrdinaryViewModelWithoutSubmission() throws {
        let library = SampleLibrary()
        library.populate()
        XCTAssertNil(library.loadError)
        let fixture = try XCTUnwrap(library.fixture)
        XCTAssertEqual(fixture.viewModel.presentation.requests.count, 45)
        var compatibilityExamples = 0
        for message in library.messages {
            let response = try XCTUnwrap(library.responses[message.id])
            let projected = try XCTUnwrap(fixture.viewModel.request(for: response.key))
            var supportsNoteDraft = false
            switch projected.projection {
            case let .sender(sender):
                supportsNoteDraft = sender.inputs.contains { $0.id == ExactText("note") }
            case let .compatibility(actions):
                compatibilityExamples += 1
                XCTAssertTrue(actions.contains { ["seen", "reply"].contains($0.id.rawValue) },
                    "Compatibility examples must retain their explicit Seen or Reply action.")
                if actions.contains(where: { $0.id == ExactText("reply") && $0.kind == .text }) {
                    fixture.viewModel.selectAction(ExactText("reply"), input: nil, for: response.key)
                    fixture.viewModel.updateCompatibilityText("A compatibility reply",
                                                              action: ExactText("reply"),
                                                              for: response.key)
                }
            case .unsupported:
                return XCTFail("Unrecognized fixture descriptor")
            }
            XCTAssertEqual(projected.title?.rawValue, message.title)
            library.select(message.id)
            XCTAssertEqual(fixture.viewModel.selectedRequestKey, response.key)
            if fixture.viewModel.isRetracted(response.key) {
                XCTAssertFalse(response.canFinishLocally,
                               "Retraction keeps the saved response but prevents another answer.")
                XCTAssertEqual(projected.draft.inputs[ExactText("answer")]?.selectedActionID,
                               ExactText("archive"))
                XCTAssertEqual(fixture.viewModel.conversationDraft(for: response.key, revision: 1).text,
                               ExactText("Please keep this unsent note."))
                continue
            }
            if let option = message.options.first {
                response.choose(option.id, multiple: message.kind == .multipleChoice)
            }
            if supportsNoteDraft { response.text = "A domain draft" }
            if message.kind == .textChoice {
                response.ownAnswer = true
                response.text = "My own domain answer"
            }
            if message.kind == .value { response.number = 42 }
            if message.kind == .point { response.addMark(SampleMark(x: 0.25, y: 0.75)) }
            response.finished = true
            // Even an erroneous submit/retry callback cannot create an intent.
            XCTAssertThrowsError(try fixture.viewModel.submit(response.key))
            fixture.viewModel.submitFromUser(response.key)
        }
        fixture.viewModel.retryPendingDelivery()
        let snapshot = try fixture.domain.snapshot(context: fixture.context)
        XCTAssertTrue(snapshot.intents.isEmpty)
        let restored = try LivePresentationStore(localFixtureStore: fixture.domain, context: fixture.context)
        for message in library.messages {
            let request = try XCTUnwrap(restored.request(for: fixture.key(for: message)))
            XCTAssertNil(request.intentReceipt)
            let retracted = restored.isRetracted(request.key)
            let expectedLifecycle: AppLifecycleStatus =
                message.id == "sample-completed-2" || retracted ? .cleared : .open
            XCTAssertEqual(request.lifecycleStatus, expectedLifecycle)
            let hasNoteInput: Bool
            if case let .sender(sender) = request.projection {
                hasNoteInput = sender.inputs.contains { $0.id == ExactText("note") }
            } else {
                hasNoteInput = false
            }
            if hasNoteInput {
                let expectedDraft: ExactText? = retracted ? ExactText("") : ExactText("A domain draft")
                XCTAssertEqual(request.draft.inputs[ExactText("note")]?.text, expectedDraft)
            } else {
                XCTAssertNil(request.draft.inputs[ExactText("note")]?.text,
                             "Only messages with an admitted note input retain a note draft.")
            }
            if message.kind == .note {
                XCTAssertEqual(request.draft.compatibility.selectedActionID, ExactText("reply"))
                XCTAssertEqual(request.draft.compatibility.textByActionID[ExactText("reply")],
                               ExactText("A compatibility reply"))
            }
            switch message.kind {
            case .textChoice:
                XCTAssertEqual(request.draft.inputs[ExactText("answer")]?.selectedActionID, ExactText("own"))
                XCTAssertEqual(request.draft.inputs[ExactText("answer")]?.textByActionID[ExactText("own")], ExactText("My own domain answer"))
            case .multipleChoice:
                XCTAssertEqual(request.draft.inputs[ExactText(message.options[0].id)]?.selectedActionID, ExactText("yes"))
                XCTAssertEqual(request.draft.inputs[ExactText(message.options[1].id)]?.selectedActionID, ExactText("no"))
            case .value:
                XCTAssertEqual(request.draft.inputs[ExactText("value")]?.text, ExactText("42.0"))
            case .point:
                XCTAssertEqual(request.draft.inputs[ExactText("point")]?.effectivePoint, PointValue(x: 250, y: 750))
            case .instructions:
                XCTAssertEqual(request.draft.inputs[ExactText("answer")]?.selectedActionID, ExactText("done"))
            default: break
            }
        }
        XCTAssertGreaterThan(compatibilityExamples, 0,
            "The fixture must exercise compatibility Seen/Reply projections as well as sender descriptors.")
        for message in library.messages where [.approval, .review, .multipleChoice, .colorChoice, .soundChoice].contains(message.kind) {
            let response = try XCTUnwrap(library.responses[message.id])
            let request = try XCTUnwrap(fixture.viewModel.request(for: response.key))
            if fixture.viewModel.isRetracted(response.key) {
                XCTAssertFalse(response.canFinishLocally,
                               "A retracted request keeps its saved answer but cannot accept another one.")
                XCTAssertEqual(request.draft.inputs[ExactText("answer")]?.selectedActionID,
                               ExactText("archive"),
                               "Retraction preserves the original unsent choice.")
                continue
            }
            response.ownAnswer = true
            response.choices = []
            response.text = "An alternative for " + message.id
            XCTAssertTrue(response.ownAnswer)
            let editedRequest = try XCTUnwrap(fixture.viewModel.request(for: response.key))
            XCTAssertEqual(editedRequest.draft.inputs[ExactText("answer")]?.selectedActionID, ExactText("own"))
            XCTAssertEqual(editedRequest.draft.inputs[ExactText("answer")]?.textByActionID[ExactText("own")]?.rawValue,
                "An alternative for " + message.id)
            XCTAssertTrue(response.canFinishLocally,
                "The offered own-answer alternative must not require unrelated per-option choices.")
        }
        let multipleChoice = try XCTUnwrap(library.messages.first { $0.kind == .multipleChoice })
        let multipleChoiceResponse = try XCTUnwrap(library.responses[multipleChoice.id])
        multipleChoiceResponse.ownAnswer = false
        multipleChoiceResponse.choices = [try XCTUnwrap(multipleChoice.options.first).id]
        XCTAssertEqual(multipleChoiceResponse.choices.count, 1)
        XCTAssertTrue(multipleChoiceResponse.canFinishLocally,
            "Selecting a subset must not require unrelated answers for every option.")
        library.populate()
        XCTAssertEqual(fixture.viewModel.presentation.requests.count, 45)
        XCTAssertTrue(try fixture.domain.snapshot(context: fixture.context).intents.isEmpty)
    }

    func testReorderKeepsSelectionAndUsesCurrentNeighbors() throws {
        let library = SampleLibrary()
        library.populate()
        let first = try XCTUnwrap(library.messages.first)
        library.select(first.id)
        library.demonstrateReorder()
        XCTAssertEqual(library.selectedID, first.id)
        XCTAssertEqual(library.lastViewedID, first.id)
        XCTAssertEqual(library.messages.last?.id, first.id)
        XCTAssertNil(library.neighbor(of: first.id, direction: 1))
        XCTAssertEqual(library.neighbor(of: first.id, direction: -1)?.id, library.messages.dropLast().last?.id)
    }
}
