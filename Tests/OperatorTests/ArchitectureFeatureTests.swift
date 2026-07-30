import Foundation
import Testing

@testable import Operator

struct HarnessAdapterTests {
  @Test func adaptersDetectAndBuildSupportedResumeCommands() throws {
    let id = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
    let claude = LaunchRequest(title: "Claude", command: "claude", directory: "/tmp")
      .preparedForNewSession(id: id, projectName: "API")
    #expect(claude.harness == .claudeCode)
    #expect(claude.resumeIdentifier == "operator-api-01234567")

    let codex = LaunchRequest(title: "Codex", command: "codex --search", directory: "/tmp")
      .preparedForNewSession(id: id, projectName: "API")
    #expect(codex.harness == .codex)
    #expect(codex.resumeIdentifier == nil)

    let projectID = UUID()
    let workspace = Workspace(name: "API", directory: "/tmp")
    let recipe = SessionRecipe(
      id: id, projectID: projectID, workspaceID: workspace.id, title: "Codex", command: "codex",
      environment: [:], harness: .codex, resumeIdentifier: "session-name", restoreOnOpen: true)
    let resumed = try #require(CodexAdapter().prepareResume(recipe: recipe, workspace: workspace))
    #expect(resumed.command == "codex resume 'session-name'")
    #expect(recipe.isAutoRestorable)

    let generic = LaunchRequest(title: "Shell", command: "zsh", directory: "/tmp")
      .preparedForNewSession(id: id, projectName: "API")
    #expect(generic.harness == .generic)
  }

  @Test func interactiveShellRestorationRejectsCommandsWithSideEffects() {
    #expect(InteractiveShellRestorationPolicy.isSafeInteractiveShellCommand("fish"))
    #expect(
      InteractiveShellRestorationPolicy.isSafeInteractiveShellCommand(
        "/opt/homebrew/bin/fish --login"))
    #expect(InteractiveShellRestorationPolicy.isSafeInteractiveShellCommand("/bin/zsh -l"))
    #expect(!InteractiveShellRestorationPolicy.isSafeInteractiveShellCommand("fish -c 'echo hi'"))
    #expect(!InteractiveShellRestorationPolicy.isSafeInteractiveShellCommand("fish; npm start"))
    #expect(!InteractiveShellRestorationPolicy.isSafeInteractiveShellCommand("npm start"))
  }
}

@MainActor
struct ProjectRuntimeTests {
  @Test func switchingProjectsPreservesIndependentLiveSessionGrids() throws {
    let root = try TestSupport.temporaryDirectory()
    let second = root.appendingPathComponent("second")
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    defer { TestSupport.remove(root) }
    let store = StateStore(fileURL: root.appendingPathComponent("state.json"))
    store.addProject(name: "One", directory: root.path)
    let firstProject = try #require(store.state.projects.first)
    store.addProject(name: "Two", directory: second.path)
    let secondProject = try #require(store.state.projects.last)
    let controller = WorkspaceController(store: store)

    controller.selectProject(firstProject.id)
    controller.launch(
      LaunchRequest(
        title: "One agent", command: "echo one", directory: root.path, projectID: firstProject.id,
        workspaceID: firstProject.workspaces[0].id))
    let firstID = try #require(controller.sessions.first?.id)
    controller.selectProject(secondProject.id)
    #expect(controller.sessions.isEmpty)
    controller.launch(
      LaunchRequest(
        title: "Two agent", command: "echo two", directory: second.path,
        projectID: secondProject.id, workspaceID: secondProject.workspaces[0].id))
    controller.selectProject(firstProject.id)
    #expect(controller.sessions.map(\.id) == [firstID])
    #expect(controller.terminalLayout?.contains(firstID) == true)
  }

