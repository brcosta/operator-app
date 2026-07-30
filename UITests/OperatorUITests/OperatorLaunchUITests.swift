import XCTest

final class OperatorLaunchUITests: OperatorUITestCase {
  func testLaunchShowsWorkspaceAndEmptyState() {
    XCTAssertTrue(button("operator.newProject").waitForExistence(timeout: 5))
    XCTAssertFalse(button("operator.activity").exists)
    XCTAssertTrue(app.staticTexts["Build your command center"].waitForExistence(timeout: 3))
    XCTAssertTrue(button("operator.emptyWorkspace.addProject").exists)
  }

  func testNewProjectCanBeCreatedFromToolbar() {
    let project = addProject(named: "UI Test Project")
    XCTAssertFalse(app.staticTexts["operator.projectEditor.title"].exists)
    XCTAssertTrue(project.exists)
  }

  func testEmojiPickerSelectsAProjectEmojiInsideOperator() {
    button("operator.newProject").click()
    let emojiPicker = button("operator.projectEditor.emoji")
    XCTAssertTrue(emojiPicker.waitForExistence(timeout: 3))
    emojiPicker.click()

    let rocket = button("operator.emoji.rocket")
    XCTAssertTrue(rocket.waitForExistence(timeout: 3))
    rocket.click()

    XCTAssertTrue(emojiPicker.waitForExistence(timeout: 3))
    XCTAssertEqual(emojiPicker.value as? String, "🚀")
  }
}
