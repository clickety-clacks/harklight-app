import AttentionDomain
import Foundation
import XCTest

/// A client API v2 client renders a sender answer screen up to each of the
/// Server's published limits and degrades one over a limit to the plain reply,
/// saying the custom screen is not shown. Each test lowers one limit to the
/// count its screen has, keeps every other limit at the built-in value, and
/// checks the screen at that cap and one over it.
final class AnswerScreenLimitCapTests: XCTestCase {
    private let resolved = #""resolved":{"kind":"text","text":"Done","style":"body"}"#
    private let open = #""open":{"kind":"text","text":"Ready?","style":"body"}"#
    private let literalResult = #""submission":{"label":"Done","result":{"kind":"literal","value":null}}"#

    private func screen(requires: [String] = ["scene/1", "result/1"],
                        illustrations: String = "[]",
                        inputs: String = "[]",
                        open: String? = nil,
                        extra: String = "",
                        result: String? = nil) -> String {
        let requiresList = requires.map { "\"\($0)\"" }.joined(separator: ",")
        let openMember = open.map { #""open":"# + $0 } ?? self.open
        let submission = result.map { #""submission":{"label":"Done","result":"# + $0 + "}" } ?? literalResult
        return #"{"schema":"attention-client.ui/1","requires":["# + requiresList + #"],"illustrations":"#
            + illustrations + #","inputs":"# + inputs + "," + openMember + "," + resolved + extra + ","
            + submission + "}"
    }

    private func illustration(_ id: String, primitives: Int = 0) -> String {
        let rect = ##"{"kind":"rect","x":0,"y":0,"width":1,"height":1,"fill":"#000000"}"##
        let list = Array(repeating: rect, count: primitives).joined(separator: ",")
        return #"{"id":""# + id + #"","label":"Picture","width":10,"height":10,"primitives":["# + list + "]}"
    }

    private func illustrationNode(_ id: String) -> String { #"{"kind":"illustration","id":""# + id + #""}"# }

    private func verticalStack(_ children: [String]) -> String {
        #"{"kind":"stack","axis":"vertical","children":["# + children.joined(separator: ",") + "]}"
    }

    private func v2(_ limit: WritableKeyPath<SenderDocumentLimits, Int>, _ value: Int) -> AnswerScreenRules {
        var limits = SenderDocumentLimits.builtIn
        limits[keyPath: limit] = value
        return AnswerScreenRules(limits: limits, degradesUnshowableScreens: true)
    }

    private func assertRendersAtCapAndDegradesOver(_ limit: WritableKeyPath<SenderDocumentLimits, Int>,
                                                   cap: Int,
                                                   _ text: String,
                                                   file: StaticString = #filePath,
                                                   line: UInt = #line) throws {
        let screen = try JSONValue.parse(Data(text.utf8))
        let atCap = v2(limit, cap)
        guard case .sender = RequestInterface.recognize(screen, rules: atCap) else {
            return XCTFail("At the cap of \(cap), the screen renders.", file: file, line: line)
        }
        XCTAssertFalse(RequestInterface.customScreenNotShown(screen, rules: atCap), file: file, line: line)

        let over = v2(limit, cap - 1)
        XCTAssertEqual(RequestInterface.recognize(screen, rules: over), .plainReply,
                       "One over the cap, the screen degrades to the plain reply.", file: file, line: line)
        XCTAssertTrue(RequestInterface.customScreenNotShown(screen, rules: over), file: file, line: line)
    }

    func testRequiredCapabilitiesAtTheCapRenderAndOneOverDegrades() throws {
        try assertRendersAtCapAndDegradesOver(\.requires, cap: 2, screen())
    }

    func testIllustrationsAtTheCapRenderAndOneOverDegrades() throws {
        try assertRendersAtCapAndDegradesOver(\.illustrations, cap: 2, screen(
            requires: ["scene/1", "result/1", "illustration/1"],
            illustrations: "[" + illustration("a") + "," + illustration("b") + "]",
            open: verticalStack([illustrationNode("a"), illustrationNode("b")])))
    }

    func testPrimitivesInOneIllustrationAtTheCapRenderAndOneOverDegrades() throws {
        try assertRendersAtCapAndDegradesOver(\.primitivesPerIllustration, cap: 2, screen(
            requires: ["scene/1", "result/1", "illustration/1"],
            illustrations: "[" + illustration("a", primitives: 2) + "]",
            open: illustrationNode("a")))
    }

    func testPrimitivesAcrossIllustrationsAtTheCapRenderAndOneOverDegrades() throws {
        // One primitive in each illustration: the total, not any one illustration, is over.
        try assertRendersAtCapAndDegradesOver(\.primitivesTotal, cap: 2, screen(
            requires: ["scene/1", "result/1", "illustration/1"],
            illustrations: "[" + illustration("a", primitives: 1) + "," + illustration("b", primitives: 1) + "]",
            open: verticalStack([illustrationNode("a"), illustrationNode("b")])))
    }

    func testInputsAtTheCapRenderAndOneOverDegrades() throws {
        try assertRendersAtCapAndDegradesOver(\.inputs, cap: 2, screen(
            requires: ["scene/1", "result/1", "text/1"],
            inputs: #"[{"kind":"text","id":"first","label":"First"},{"kind":"text","id":"second","label":"Second"}]"#,
            open: verticalStack([#"{"kind":"input","id":"first","layout":"editor"}"#,
                                 #"{"kind":"input","id":"second","layout":"editor"}"#]),
            result: #"{"kind":"array","items":[{"kind":"input","id":"first"},{"kind":"input","id":"second"}]}"#))
    }

    func testActionsAtTheCapRenderAndOneOverDegrades() throws {
        try assertRendersAtCapAndDegradesOver(\.actions, cap: 2, screen(
            requires: ["scene/1", "result/1", "response/1"],
            inputs: #"[{"kind":"response","id":"choice","label":"Choose","actions":[{"id":"yes","label":"Yes","kind":"value","value":true},{"id":"no","label":"No","kind":"value","value":false}]}]"#,
            open: #"{"kind":"input","id":"choice","layout":"cards"}"#,
            result: #"{"kind":"input","id":"choice"}"#))
    }

    func testSceneNodesAtTheCapRenderAndOneOverDegrades() throws {
        // The open stack and its two texts, plus the resolved text: four nodes.
        try assertRendersAtCapAndDegradesOver(\.sceneNodes, cap: 4, screen(
            open: verticalStack([#"{"kind":"text","text":"Ready?","style":"body"}"#,
                                 #"{"kind":"text","text":"Go","style":"caption"}"#])))
    }

    func testSceneDepthAtTheCapRendersAndOneOverDegrades() throws {
        // A stack in a stack around a text: the text is at depth three.
        try assertRendersAtCapAndDegradesOver(\.sceneDepth, cap: 3, screen(
            open: verticalStack([verticalStack([#"{"kind":"text","text":"Ready?","style":"body"}"#])])))
    }

    func testResultNodesAtTheCapRenderAndOneOverDegrades() throws {
        // An array and its two literals: three nodes.
        try assertRendersAtCapAndDegradesOver(\.resultNodes, cap: 3, screen(
            result: #"{"kind":"array","items":[{"kind":"literal","value":1},{"kind":"literal","value":2}]}"#))
    }

    func testResultDepthAtTheCapRendersAndOneOverDegrades() throws {
        // An array in an array around a literal: the literal is at depth three.
        try assertRendersAtCapAndDegradesOver(\.resultDepth, cap: 3, screen(
            result: #"{"kind":"array","items":[{"kind":"array","items":[{"kind":"literal","value":null}]}]}"#))
    }

    func testAResultPointPathAtTheCapRendersAndOneOverDegrades() throws {
        try assertRendersAtCapAndDegradesOver(\.resultPointPath, cap: 2, screen(
            requires: ["scene/1", "result/1", "illustration/1", "result-point/1"],
            illustrations: "[" + illustration("a") + "]",
            extra: #","answeredWithResult":{"kind":"result-point","id":"a","label":"Picked","path":["picks",0]}"#))
    }

    func testArrayItemsAtTheCapRenderAndOneOverDegrades() throws {
        try assertRendersAtCapAndDegradesOver(\.arrayItems, cap: 2, screen(
            result: #"{"kind":"array","items":[{"kind":"literal","value":1},{"kind":"literal","value":2}]}"#))
    }

    func testObjectMembersAtTheCapRenderAndOneOverDegrades() throws {
        try assertRendersAtCapAndDegradesOver(\.objectMembers, cap: 2, screen(
            result: #"{"kind":"object","members":[{"name":"a","value":{"kind":"literal","value":1}},{"name":"b","value":{"kind":"literal","value":2}}]}"#))
    }

    func testAnIdentifierAtTheCapRendersAndOneOverDegrades() throws {
        // "café" is four characters and five UTF-8 bytes; the cap counts bytes.
        try assertRendersAtCapAndDegradesOver(\.identifierBytes, cap: 5, screen(
            requires: ["scene/1", "result/1", "text/1"],
            inputs: #"[{"kind":"text","id":"café","label":"Note"}]"#,
            open: #"{"kind":"input","id":"café","layout":"editor"}"#,
            result: #"{"kind":"input","id":"café"}"#))
    }
}
