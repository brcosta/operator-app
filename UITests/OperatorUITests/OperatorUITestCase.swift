import XCTest

class OperatorUITestCase: XCTestCase {
  var app: XCUIApplication!
  var testRoot: URL!
  var workspaceURL: URL!

  override func setUpWithError() throws {
    continueAfterFailure = false

    testRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("OperatorUITests-\(UUID().uuidString)", isDirectory: true)
    workspaceURL = testRoot.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

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
    nameField.click()
    nameField.typeText(name)
    directoryField.click()
    directoryField.typeText(workspaceURL.path)

    let add = app.buttons["operator.projectEditor.add"]
    XCTAssertTrue(add.isEnabled)
    add.click()

    let project = app.staticTexts[name]
    XCTAssertTrue(project.waitForExistence(timeout: 3))
    return project
  }

  func button(_ identifier: String) -> XCUIElement {
    app.buttons[identifier].firstMatch
  }

  func assertDisappears(_ element: XCUIElement, timeout: TimeInterval = 3) {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: element)
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
  }
}
