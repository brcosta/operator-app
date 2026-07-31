import Foundation
import Testing

@testable import Operator

@MainActor
struct StateStoreTests {
  @Test func integrationOptOutPreferencesPersistAndDisableRuntimeNotifications() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let stateURL = directory.appendingPathComponent("state.json")
    let store = StateStore(fileURL: stateURL)
    store.setNotificationsEnabled(true)
    let preferences = OperatorIntegrationPreferences(
      skillsEnabled: false, hooksEnabled: false, notificationsPermitted: false,
      fileWatchingEnabled: false)

    store.setIntegrationPreferences(preferences)

    #expect(store.state.integrationPreferences == preferences)
    #expect(!store.state.notificationsEnabled)
    #expect(StateStore(fileURL: stateURL).state.integrationPreferences == preferences)
  }

  @Test func agentPaneMetadataPersistsCheckpointReviewAndNotificationPolicy() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let stateURL = directory.appendingPathComponent("state.json")
    let store = StateStore(fileURL: stateURL)
    let sessionID = UUID()

    store.setPaneCheckpoint("Review the migration output", for: sessionID)
    store.setPaneNotificationPolicy(.muted, for: sessionID)
    store.setPaneAwaitingReview(true, for: sessionID)

    let metadata = StateStore(fileURL: stateURL).paneMetadata(for: sessionID)
    #expect(metadata.checkpoint == "Review the migration output")
    #expect(metadata.notificationPolicy == .muted)
    #expect(metadata.isAwaitingReview)
    #expect(!metadata.notificationPolicy.permits(.failed))
  }

  @Test func artifactsPersistPinAndSessionAttachment() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let stateURL = directory.appendingPathComponent("state.json")
    let store = StateStore(fileURL: stateURL)
    let artifact = ArtifactDescriptor(
      projectID: UUID(), sessionID: UUID(),
      path: directory.appendingPathComponent("report.json").path,
      workspaceDirectory: directory.path, kind: .json)

    store.upsertArtifact(artifact)
    store.setArtifactPinned(true, id: artifact.id)
    let attachment = UUID()
    store.attachArtifact(artifact.id, to: attachment)

    let restored = try #require(StateStore(fileURL: stateURL).state.artifacts.first)
    #expect(restored.isPinned)
    #expect(restored.attachedSessionID == attachment)
    #expect(restored.kind == .json)
  }

  @Test func mountedRecoveryToastInjectionIsUnavailableOutsideUIStressTesting() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))

    store.presentRecoveryMessageForMountedUITest("Synthetic recovery")

    #expect(store.recoveryMessage == nil)
  }

  @Test func projectVisibilityRecentsAndMetadataDeletionArePersisted() throws {
    let directory = try TestSupport.temporaryDirectory()
    let secondDirectory = directory.appendingPathComponent("second")
    try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
    defer { TestSupport.remove(directory) }
    let stateURL = directory.appendingPathComponent("state.json")
    let store = StateStore(fileURL: stateURL)
    store.addProject(name: "First", directory: directory.path)
    let first = try #require(store.state.projects.first)
    store.addProject(name: "Second", directory: secondDirectory.path)
    let second = try #require(store.state.projects.last)

    store.selectProject(first.id)
    store.hideProjectFromSidebar(first.id)
    #expect(store.sidebarProjects.map(\.id) == [second.id])
    #expect(store.recentProjects.first?.id == first.id)

    store.showProjectInSidebar(first.id)
    #expect(store.sidebarProjects.map(\.id).contains(first.id))
    store.deleteProjectMetadata(first.id)
    #expect(!store.state.projects.contains(where: { $0.id == first.id }))
    #expect(!store.recentProjects.contains(where: { $0.id == first.id }))

    let reloaded = StateStore(fileURL: stateURL)
    #expect(reloaded.state.projects.map(\.id) == [second.id])
  }

  @Test func sidebarExpansionDefaultsOpenPersistsAndCleansUpWithProjects() throws {
    let directory = try TestSupport.temporaryDirectory()
    let secondDirectory = directory.appendingPathComponent("second")
    try FileManager.default.createDirectory(
      at: secondDirectory, withIntermediateDirectories: true)
    defer { TestSupport.remove(directory) }
    let stateURL = directory.appendingPathComponent("state.json")
    let store = StateStore(fileURL: stateURL)
    let firstID = store.addProject(name: "First", directory: directory.path)
    let secondID = store.addProject(name: "Second", directory: secondDirectory.path)

    #expect(store.isProjectExpanded(firstID))
    #expect(store.isProjectExpanded(secondID))
    store.setProjectExpanded(false, for: firstID)
    store.setProjectExpanded(false, for: UUID())
    #expect(!store.isProjectExpanded(firstID))
    #expect(store.state.collapsedProjectIDs == [firstID])

    let reloaded = StateStore(fileURL: stateURL)
    #expect(!reloaded.isProjectExpanded(firstID))
    #expect(reloaded.isProjectExpanded(secondID))
    reloaded.setProjectExpanded(true, for: firstID)
    #expect(reloaded.isProjectExpanded(firstID))
    reloaded.setProjectExpanded(false, for: firstID)
    reloaded.deleteProjectMetadata(firstID)
    #expect(!reloaded.state.collapsedProjectIDs.contains(firstID))
  }

  @Test func diagnosticsExportIncludesRuntimeTrace() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
    let reportURL = directory.appendingPathComponent("diagnostics.json")
    OperatorDebugLog.record("test", "runtime trace is exportable")

    try OperatorDiagnostics.write(to: reportURL, store: store)

    let payload =
      try JSONSerialization.jsonObject(with: Data(contentsOf: reportURL)) as? [String: Any]
    let trace = try #require(payload?["runtimeTrace"] as? [[String: Any]])
    #expect(trace.contains { $0["category"] as? String == "test" })
  }

  @Test func shortcutsPersistAndProjectNavigationWraps() throws {
    let directory = try TestSupport.temporaryDirectory()
    let second = directory.appendingPathComponent("second")
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    defer { TestSupport.remove(directory) }
    let stateURL = directory.appendingPathComponent("state.json")
    let store = StateStore(fileURL: stateURL)
    store.addProject(name: "One", directory: directory.path)
    store.addProject(name: "Two", directory: second.path)
    store.setShortcut(
      ShortcutBinding(action: .missionControl, key: "9", command: false, control: true))
    WorkspaceController(store: store).selectAdjacentProject(1)
    #expect(store.state.selectedProjectID == store.state.projects[0].id)

    let shortcut = StateStore(fileURL: stateURL).shortcut(for: .missionControl)
    #expect(shortcut.key == "9")
    #expect(shortcut.control)
    #expect(!shortcut.command)
  }

  @Test func stateStorePersistsProjectsAndSessionMetadata() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let stateURL = directory.appendingPathComponent("state.json")
    let store = StateStore(fileURL: stateURL)
    store.addProject(name: "Operator", directory: directory.path)
    let project = try #require(store.state.projects.first)
    let id = UUID()
    store.recordStart(
      LaunchRequest(
        title: "Shell", command: "zsh", directory: directory.path, projectID: project.id), id: id)
    store.recordFinish(id: id, exitCode: 0)
    store.saveTaskBrief(
      sessionID: id, objective: "Implement radar", constraints: "Keep Git read-only",
      acceptanceCriteria: "Tests pass", title: "Shell")
    store.recordFileChanges(sessionID: id, title: "Shell", count: 2)
    store.setNotificationsEnabled(true)

    let reloaded = StateStore(fileURL: stateURL)
    #expect(reloaded.state.projects.first?.name == "Operator")
    #expect(reloaded.state.recentSessions.first?.directory == directory.path)
    #expect(reloaded.state.recentSessions.first?.exitCode == 0)
    #expect(reloaded.state.recentSessions.first?.status == .exited)
    #expect(reloaded.taskBrief(for: id)?.objective == "Implement radar")
    #expect(reloaded.state.activity.count == 4)
    #expect(reloaded.state.activity.allSatisfy { $0.projectID == project.id })
    #expect(!reloaded.state.notificationsEnabled)
  }

  @Test func corruptStateIsBackedUpAndReported() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let stateURL = directory.appendingPathComponent("state.json")
    try "not json".write(to: stateURL, atomically: true, encoding: .utf8)
    let store = StateStore(fileURL: stateURL)
    #expect(store.recoveryMessage != nil)
    #expect(store.state.projects.isEmpty)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: directory.path).contains {
        $0.hasPrefix("state-invalid-")
      })
  }

  @Test func corruptPrimaryRecoversLastKnownGoodState() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let stateURL = directory.appendingPathComponent("state.json")
    let store = StateStore(fileURL: stateURL)
    store.addProject(name: "Recoverable", directory: directory.path)
    store.setNotificationsEnabled(true)
    try "{ definitely not JSON".write(to: stateURL, atomically: true, encoding: .utf8)

    let recovered = StateStore(fileURL: stateURL)

    #expect(recovered.state.projects.first?.name == "Recoverable")
    #expect(recovered.recoveryMessage?.contains("last-known-good") == true)
    #expect(FileManager.default.fileExists(atPath: recovered.backupFileURL.path))
    #expect(
      (try? JSONDecoder().decode(PersistedState.self, from: Data(contentsOf: stateURL))) != nil)
  }

  @Test func legacyAndPartiallyCorruptStateLoadsLossily() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let stateURL = directory.appendingPathComponent("state.json")
    let project = Project(name: "Kept", directory: directory.path)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let projectObject = try JSONSerialization.jsonObject(with: encoder.encode(project))
    let payload: [String: Any] = [
      "schemaVersion": 1,
      "projects": [projectObject, 42, ["name": NSNull()]],
      "profiles": ["broken"],
      "notificationsEnabled": true,
    ]
    try JSONSerialization.data(withJSONObject: payload).write(to: stateURL, options: .atomic)

    let store = StateStore(fileURL: stateURL)

    #expect(store.state.projects.map(\.name) == ["Kept"])
    #expect(store.state.profiles.isEmpty)
    #expect(!store.state.notificationsEnabled)
    #expect(store.state.schemaVersion == PersistedState.currentSchemaVersion)
    #expect(store.isProjectExpanded(project.id))
  }

  @Test func projectDraftValidationRejectsUnsafeOrDuplicateInput() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let missing = directory.appendingPathComponent("missing").path

    #expect(throws: ProjectCreationError.self) {
      try ProjectDraftValidator.validate(
        name: "", directory: missing, emoji: "", existingProjects: [])
    }

    let existing = Project(name: "Existing", directory: directory.path)
    #expect(throws: ProjectCreationError.self) {
      try ProjectDraftValidator.validate(
        name: "Duplicate", directory: directory.path, emoji: "🚀",
        existingProjects: [existing])
    }
    #expect(throws: ProjectCreationError.self) {
      try ProjectDraftValidator.validate(
        name: "Bad icon", directory: directory.path, emoji: "x", existingProjects: [])
    }

    let valid = try ProjectDraftValidator.validate(
      name: "  ", directory: directory.path, emoji: "🛠️", existingProjects: [])
    #expect(valid.name == directory.lastPathComponent)
    #expect(valid.directory == directory.resolvingSymlinksInPath().path)
    #expect(valid.emoji != nil)
  }

  @Test func saveFailureIsVisibleAndDoesNotCrash() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let blockedParent = directory.appendingPathComponent("not-a-directory")
    try Data("file".utf8).write(to: blockedParent)
    let store = StateStore(fileURL: blockedParent.appendingPathComponent("state.json"))

    store.addProject(name: "Unsaved", directory: directory.path)

    #expect(store.persistenceMessage?.contains("could not save") == true)
    #expect(store.state.projects.first?.name == "Unsaved")
  }

  @Test func duplicateCanonicalProjectPathIsIgnored() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let stateURL = directory.appendingPathComponent("state.json")
    let store = StateStore(fileURL: stateURL)

    store.addProject(name: "First", directory: directory.path)
    store.addProject(name: "Duplicate", directory: directory.appendingPathComponent(".").path)

    #expect(store.state.projects.count == 1)
    #expect(store.state.projects.first?.name == "First")
  }

  @Test func savedStateCanBeReadByTheNextProcess() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let stateURL = directory.appendingPathComponent("state.json")
    let store = StateStore(fileURL: stateURL)
    store.addProject(name: "Readable", directory: directory.path)

    let result = try BoundedProcessRunner.run(
      executable: "/bin/cat", arguments: [stateURL.path], timeout: 2)

    #expect(result.exitCode == 0)
    #expect(result.standardOutput.contains("\"Readable\""))
    #expect(result.standardError.isEmpty)
  }

  @Test func addingNewDefaultShortcutsDoesNotShowARecoveryWarning() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let stateURL = directory.appendingPathComponent("state.json")
    let payload = """
      {
        "schemaVersion": \(PersistedState.currentSchemaVersion),
        "shortcuts": []
      }
      """
    try payload.write(to: stateURL, atomically: true, encoding: .utf8)

    let store = StateStore(fileURL: stateURL)

    #expect(store.recoveryMessage == nil)
    #expect(store.state.shortcuts.count == ShortcutBinding.defaults.count)
  }

  @Test func recentCustomCommandsAreDeduplicatedAndLimited() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
    let commands = ["one", "two", "three", "two", "four", "five", "six"]
    for command in commands {
      store.recordStart(
        LaunchRequest(
          title: command, command: command, directory: directory.path, harness: .generic),
        id: UUID())
    }
    store.recordStart(
      LaunchRequest(title: "Codex", command: "codex", directory: directory.path, harness: .codex),
      id: UUID())

    #expect(store.recentCustomCommands().map(\.command) == ["six", "five", "four", "two", "three"])
  }

  @Test func paneStatusBarPositionDefaultsToTopAndPersists() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let stateURL = directory.appendingPathComponent("state.json")
    let store = StateStore(fileURL: stateURL)

    #expect((store.state.paneStatusBarPosition ?? .top) == .top)
    store.setPaneStatusBarPosition(.bottom)

    let reloaded = StateStore(fileURL: stateURL)
    #expect(reloaded.state.paneStatusBarPosition == .bottom)
  }

  @Test func projectPersistsMultipleRepositoriesAndWorktrees() throws {
    let directory = try TestSupport.temporaryDirectory()
    let secondDirectory = directory.appendingPathComponent("service-b")
    try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
    defer { TestSupport.remove(directory) }
    let stateURL = directory.appendingPathComponent("state.json")
    let store = StateStore(fileURL: stateURL)
    store.addProject(name: "Checkout", directory: directory.path)
    let project = try #require(store.state.projects.first)
    store.addWorkspace(name: "Service B", directory: secondDirectory.path, to: project.id)
    #expect(
      StateStore(fileURL: stateURL).state.projects.first?.workspaces.map(\.directory) == [
        directory.path, secondDirectory.path,
      ])
  }

  @Test func projectIdentityPersistsAndKeepsOneEmojiCluster() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let stateURL = directory.appendingPathComponent("state.json")
    let store = StateStore(fileURL: stateURL)
    store.addProject(name: "Orbit", directory: directory.path, emoji: "🚀✨", accent: .purple)
    let project = try #require(store.state.projects.first)
    #expect(project.emoji == "🚀")
    #expect(project.accent == .purple)
    #expect(project.displayName == "🚀 Orbit")

    store.updateProjectIdentity(project.id, emoji: "", accent: .teal)
    let reloaded = StateStore(fileURL: stateURL)
    #expect(reloaded.state.projects.first?.emoji == nil)
    #expect(reloaded.state.projects.first?.accent == .teal)
  }

  @Test func workspaceAliasPersistsWithoutChangingItsDirectoryName() throws {
    let directory = try TestSupport.temporaryDirectory()
    let worktree = directory.appendingPathComponent("service-api")
    try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    defer { TestSupport.remove(directory) }
    let stateURL = directory.appendingPathComponent("state.json")
    let store = StateStore(fileURL: stateURL)
    store.addProject(name: "Suite", directory: directory.path)
    let project = try #require(store.state.projects.first)
    store.addWorkspace(
      name: "service-api", directory: worktree.path, to: project.id, alias: "API · feature/auth")
    let workspace = try #require(store.state.projects.first?.workspaces.last)
    #expect(workspace.displayName == "API · feature/auth")
    #expect(workspace.directory == worktree.path)

    store.renameWorkspace(workspace.id, in: project.id, to: "API · review")
    let reloaded = StateStore(fileURL: stateURL)
    #expect(reloaded.state.projects.first?.workspaces.last?.displayName == "API · review")
    #expect(reloaded.state.projects.first?.workspaces.last?.name == "service-api")
  }

  @Test func mainWindowLayoutPersistsAcrossReloads() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let stateURL = directory.appendingPathComponent("state.json")
    let layout = OperatorWindowLayout(
      x: 120, y: 80, width: 1_440, height: 900, isZoomed: true, isFullScreen: false)

    StateStore(fileURL: stateURL).saveMainWindowLayout(layout)

    #expect(StateStore(fileURL: stateURL).state.mainWindowLayout == layout)
  }

  @Test func appearanceDefaultsPersistsAndUnknownValuesFallBackSafely() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let stateURL = directory.appendingPathComponent("state.json")
    let store = StateStore(fileURL: stateURL)

    #expect(store.state.appearance == .system)
    store.setAppearance(.light)
    #expect(StateStore(fileURL: stateURL).state.appearance == .light)

    let futureStateURL = directory.appendingPathComponent("future-state.json")
    try """
    {
      "schemaVersion": \(PersistedState.currentSchemaVersion),
      "appearance": "sepia"
    }
    """.write(to: futureStateURL, atomically: true, encoding: .utf8)
    #expect(StateStore(fileURL: futureStateURL).state.appearance == .system)
  }

  @Test func profilesUpsertAndActivityRetentionArePersisted() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let stateURL = directory.appendingPathComponent("state.json")
    let store = StateStore(fileURL: stateURL)
    var profile = LaunchProfile(name: "Codex", command: "codex", directory: directory.path)
    store.saveProfile(profile)
    profile.command = "codex --full-auto"
    store.saveProfile(profile)
    let projectID = UUID()
    for index in 0..<101 {
      let sessionID = UUID()
      store.recordStart(
        LaunchRequest(
          title: "Agent \(index)", command: "echo ok", directory: directory.path,
          projectID: projectID), id: sessionID)
    }

    let reloaded = StateStore(fileURL: stateURL)
    #expect(reloaded.state.profiles == [profile])
    #expect(reloaded.state.activity.count == 100)
    #expect(reloaded.state.recentSessions.count == 30)
  }

  @Test func stateAndConfigurationExportsNeverPersistEnvironmentSecrets() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let stateURL = directory.appendingPathComponent("state.json")
    let exportURL = directory.appendingPathComponent("configuration.json")
    let store = StateStore(fileURL: stateURL)
    store.saveProfile(
      LaunchProfile(
        name: "Secure", command: "codex", directory: directory.path,
        environment: [
          EnvironmentOverride(key: "SAFE_FLAG", value: "enabled"),
          EnvironmentOverride(key: "OPENAI_API_KEY", value: "sk-persist-me-not-123456"),
          EnvironmentOverride(
            key: "DATABASE_URL", value: "postgres://user:password@example.com/database"),
        ]))
    store.recordStart(
      LaunchRequest(
        title: "Secure", command: "codex", directory: directory.path,
        environment: [
          "SAFE_FLAG": "enabled",
          "GITHUB_TOKEN": "ghp_persist_me_not_1234567890",
        ]),
      id: UUID())
    try store.exportConfiguration(to: exportURL)

    let stateText = try String(contentsOf: stateURL, encoding: .utf8)
    let exportText = try String(contentsOf: exportURL, encoding: .utf8)
    for text in [stateText, exportText] {
      #expect(text.contains("SAFE_FLAG"))
      #expect(!text.contains("persist-me-not"))
      #expect(!text.contains("persist_me_not"))
      #expect(!text.contains("password@example.com"))
    }
    let permissions =
      try #require(
        FileManager.default.attributesOfItem(atPath: exportURL.path)[.posixPermissions] as? NSNumber
      )
    #expect(permissions.intValue & 0o077 == 0)
  }

  @Test func loadingLegacyStateScrubsSecretsFromPrimaryAndBackupFiles() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let stateURL = directory.appendingPathComponent("state.json")
    var legacy = PersistedState()
    legacy.schemaVersion = PersistedState.currentSchemaVersion - 1
    legacy.profiles = [
      LaunchProfile(
        name: "Legacy", command: "codex", directory: directory.path,
        environment: [
          EnvironmentOverride(key: "SAFE_FLAG", value: "enabled"),
          EnvironmentOverride(key: "GITHUB_TOKEN", value: "ghp_legacy_secret_1234567890"),
        ])
    ]
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(legacy).write(to: stateURL, options: .atomic)

    let migrated = StateStore(fileURL: stateURL)

    #expect(migrated.recoveryMessage?.contains("sensitive environment") == true)
    for url in [migrated.stateFileURL, migrated.backupFileURL] {
      let text = try String(contentsOf: url, encoding: .utf8)
      #expect(text.contains("SAFE_FLAG"))
      #expect(!text.contains("legacy_secret"))
      let permissions =
        try #require(
          FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        )
      #expect(permissions.intValue & 0o077 == 0)
    }
  }

  @Test func emptyShortcutDoesNotReplaceExistingBindingAndDefaultsRestoreAfterReload() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let stateURL = directory.appendingPathComponent("state.json")
    let store = StateStore(fileURL: stateURL)
    let original = store.shortcut(for: .activity)
    store.setShortcut(.init(action: .activity, key: ""))
    #expect(store.shortcut(for: .activity) == original)
    store.setShortcut(.init(action: .activity, key: "x", command: false, option: true))
    store.restoreDefaultShortcuts()
    let reloaded = StateStore(fileURL: stateURL)
    #expect(
      reloaded.shortcut(for: .activity) == ShortcutBinding.defaults.first { $0.action == .activity }
    )
  }

  @Test func arrowShortcutsNormalizeAndPersistWithEveryModifier() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let stateURL = directory.appendingPathComponent("state.json")
    let store = StateStore(fileURL: stateURL)
    store.setShortcut(
      .init(
        action: .nextPane, key: "→", command: true, shift: true, option: true,
        control: true))

    let reloaded = StateStore(fileURL: stateURL)
    let shortcut = reloaded.shortcut(for: .nextPane)
    #expect(shortcut.key == ShortcutKey.rightArrow)
    #expect(shortcut.keyDisplayName == "→")
    #expect(shortcut.command)
    #expect(shortcut.shift)
    #expect(shortcut.option)
    #expect(shortcut.control)
    #expect(ShortcutKey.normalized("LEFT") == ShortcutKey.leftArrow)
    #expect(ShortcutKey.normalized(" ↑ ") == ShortcutKey.upArrow)
    #expect(ShortcutKey.normalized("downArrow") == ShortcutKey.downArrow)
  }
}