  @Test func persistedClaudeAndExplicitCodexRecipesRestoreAutomatically() throws {
    let root = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(root) }
    let stateURL = root.appendingPathComponent("state.json")
    let store = StateStore(fileURL: stateURL)
    store.addProject(name: "Restore", directory: root.path)
    let project = try #require(store.state.projects.first)
    let workspace = try #require(project.workspaces.first)
    let claudeID = UUID()
    let codexID = UUID()
    store.saveSessionRecipe(
      SessionRecipe(
        id: claudeID, projectID: project.id, workspaceID: workspace.id, title: "Claude",
        command: "claude", environment: [:], harness: .claudeCode,
        resumeIdentifier: "operator-restore", restoreOnOpen: true))
    store.saveSessionRecipe(
      SessionRecipe(
        id: codexID, projectID: project.id, workspaceID: workspace.id, title: "Codex",
        command: "codex", environment: [:], harness: .codex, resumeIdentifier: "codex-session",
        restoreOnOpen: true))
    let genericID = UUID()
    store.saveSessionRecipe(
      SessionRecipe(
        id: genericID, projectID: project.id, workspaceID: workspace.id, title: "Server",
        command: "npm start", environment: [:], harness: .generic, resumeIdentifier: nil,
        restoreOnOpen: true))

    let controller = WorkspaceController(store: StateStore(fileURL: stateURL))
    controller.restoreSelectedProject()
    #expect(controller.sessions.count == 2)
    #expect(Set(controller.sessions.map(\.id)) == Set([claudeID, codexID]))
    #expect(
      controller.sessions.first(where: { $0.id == codexID })?.request.command
        == "codex resume 'codex-session'")
    #expect(controller.sessions.contains(where: { $0.id == genericID }) == false)
  }
}

@MainActor
struct ConfigurationAndProcessRunnerTests {
  @Test func configurationExportExcludesRuntimeSessionDataAndGuardedCRUDWorks() throws {
    let root = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(root) }
    let store = StateStore(fileURL: root.appendingPathComponent("state.json"))
    store.addProject(name: "API", directory: root.path)
    let project = try #require(store.state.projects.first)
    let workspace = try #require(project.workspaces.first)
    let recipe = SessionRecipe(
      id: UUID(), projectID: project.id, workspaceID: workspace.id, title: "Codex",
      command: "codex", environment: [:], harness: .codex, resumeIdentifier: "private-session",
      restoreOnOpen: true)
    store.saveSessionRecipe(recipe)
    #expect(!store.removeWorkspace(workspace.id, from: project.id))
    #expect(!store.removeProject(project.id))

    let export = root.appendingPathComponent("operator-config.json")
    try store.exportConfiguration(to: export)
    let text = try String(contentsOf: export)
    #expect(!text.contains("private-session"))
    let exportedConfiguration =
      try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: export)) as? [String: Any])
    #expect(exportedConfiguration["notificationsEnabled"] as? Bool == false)
    let imported = StateStore(fileURL: root.appendingPathComponent("imported.json"))
    try imported.importConfiguration(from: export)
    #expect(imported.state.projects.first?.name == "API")
    #expect(imported.state.sessionRecipes.isEmpty)
  }

  @Test func boundedProcessRunnerCapturesNonzeroExitAndStderr() throws {
    let result = try BoundedProcessRunner.run(
      executable: "/bin/zsh", arguments: ["-lc", "print -u2 'action failed'; exit 23"],
      timeout: 2)

    #expect(result.exitCode == 23)
    #expect(result.standardError.contains("action failed"))
    #expect(!result.timedOut)
  }

  @Test func boundedProcessRunnerTimesOutWithoutHanging() throws {
    let started = Date()
    let result = try BoundedProcessRunner.run(
      executable: "/bin/sleep", arguments: ["5"], timeout: 0.1)

    #expect(result.timedOut)
    #expect(Date().timeIntervalSince(started) < 2)
  }

  @Test func boundedProcessRunnerCapsNoisyCommands() throws {
    let result = try BoundedProcessRunner.run(
      executable: "/bin/zsh",
      arguments: ["-lc", "while true; do print '012345678901234567890123456789'; done"],
      timeout: 0.2, outputLimit: 4_096)

    #expect(result.timedOut)
    #expect(result.outputWasTruncated)
    #expect(result.standardOutput.utf8.count <= 4_096)
  }

}
