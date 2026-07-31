import Foundation
import Testing

@testable import Operator

@MainActor
struct WorkspaceControllerTests {
  @Test func notificationAuthorizationRefreshPromptsOrActivatesSafely() async throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
    let controller = WorkspaceController(store: store)
    var activationCount = 0
    controller.notificationAuthorizationHandler = {
      activationCount += 1
      return true
    }
    controller.notificationAuthorizationStatusHandler = { .notDetermined }

    await controller.refreshNotificationAuthorization()
    #expect(controller.notificationPermissionPrompt == .request)
    #expect(!store.state.notificationsEnabled)

    controller.notificationAuthorizationStatusHandler = { .authorized }
    await controller.refreshNotificationAuthorization()
    #expect(controller.notificationPermissionPrompt == nil)
    #expect(store.state.notificationsEnabled)
    #expect(activationCount == 1)

    controller.notificationAuthorizationStatusHandler = { .denied }
    await controller.refreshNotificationAuthorization()
    #expect(controller.notificationPermissionPrompt == .denied)
    #expect(!store.state.notificationsEnabled)
  }

  @Test func harnessTaskFinishedEventEmitsRoutableNotification() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
    let projectID = store.addProject(name: "Notifications", directory: directory.path)
    let project = try #require(store.state.projects.first)
    let workspace = try #require(project.workspaces.first)
    let controller = WorkspaceController(store: store)
    controller.launch(
      LaunchRequest(
        title: "Harness", command: "/bin/cat", directory: directory.path,
        projectID: projectID, workspaceID: workspace.id, harness: .codex))
    let session = try #require(controller.selectedSession)
    store.setNotificationsEnabled(true)
    var notification: (String, UUID, String, Int32, Bool)?
    controller.taskFinishedNotificationHandler = {
      notification = ($0, $1, $2, $3, $4)
    }

    controller.receiveEvent(
      HarnessEventEnvelope(
        sessionID: session.id, kind: .taskFinished, message: "Finished implementation"))

    #expect(controller.sessionProgress[session.id] == 1)
    #expect(notification?.0 == "Harness")
    #expect(notification?.1 == session.id)
    #expect(notification?.2 == directory.lastPathComponent)
    #expect(notification?.3 == 0)
    #expect(notification?.4 == false)
    controller.close(session)
  }

  @Test func paneNotificationPolicySuppressesOnlyThatPane() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
    let controller = WorkspaceController(store: store)
    controller.launch(LaunchRequest(title: "Muted", command: "/bin/cat", directory: directory.path))
    let session = try #require(controller.selectedSession)
    store.setNotificationsEnabled(true)
    store.setPaneNotificationPolicy(.muted, for: session.id)
    var notificationCount = 0
    controller.questionNotificationHandler = { _, _, _ in notificationCount += 1 }

    controller.receiveQuestion(sessionID: session.id, message: "Should I notify?")

    #expect(notificationCount == 0)
    store.setPaneNotificationPolicy(.attentionOnly, for: session.id)
    controller.receiveQuestion(sessionID: session.id, message: "Now notify")
    #expect(notificationCount == 1)
    controller.close(session)
  }

  @Test func focusedDeletedFilePromptsAndCanCloseItsPane() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let file = directory.appendingPathComponent("tracked.clj")
    try "(println :ready)".write(to: file, atomically: true, encoding: .utf8)
    let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
    store.addProject(name: "Files", directory: directory.path)
    let controller = WorkspaceController(store: store)

    controller.openFile(file.path)
    let paneID = try #require(controller.selectedPaneID)
    try FileManager.default.removeItem(at: file)
    controller.reportOpenFileMissing(paneID: paneID, path: file.path)

    #expect(controller.deletedOpenFilePrompt?.paneID == paneID)
    #expect(controller.deletedOpenFilePrompt?.title == "tracked.clj")
    controller.closeDeletedOpenFilePrompt()
    #expect(controller.deletedOpenFilePrompt == nil)
    #expect(controller.tabs.isEmpty)
  }

  @Test func notificationRevealSwitchesProjectAndFocusesOriginatingSession() throws {
    let root = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(root) }
    let secondDirectory = root.appendingPathComponent("second", isDirectory: true)
    try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
    let store = StateStore(fileURL: root.appendingPathComponent("state.json"))
    let firstID = store.addProject(name: "First", directory: root.path)
    let secondID = store.addProject(name: "Second", directory: secondDirectory.path)
    let controller = WorkspaceController(store: store)
    let first = try #require(store.state.projects.first(where: { $0.id == firstID }))
    let second = try #require(store.state.projects.first(where: { $0.id == secondID }))

    controller.selectProject(firstID)
    controller.launch(
      LaunchRequest(
        title: "Origin", command: "/bin/cat", directory: root.path,
        projectID: firstID, workspaceID: first.workspaces[0].id))
    let originID = try #require(controller.selectedSessionID)
    controller.selectProject(secondID)
    controller.launch(
      LaunchRequest(
        title: "Visible", command: "/bin/cat", directory: secondDirectory.path,
        projectID: secondID, workspaceID: second.workspaces[0].id))

    controller.revealSession(originID)

    #expect(store.state.selectedProjectID == firstID)
    #expect(controller.selectedSessionID == originID)
    for session in controller.allSessions { controller.close(session) }
  }

  @Test func notificationRetryReplacesTheOriginatingSessionWithTheSameLaunchRequest() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
    let projectID = store.addProject(name: "Retry", directory: directory.path)
    let workspace = try #require(store.state.projects.first?.workspaces.first)
    let controller = WorkspaceController(store: store)
    controller.launch(
      LaunchRequest(
        title: "Recoverable", command: "/bin/cat", directory: directory.path,
        projectID: projectID, workspaceID: workspace.id))
    let previous = try #require(controller.selectedSession)

    controller.retrySession(previous.id)

    let replacement = try #require(controller.selectedSession)
    #expect(replacement.id != previous.id)
    #expect(replacement.request.command == "/bin/cat")
    #expect(replacement.request.directory == directory.path)
    #expect(controller.sessions.count == 1)
    controller.close(replacement)
  }

  @Test func notificationsRequireExplicitRuntimeAuthorization() async throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
    let controller = WorkspaceController(store: store)
    var authorizationRequests = 0
    controller.notificationAuthorizationHandler = {
      authorizationRequests += 1
      return true
    }

    #expect(!store.state.notificationsEnabled)
    #expect(authorizationRequests == 0)

    controller.setNotificationsEnabled(true)
    for _ in 0..<20 where !store.state.notificationsEnabled {
      await Task.yield()
    }
    #expect(authorizationRequests == 1)
    #expect(store.state.notificationsEnabled)

    controller.setNotificationsEnabled(false)
    #expect(!store.state.notificationsEnabled)
    #expect(authorizationRequests == 1)
    #expect(!StateStore(fileURL: store.stateFileURL).state.notificationsEnabled)
  }

  @Test func emptyWorkspaceLauncherStartsSelectedHarnessInProjectWorkspace() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
    store.addProject(name: "Agent Task", directory: directory.path)
    let project = try #require(store.state.projects.first)
    let workspace = try #require(project.workspaces.first)
    let controller = WorkspaceController(store: store)

    controller.launchQuickHarness(.claudeCode)
    let claude = try #require(controller.sessions.first)
    #expect(claude.request.directory == workspace.directory)
    #expect(claude.request.projectID == project.id)
    #expect(claude.request.workspaceID == workspace.id)
    #expect(claude.request.harness == .claudeCode)
    #expect(claude.request.command.hasPrefix("claude -n "))

    controller.launchQuickHarness(.codex)
    let codex = try #require(controller.sessions.last)
    #expect(codex.request.harness == .codex)
    #expect(codex.request.command == "codex")
    #expect(controller.sessions.count == 2)
    #expect(codex.title == "Codex")
    #expect(claude.title == "Claude Code")
    #expect(controller.terminalLayout == .terminal(codex.id))

    controller.selectTerminal(claude.id)
    #expect(controller.terminalLayout == .terminal(claude.id))
  }

  @Test func launchingForAnotherProjectSwitchesToItsIndependentSessionGrid() throws {
    let root = try TestSupport.temporaryDirectory()
    let secondDirectory = root.appendingPathComponent("second-project")
    try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
    defer { TestSupport.remove(root) }
    let store = StateStore(fileURL: root.appendingPathComponent("state.json"))
    store.addProject(name: "First", directory: root.path)
    let first = try #require(store.state.projects.first)
    store.addProject(name: "Second", directory: secondDirectory.path)
    let second = try #require(store.state.projects.last)
    let controller = WorkspaceController(store: store)

    controller.selectProject(first.id)
    controller.launchQuickHarness(.codex)
    let firstSession = try #require(controller.sessions.first)

    controller.launch(
      LaunchRequest(
        title: "Second Claude", command: "claude", directory: secondDirectory.path,
        projectID: second.id, workspaceID: second.workspaces[0].id))
    let secondSession = try #require(controller.sessions.first)
    #expect(store.state.selectedProjectID == second.id)
    #expect(secondSession.request.directory == secondDirectory.path)
    #expect(secondSession.request.projectID == second.id)
    #expect(controller.sessions.count == 1)
    #expect(controller.allSessions.count == 2)
    #expect(controller.systemSurfaceState.runningHarnessCount == 2)

    controller.selectProject(first.id)
    #expect(controller.sessions.map(\.id) == [firstSession.id])
    #expect(controller.sessions.first?.request.directory == root.path)
    #expect(controller.allSessions.count == 2)
    #expect(controller.systemSurfaceState.runningHarnessCount == 2)
  }

  @Test func newlyCreatedProjectDoesNotInheritThePreviouslyVisibleTerminalGrid() throws {
    let root = try TestSupport.temporaryDirectory()
    let newDirectory = root.appendingPathComponent("new-project")
    try FileManager.default.createDirectory(at: newDirectory, withIntermediateDirectories: true)
    defer { TestSupport.remove(root) }
    let store = StateStore(fileURL: root.appendingPathComponent("state.json"))
    let firstID = store.addProject(name: "First", directory: root.path)
    let controller = WorkspaceController(store: store)
    controller.launchQuickHarness(.codex)
    #expect(!controller.sessions.isEmpty)

    let newProjectID = store.addProject(name: "New", directory: newDirectory.path)
    controller.selectProject(newProjectID)

    #expect(firstID != newProjectID)
    #expect(controller.sessions.isEmpty)
    #expect(controller.tabs.isEmpty)
    #expect(controller.terminalLayout == nil)
    #expect(controller.selectedSessionID == nil)
  }

  @Test func closingTheLastTerminalReturnsTheProjectToItsEmptyState() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
    store.addProject(name: "Empty Again", directory: directory.path)
    let controller = WorkspaceController(store: store)
    controller.launchQuickHarness(.codex)
    let session = try #require(controller.sessions.first)

    controller.close(session)

    #expect(controller.sessions.isEmpty)
    #expect(controller.tabs.isEmpty)
    #expect(controller.terminalLayout == nil)
    #expect(controller.selectedSessionID == nil)
  }

  @Test func closingTheOnlyTerminalInASplitAlsoClosesItsNowEmptyTab() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
    store.addProject(name: "Split Cleanup", directory: directory.path)
    let controller = WorkspaceController(store: store)
    controller.launchQuickHarness(.codex)
    let session = try #require(controller.sessions.first)
    controller.splitFocusedTerminal(.horizontal)
    #expect(controller.terminalLayout?.emptyPaneIDs.isEmpty == false)

    controller.close(session)

    #expect(controller.sessions.isEmpty)
    #expect(controller.tabs.isEmpty)
    #expect(controller.terminalLayout == nil)
  }

  @Test func activePaneCountIncludesEveryTerminalAcrossProjectTabs() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
    store.addProject(name: "Pane Count", directory: directory.path)
    let project = try #require(store.state.projects.first)
    let controller = WorkspaceController(store: store)
    controller.launchQuickHarness(.codex)
    controller.launchQuickHarness(.claudeCode)
    controller.splitFocusedTerminal(.horizontal)
    let emptyPane = try #require(controller.terminalLayout?.emptyPaneIDs.first)
    controller.launchQuickHarness(.codex, intoPane: emptyPane)

    #expect(controller.activePaneCount(for: project.id) == 3)
  }

  @Test func tabRenameValidatesPersistsAndWorksForInactiveProjects() throws {
    let root = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(root) }
    let stateURL = root.appendingPathComponent("state.json")
    let store = StateStore(fileURL: stateURL)
    let controller = WorkspaceController(store: store)

    let atlasID = store.addProject(name: "Atlas", directory: root.path)
    controller.selectProject(atlasID)
    controller.launchQuickHarness(.codex)
    let atlasTabID = try #require(controller.selectedTabID)

    let beaconDirectory = root.appendingPathComponent("beacon", isDirectory: true)
    try FileManager.default.createDirectory(
      at: beaconDirectory, withIntermediateDirectories: true)
    let beaconID = store.addProject(name: "Beacon", directory: beaconDirectory.path)
    controller.selectProject(beaconID)
    controller.launchQuickHarness(.claudeCode)

    #expect(controller.renameTab(atlasTabID, inProject: atlasID, to: "  Planning  "))
    #expect(store.state.projectTabs[atlasID]?.first?.title == "Planning")

    controller.selectProject(atlasID)
    #expect(controller.tabs.first?.title == "Planning")
    #expect(controller.renameTab(atlasTabID, to: "Daily Driver"))
    #expect(controller.tabs.first?.title == "Daily Driver")

    #expect(!controller.renameTab(atlasTabID, to: "   "))
    #expect(
      !controller.renameTab(
        atlasTabID, to: String(repeating: "x", count: WorkspaceTabTitlePolicy.maximumLength + 1)))
    #expect(!controller.renameTab(UUID(), to: "Missing"))
    #expect(controller.tabs.first?.title == "Daily Driver")

    let reloaded = StateStore(fileURL: stateURL)
    #expect(reloaded.state.projectTabs[atlasID]?.first?.title == "Daily Driver")
  }

  @Test func outputActivityAggregatesSplitPanesAndClearsWhenTabIsRead() throws {
    let root = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(root) }
    let store = StateStore(fileURL: root.appendingPathComponent("state.json"))
    store.addProject(name: "Activity", directory: root.path)
    let controller = WorkspaceController(store: store)

    controller.launchQuickHarness(.codex)
    let first = try #require(controller.sessions.first)
    let tabID = try #require(controller.selectedTabID)
    controller.splitFocusedTerminal(.horizontal)
    let emptyPaneID = try #require(controller.terminalLayout?.emptyPaneIDs.first)
    controller.launchQuickHarness(.claudeCode, intoPane: emptyPaneID)
    let second = try #require(controller.sessions.last)
    let tab = try #require(controller.tabs.first(where: { $0.id == tabID }))

    controller.recordTerminalOutput(sessionID: first.id, isVisible: false)
    #expect(controller.outputActivity(for: tab).isProducingOutput)
    #expect(controller.outputActivity(for: tab).hasUnreadOutput)
    #expect(controller.outputActivityDescription(for: tab) == "Producing unread terminal output")
    #expect(
      TerminalTabActivityVisualState(activity: controller.outputActivity(for: tab))
        == .producingOutput
    )

    controller.finishTerminalOutputBurst(sessionID: first.id)
    #expect(!controller.outputActivity(for: tab).isProducingOutput)
    #expect(controller.outputActivity(for: tab).hasUnreadOutput)
    #expect(controller.outputActivityDescription(for: tab) == "Unread terminal output")
    #expect(
      TerminalTabActivityVisualState(activity: controller.outputActivity(for: tab))
        == .unreadOutput
    )

    controller.recordTerminalOutput(sessionID: second.id, isVisible: true)
    #expect(controller.outputActivity(for: tab).isProducingOutput)
    #expect(controller.outputActivity(for: tab).hasUnreadOutput)

    controller.selectTab(tabID)
    #expect(!controller.outputActivity(for: tab).hasUnreadOutput)
    #expect(controller.outputActivity(for: tab).isProducingOutput)
    controller.finishTerminalOutputBurst(sessionID: second.id)
    #expect(controller.outputActivity(for: tab) == .idle)
    #expect(TerminalTabActivityVisualState(activity: .idle) == .idle)

    controller.recordTerminalOutput(sessionID: UUID(), isVisible: false)
    #expect(controller.sessionOutputActivity.isEmpty)
  }

  @Test func tabsRestoreTheirIndependentSplitLayouts() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
    store.addProject(name: "Tabs", directory: directory.path)
    let controller = WorkspaceController(store: store)

    controller.launchQuickHarness(.codex)
    let first = try #require(controller.sessions.first)
    controller.launchQuickHarness(.claudeCode)
    let second = try #require(controller.sessions.last)
    controller.splitFocusedTerminal(.horizontal)
    let emptyPaneID = try #require(controller.terminalLayout?.emptyPaneIDs.first)
    controller.launchQuickHarness(.codex, intoPane: emptyPaneID)
    let third = try #require(controller.sessions.last)

    let splitTabID = try #require(controller.selectedTabID)
    controller.selectTab(try #require(controller.tabs.first?.id))

    let layout = try #require(controller.terminalLayout)
    #expect(layout == .terminal(first.id))

    controller.selectTab(splitTabID)
    let restored = try #require(controller.terminalLayout)
    #expect(restored.isSplit)
    #expect(restored.contains(second.id))
    #expect(restored.contains(third.id))
    #expect(!restored.contains(first.id))
    #expect(store.state.projectTabs.values.flatMap { $0 }.contains(where: { $0.id == splitTabID }))
  }

  @Test func switchingProjectsRestoresTheSelectedTabsCompleteSplitTree() throws {
    let root = try TestSupport.temporaryDirectory()
    let secondDirectory = root.appendingPathComponent("second")
    try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
    defer { TestSupport.remove(root) }
    let store = StateStore(fileURL: root.appendingPathComponent("state.json"))
    store.addProject(name: "First", directory: root.path)
    let firstProject = try #require(store.state.projects.first)
    store.addProject(name: "Second", directory: secondDirectory.path)
    let secondProject = try #require(store.state.projects.last)
    let controller = WorkspaceController(store: store)

    controller.selectProject(firstProject.id)
    controller.launchQuickHarness(.codex)
    let firstPane = try #require(controller.selectedSessionID)
    controller.splitFocusedTerminal(.vertical)
    let emptyPaneID = try #require(controller.terminalLayout?.emptyPaneIDs.first)
    controller.launchQuickHarness(.claudeCode, intoPane: emptyPaneID)
    let secondPane = try #require(controller.selectedSessionID)
    let firstTabID = try #require(controller.selectedTabID)

    controller.selectProject(secondProject.id)
    controller.launchQuickHarness(.codex)

    controller.selectProject(firstProject.id)
    #expect(controller.selectedTabID == firstTabID)
    #expect(controller.terminalLayout?.isSplit == true)
    #expect(controller.terminalLayout?.contains(firstPane) == true)
    #expect(controller.terminalLayout?.contains(secondPane) == true)
  }

  @Test func restoringProjectRecreatesEveryPaneInItsSavedSplitTab() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
    store.addProject(name: "Restore", directory: directory.path)
    let project = try #require(store.state.projects.first)
    let workspace = try #require(project.workspaces.first)
    let firstID = UUID()
    let secondID = UUID()
    let tabID = UUID()
    let tab = WorkspaceTab(
      id: tabID, title: "Codex",
      layout: .split(.horizontal, .terminal(firstID), .terminal(secondID)),
      focusedSessionID: secondID, splitRatios: ["root": 0.35])
    store.saveTabs([tab], selectedTabID: tabID, for: project.id)
    for (id, title, command, harness, resumeIdentifier) in [
      (firstID, "Codex", "codex", HarnessKind.codex, "codex-session"),
      (secondID, "Claude", "claude", HarnessKind.claudeCode, "operator-restore"),
    ] {
      store.saveSessionRecipe(
        SessionRecipe(
          id: id, projectID: project.id, workspaceID: workspace.id, title: title, command: command,
          environment: [:], harness: harness, resumeIdentifier: resumeIdentifier,
          restoreOnOpen: true,
          tabID: tabID))
    }

    let controller = WorkspaceController(store: store)
    controller.restoreSelectedProject()

    let restoredIDs = Set(controller.sessions.map(\.id))
    #expect(restoredIDs == Set([firstID, secondID]))
    #expect(controller.terminalLayout?.contains(firstID) == true)
    #expect(controller.terminalLayout?.contains(secondID) == true)
    #expect(controller.selectedSessionID == secondID)
    #expect(controller.splitRatio(for: "root") == 0.35)
    controller.setSplitRatio(0.65, for: "root")
    #expect(store.state.projectTabs[project.id]?.first?.splitRatios["root"] == 0.65)
  }

  @Test func customCommandFillsTheRequestedEmptyPaneWithoutCreatingATab() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
    store.addProject(name: "Custom", directory: directory.path)
    let project = try #require(store.state.projects.first)
    let workspace = try #require(project.workspaces.first)
    let controller = WorkspaceController(store: store)

    controller.launchQuickHarness(.codex)
    let firstID = try #require(controller.selectedSessionID)
    let tabID = try #require(controller.selectedTabID)
    controller.splitFocusedTerminal(.horizontal)
    let paneID = try #require(controller.terminalLayout?.emptyPaneIDs.first)
    controller.launch(
      LaunchRequest(
        title: "Shell", command: "fish", directory: workspace.directory, projectID: project.id,
        workspaceID: workspace.id), intoPane: paneID)
    let secondID = try #require(controller.selectedSessionID)

    #expect(controller.tabs.count == 1)
    #expect(controller.selectedTabID == tabID)
    #expect(controller.terminalLayout?.contains(firstID) == true)
    #expect(controller.terminalLayout?.contains(secondID) == true)
    #expect(controller.terminalLayout?.emptyPaneIDs.isEmpty == true)
  }

  @Test func splitTargetsTheFocusedPaneInsteadOfTheMostRecentlyCreatedPane() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
    store.addProject(name: "Focus", directory: directory.path)
    let controller = WorkspaceController(store: store)

    controller.launchQuickHarness(.codex)
    let firstID = try #require(controller.selectedSessionID)
    controller.splitFocusedTerminal(.horizontal)
    let paneID = try #require(controller.terminalLayout?.emptyPaneIDs.first)
    controller.launchQuickHarness(.claudeCode, intoPane: paneID)
    let secondID = try #require(controller.selectedSessionID)

    controller.selectTerminal(firstID)
    controller.splitFocusedTerminal(.vertical)

    guard
      case .split(
        .horizontal, .split(.vertical, .terminal(let left), .empty), .terminal(let right)) =
        controller.terminalLayout
    else {
      Issue.record("Expected the focused first pane to be split")
      return
    }
    #expect(left == firstID)
    #expect(right == secondID)
  }

  @Test func newlyCreatedSplitResetsAnyStaleRatioToAnEvenDivision() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
    store.addProject(name: "Fresh Split", directory: directory.path)
    let controller = WorkspaceController(store: store)

    controller.launchQuickHarness(.codex)
    controller.splitFocusedTerminal(.horizontal)
    controller.setSplitRatio(0.16, for: "root")
    let emptyPane = try #require(controller.terminalLayout?.emptyPaneIDs.first)
    controller.closeEmptyPane(emptyPane)

    controller.splitFocusedTerminal(.horizontal)
    #expect(controller.splitRatio(for: "root") == 0.5)
  }

  @Test func emptyPaneCanBeFocusedAndSplitWithoutCreatingAnotherTab() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
    store.addProject(name: "Empty Pane", directory: directory.path)
    let controller = WorkspaceController(store: store)

    controller.launchQuickHarness(.codex)
    let tabID = try #require(controller.selectedTabID)
    controller.splitFocusedTerminal(.horizontal)
    let emptyPaneID = try #require(controller.terminalLayout?.emptyPaneIDs.first)
    controller.selectEmptyPane(emptyPaneID)

    #expect(controller.selectedSessionID == nil)
    #expect(controller.canSplitFocusedPane)
    controller.splitFocusedTerminal(.vertical)

    #expect(controller.selectedTabID == tabID)
    #expect(controller.tabs.count == 1)
    #expect(controller.terminalLayout?.emptyPaneIDs.count == 2)
    #expect(controller.splitRatio(for: "root.1") == 0.5)
  }

  @Test func defaultShellFillsAnEmptyPaneWithoutOpeningTheCommandPalette() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
    store.addProject(name: "Shell", directory: directory.path)
    let controller = WorkspaceController(store: store)
    controller.launchQuickHarness(.codex)
    let tabID = try #require(controller.selectedTabID)
    controller.splitFocusedTerminal(.horizontal)
    let emptyPaneID = try #require(controller.terminalLayout?.emptyPaneIDs.first)

    controller.launchShell(intoPane: emptyPaneID)

    let shell = try #require(controller.sessions.first { $0.request.harness == .generic })
    #expect(shell.title == "Terminal")
    #expect(shell.request.command == ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
    #expect(controller.selectedTabID == tabID)
    #expect(controller.terminalLayout?.contains(shell.id) == true)
    #expect(controller.terminalLayout?.emptyPaneIDs.contains(emptyPaneID) == false)
  }

  @Test func restorationDropsTabsWhoseSessionsCannotResume() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let stateURL = directory.appendingPathComponent("state.json")
    let store = StateStore(fileURL: stateURL)
    store.addProject(name: "Restore", directory: directory.path)
    let project = try #require(store.state.projects.first)
    let workspace = try #require(project.workspaces.first)
    let staleSessionID = UUID()
    let staleTab = WorkspaceTab(
      id: UUID(), title: "Codex", layout: .terminal(staleSessionID),
      focusedSessionID: staleSessionID)
    store.saveTabs([staleTab], selectedTabID: staleTab.id, for: project.id)
    store.saveSessionRecipe(
      SessionRecipe(
        id: staleSessionID, projectID: project.id, workspaceID: workspace.id, title: "Codex",
        command: "codex", environment: [:], harness: .codex, resumeIdentifier: nil,
        restoreOnOpen: true, tabID: staleTab.id))

    let controller = WorkspaceController(store: StateStore(fileURL: stateURL))
    controller.restoreSelectedProject()

    #expect(controller.sessions.isEmpty)
    #expect(controller.tabs.isEmpty)
    #expect(controller.terminalLayout == nil)
    #expect(controller.store.state.projectTabs[project.id]?.isEmpty == true)
  }

  @Test func persistedFishTabsRestoreWithoutResurrectingOrphanedCommands() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let stateURL = directory.appendingPathComponent("state.json")
    let store = StateStore(fileURL: stateURL)
    store.addProject(name: "Shells", directory: directory.path)
    let project = try #require(store.state.projects.first)
    let workspace = try #require(project.workspaces.first)
    let firstFishID = UUID()
    let secondFishID = UUID()
    let orphanedFishID = UUID()
    let oneShotID = UUID()
    let firstTab = WorkspaceTab(
      id: UUID(), title: "fish", layout: .terminal(firstFishID),
      focusedSessionID: firstFishID)
    let secondTab = WorkspaceTab(
      id: UUID(), title: "fish", layout: .terminal(secondFishID),
      focusedSessionID: secondFishID)
    let unsafeTab = WorkspaceTab(
      id: UUID(), title: "Server", layout: .terminal(oneShotID),
      focusedSessionID: oneShotID)
    store.saveTabs(
      [firstTab, secondTab, unsafeTab], selectedTabID: secondTab.id, for: project.id)

    for (id, title, command, tabID) in [
      (firstFishID, "fish", "fish", firstTab.id),
      (secondFishID, "fish", "/opt/homebrew/bin/fish --login", secondTab.id),
      (orphanedFishID, "old fish", "fish", UUID()),
      (oneShotID, "Server", "npm start", unsafeTab.id),
    ] {
      store.saveSessionRecipe(
        SessionRecipe(
          id: id, projectID: project.id, workspaceID: workspace.id, title: title,
          command: command, environment: [:], harness: .generic, resumeIdentifier: nil,
          restoreOnOpen: false, tabID: tabID))
    }

    let controller = WorkspaceController(store: StateStore(fileURL: stateURL))
    controller.restoreSelectedProject()

    #expect(Set(controller.sessions.map(\.id)) == Set([firstFishID, secondFishID]))
    #expect(controller.sessions.allSatisfy { $0.request.harness == .generic })
    #expect(controller.tabs.count == 2)
    #expect(controller.tabs.contains(where: { $0.layout.contains(orphanedFishID) }) == false)
    #expect(controller.tabs.contains(where: { $0.layout.contains(oneShotID) }) == false)
  }

  @Test func fiveProjectsRestoreIndependentTabsAndSplitPanes() throws {
    let root = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(root) }
    let stateURL = root.appendingPathComponent("state.json")
    let store = StateStore(fileURL: stateURL)
    let controller = WorkspaceController(store: store)
    var splitTabs: [UUID: UUID] = [:]

    for name in ["Atlas", "Beacon", "Comet", "Delta", "Echo"] {
      let directory = root.appendingPathComponent(name.lowercased(), isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let projectID = store.addProject(name: name, directory: directory.path)
      let project = try #require(store.state.projects.first(where: { $0.id == projectID }))
      let workspace = try #require(project.workspaces.first)
      controller.selectProject(project.id)
      controller.launch(
        LaunchRequest(
          title: "\(name) Shell A", command: "/bin/zsh -l", directory: workspace.directory,
          projectID: project.id, workspaceID: workspace.id))
      let splitTabID = try #require(controller.selectedTabID)
      controller.splitFocusedTerminal(.horizontal)
      let emptyPaneID = try #require(controller.terminalLayout?.emptyPaneIDs.first)
      controller.launch(
        LaunchRequest(
          title: "\(name) Split Shell", command: "/bin/zsh -l", directory: workspace.directory,
          projectID: project.id, workspaceID: workspace.id),
        intoPane: emptyPaneID)
      controller.launch(
        LaunchRequest(
          title: "\(name) Shell B", command: "/bin/zsh -l", directory: workspace.directory,
          projectID: project.id, workspaceID: workspace.id))
      controller.selectTab(splitTabID)
      splitTabs[project.id] = splitTabID

      #expect(controller.sessions.count == 3)
      #expect(controller.tabs.count == 2)
      #expect(
        controller.tabs.first(where: { $0.id == splitTabID })?.layout.terminalIDs.count == 2)
    }

    let restoredStore = StateStore(fileURL: stateURL)
    let restored = WorkspaceController(store: restoredStore)
    for project in restoredStore.state.projects {
      restored.selectProject(project.id)
      let splitTabID = try #require(splitTabs[project.id])
      #expect(restored.sessions.count == 3)
      #expect(restored.tabs.count == 2)
      #expect(
        restored.tabs.first(where: { $0.id == splitTabID })?.layout.terminalIDs.count == 2)
    }
    #expect(restored.allSessions.count == 15)
  }

  @Test func sidebarTabNavigationSwitchesProjectsAndRejectsStaleTargets() throws {
    let root = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(root) }
    let store = StateStore(fileURL: root.appendingPathComponent("state.json"))
    let controller = WorkspaceController(store: store)

    let atlasDirectory = root.appendingPathComponent("atlas", isDirectory: true)
    let beaconDirectory = root.appendingPathComponent("beacon", isDirectory: true)
    try FileManager.default.createDirectory(
      at: atlasDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: beaconDirectory, withIntermediateDirectories: true)
    let atlasID = store.addProject(name: "Atlas", directory: atlasDirectory.path)
    let beaconID = store.addProject(name: "Beacon", directory: beaconDirectory.path)
    let atlas = try #require(store.state.projects.first(where: { $0.id == atlasID }))
    let beacon = try #require(store.state.projects.first(where: { $0.id == beaconID }))
    let atlasWorkspace = try #require(atlas.workspaces.first)
    let beaconWorkspace = try #require(beacon.workspaces.first)

    controller.selectProject(atlasID)
    controller.launch(
      LaunchRequest(
        title: "Atlas One", command: "/bin/zsh -l", directory: atlasWorkspace.directory,
        projectID: atlasID, workspaceID: atlasWorkspace.id))
    let atlasFirstTab = try #require(controller.selectedTabID)
    let atlasFirstSession = try #require(controller.selectedSessionID)
    controller.launch(
      LaunchRequest(
        title: "Atlas Two", command: "/bin/zsh -l", directory: atlasWorkspace.directory,
        projectID: atlasID, workspaceID: atlasWorkspace.id))

    controller.selectProject(beaconID)
    controller.launch(
      LaunchRequest(
        title: "Beacon One", command: "/bin/zsh -l", directory: beaconWorkspace.directory,
        projectID: beaconID, workspaceID: beaconWorkspace.id))
    let beaconTab = try #require(controller.selectedTabID)

    #expect(controller.tabs(forProjectID: atlasID).count == 2)
    #expect(controller.tabs(forProjectID: beaconID).map(\.id) == [beaconTab])
    #expect(controller.selectTab(atlasFirstTab, inProject: atlasID))
    #expect(store.state.selectedProjectID == atlasID)
    #expect(controller.selectedTabID == atlasFirstTab)
    #expect(controller.selectedSessionID == atlasFirstSession)
    #expect(controller.terminalLayout?.contains(atlasFirstSession) == true)

    let selectedProjectID = store.state.selectedProjectID
    let selectedTabID = controller.selectedTabID
    #expect(controller.selectTab(UUID(), inProject: beaconID) == false)
    #expect(controller.selectTab(atlasFirstTab, inProject: beaconID) == false)
    #expect(store.state.selectedProjectID == selectedProjectID)
    #expect(controller.selectedTabID == selectedTabID)
  }

  @Test func harnessLayoutCommandTargetsTheIssuingPaneInsteadOfTheVisiblePane() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
    store.addProject(name: "Targeted Layout", directory: directory.path)
    let controller = WorkspaceController(store: store)

    controller.launchQuickHarness(.codex)
    let issuingSessionID = try #require(controller.selectedSessionID)
    controller.launchQuickHarness(.claudeCode)
    let visibleSessionID = try #require(controller.selectedSessionID)

    controller.applyLayout(command: "split-bottom", sessionID: issuingSessionID)

    #expect(controller.selectedSessionID == issuingSessionID)
    #expect(controller.terminalLayout?.contains(issuingSessionID) == true)
    #expect(controller.terminalLayout?.contains(visibleSessionID) == false)
    #expect(controller.terminalLayout?.isSplit == true)
  }

  @Test func exitedSessionOffersPaneClosureAndCanBeRemoved() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
    store.addProject(name: "Exit", directory: directory.path)
    let controller = WorkspaceController(store: store)

    controller.launchQuickHarness(.codex)
    let session = try #require(controller.selectedSession)
    session.didExit(code: 0)

    #expect(controller.exitClosePromptSessionID == session.id)
    #expect(controller.exitClosePromptSession?.id == session.id)
    controller.close(session)
    #expect(controller.sessions.isEmpty)
    #expect(controller.exitClosePromptSessionID == nil)
  }

  @Test func managedResumeKeepsWorkspaceAndTaskBrief() throws {
    let directory = try TestSupport.temporaryDirectory()
    let worktree = directory.appendingPathComponent("worktree")
    try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    defer { TestSupport.remove(directory) }
    let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
    store.addProject(name: "Task", directory: directory.path)
    let project = try #require(store.state.projects.first)
    let originalID = UUID()
    store.addWorkspace(name: "Worktree", directory: worktree.path, to: project.id)
    let workspace = try #require(store.state.projects.first?.workspaces.last)
    let original = LaunchRequest(
      title: "Claude", command: "claude", directory: worktree.path, projectID: project.id,
      workspaceID: workspace.id
    )
    .preparedForNewSession(id: originalID, projectName: project.name)
    store.recordStart(original, id: originalID)
    store.saveTaskBrief(
      sessionID: originalID, objective: "Update service", constraints: "Use this worktree",
      acceptanceCriteria: "Tests pass", title: "Claude")
    let controller = WorkspaceController(store: store)
    controller.resume(try #require(store.state.recentSessions.first))
    let resumed = try #require(controller.sessions.first)
    #expect(resumed.request.directory == worktree.path)
    #expect(controller.taskBrief(for: resumed)?.objective == "Update service")
  }

  @Test func claudeHookSessionSwitchUpdatesRecipeAndRecentResumeState() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let stateURL = directory.appendingPathComponent("state.json")
    let store = StateStore(fileURL: stateURL)
    store.addProject(name: "Claude Sync", directory: directory.path)
    let controller = WorkspaceController(store: store)
    controller.launchQuickHarness(.claudeCode)
    let session = try #require(controller.selectedSession)
    let switchedIdentifier = "4e92e921-1454-4b5d-a62a-4c71d31b47f4"

    controller.receiveEvent(
      HarnessEventEnvelope(
        sessionID: session.id, kind: .childStarted, message: "Claude Code session started",
        resumeIdentifier: switchedIdentifier))

    #expect(store.state.sessionRecipes.first?.resumeIdentifier == switchedIdentifier)
    #expect(store.state.recentSessions.first?.resumeIdentifier == switchedIdentifier)
    let reloaded = StateStore(fileURL: stateURL)
    #expect(reloaded.state.sessionRecipes.first?.resumeIdentifier == switchedIdentifier)
    #expect(reloaded.state.recentSessions.first?.resumeIdentifier == switchedIdentifier)
  }

  @Test func codexHookThreadSwitchUpdatesRecipeAndRecentResumeState() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let stateURL = directory.appendingPathComponent("state.json")
    let store = StateStore(fileURL: stateURL)
    store.addProject(name: "Codex Sync", directory: directory.path)
    let controller = WorkspaceController(store: store)
    controller.launchQuickHarness(.codex)
    let session = try #require(controller.selectedSession)
    let switchedIdentifier = "0199a213-81c0-7800-8aa1-bbab2a035a53"

    controller.receiveEvent(
      HarnessEventEnvelope(
        sessionID: session.id, kind: .childStarted, message: "Codex session started",
        resumeIdentifier: switchedIdentifier))

    #expect(store.state.sessionRecipes.first?.resumeIdentifier == switchedIdentifier)
    #expect(store.state.recentSessions.first?.resumeIdentifier == switchedIdentifier)
    let reloaded = StateStore(fileURL: stateURL)
    #expect(reloaded.state.sessionRecipes.first?.resumeIdentifier == switchedIdentifier)
    #expect(reloaded.state.recentSessions.first?.resumeIdentifier == switchedIdentifier)
  }

  @Test func statusBarTracksFocusedHarnessAndQuestionRouting() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
    store.addProject(name: "Status", directory: directory.path)
    let project = try #require(store.state.projects.first)
    let workspace = try #require(project.workspaces.first)
    let controller = WorkspaceController(store: store)
    controller.launch(
      LaunchRequest(
        title: "Agent One", command: "echo one", directory: workspace.directory,
        projectID: project.id, workspaceID: workspace.id))
    controller.launch(
      LaunchRequest(
        title: "Agent Two", command: "echo two", directory: workspace.directory,
        projectID: project.id, workspaceID: workspace.id))
    let first = controller.sessions[0]
    let second = controller.sessions[1]
    controller.selectTerminal(first.id)
    controller.enqueueQuestion(sessionID: second.id, message: "Choose an API version")
    #expect(controller.statusBarState.sessionTitle == "Agent One")
    #expect(controller.statusBarState.workspaceName == "Status")
    #expect(controller.statusBarState.agentCount == 2)
    #expect(controller.statusBarState.question?.sessionID == second.id)
    controller.focusQuestion(try #require(controller.statusBarState.question))
    #expect(controller.selectedSessionID == second.id)
    #expect(controller.statusBarState.question?.sessionID == second.id)
  }

  @Test func agentPaneStatePrioritizesQuestionsReviewOutputAndFailures() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
    let controller = WorkspaceController(store: store)
    controller.launch(LaunchRequest(title: "Agent", command: "/bin/cat", directory: directory.path))
    let session = try #require(controller.selectedSession)

    #expect(controller.paneState(for: session) == .idle)
    controller.receiveEvent(HarnessEventEnvelope(sessionID: session.id, kind: .taskFinished))
    #expect(controller.paneState(for: session) == .awaitingReview)
    controller.receiveQuestion(sessionID: session.id, message: "Review this?")
    #expect(controller.paneState(for: session) == .needsAnswer)
    let question = try #require(controller.questions.first)
    controller.answerQuestion(question, answer: "yes")
    #expect(controller.paneState(for: session) == .awaitingReview)
    controller.recordTerminalOutput(sessionID: session.id, isVisible: true)
    #expect(controller.paneState(for: session) == .running)
    session.didExit(code: 1)
    #expect(controller.paneState(for: session) == .failed)
  }

  @Test func revealingQuestionRoutesToHarnessWithoutResolvingIt() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
    let controller = WorkspaceController(store: store)
    controller.launch(LaunchRequest(title: "Agent", command: "echo one", directory: directory.path))
    let session = try #require(controller.sessions.first)
    _ = controller.enqueueQuestion(sessionID: session.id, message: "Continue?")
    let question = try #require(controller.questions.first)

    controller.revealQuestion(question)
    #expect(controller.selectedSessionID == session.id)
    #expect(controller.questions.contains(question))
  }

  @Test func managedResumeRejectsMissingWorkspaceDirectory() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let missing = directory.appendingPathComponent("removed-worktree")
    let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
    store.addProject(name: "Task", directory: directory.path)
    let project = try #require(store.state.projects.first)
    store.addWorkspace(name: "Removed", directory: missing.path, to: project.id)
    let workspace = try #require(store.state.projects.first?.workspaces.last)
    let id = UUID()
    let request = LaunchRequest(
      title: "Claude", command: "claude", directory: missing.path, projectID: project.id,
      workspaceID: workspace.id
    )
    .preparedForNewSession(id: id, projectName: project.name)
    store.recordStart(request, id: id)
    let controller = WorkspaceController(store: store)
    controller.resume(try #require(store.state.recentSessions.first))
    #expect(controller.sessions.isEmpty)
    #expect(controller.alertMessage?.contains("does not exist") == true)
  }

  @Test func managedResumeRejectsOrphanedProjectOrWorkspaceReference() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
    let orphaned = RecentSession(
      id: UUID(), title: "Claude", command: "claude", projectID: UUID(), workspaceID: UUID(),
      directory: directory.path, startedAt: .now, endedAt: nil, exitCode: nil, status: .exited,
      harness: .claudeCode, managedSessionName: "operator-orphan", environment: [:])
    let controller = WorkspaceController(store: store)
    controller.resume(orphaned)
    #expect(controller.sessions.isEmpty)
    #expect(controller.alertMessage?.contains("no longer has its project") == true)
  }

  @Test func concurrentHarnessTabsKeepSeparateWorkspacesAndBriefs() throws {
    let directory = try TestSupport.temporaryDirectory()
    let serviceA = directory.appendingPathComponent("service-a")
    let serviceB = directory.appendingPathComponent("service-b")
    try FileManager.default.createDirectory(at: serviceA, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: serviceB, withIntermediateDirectories: true)
    defer { TestSupport.remove(directory) }
    let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
    store.addProject(name: "Task", directory: serviceA.path)
    let project = try #require(store.state.projects.first)
    let controller = WorkspaceController(store: store)
    controller.launch(
      LaunchRequest(
        title: "Codex A", command: "codex", directory: serviceA.path, projectID: project.id))
    controller.launch(
      LaunchRequest(
        title: "Claude B", command: "claude", directory: serviceB.path, projectID: project.id))
    let first = controller.sessions[0]
    let second = controller.sessions[1]
    controller.saveTaskBrief(
      for: first, objective: "Service A", constraints: "A only", acceptanceCriteria: "A passes")
    controller.saveTaskBrief(
      for: second, objective: "Service B", constraints: "B only", acceptanceCriteria: "B passes")
    #expect(controller.sessions.count == 2)
    #expect(first.request.directory == serviceA.path)
    #expect(second.request.directory == serviceB.path)
    #expect(controller.taskBrief(for: first)?.objective == "Service A")
    #expect(controller.taskBrief(for: second)?.objective == "Service B")
  }

  @Test func markdownTabsAreReusedAndClosingFocusedDocumentClearsSelection() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let markdown = directory.appendingPathComponent("brief.md")
    try "# Brief".write(to: markdown, atomically: true, encoding: .utf8)
    let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
    let controller = WorkspaceController(store: store)

    controller.openMarkdown(markdown.path)
    controller.openMarkdown(markdown.path)
    #expect(controller.markdownDocuments.count == 1)
    controller.closeMarkdown(try #require(controller.selectedMarkdownDocument))
    #expect(controller.selectedMarkdownPath == nil)

  }

  @Test func markdownAndSourceFilesArePersistedFirstClassProjectTabs() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let markdown = directory.appendingPathComponent("README.md")
    let source = directory.appendingPathComponent("App.swift")
    try "# Project".write(to: markdown, atomically: true, encoding: .utf8)
    try "struct App {}".write(to: source, atomically: true, encoding: .utf8)
    let stateURL = directory.appendingPathComponent("state.json")
    let store = StateStore(fileURL: stateURL)
    store.addProject(name: "Project", directory: directory.path)
    let controller = WorkspaceController(store: store)

    controller.openMarkdown(markdown.path)
    #expect(controller.tabs.count == 1)
    #expect(controller.tabs.first?.contentKind == .markdown)
    #expect(controller.tabs.first?.layout.firstMarkdownPane?.path == markdown.path)

    controller.openFile(source.path)
    #expect(controller.tabs.count == 2)
    #expect(controller.selectedTab?.contentKind == .file)
    let sourcePaneID = try #require(controller.selectedTab?.layout.firstFilePane?.id)

    let secondSource = directory.appendingPathComponent("Support.swift")
    try "let supported = true".write(to: secondSource, atomically: true, encoding: .utf8)
    controller.openFile(secondSource.path)
    #expect(controller.tabs.count == 2)
    #expect(controller.selectedTab?.layout.firstFilePane?.id == sourcePaneID)
    #expect(controller.selectedTab?.layout.firstFilePane?.path == secondSource.path)

    let reloaded = WorkspaceController(store: StateStore(fileURL: stateURL))
    #expect(reloaded.tabs.count == 2)
    #expect(reloaded.tabs.contains { $0.contentKind == .markdown })
    #expect(
      reloaded.tabs.contains {
        $0.layout.firstFilePane?.path == secondSource.path
      })
  }

  @Test func markdownCanFillAnEmptySplitBesideATerminal() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let markdown = directory.appendingPathComponent("notes.md")
    try "# Notes".write(to: markdown, atomically: true, encoding: .utf8)
    let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
    store.addProject(name: "Project", directory: directory.path)
    let controller = WorkspaceController(store: store)
    controller.launch(
      LaunchRequest(title: "Shell", command: "cat", directory: directory.path))
    let session = try #require(controller.sessions.first)

    controller.splitFocusedTerminal(.vertical)
    let emptyPaneID = try #require(controller.terminalLayout?.emptyPaneIDs.first)
    controller.selectEmptyPane(emptyPaneID)
    controller.openMarkdown(markdown.path)

    #expect(controller.tabs.count == 1)
    #expect(controller.selectedTab?.contentKind == .mixed)
    #expect(controller.terminalLayout?.terminalIDs == [session.id])
    #expect(controller.terminalLayout?.markdownPane(forPath: markdown.path)?.id == emptyPaneID)
    #expect(controller.selectedPaneID == emptyPaneID)
    controller.close(session)
  }

  @Test func questionBadgesCountPerTabAndProjectThenClearAfterAnswer() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
    store.addProject(name: "Project", directory: directory.path)
    let project = try #require(store.state.projects.first)
    let controller = WorkspaceController(store: store)
    controller.launch(
      LaunchRequest(
        title: "Agent", command: "cat", directory: directory.path, projectID: project.id,
        workspaceID: project.workspaces.first?.id))
    let session = try #require(controller.sessions.first)
    let tab = try #require(controller.selectedTab)
    controller.enqueueQuestion(sessionID: session.id, message: "Continue?")
    let question = try #require(controller.questions.first)

    #expect(controller.questionCount(for: tab) == 1)
    #expect(controller.questionCount(forProjectID: project.id) == 1)
    controller.answerQuestion(question, answer: "yes")
    #expect(controller.questionCount(for: tab) == 0)
    #expect(controller.questionCount(forProjectID: project.id) == 0)
    controller.close(session)
  }

  @Test func duplicateRestartAndCloseKeepSessionAndLayoutStateConsistent() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
    let controller = WorkspaceController(store: store)
    controller.launch(LaunchRequest(title: "Agent", command: "echo one", directory: directory.path))
    let original = try #require(controller.sessions.first)
    controller.duplicate(original)
    #expect(controller.sessions.count == 2)
    controller.restart(original)
    #expect(controller.sessions.count == 2)
    #expect(!controller.sessions.contains { $0.id == original.id })
    let remaining = controller.sessions[0]
    controller.close(remaining)
    #expect(controller.sessions.count == 1)
    #expect(controller.terminalLayout?.contains(controller.sessions[0].id) == true)
    controller.close(controller.sessions[0])
    #expect(controller.terminalLayout == nil)
  }
}
