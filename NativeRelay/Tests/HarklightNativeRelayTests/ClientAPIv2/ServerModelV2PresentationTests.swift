import AttentionDomain
import Foundation
@testable import HarklightNativeRelay
import XCTest

/// Review L-27: the answer-screen rules from `GET /v2/me` are in force before
/// the first v2 projection.
final class ServerModelV2PresentationTests: XCTestCase {
    private let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                           personID: ExactText("person-A"), deviceID: ExactText("installation-A"))
    private let screen = #"{"schema":"attention-client.ui/1","requires":["scene/1","result/1"],"illustrations":[],"inputs":[],"open":{"kind":"text","text":"Ready?","style":"body"},"resolved":{"kind":"text","text":"Done","style":"body"},"submission":{"label":"Done","result":{"kind":"literal","value":null}}}"#
    private var saved = AnswerScreenRules.today

    override func setUp() {
        saved = AnswerScreenRules.current
        AnswerScreenRules.current = .today
    }

    override func tearDown() {
        AnswerScreenRules.current = saved
    }

    private func me(documentBytes: Int) throws -> APIMe {
        let limits = #"{"document_bytes":\#(documentBytes),"requires":16,"illustrations":128,"primitives_per_illustration":2048,"primitives_total":4096,"inputs":64,"actions":256,"scene_nodes":1024,"scene_depth":32,"result_nodes":1024,"result_depth":32,"result_point_path":32,"array_items":1024,"object_members":512,"identifier_bytes":256}"#
        return try APIMe(json: V2Fixture.json(#"{"account":{"state":"active"},"features":{},"limits":{"upload_cap_bytes_per_file":1,"inline_decoded_bytes_per_entry":1,"answer_ui_limits":\#(limits),"retention_days":30}}"#))
    }

    private func model() throws -> ServerModelV2 {
        let store = ServerModelV2Store(fileURL: nil)
        try store.apply(kind: "item", rev: 1, data: V2Fixture.json(V2Fixture.item(
            "item-1", rev: 1, rankKey: "a", message: #"{"title":"Question","answer_ui":\#(screen)}"#)))
        return store.snapshot
    }

    private func projectedRequest(_ presentation: ServerModelV2Presentation) throws -> StoredRequest {
        try XCTUnwrap(presentation.cachedState(model(), identity: identity).requests.values.first)
    }

    private func isSender(_ interface: RequestInterface) -> Bool {
        if case .sender = interface { return true }
        return false
    }

    func testTheModelIsNotProjectedBeforeTheRulesAreRead() throws {
        let presentation = ServerModelV2Presentation()
        XCTAssertFalse(presentation.hasRules)
        XCTAssertThrowsError(try presentation.cachedState(model(), identity: identity)) {
            XCTAssertEqual($0 as? ServerModelV2Presentation.PresentationError, .rulesNotRead)
        }
    }

    func testThePublishedLimitsDecideHowTheProjectedScreenIsShown() throws {
        let size = Data(try V2Fixture.json(screen).jsonString.utf8).count
        let presentation = ServerModelV2Presentation()

        presentation.apply(try me(documentBytes: size))
        XCTAssertEqual(AnswerScreenRules.current, .v2(try me(documentBytes: size)))
        let atCap = try projectedRequest(presentation)
        XCTAssertTrue(isSender(atCap.interface), "At the published cap, the screen renders.")

        presentation.apply(try me(documentBytes: size - 1))
        let overCap = try projectedRequest(presentation)
        XCTAssertEqual(overCap.interface, .plainReply, "Over it, the screen degrades to the plain reply.")
        XCTAssertTrue(overCap.customAnswerScreenNotShown(deliveredFileNames: []))
    }

    func testASavedReadPutsTheRulesInForceAtLaunch() throws {
        let saved = try me(documentBytes: 262_144)
        let presentation = ServerModelV2Presentation(savedMe: saved)
        XCTAssertTrue(presentation.hasRules)
        XCTAssertEqual(AnswerScreenRules.current.limits.documentBytes, 262_144)
        XCTAssertTrue(AnswerScreenRules.current.degradesUnshowableScreens)
        XCTAssertNoThrow(try presentation.cachedState(model(), identity: identity))
    }

    func testAnIncompleteLimitSetStillUsesTheV2RulesWithTheBuiltInLimits() throws {
        let me = try APIMe(json: V2Fixture.json(#"{"account":{"state":"active"},"features":{},"limits":{"answer_ui_limits":{"document_bytes":5}}}"#))
        XCTAssertNil(me.answerUILimits)
        ServerModelV2Presentation().apply(me)
        XCTAssertEqual(AnswerScreenRules.current,
                       AnswerScreenRules(limits: .builtIn, degradesUnshowableScreens: true))
    }
}
