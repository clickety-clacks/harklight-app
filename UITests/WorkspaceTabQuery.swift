import XCTest

@MainActor
func workspaceTab(_ title: String, in app: XCUIApplication) -> XCUIElement {
    let tabBarButton = app.tabBars.buttons[title]
    if tabBarButton.exists { return tabBarButton }
    return app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch
}

@MainActor
func workspaceSearchField(in app: XCUIApplication) -> XCUIElement {
    let field = app.searchFields.firstMatch
    if field.exists { return field }
    let list = app.collectionViews.firstMatch
    if list.exists {
        for _ in 0..<3 {
            list.swipeDown()
            if field.waitForExistence(timeout: 1) { break }
        }
    }
    return field
}

@MainActor
func workspaceBackButton(in app: XCUIApplication) -> XCUIElement {
    let toolbarBack = app.toolbars.buttons["BackButton"]
    return toolbarBack.exists ? toolbarBack : app.navigationBars.buttons.firstMatch
}
