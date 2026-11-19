import CoreGraphics
import XCTest
@testable import Harklight

final class WorkspaceChatLayoutTests: XCTestCase {
    // A 13-inch iPad in portrait; the on-screen keyboard shrinks the content
    // area below the window width, but the window keeps its size.
    private let portraitWindow = CGSize(width: 1032, height: 1376)
    private let keyboardShrunkContent = CGSize(width: 1032, height: 620)

    func testPortraitKeyboardDoesNotSwitchWideIPadToInlineChat() {
        let withoutKeyboard = WorkspaceChatLayout(
            window: portraitWindow, container: CGSize(width: 1032, height: 1300), isPad: true)
        let withKeyboard = WorkspaceChatLayout(
            window: portraitWindow, container: keyboardShrunkContent, isPad: true)

        XCTAssertFalse(withoutKeyboard.inlineChat)
        XCTAssertFalse(withKeyboard.landscape)
        XCTAssertFalse(withKeyboard.inlineChat, "the keyboard must not close the portrait Chat sheet")
        XCTAssertEqual(withKeyboard, withoutKeyboard)
    }

    func testRotatingWideIPadToLandscapeShowsInlineChat() {
        let layout = WorkspaceChatLayout(
            window: CGSize(width: 1376, height: 1032),
            container: CGSize(width: 1376, height: 1000), isPad: true)

        XCTAssertTrue(layout.landscape)
        XCTAssertTrue(layout.inlineChat)
    }

    func testNarrowIPadAndIPhoneKeepChatInASheet() {
        XCTAssertFalse(WorkspaceChatLayout(
            window: CGSize(width: 744, height: 1133),
            container: CGSize(width: 744, height: 600), isPad: true).inlineChat)
        XCTAssertFalse(WorkspaceChatLayout(
            window: CGSize(width: 932, height: 430),
            container: CGSize(width: 932, height: 400), isPad: false).inlineChat)
    }

    func testUnmeasuredWindowUsesContentSize() {
        XCTAssertTrue(WorkspaceChatLayout(
            window: nil, container: CGSize(width: 1376, height: 1000), isPad: true).inlineChat)
        XCTAssertFalse(WorkspaceChatLayout(
            window: nil, container: CGSize(width: 1032, height: 1300), isPad: true).inlineChat)
    }
}
