import XCTest

final class OperatorWorkflowUITests: OperatorUITestCase {
  func testRealCodexSessionsKeepKeyboardFocusAfterTabSwitching() throws {
    addProject(named: "Codex Focus Project")

    let initialCodex = button("operator.emptyWorkspace.startCodex")
    XCTAssertTrue(initialCodex.waitForExistence(timeout: 3))
    XCTAssertTrue(initialCodex.isEnabled, "Codex is installed locally but unavailable to Operator")
    initialCodex.click()

    let codexTabs = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Codex,"))
    XCTAssertTrue(codexTabs.element(boundBy: 0).waitForExistence(timeout: 10))

    let newHarness = app.descendants(matching: .any)["operator.newHarness"]
    XCTAssertTrue(newHarness.waitForExistence(timeout: 3))

    func startAnotherCodex() {
      let codex = app.menuItems["Start Codex"]
      var menuOpened = false
      for _ in 0..<3 {
        newHarness.click()
        if codex.waitForExistence(timeout: 1) {
          menuOpened = true
          break
        }
      }
      XCTAssertTrue(menuOpened, "Could not open the New Session menu")
      guard codex.isEnabled else {
        XCTFail("Codex is installed locally but unavailable to Operator")
        return
      }
      codex.click()
    }

    startAnotherCodex()
    XCTAssertTrue(codexTabs.element(boundBy: 1).waitForExistence(timeout: 10))

    // Do not submit an agent prompt. A double interrupt is a safe way to close
    // Codex at either its startup or normal prompt, and proves key delivery.
    let firstCodex = codexTabs.element(boundBy: 0)
    let secondCodex = codexTabs.element(boundBy: 1)
    firstCodex.click()
    secondCodex.click()
    firstCodex.click()
    app.typeKey("c", modifierFlags: .control)
    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    app.typeKey("c", modifierFlags: .control)

    let codexFinished = expectation(
      for: NSPredicate(format: "label CONTAINS %@", "Finished"),
      evaluatedWith: firstCodex)
    wait(for: [codexFinished], timeout: 10)
  }

  func testRealClaudeSessionsKeepKeyboardFocusAfterTabSwitching() throws {
    addProject(named: "Claude Focus Project")

    let initialClaude = button("operator.emptyWorkspace.startClaude")
    XCTAssertTrue(initialClaude.waitForExistence(timeout: 3))
    XCTAssertTrue(initialClaude.isEnabled, "Claude Code is installed locally but unavailable to Operator")
    initialClaude.click()

    let claudeTabs = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Claude Code,"))
    XCTAssertTrue(claudeTabs.element(boundBy: 0).waitForExistence(timeout: 10))

    let newHarness = app.descendants(matching: .any)["operator.newHarness"]
    XCTAssertTrue(newHarness.waitForExistence(timeout: 3))

    func startAnotherClaude() {
      let claude = app.menuItems["Start Claude Code"]
      var menuOpened = false
      for _ in 0..<3 {
        newHarness.click()
        if claude.waitForExistence(timeout: 1) {
          menuOpened = true
          break
        }
      }
      XCTAssertTrue(menuOpened, "Could not open the New Session menu")
      guard claude.isEnabled else {
        XCTFail("Claude Code is installed locally but unavailable to Operator")
        return
      }
      claude.click()
    }

    startAnotherClaude()
    XCTAssertTrue(claudeTabs.element(boundBy: 1).waitForExistence(timeout: 10))

    // This is a real Claude Code process, not a shell stand-in. Claude treats
    // the first interrupt as cancel and the second as exit; neither submits a
    // prompt. A Finished tab proves both events reached the returned pane.
    let firstClaude = claudeTabs.element(boundBy: 0)
    let secondClaude = claudeTabs.element(boundBy: 1)
    firstClaude.click()
    secondClaude.click()
    firstClaude.click()
    app.typeKey("c", modifierFlags: .control)
    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    app.typeKey("c", modifierFlags: .control)

    let claudeFinished = expectation(
      for: NSPredicate(format: "label CONTAINS %@", "Finished"),
      evaluatedWith: firstClaude)
    wait(for: [claudeFinished], timeout: 10)
  }

  func testSwitchingTabsKeepsTheVisibleTerminalAsKeyboardFirstResponder() {
    addProject(named: "Focus Project")
    let firstCommand = "/bin/sh -c 'read value; exit 0'"

    launchInteractiveSession(title: "First focus session", command: firstCommand)
    launchInteractiveSession(title: "Second focus session", command: "/bin/sh -c 'sleep 20'")

    let firstTab = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@", "First focus session,"))
      .firstMatch
    let secondTab = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Second focus session,"))
      .firstMatch
    XCTAssertTrue(firstTab.waitForExistence(timeout: 3))
    XCTAssertTrue(secondTab.waitForExistence(timeout: 3))

    // This is deliberately an application-level test: it exercises the real SwiftUI host
    // teardown/reparenting sequence and proves keystrokes reach the active PTY after switches.
    firstTab.click()
    secondTab.click()
    firstTab.click()
    app.typeText("focus-restored\n")

    let terminalFinished = expectation(
      for: NSPredicate(format: "label CONTAINS %@", "Finished"),
      evaluatedWith: firstTab)
    wait(for: [terminalFinished], timeout: 5)
  }

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
    addProject(named: "Activity Project")

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
    let shortcutsSection = button("operator.settings.section.shortcuts")
    XCTAssertTrue(shortcutsSection.waitForExistence(timeout: 3))
    shortcutsSection.click()
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
