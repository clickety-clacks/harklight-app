import XCTest

@MainActor
func workspaceTab(_ title: String, in app: XCUIApplication) -> XCUIElement {
    let tabBarButton = app.tabBars.buttons[title]
    if tabBarButton.exists { return tabBarButton }
    return app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch
}

/// Search belongs to the list: a field, or a search button that raises it.
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

/// Leaves search through the system's close control, which returns to the
/// unfiltered list the person searched.
@MainActor
func leaveWorkspaceSearch(in app: XCUIApplication) {
    for label in ["close", "cancel"] {
        let button = app.buttons.matching(NSPredicate(format: "label ==[c] %@", label)).firstMatch
        if button.exists && button.isHittable {
            button.tap()
            return
        }
    }
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

/// Whether the inbox list stays visible beside an open message (the iPad
/// split) rather than being replaced by it. The list has no search field of
/// its own any more, so this checks the list itself.
@MainActor
func listVisibleBesideDetail(in app: XCUIApplication) -> Bool {
    let list = app.collectionViews.firstMatch
    return list.exists && list.isHittable
}
