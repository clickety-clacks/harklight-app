import XCTest
@testable import Harklight
import AttentionDomain

final class HarklightTests: XCTestCase {
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

        let repliedResults = InboxListProjection.filteredRows(
            rows, in: .replied, search: "archive")
        XCTAssertEqual(repliedResults.map(\.id), [.request(repliedMatch.key)])
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
    func testLivePresentationReadsCommittedRelayEnvelopeFromSharedDomainStore() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person-A"),
                                       deviceID: ExactText("device-A"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let store = try AttentionDomainStore(context: context,
                                             persistence: MemoryAttentionStatePersistence())
        let visible = try LivePresentationStore(store: store, context: context)
        XCTAssertTrue(visible.presentation.requests.isEmpty)

        let payload = try JSONValue.parse(Data(#"{"sender_id":"app:test","message_id":"m1","created_at":1,"title":"Real relay request","body":"Reply requested"}"#.utf8))
        let key = RequestKey(accountScope: identity.personID,
                             senderID: ExactText("app:test"), messageID: ExactText("m1"))
        _ = try store.apply(RelayEvent(sequence: 1,
                                       body: .delivery(StoredRequest(key: key, originalPayload: payload), .message)),
                            context: context)
        try visible.refreshFromDurableStore()

        XCTAssertEqual(visible.presentation.cursor, 1)
        XCTAssertEqual(visible.openRequests.map(\.key), [key])
        XCTAssertEqual(visible.selectedRequest?.title?.rawValue, "Real relay request")
        XCTAssertEqual(visible.selectedRequest?.body?.rawValue, "Reply requested")
        XCTAssertTrue(LiveRequestDetail(request: try XCTUnwrap(visible.selectedRequest),
                                        store: visible).canAnswer)

        guard case let .compatibility(actions) = try XCTUnwrap(visible.selectedRequest).projection,
              actions.count == 1,
              let reply = actions.first,
              reply.kind == .text else {
            return XCTFail("A plain sender message needs a deliberate text reply in the real inbox.")
        }
        visible.selectAction(reply.id, input: nil, for: key)
        visible.updateCompatibilityText("  Yes, I can help.\n", action: reply.id, for: key)
        let receipt = try visible.submit(key)
        XCTAssertEqual(receipt.exactAnswerJSON, #""  Yes, I can help.\n""#)
        XCTAssertEqual(visible.selectedRequest?.lifecycleStatus, .pending)
        XCTAssertEqual(try store.snapshot(context: context).outbox.first?.operationID, receipt.opID)
    }

    @MainActor
    func testOnlyRequestsWithAUserActionAppearInReplied() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("inbox-replied-\(UUID().uuidString)"),
                                       deviceID: ExactText("device-A"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let store = try AttentionDomainStore(context: context,
                                             persistence: MemoryAttentionStatePersistence())
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
    func testSuppliedUnsupportedAnswerFormatOffersNoSend() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person-A"),
                                       deviceID: ExactText("device-A"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let store = try AttentionDomainStore(context: context,
                                             persistence: MemoryAttentionStatePersistence())
        let key = RequestKey(accountScope: identity.personID,
                             senderID: ExactText("app:test"), messageID: ExactText("unsupported"))
        let payload = try JSONValue.parse(Data(#"{"title":"Future answer","answer_ui":{"schema":"future.answer/9"}}"#.utf8))
        _ = try store.apply(RelayEvent(sequence: 1,
                                       body: .delivery(StoredRequest(key: key, originalPayload: payload), .message)),
                            context: context)
        let visible = try LivePresentationStore(store: store, context: context)
        let request = try XCTUnwrap(visible.selectedRequest)
        guard case .unsupported = request.projection else {
            return XCTFail("An explicitly supplied unknown answer format must be unsupported.")
        }
        XCTAssertFalse(LiveRequestDetail(request: request, store: visible).canAnswer,
                       "An unsupported sender format must not offer Send.")
    }

    @MainActor
    func testAnswerControlsRemainAvailableWhileInboxFreshnessIsUnknown() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("refresh-answer-\(UUID().uuidString)"),
                                       deviceID: ExactText("device-A"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let store = try AttentionDomainStore(context: context,
                                             persistence: MemoryAttentionStatePersistence())
        let key = RequestKey(accountScope: identity.personID,
                             senderID: ExactText("app:test"), messageID: ExactText("refresh-answer"))
        let payload = try JSONValue.parse(Data(#"{"sender_id":"app:test","message_id":"refresh-answer","title":"Refresh answer","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"reply","label":"Reply","kind":"text"}]}}"#.utf8))
        let acceptance = RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: payload), .message))
        _ = try store.beginInboxCandidate(startupID: "first", since: 0, batches: [], context: context)
        try store.saveInboxInitialPage(snapshotID: "accepted-snapshot", highWater: 1,
            items: [InboxSnapshotItem(acceptance: acceptance)],
            nextCursor: nil, receiptCursor: nil, context: context)
        _ = try store.prepareInboxCheckpointAcknowledgement(context: context)
        _ = try store.acceptInboxCheckpoint(snapshotID: "accepted-snapshot", highWater: 1, context: context)
        _ = try store.beginInboxCandidate(startupID: "refresh", since: 1, batches: [], context: context)
        let visible = try LivePresentationStore(store: store, context: context)
        let request = try XCTUnwrap(visible.request(for: key))

        visible.beginRefresh()
        defer { visible.endRefresh() }
        let row = try XCTUnwrap(visible.inboxRows.first { $0.key == key })
        XCTAssertTrue(request.inboxStateIsCurrent,
                      "A pending refresh keeps rows from the last accepted inbox snapshot current.")
        XCTAssertTrue(visible.isRefreshing)
        XCTAssertFalse(row.isResolved, "Unknown freshness must not gray an otherwise open message.")
        XCTAssertTrue(row.canNoComment)
        XCTAssertTrue(LiveRequestDetail(request: request, store: visible).canAnswer,
                      "A freshness check must not dim or disable an answer for the version on screen.")
    }

    @MainActor
    func testLiveAnswerUsesSenderChoiceAndStaysPendingAcrossRestart() throws {
        let fixture = try XCTUnwrap(loadFixtures().requests.first(where: { $0.key.messageID == ExactText("review-01") }))
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: fixture.key.accountScope,
                                       deviceID: ExactText("enrolled-device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let persistence = MemoryAttentionStatePersistence()
        let store = try AttentionDomainStore(context: context, persistence: persistence)
        _ = try store.apply(RelayEvent(sequence: 1,
                                       body: .delivery(StoredRequest(key: fixture.key,
                                                                     originalPayload: fixture.originalPayload), .message)),
                            context: context)
        let live = try LivePresentationStore(store: store, context: context)
        guard case let .sender(sender) = try XCTUnwrap(live.selectedRequest).projection,
              let input = sender.inputs.first,
              case let .response(actions) = input.kind,
              let action = actions.first(where: { $0.kind == .value }) else {
            return XCTFail("The admitted sender choice must be available to the real inbox.")
        }

        live.selectAction(action.id, input: input.id, for: fixture.key)
        XCTAssertNil(live.actionError)
        let receipt = try live.submit(fixture.key)
        XCTAssertEqual(live.selectedRequest?.lifecycleStatus, .pending)
        XCTAssertEqual(live.selectedRequest?.intentReceipt?.opID, receipt.opID)
        XCTAssertEqual(try store.snapshot(context: context).outbox.first?.operationID, receipt.opID)

        let reopenedContext = ProfileContext(identity: identity, transportMode: .relay)
        let reopened = try AttentionDomainStore(context: reopenedContext, persistence: persistence)
        let reopenedLive = try LivePresentationStore(store: reopened, context: reopenedContext)
        XCTAssertEqual(reopenedLive.selectedRequest?.lifecycleStatus, .pending)
        XCTAssertEqual(reopenedLive.selectedRequest?.intentReceipt?.intentID, receipt.intentID)
        XCTAssertThrowsError(try reopenedLive.submit(fixture.key),
                             "The visible Pending answer must not mint another original operation.")
        XCTAssertEqual(try reopened.snapshot(context: reopenedContext).outbox.count, 1)
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
                                  persistence: MemoryAttentionStatePersistence())
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

    func testRelayPresentationPreservesDurableAcceptanceOrderAcrossRestart() throws {
        let fixtures = try loadFixtures()
        let review = try XCTUnwrap(fixtures.requests.first)
        let facilities = try XCTUnwrap(fixtures.requests.first(where: { $0.key.messageID == ExactText("facilities-01") }))
        let lexicalOrder = [review, facilities].sorted { left, right in
            if left.key.senderID.rawValue != right.key.senderID.rawValue {
                return left.key.senderID.rawValue < right.key.senderID.rawValue
            }
            return left.key.messageID.rawValue < right.key.messageID.rawValue
        }
        let acceptedOrder = Array(lexicalOrder.reversed())
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay-test"),
                                       personID: fixtures.accountScope,
                                       deviceID: ExactText("device-a"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let persistence = MemoryAttentionStatePersistence()
        let store = try AttentionDomainStore(context: context, persistence: persistence)

        XCTAssertNotEqual(acceptedOrder.map(\.key), lexicalOrder.map(\.key))
        XCTAssertEqual(try store.apply(RelayEvent(sequence: 1,
                                                  body: .delivery(StoredRequest(key: acceptedOrder[0].key,
                                                                                originalPayload: acceptedOrder[0].originalPayload),
                                                                  .message)),
                                       context: context), 1)
        XCTAssertEqual(try store.apply(RelayEvent(sequence: 2,
                                                  body: .delivery(StoredRequest(key: acceptedOrder[1].key,
                                                                                originalPayload: acceptedOrder[1].originalPayload),
                                                                  .message)),
                                       context: context), 2)

        let port = AttentionDomainPort(store: store)
        let firstSnapshot = try port.observe(context: port.context)
        let newestFirst = Array(acceptedOrder.reversed())
        XCTAssertEqual(firstSnapshot.requests.map(\.key), newestFirst.map(\.key),
                       "The inbox presents the most recently accepted item first while retaining durable order values.")
        XCTAssertEqual(firstSnapshot.requests.map(\.acceptanceOrder), [UInt64(2), 1])

        let restartedContext = ProfileContext(identity: identity, transportMode: .relay)
        let restartedStore = try AttentionDomainStore(context: restartedContext, persistence: persistence)
        let restartedPort = AttentionDomainPort(store: restartedStore)
        let restartedSnapshot = try restartedPort.observe(context: restartedPort.context)
        XCTAssertEqual(restartedSnapshot.requests.map(\.key), newestFirst.map(\.key))
        XCTAssertEqual(restartedSnapshot.requests.map(\.acceptanceOrder), [UInt64(2), 1])
    }

    func testMalformedAuthorizedResultPointProjectsTheWholeNeutralScene() throws {
        let fixtures = try loadFixtures()
        let fixture = try XCTUnwrap(fixtures.requests.first(where: { $0.key.messageID == ExactText("facilities-01") }))
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay-test"),
                                       personID: fixtures.accountScope,
                                       deviceID: ExactText("device-a"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let store = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
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

    @MainActor
    func testInvalidTypedStatesCapacityAndUnsupportedDocumentsCreateNoReceipt() throws {
        let fixtures = try loadFixtures()
        let review = try XCTUnwrap(fixtures.requests.first)
        guard case let .sender(reviewDocument) = review.interface else { return XCTFail("Missing review document") }
        let response = try XCTUnwrap(reviewDocument.inputs.first)
        let actions: [SenderAction]
        if case let .response(values) = response.kind { actions = values } else { return XCTFail("Expected response input") }
        let noteAction = try XCTUnwrap(actions.first(where: { $0.id == ExactText("note") }))
        let coverAction = try XCTUnwrap(actions.first(where: { $0.id == ExactText("cover-a") }))

        var missingSelection = RequestDraft(interface: review.interface)
        XCTAssertNil(reviewDocument.compose(drafts: missingSelection.inputs, maximumBytes: 65_536))

        missingSelection.inputs[response.id]?.selectedActionID = noteAction.id
        XCTAssertNil(reviewDocument.compose(drafts: missingSelection.inputs, maximumBytes: 65_536), "A selected text action needs an explicit text record.")

        var extraText = RequestDraft(interface: review.interface)
        extraText.inputs[response.id]?.selectedActionID = coverAction.id
        extraText.inputs[response.id]?.textByActionID[coverAction.id] = ExactText("override")
        XCTAssertNil(reviewDocument.compose(drafts: extraText.inputs, maximumBytes: 65_536), "Literal responses cannot carry text overrides.")

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
        XCTAssertNil(facilitiesDocument.compose(drafts: missingNote.inputs, maximumBytes: 65_536))

        let lowCapacity = PrototypeStore(fixtures: fixtures, captureLimitBytes: 2)
        lowCapacity.selectAction(coverAction.id, inputID: response.id, for: review.key)
        XCTAssertFalse(lowCapacity.canSend(for: review.key))
        XCTAssertEqual(lowCapacity.session(for: review.key)?.draft.inputs[response.id]?.selectedActionID, coverAction.id)
        XCTAssertEqual(lowCapacity.session(for: review.key)?.lifecycle, .open)

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
                       "A request closed without a confirmed result for your answer. Your answer stays saved on this device.",
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
        let persistence = FileAttentionStatePersistence(directoryURL: directory)
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("fixture-only:test"),
                                       personID: fixtures.accountScope,
                                       deviceID: ExactText("device-a"))
        let firstContext = ProfileContext(identity: identity, transportMode: .fixture)
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

        // Reopening a process uses a fresh generation and the same protected profile file.
        let restartedContext = ProfileContext(identity: identity, transportMode: .fixture)
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
        XCTAssertEqual(receipt.localState, .durable)

        // No caller-visible response was delivered. A second host resumes by intent ID and
        // obtains the original operation UUID and exact answer without creating another row.
        let lookup = try XCTUnwrap(restartedPort.lookupIntent(context: restartedPort.context, intentID: intentID))
        XCTAssertEqual(lookup.opID, receipt.opID)
        XCTAssertEqual(lookup.exactAnswer, receipt.exactAnswer)
        XCTAssertEqual(lookup.inputs, records)
        let submitWonFence = try XCTUnwrap(restartedPort.fenceUncommittedIntent(
            context: restartedPort.context, requestKey: fixture.key, intentID: intentID))
        XCTAssertEqual(submitWonFence.opID, receipt.opID)

        let postCommitContext = ProfileContext(identity: identity, transportMode: .fixture)
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
        XCTAssertEqual(try postCommitStore.snapshot(context: postCommitContext).outbox.count, 1)

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
        XCTAssertEqual(try postCommitStore.snapshot(context: postCommitContext).outbox.count, 1)
    }

    @MainActor
    func testReplyDraftIsSavedAfterTypingPauseAndSurvivesStoreRestart() async throws {
        let fixtures = try loadFixtures()
        let fixture = try XCTUnwrap(fixtures.requests.first(where: { $0.key.messageID == ExactText("facilities-01") }))
        guard case let .sender(document) = fixture.interface else { return XCTFail("Expected the facilities sender document.") }
        let noteInput = try XCTUnwrap(document.inputs.first(where: { if case .text = $0.kind { return true }; return false }))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("attention-debounced-draft-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = FileAttentionStatePersistence(directoryURL: directory)
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: fixtures.accountScope,
                                       deviceID: ExactText("device-a"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let requestKey = RequestKey(accountScope: context.identity.personID,
                                    senderID: fixture.key.senderID,
                                    messageID: fixture.key.messageID)
        func makeRelayStore() throws -> AttentionDomainStore {
            let store = try AttentionDomainStore(context: context, persistence: persistence)
            _ = try store.apply(RelayEvent(sequence: 1,
                body: .delivery(StoredRequest(key: requestKey,
                                              originalPayload: fixture.originalPayload), .message)),
                context: context)
            return store
        }
        let firstStore = try makeRelayStore()
        let editor = try LivePresentationStore(store: firstStore, context: context)
        let longReply = String(repeating: "Near the east entrance; please keep the access path clear. ", count: 8)

        editor.updateText(longReply, input: noteInput.id, action: nil, for: requestKey)
        let beforePause = try makeRelayStore()
        XCTAssertNotEqual(try beforePause.snapshot(context: context).drafts[requestKey]?.inputs[noteInput.id]?.text?.rawValue,
                          longReply,
                          "Typing remains in view state until the debounce interval expires.")

        try await Task.sleep(for: .milliseconds(600))
        let afterPause = try makeRelayStore()
        XCTAssertEqual(try afterPause.snapshot(context: context).drafts[requestKey]?.inputs[noteInput.id]?.text?.rawValue,
                       longReply,
                       "The paused draft is durable and available after a new store opens.")

        let flushedReply = longReply + " Still here."
        editor.updateText(flushedReply, input: noteInput.id, action: nil, for: requestKey)
        editor.flushPendingDrafts()
        let afterFlush = try makeRelayStore()
        XCTAssertEqual(try afterFlush.snapshot(context: context).drafts[requestKey]?.inputs[noteInput.id]?.text?.rawValue,
                       flushedReply,
                       "A forced flush durably saves the latest draft without waiting for another pause.")
    }

    func testDurableFenceRejectsLateOriginalSubmitAfterRestartAndChangedDraft() throws {
        let fixtures = try loadFixtures()
        let fixture = try XCTUnwrap(fixtures.requests.first(where: { $0.key.messageID == ExactText("facilities-01") }))
        guard case let .sender(document) = fixture.interface else { return XCTFail("Expected facilities sender document.") }
        let point = try XCTUnwrap(document.inputs.first(where: { if case .point = $0.kind { return true }; return false }))
        let note = try XCTUnwrap(document.inputs.first(where: { if case .text = $0.kind { return true }; return false }))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("attention-fence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = FileAttentionStatePersistence(directoryURL: directory)
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
        let persistence = MemoryAttentionStatePersistence()
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("fixture-only:test"),
                                       personID: fixtures.accountScope,
                                       deviceID: ExactText("device-precommit"))
        let context = ProfileContext(identity: identity, transportMode: .fixture)
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

        let restartedContext = ProfileContext(identity: identity, transportMode: .fixture)
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
        XCTAssertEqual(try restartedStore.snapshot(context: restartedContext).outbox.count, 1)
    }

    func testAccountAndGenerationBindingHideCollidingRequests() throws {
        let fixtures = try loadFixtures()
        let source = try XCTUnwrap(fixtures.requests.first(where: { $0.key.messageID == ExactText("facilities-01") }))
        let persistence = MemoryAttentionStatePersistence()
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
        let persistence = MemoryAttentionStatePersistence()
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
        let store = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
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
        XCTAssertThrowsError(try store.apply(RelayEvent(sequence: 3, body: .terminal(fixture.key, .cleared, nil)), context: context)) {
            XCTAssertEqual($0 as? AttentionStoreError, .eventConflict(3))
        }
        XCTAssertEqual(try store.snapshot(context: context).cursor, 2)
    }

    func testOwnOperationReceiptDoesNotJumpCursorAndEnablesKnownAnswerScene() throws {
        let fixtures = try loadFixtures()
        let fixture = try XCTUnwrap(fixtures.requests.first(where: { $0.key.messageID == ExactText("facilities-01") }))
        guard case let .sender(document) = fixture.interface else { return XCTFail("Expected a facilities sender document.") }
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay-test"),
                                       personID: fixtures.accountScope,
                                       deviceID: ExactText("device-a"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let store = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
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
        try store.finishReplay(at: 2, context: context)
        let presented = try XCTUnwrap(port.observe(context: port.context).requests.first)
        XCTAssertEqual(presented.lifecycleStatus, .answered)
        XCTAssertEqual(presented.receiptFacts?.ownOutcome, .accepted)
        guard case let .sender(projection) = presented.projection else { return XCTFail("Expected a sender projection.") }
        XCTAssertEqual(projection.illustrations, document.illustrations)
        XCTAssertEqual(projection.submissionLabel, document.submissionLabel)
        let projectedPoints = resultPointNodes(in: projection.scene)
        XCTAssertEqual(projectedPoints.count, 1)
        guard case let .resultPoint(illustrationID, _, point) = try XCTUnwrap(projectedPoints.first?.kind) else {
            return XCTFail("Expected the authorized result point to be projected as coordinates.")
        }
        XCTAssertNotNil(document.illustration(withID: illustrationID))
        XCTAssertEqual(point, PointValue(x: 240, y: 610))
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
            let persistence = MemoryAttentionStatePersistence()
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
            let restartedContext = ProfileContext(identity: identity, transportMode: .fixture)
            let restartedStore = try makeStore(fixtures: fixtures,
                                               context: restartedContext,
                                               persistence: persistence)
            let restartedPort = AttentionDomainPort(store: restartedStore)
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
                           persistence: any AttentionStatePersistence,
                           replacing replacements: [RequestKey: RequestKey] = [:]) throws -> AttentionDomainStore {
        let store = try AttentionDomainStore(context: context, persistence: persistence)
        let requests = fixtures.requests.map { request in
            StoredRequest(key: replacements[request.key] ?? RequestKey(accountScope: context.identity.personID,
                                                                      senderID: request.key.senderID,
                                                                      messageID: request.key.messageID),
                          originalPayload: request.originalPayload)
        }
        try store.registerFixtureRequests(requests, context: context)
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
