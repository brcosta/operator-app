import XCTest

final class OperatorWorkflowUITests: OperatorUITestCase {
  func testCommandPaletteLaunchesARealTerminalSession() {
    addProject(named: "Terminal Project")

    app.typeKey("k", modifierFlags: .command)
    XCTAssertTrue(app.staticTexts["operator.commandPalette.title"].waitForExistence(timeout: 3))

    let command = app.textFields["operator.commandPalette.command"]
    command.click()
    command.typeText("/bin/sh -c 'printf operator-ui-ready; sleep 8'")

    let title = app.textFields["operator.commandPalette.sessionTitle"]
    title.click()
    title.typeText("UI Smoke Session")

    let run = app.buttons["operator.commandPalette.run"]
    XCTAssertTrue(run.isEnabled)
    run.click()

    XCTAssertTrue(button("operator.session").waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["No active sessions"].exists)
  }

  func testActivityAndShortcutSheetsOpenAndDismiss() {
    let activity = button("operator.activity")
    XCTAssertTrue(activity.waitForExistence(timeout: 3))
    activity.click()
    let activityDone = button("operator.activity.done")
    XCTAssertTrue(activityDone.waitForExistence(timeout: 3))
    activityDone.click()
    assertDisappears(activityDone)

    let shortcuts = button("operator.shortcuts")
    XCTAssertTrue(shortcuts.waitForExistence(timeout: 3))
    shortcuts.click()
    let shortcutsDone = button("operator.shortcuts.done")
    XCTAssertTrue(shortcutsDone.waitForExistence(timeout: 3))
    XCTAssertTrue(
      app.descendants(matching: .any)["operator.settings.appearance"].waitForExistence(timeout: 3)
    )
    XCTAssertTrue(app.staticTexts["New Session"].exists)
    XCTAssertTrue(app.staticTexts["Next Project"].exists)
    shortcutsDone.click()
    assertDisappears(shortcutsDone)
  }

  func testConfiguredKeyboardShortcutsPresentPrimaryWorkflows() {
    app.typeKey("n", modifierFlags: [.command, .shift])
    XCTAssertTrue(app.staticTexts["operator.projectEditor.title"].waitForExistence(timeout: 3))
    button("operator.projectEditor.cancel").click()

    addProject(named: "Shortcut Project")
    app.typeKey("a", modifierFlags: [.command, .shift])
    XCTAssertTrue(app.staticTexts["operator.activity.title"].waitForExistence(timeout: 3))
    button("operator.activity.done").click()

    app.typeKey("k", modifierFlags: .command)
    XCTAssertTrue(app.staticTexts["operator.commandPalette.title"].waitForExistence(timeout: 3))
    button("operator.commandPalette.cancel").click()
  }
}
