import AttentionDomain
import Foundation
import XCTest

/// Product rulings APP-09/10: a client API v2 client renders sender answer
/// screens up to the Server's published limits and degrades one it still
/// cannot show to the plain reply, saying so. Today's rules are unchanged.
final class AnswerScreenRulesTests: XCTestCase {
    private let document = #"{"schema":"attention-client.ui/1","requires":["scene/1","result/1"],"illustrations":[],"inputs":[],"open":{"kind":"text","text":"Ready?","style":"body"},"resolved":{"kind":"text","text":"Done","style":"body"},"submission":{"label":"Done","result":{"kind":"literal","value":null}}}"#

    private func json(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }

    private func v2(documentBytes: Int) -> AnswerScreenRules {
        var limits = SenderDocumentLimits.builtIn
        limits.documentBytes = documentBytes
        return AnswerScreenRules(limits: limits, degradesUnshowableScreens: true)
    }

    private func isSender(_ interface: RequestInterface) -> Bool {
        if case .sender = interface { return true }
        return false
    }

    func testTheValidFixtureRendersToday() throws {
        XCTAssertTrue(isSender(RequestInterface.recognize(try json(document), rules: .today)))
    }

    func testAScreenAtThePublishedLimitRendersAndOneOverItDegradesToThePlainReply() throws {
        let screen = try json(document)
        let size = screen.jsonString.utf8.count
        XCTAssertTrue(isSender(RequestInterface.recognize(screen, rules: v2(documentBytes: size))),
                      "At the cap, the screen renders.")
        XCTAssertFalse(RequestInterface.customScreenNotShown(screen, rules: v2(documentBytes: size)))

        let over = v2(documentBytes: size - 1)
        XCTAssertEqual(RequestInterface.recognize(screen, rules: over), .plainReply, "Over the cap, it degrades.")
        XCTAssertTrue(RequestInterface.customScreenNotShown(screen, rules: over))
    }

    func testTodaysRulesStillShowAnOverCapScreenAsUnsupported() throws {
        var limits = SenderDocumentLimits.builtIn
        limits.documentBytes = 10
        let rules = AnswerScreenRules(limits: limits, degradesUnshowableScreens: false)
        XCTAssertEqual(RequestInterface.recognize(try json(document), rules: rules), .unsupported(.unfamiliar))
        XCTAssertFalse(RequestInterface.customScreenNotShown(try json(document), rules: rules))
    }

    func testAnUnknownVersionOrAMalformedScreenDegradesUnderTheV2Rules() throws {
        let v2Rules = AnswerScreenRules(limits: .builtIn, degradesUnshowableScreens: true)
        for screen in [#"{"schema":"attention-client.ui/9","anything":true}"#,
                       #"{"schema":"attention-client.ui/1","requires":"not-a-list"}"#] {
            XCTAssertEqual(RequestInterface.recognize(try json(screen), rules: v2Rules), .plainReply)
            XCTAssertTrue(RequestInterface.customScreenNotShown(try json(screen), rules: v2Rules))
            XCTAssertEqual(RequestInterface.recognize(try json(screen), rules: .today), .unsupported(.unfamiliar))
        }
    }

    func testAPlainMessageWithoutAScreenIsNotReportedAsHidden() throws {
        let v2Rules = AnswerScreenRules(limits: .builtIn, degradesUnshowableScreens: true)
        XCTAssertEqual(RequestInterface.recognize(nil, rules: v2Rules), .plainReply)
        XCTAssertFalse(RequestInterface.customScreenNotShown(nil, rules: v2Rules))
    }

    func testThePublishedLimitsAreReadByTheirServerNames() throws {
        let published = #"{"document_bytes":262144,"requires":16,"illustrations":128,"primitives_per_illustration":2048,"primitives_total":4096,"inputs":64,"actions":256,"scene_nodes":1024,"scene_depth":32,"result_nodes":1024,"result_depth":32,"result_point_path":32,"array_items":1024,"object_members":512,"identifier_bytes":256}"#
        let limits = try XCTUnwrap(SenderDocumentLimits(answerUILimits: try json(published)))
        XCTAssertEqual(limits.documentBytes, 262_144)
        XCTAssertEqual(limits.identifierBytes, 256)
        XCTAssertNil(SenderDocumentLimits(answerUILimits: try json(#"{"document_bytes":1}"#)),
                     "A partial set is not used.")
    }
}
