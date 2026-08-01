import AppKit
import XCTest

class OperatorUITestCase: XCTestCase {
  var app: XCUIApplication!
  var testRoot: URL!
  var workspaceURL: URL!

  override func setUpWithError() throws {
    continueAfterFailure = false

    testRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("OperatorUITests-\(UUID().uuidString)", isDirectory: true)
    // The test runner is sandboxed but Operator is launched as a separate app.
    // Use the checkout itself as a pre-existing directory both can access.
    workspaceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)

    app = XCUIApplication()
    app.launchArguments = ["--ui-testing"]
    app.launchEnvironment["OPERATOR_STATE_PATH"] =
      testRoot.appendingPathComponent("state.json").path
    app.launch()

    XCTAssertTrue(app.windows["Operator"].waitForExistence(timeout: 5))
  }

  override func tearDownWithError() throws {
    app?.terminate()
    if let testRoot {
      try? FileManager.default.removeItem(at: testRoot)
    }
  }

  @discardableResult
  func addProject(named name: String) -> XCUIElement {
    let addProject = button("operator.newProject")
    XCTAssertTrue(addProject.waitForExistence(timeout: 3))
    addProject.click()

    let title = app.staticTexts["operator.projectEditor.title"]
    XCTAssertTrue(title.waitForExistence(timeout: 3))

    let nameField = app.textFields["operator.projectEditor.name"]
    let directoryField = app.textFields["operator.projectEditor.directory"]
    replaceText(in: nameField, with: name)
    replaceText(in: directoryField, with: workspaceURL.path)
    XCTAssertEqual(
      directoryField.value as? String, workspaceURL.path,
      "The project directory field did not receive the intended path")

    let add = app.buttons["operator.projectEditor.add"]
    XCTAssertTrue(add.isEnabled)
    add.click()

    let validationError = app.staticTexts["operator.projectEditor.error"]
    if validationError.waitForExistence(timeout: 1) {
      XCTFail(
        "Project creation failed: label=\(validationError.label), value=\(String(describing: validationError.value))")
    }
    assertDisappears(title)
    return addProject
  }

  func button(_ identifier: String) -> XCUIElement {
    app.buttons[identifier].firstMatch
  }

  func assertDisappears(_ element: XCUIElement, timeout: TimeInterval = 3) {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: element)
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
  }

  func replaceText(in field: XCUIElement, with text: String) {
    field.click()
    field.typeKey("a", modifierFlags: .command)
    NSPasteboard.general.clearContents()
    XCTAssertTrue(NSPasteboard.general.setString(text, forType: .string))
    field.typeKey("v", modifierFlags: .command)
  }

  func waitForFile(_ url: URL, timeout: TimeInterval = 3) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: url.path) },
      object: nil)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  func launchInteractiveSession(title: String, command: String) {
    app.typeKey("k", modifierFlags: .command)
    XCTAssertTrue(app.staticTexts["operator.commandPalette.title"].waitForExistence(timeout: 3))

    let commandField = app.textFields["operator.commandPalette.command"]
    replaceText(in: commandField, with: command)
    let titleField = app.textFields["operator.commandPalette.sessionTitle"]
    replaceText(in: titleField, with: title)
    let run = app.buttons["operator.commandPalette.run"]
    XCTAssertTrue(run.isEnabled)
    run.click()
    XCTAssertTrue(
      app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(title),"))
        .firstMatch.waitForExistence(timeout: 5))
  }
}
