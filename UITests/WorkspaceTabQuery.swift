import XCTest

@MainActor
func workspaceTab(_ title: String, in app: XCUIApplication) -> XCUIElement {
    let tabBarButton = app.tabBars.buttons[title]
    if tabBarButton.exists { return tabBarButton }
    return app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch
}

/// Search is a tab: selecting it raises the one search field.
@MainActor
func workspaceSearchField(in app: XCUIApplication) -> XCUIElement {
    let field = app.searchFields.firstMatch
    if field.exists { return field }
    let searchTab = app.tabBars.buttons["Search"]
    if searchTab.exists {
        searchTab.tap()
    } else {
        let tab = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Search")).firstMatch
        if tab.exists { tab.tap() }
    }
    _ = field.waitForExistence(timeout: 3)
    return field
}

@MainActor
func workspaceBackButton(in app: XCUIApplication) -> XCUIElement {
    let toolbarBack = app.toolbars.buttons["BackButton"]
    if toolbarBack.exists { return toolbarBack }

    // A split-view detail can put Settings first in the navigation bar; only use an explicit Back control.
    let navigationBack = app.navigationBars.buttons.matching(
        NSPredicate(format: "identifier == 'BackButton' OR label == 'Back'")
    ).firstMatch
    if navigationBack.exists { return navigationBack }

    return app.buttons["BackButton"]
}
