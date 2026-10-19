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

        let previewQuery = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "app_version="))
        let preview = previewQuery.firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5), app.debugDescription)
        let sharedText = preview.label
        XCTAssertTrue(sharedText.contains("Harklight client diagnostics"), sharedText)

        let appVersion = try XCTUnwrap(value(named: "app_version", in: sharedText), sharedText)
        let appBuild = try XCTUnwrap(value(named: "app_build", in: sharedText), sharedText)
        let executableSHA256 = try XCTUnwrap(value(named: "app_executable_sha256", in: sharedText), sharedText)
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

        let copy = app.cells["Copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5), app.debugDescription)
        copy.tap()
        XCTAssertTrue(shareDiagnostics.isHittable,
                      "Copying diagnostics should return to the app's diagnostic action.")
    }

    private func value(named name: String, in text: String) -> String? {
        let prefix = "\(name)="
        guard let token = text.split(whereSeparator: \.isWhitespace).first(where: { $0.hasPrefix(prefix) }) else {
            return nil
        }
        return String(token.dropFirst(prefix.count))
    }
}
