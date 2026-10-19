import UIKit
import XCTest

@MainActor
final class NativeClientDiagnosticsVersionUITests: XCTestCase {
    func testCopiedDiagnosticsReportInstalledAppVersionAndBuild() throws {
        let app = XCUIApplication()
        app.launch()

        let invitation = app.secureTextFields["Full invitation"]
        XCTAssertTrue(invitation.waitForExistence(timeout: 5), app.debugDescription)
        invitation.tap()
        invitation.typeText("harklight://join#invalid")
        app.buttons["Check invitation"].tap()

        XCTAssertTrue(app.staticTexts["Joining could not be confirmed"].waitForExistence(timeout: 5),
                      app.debugDescription)
        let shareDiagnostics = app.buttons["enrollment-client-diagnostics-share"]
        XCTAssertTrue(shareDiagnostics.waitForExistence(timeout: 5), app.debugDescription)
        shareDiagnostics.tap()

        let copy = app.buttons["Copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5), app.debugDescription)
        copy.tap()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allowPaste = springboard.alerts.buttons["Allow Paste"]
        if allowPaste.waitForExistence(timeout: 1) { allowPaste.tap() }
        let copiedText = try XCTUnwrap(UIPasteboard.general.string,
                                       "Copying diagnostics should place the export on the clipboard.")
        XCTAssertTrue(copiedText.contains("Harklight client diagnostics"), copiedText)

        let appVersion = try XCTUnwrap(value(named: "app_version", in: copiedText), copiedText)
        let appBuild = try XCTUnwrap(value(named: "app_build", in: copiedText), copiedText)
        let executableSHA256 = try XCTUnwrap(value(named: "app_executable_sha256", in: copiedText), copiedText)
        XCTAssertFalse(appVersion.isEmpty)
        XCTAssertNotEqual(appVersion, "unavailable")
        XCTAssertFalse(appBuild.isEmpty)
        XCTAssertNotEqual(appBuild, "unavailable")
        XCTAssertTrue(executableSHA256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
                      executableSHA256)

        let metadata = [
            "Harklight client diagnostics",
            "app_version=\(appVersion)",
            "app_build=\(appBuild)",
            "app_executable_sha256=\(executableSHA256)"
        ].joined(separator: "\n")
        print("Copied diagnostics from the installed app:\n\(metadata)")
        let attachment = XCTAttachment(string: metadata)
        attachment.name = "Copied diagnostics app metadata"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func value(named name: String, in text: String) -> String? {
        let prefix = "\(name)="
        guard let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix(prefix) }) else {
            return nil
        }
        return String(line.dropFirst(prefix.count))
    }
}
