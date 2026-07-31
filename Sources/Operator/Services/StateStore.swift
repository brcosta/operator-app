import Combine
import Foundation

@MainActor
final class StateStore: ObservableObject {
  @Published private(set) var state: PersistedState
  @Published private(set) var recoveryMessage: String?
  @Published private(set) var persistenceMessage: String?

  private let fileURL: URL
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  init(fileURL: URL? = nil) {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
      0
    ]
    .appendingPathComponent("Operator", isDirectory: true)
    let environmentPath = ProcessInfo.processInfo.environment["OPERATOR_STATE_PATH"]
      .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    self.fileURL = fileURL ?? environmentPath ?? support.appendingPathComponent("state.json")
    encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let loaded = Self.load(from: self.fileURL, decoder: decoder)
    let repaired = Self.reconcile(loaded.state)
    state = repaired.state
    recoveryMessage = [loaded.recoveryMessage, repaired.message].compactMap { $0 }.joined(
      separator: " ")
    if recoveryMessage?.isEmpty == true { recoveryMessage = nil }
    if repaired.message != nil { save() }
  }

  var stateFileURL: URL { fileURL }
  var backupFileURL: URL { Self.backupURL(for: fileURL) }

  func dismissRecoveryMessage() { recoveryMessage = nil }
  func dismissPersistenceMessage() { persistenceMessage = nil }

  func presentRecoveryMessageForMountedUITest(_ message: String) {
    let environment = ProcessInfo.processInfo.environment
    guard ProcessInfo.processInfo.arguments.contains("--ui-testing"),
      environment["OPERATOR_MULTI_PROJECT_REPORT"]?.isEmpty == false
    else { return }
    recoveryMessage = message
  }

  @discardableResult
  func addProject(
    name: String, directory: String, emoji: String? = nil, accent: ProjectAccent? = nil
  ) -> UUID {
    let canonicalDirectory = URL(fileURLWithPath: directory, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath().path
    if let existing = state.projects.first(where: {
      $0.workspaces.contains {
        URL(fileURLWithPath: $0.directory, isDirectory: true)
          .standardizedFileURL.resolvingSymlinksInPath().path == canonicalDirectory
      }
    }) {
      state.selectedProjectID = existing.id
      save()
      return existing.id
    }
    let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let project = Project(
      name: cleanName.isEmpty
        ? URL(fileURLWithPath: canonicalDirectory).lastPathComponent : cleanName,
      directory: canonicalDirectory, emoji: emoji, accent: accent ?? .blue)
    state.projects.append(project)
    state.selectedProjectID = project.id
    save()
    return project.id
  }

  func recentCustomCommands(limit: Int = 5) -> [RecentSession] {
    var seenCommands = Set<String>()
    return state.recentSessions.filter { session in
      let command = session.command.trimmingCharacters(in: .whitespacesAndNewlines)
      return session.harness == .generic && !command.isEmpty
        && seenCommands.insert(command).inserted
    }
    .prefix(max(0, limit))
    .map { $0 }
  }

  var sidebarProjects: [Project] { state.projects.filter(\.isShownInSidebar) }
  func isProjectExpanded(_ projectID: UUID) -> Bool {
    !state.collapsedProjectIDs.contains(projectID)
  }

  func setProjectExpanded(_ isExpanded: Bool, for projectID: UUID) {
    guard state.projects.contains(where: { $0.id == projectID }),
      isProjectExpanded(projectID) != isExpanded
    else { return }
    if isExpanded {
      state.collapsedProjectIDs.remove(projectID)
    } else {
      state.collapsedProjectIDs.insert(projectID)
    }
    save()
  }

  func setAppearance(_ appearance: AppAppearancePreference) {
    guard state.appearance != appearance else { return }
    state.appearance = appearance
    OperatorDebugLog.record(
      "appearance.changed", "Application appearance changed",
      level: .info, metadata: ["appearance": appearance.rawValue])
    save()
  }

  func setTerminalPreferences(_ preferences: TerminalPreferences) {
    let normalized = preferences.normalized
    guard state.terminalPreferences != normalized else { return }
    state.terminalPreferences = normalized
    OperatorDebugLog.record(
      "terminal.preferences.changed", "Terminal presentation preferences changed",
      level: .info,
      metadata: [
        "font": normalized.fontFamily ?? "system",
        "fontSize": String(normalized.fontSize),
        "ligatures": String(normalized.ligaturesEnabled),
        "scrollbackLines": String(normalized.scrollbackLines),
      ])
    save()
  }

  var recentProjects: [Project] {
    Array(
      state.projects.sorted {
        ($0.lastOpenedAt ?? $0.createdAt) > ($1.lastOpenedAt ?? $1.createdAt)
      }.prefix(10))
  }

  func addWorkspace(name: String, directory: String, to projectID: UUID, alias: String? = nil) {
    guard let index = state.projects.firstIndex(where: { $0.id == projectID }) else { return }
    let canonicalDirectory = URL(fileURLWithPath: directory, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath().path
    guard
      !state.projects[index].workspaces.contains(where: {
        URL(fileURLWithPath: $0.directory, isDirectory: true)
          .standardizedFileURL.resolvingSymlinksInPath().path == canonicalDirectory
      })
    else { return }
    state.projects[index].workspaces.append(
      Workspace(name: name, directory: canonicalDirectory, alias: alias))
    save()
  }

  func renameProject(_ id: UUID, to name: String) {
    guard let index = state.projects.firstIndex(where: { $0.id == id }) else { return }
    state.projects[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    save()
  }

  func updateProjectIdentity(_ id: UUID, emoji: String?, accent: ProjectAccent) {
    guard let index = state.projects.firstIndex(where: { $0.id == id }) else { return }
    state.projects[index].emoji = Project.normalizedEmoji(emoji)
    state.projects[index].accent = accent
    save()
  }

  @discardableResult
  func removeProject(_ id: UUID) -> Bool {
    guard !state.sessionRecipes.contains(where: { $0.projectID == id }) else { return false }
    state.projects.removeAll { $0.id == id }
    state.projectLayouts[id] = nil
    state.collapsedProjectIDs.remove(id)
    if state.selectedProjectID == id { state.selectedProjectID = state.projects.first?.id }
    save()
    return true
  }

  func renameWorkspace(_ id: UUID, in projectID: UUID, to name: String) {
    guard let projectIndex = state.projects.firstIndex(where: { $0.id == projectID }),
      let workspaceIndex = state.projects[projectIndex].workspaces.firstIndex(where: { $0.id == id }
      )
    else { return }
    state.projects[projectIndex].workspaces[workspaceIndex].alias = Workspace.normalizedAlias(name)
    save()
  }

  @discardableResult
  func removeWorkspace(_ id: UUID, from projectID: UUID) -> Bool {
    guard !state.sessionRecipes.contains(where: { $0.workspaceID == id }) else { return false }
    guard let index = state.projects.firstIndex(where: { $0.id == projectID }) else { return false }
    state.projects[index].workspaces.removeAll { $0.id == id }
    save()
    return true
  }

  func saveProfile(_ profile: LaunchProfile) {
    if let index = state.profiles.firstIndex(where: { $0.id == profile.id }) {
      state.profiles[index] = profile
    } else {
      state.profiles.append(profile)
    }
    save()
  }

  func removeProfile(_ id: UUID) {
    state.profiles.removeAll { $0.id == id }
    save()
  }

  func selectProject(_ id: UUID?) {
    state.selectedProjectID = id
    if let id, let index = state.projects.firstIndex(where: { $0.id == id }) {
      state.projects[index].lastOpenedAt = .now
    }
    save()
  }

  func showProjectInSidebar(_ id: UUID) {
    guard let index = state.projects.firstIndex(where: { $0.id == id }) else { return }
    state.projects[index].isShownInSidebar = true
    save()
  }

  func hideProjectFromSidebar(_ id: UUID) {
    guard let index = state.projects.firstIndex(where: { $0.id == id }) else { return }
    state.projects[index].isShownInSidebar = false
    if state.selectedProjectID == id {
      state.selectedProjectID = sidebarProjects.first?.id
    }
    save()
  }

  func deleteProjectMetadata(_ id: UUID) {
    let sessionIDs = Set(state.sessionRecipes.filter { $0.projectID == id }.map(\.id))
    let workspaceIDs = Set(state.projects.first(where: { $0.id == id })?.workspaces.map(\.id) ?? [])
    state.projects.removeAll { $0.id == id }
    state.profiles.removeAll {
      $0.projectID == id || ($0.workspaceID.map { workspaceIDs.contains($0) } ?? false)
    }
    state.recentSessions.removeAll { $0.projectID == id }
    state.taskBriefs.removeAll { sessionIDs.contains($0.sessionID) }
    state.activity.removeAll {
      $0.projectID == id || ($0.sessionID.map { sessionIDs.contains($0) } ?? false)
    }
    state.sessionRecipes.removeAll { $0.projectID == id }
    state.projectLayouts[id] = nil
    state.projectTabs[id] = nil
    state.selectedTabIDs[id] = nil
    state.collapsedProjectIDs.remove(id)
    if state.selectedProjectID == id { state.selectedProjectID = sidebarProjects.first?.id }
    save()
  }

  func setSplitOrientation(_ orientation: SplitOrientation?) {
    state.splitOrientation = orientation
    save()
  }

  func recordStart(_ request: LaunchRequest, id: UUID) {
    state.recentSessions.insert(
      RecentSession(
        id: id, title: request.title, command: request.command, projectID: request.projectID,
        workspaceID: request.workspaceID, directory: request.directory, startedAt: .now,
        endedAt: nil, exitCode: nil, status: .running, harness: request.harness,
        managedSessionName: request.managedSessionName,
        environment: EnvironmentSecurityPolicy.persistable(request.environment),
        resumeIdentifier: request.resumeIdentifier ?? request.managedSessionName), at: 0)
    state.recentSessions = Array(state.recentSessions.prefix(30))
    appendActivity(
      kind: .launched, sessionID: id, projectID: request.projectID, title: request.title,
      detail: "Started in \(request.directory)")
    save()
  }

  func paneMetadata(for sessionID: UUID) -> AgentPaneMetadata {
    state.agentPaneMetadata[sessionID] ?? AgentPaneMetadata()
  }

  func setPaneNotificationPolicy(_ policy: PaneNotificationPolicy, for sessionID: UUID) {
    var metadata = paneMetadata(for: sessionID)
    guard metadata.notificationPolicy != policy else { return }
    metadata.notificationPolicy = policy
    state.agentPaneMetadata[sessionID] = metadata
    save()
  }

  func setPaneAwaitingReview(_ awaitingReview: Bool, for sessionID: UUID) {
    var metadata = paneMetadata(for: sessionID)
    guard metadata.isAwaitingReview != awaitingReview else { return }
    metadata.isAwaitingReview = awaitingReview
    state.agentPaneMetadata[sessionID] = metadata
    save()
  }

  func upsertArtifact(_ artifact: ArtifactDescriptor) {
    if let index = state.artifacts.firstIndex(where: {
      $0.path == artifact.path && $0.sessionID == artifact.sessionID
    }) {
      let prior = state.artifacts[index]
      var updated = artifact
      updated.id = prior.id
      updated.isPinned = prior.isPinned
      updated.attachedSessionID = prior.attachedSessionID
      state.artifacts[index] = updated
    } else {
      state.artifacts.insert(artifact, at: 0)
    }
    state.artifacts = Array(state.artifacts.prefix(500))
    save()
  }

  func setArtifactPinned(_ pinned: Bool, id: UUID) {
    guard let index = state.artifacts.firstIndex(where: { $0.id == id }) else { return }
    state.artifacts[index].isPinned = pinned
    save()
  }

  func attachArtifact(_ id: UUID, to sessionID: UUID?) {
    guard let index = state.artifacts.firstIndex(where: { $0.id == id }) else { return }
    state.artifacts[index].attachedSessionID = sessionID
    save()
  }

  func removeArtifact(_ id: UUID) {
    state.artifacts.removeAll { $0.id == id }
    save()
  }

  func recordFinish(id: UUID, exitCode: Int32, failed: Bool = false) {
    guard let index = state.recentSessions.firstIndex(where: { $0.id == id }) else { return }
    state.recentSessions[index].endedAt = .now
    state.recentSessions[index].exitCode = exitCode
    state.recentSessions[index].status = failed ? .failed : .exited
    let recent = state.recentSessions[index]
    appendActivity(
      kind: failed ? .failed : .exited, sessionID: id, projectID: recent.projectID,
      title: recent.title,
      detail: failed
        ? "Process ended unexpectedly in \(recent.directory)."
        : "Exited with code \(exitCode) in \(recent.directory).")
    save()
  }

  func taskBrief(for sessionID: UUID) -> TaskBrief? {
    state.taskBriefs.first { $0.sessionID == sessionID }
  }

  func saveTaskBrief(
    sessionID: UUID, objective: String, constraints: String, acceptanceCriteria: String,
    title: String
  ) {
    let brief = TaskBrief(
      sessionID: sessionID, objective: objective.trimmingCharacters(in: .whitespacesAndNewlines),
      constraints: constraints.trimmingCharacters(in: .whitespacesAndNewlines),
      acceptanceCriteria: acceptanceCriteria.trimmingCharacters(in: .whitespacesAndNewlines))
    if let index = state.taskBriefs.firstIndex(where: { $0.sessionID == sessionID }) {
      state.taskBriefs[index] = brief
    } else {
      state.taskBriefs.append(brief)
    }
    appendActivity(
      kind: .taskBriefUpdated, sessionID: sessionID, projectID: projectID(for: sessionID),
      title: title, detail: brief.summary)
    save()
  }

  func recordFileChanges(sessionID: UUID, title: String, count: Int) {
    guard count > 0 else { return }
    appendActivity(
      kind: .filesChanged, sessionID: sessionID, projectID: projectID(for: sessionID), title: title,
      detail: "\(count) changed file\(count == 1 ? "" : "s") detected.")
    save()
  }

  func setNotificationsEnabled(_ enabled: Bool) {
    state.notificationsEnabled = enabled
    save()
  }

  func setIntegrationPreferences(_ preferences: OperatorIntegrationPreferences) {
    guard state.integrationPreferences != preferences else { return }
    state.integrationPreferences = preferences
    if !preferences.notificationsPermitted { state.notificationsEnabled = false }
    OperatorDebugLog.record(
      "integrations.preferences.changed", "Updated optional Operator integrations",
      metadata: [
        "skills": String(preferences.skillsEnabled), "hooks": String(preferences.hooksEnabled),
        "notificationsPermitted": String(preferences.notificationsPermitted),
        "fileWatching": String(preferences.fileWatchingEnabled),
      ])
    save()
  }

  func setPaneStatusBarPosition(_ position: PaneStatusBarPosition) {
    state.paneStatusBarPosition = position
    save()
  }

  func shortcut(for action: ShortcutAction) -> ShortcutBinding {
    state.shortcuts.first { $0.action == action } ?? ShortcutBinding.defaults.first {
      $0.action == action
    }!
  }

  func setShortcut(_ shortcut: ShortcutBinding) {
    guard let key = ShortcutKey.normalized(shortcut.key) else { return }
    var normalized = shortcut
    normalized.key = key
    if let index = state.shortcuts.firstIndex(where: { $0.action == normalized.action }) {
      state.shortcuts[index] = normalized
    } else {
      state.shortcuts.append(normalized)
    }
    save()
  }

  func restoreDefaultShortcuts() {
    state.shortcuts = ShortcutBinding.defaults
    save()
  }

  func saveSessionRecipe(_ recipe: SessionRecipe) {
    var persistableRecipe = recipe
    persistableRecipe.environment = EnvironmentSecurityPolicy.persistable(recipe.environment)
    if let index = state.sessionRecipes.firstIndex(where: { $0.id == recipe.id }) {
      state.sessionRecipes[index] = persistableRecipe
    } else {
      state.sessionRecipes.append(persistableRecipe)
    }
    save()
  }

  func removeSessionRecipe(_ id: UUID) {
    state.sessionRecipes.removeAll { $0.id == id }
    state.agentPaneMetadata[id] = nil
    for projectID in state.projectLayouts.keys {
      state.projectLayouts[projectID] = state.projectLayouts[projectID]?.removing(id)
    }
    for projectID in state.projectTabs.keys {
      state.projectTabs[projectID] = state.projectTabs[projectID]?.compactMap { tab in
        guard let layout = tab.layout.removing(id), !layout.contentPaneIDs.isEmpty else {
          return nil
        }
        var updated = tab
        updated.layout = layout
        if updated.focusedSessionID == id { updated.focusedSessionID = layout.firstTerminalID }
        if updated.focusedPaneID == id {
          updated.focusedPaneID = updated.focusedSessionID ?? layout.firstPaneID
        }
        return updated
      }
      if let selected = state.selectedTabIDs[projectID],
        state.projectTabs[projectID]?.contains(where: { $0.id == selected }) != true
      {
        state.selectedTabIDs[projectID] = state.projectTabs[projectID]?.first?.id
      }
    }
    save()
  }

  @discardableResult
  func setResumeIdentifier(_ identifier: String?, for sessionID: UUID) -> Bool {
    let value = identifier?.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalized = value?.isEmpty == false ? value : nil
    var changed = false
    if let index = state.sessionRecipes.firstIndex(where: { $0.id == sessionID }),
      state.sessionRecipes[index].resumeIdentifier != normalized
    {
      state.sessionRecipes[index].resumeIdentifier = normalized
      changed = true
    }
    if let index = state.recentSessions.firstIndex(where: { $0.id == sessionID }),
      state.recentSessions[index].resumeIdentifier != normalized
    {
      state.recentSessions[index].resumeIdentifier = normalized
      changed = true
    }
    if changed { save() }
    return changed
  }

  func saveLayout(_ layout: TerminalLayout?, for projectID: UUID) {
    state.projectLayouts[projectID] = layout
    save()
  }

  func saveTabs(_ tabs: [WorkspaceTab], selectedTabID: UUID?, for projectID: UUID) {
    state.projectTabs[projectID] = tabs
    state.selectedTabIDs[projectID] = selectedTabID
    state.projectLayouts[projectID] = tabs.first(where: { $0.id == selectedTabID })?.layout
    save()
  }

  func saveMainWindowLayout(_ layout: OperatorWindowLayout) {
    state.mainWindowLayout = layout
    save()
  }

  func exportConfiguration(to url: URL) throws {
    let configuration = OperatorConfiguration(
      projects: state.projects,
      profiles: state.profiles.map(Self.profileWithoutPersistedSecrets),
      shortcuts: state.shortcuts,
      notificationsEnabled: false,
      terminalPreferences: state.terminalPreferences,
      integrationPreferences: state.integrationPreferences)
    try encoder.encode(configuration).write(to: url, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  func importConfiguration(from url: URL) throws {
    let configuration = try decoder.decode(OperatorConfiguration.self, from: Data(contentsOf: url))
    guard configuration.version == 1 else {
      throw NSError(
        domain: "OperatorConfiguration", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Unsupported Operator configuration version."])
    }
    for project in configuration.projects {
      if let index = state.projects.firstIndex(where: { $0.id == project.id }) {
        state.projects[index] = project
      } else {
        state.projects.append(project)
      }
    }
    for profile in configuration.profiles {
      let safeProfile = Self.profileWithoutPersistedSecrets(profile)
      if let index = state.profiles.firstIndex(where: { $0.id == profile.id }) {
        state.profiles[index] = safeProfile
      } else {
        state.profiles.append(safeProfile)
      }
    }
    for shortcut in configuration.shortcuts {
      if let index = state.shortcuts.firstIndex(where: { $0.action == shortcut.action }) {
        state.shortcuts[index] = shortcut
      } else {
        state.shortcuts.append(shortcut)
      }
    }
    // Notifications are deliberately runtime-only. Importing configuration must never make the
    // next process touch UserNotifications before the operator explicitly opts in.
    state.notificationsEnabled = false
    if let preferences = configuration.integrationPreferences {
      state.integrationPreferences = preferences
      if !preferences.notificationsPermitted { state.notificationsEnabled = false }
    }
    if let preferences = configuration.terminalPreferences {
      state.terminalPreferences = preferences.normalized
    }
    if state.selectedProjectID == nil { state.selectedProjectID = configuration.projects.first?.id }
    state = Self.reconcile(state).state
    save()
  }

  private func projectID(for sessionID: UUID) -> UUID? {
    state.recentSessions.first { $0.id == sessionID }?.projectID
  }

  private func appendActivity(
    kind: ActivityKind, sessionID: UUID?, projectID: UUID?, title: String, detail: String
  ) {
    state.activity.insert(
      ActivityEvent(
        kind: kind, sessionID: sessionID, projectID: projectID, title: title, detail: detail), at: 0
    )
    state.activity = Array(state.activity.prefix(100))
  }

  @discardableResult
  private func save() -> Bool {
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: fileURL.deletingLastPathComponent().path)
      let persistableState = Self.stateWithoutPersistedSecrets(state)
      let encoded = try encoder.encode(persistableState)
      let backupURL = Self.backupURL(for: fileURL)
      if let current = try? Data(contentsOf: fileURL),
        let decodedCurrent = try? decoder.decode(PersistedState.self, from: current)
      {
        try encoder.encode(Self.stateWithoutPersistedSecrets(decodedCurrent)).write(
          to: backupURL, options: .atomic)
      }
      // POSIX mode 0600 is portable across supported macOS filesystems. Data-protection write
      // options can leave command-line-built apps unable to reopen their own state after exit.
      try encoded.write(to: fileURL, options: .atomic)
      if !FileManager.default.fileExists(atPath: backupURL.path) {
        try encoded.write(to: backupURL, options: .atomic)
      }
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
      persistenceMessage = nil
      return true
    } catch {
      persistenceMessage =
        "Operator could not save your latest changes. Your in-memory workspace is still open. "
        + error.localizedDescription
      OperatorDebugLog.record(
        "state.save.failed", error.localizedDescription, level: .error,
        metadata: ["path": fileURL.path])
      return false
    }
  }

  private static func load(from url: URL, decoder: JSONDecoder) -> (
    state: PersistedState, recoveryMessage: String?
  ) {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: url.path) else { return (PersistedState(), nil) }
    do {
      let data = try Data(contentsOf: url)
      let decoded = try decoder.decode(PersistedState.self, from: data)
      guard decoded.schemaVersion <= PersistedState.currentSchemaVersion else {
        throw NSError(
          domain: "OperatorState", code: 2,
          userInfo: [
            NSLocalizedDescriptionKey:
              "This state was created by a newer version of Operator."
          ])
      }
      return (decoded, nil)
    } catch {
      let invalid = url.deletingLastPathComponent().appendingPathComponent(
        "state-invalid-\(UUID().uuidString).json")
      try? fileManager.copyItem(at: url, to: invalid)
      try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: invalid.path)
      let backup = backupURL(for: url)
      if let backupData = try? Data(contentsOf: backup),
        let recovered = try? decoder.decode(PersistedState.self, from: backupData),
        recovered.schemaVersion <= PersistedState.currentSchemaVersion
      {
        try? backupData.write(to: url, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return (
          recovered,
          "Operator recovered your last-known-good state. The unreadable file was preserved as "
            + invalid.lastPathComponent + "."
        )
      }
      return (
        PersistedState(),
        "Operator could not read saved state or its backup. The unreadable file was preserved as "
          + invalid.lastPathComponent + "."
      )
    }
  }

  private static func backupURL(for url: URL) -> URL {
    url.deletingPathExtension().appendingPathExtension("last-good.json")
  }

  private static func profileWithoutPersistedSecrets(_ profile: LaunchProfile) -> LaunchProfile {
    var result = profile
    result.environment = EnvironmentSecurityPolicy.persistable(profile.environment)
    return result
  }

  private static func stateWithoutPersistedSecrets(_ input: PersistedState) -> PersistedState {
    var result = input
    result.profiles = result.profiles.map(profileWithoutPersistedSecrets)
    result.recentSessions = result.recentSessions.map { recent in
      var recent = recent
      recent.environment = recent.environment.map(EnvironmentSecurityPolicy.persistable)
      return recent
    }
    result.sessionRecipes = result.sessionRecipes.map { recipe in
      var recipe = recipe
      recipe.environment = EnvironmentSecurityPolicy.persistable(recipe.environment)
      return recipe
    }
    return result
  }

  private static func reconcile(_ input: PersistedState) -> (
    state: PersistedState, message: String?
  ) {
    var state = input
    var repairCount = 0
    var repairReasons = Set<String>()
    func recordRepair(_ reason: String) {
      repairCount += 1
      repairReasons.insert(reason)
    }
    state.schemaVersion = PersistedState.currentSchemaVersion

    var projectIDs = Set<UUID>()
    var workspaceIDs = Set<UUID>()
    var workspaceDirectories = Set<String>()
    state.projects = state.projects.compactMap { original in
      guard projectIDs.insert(original.id).inserted else {
        recordRepair("Removed duplicate projects.")
        return nil
      }
      var project = original
      let cleanName = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
      if cleanName != project.name || cleanName.isEmpty {
        project.name = cleanName.isEmpty ? "Untitled Project" : cleanName
        recordRepair("Normalized project metadata.")
      }
      let normalizedEmoji = Project.normalizedEmoji(project.emoji)
      if normalizedEmoji != project.emoji {
        project.emoji = normalizedEmoji
        recordRepair("Normalized project metadata.")
      }
      project.workspaces = project.workspaces.compactMap { originalWorkspace in
        var workspace = originalWorkspace
        let canonical = URL(fileURLWithPath: workspace.directory, isDirectory: true)
          .standardizedFileURL.resolvingSymlinksInPath().path
        guard workspaceIDs.insert(workspace.id).inserted,
          workspaceDirectories.insert(canonical).inserted
        else {
          recordRepair("Removed duplicate workspaces.")
          return nil
        }
        if canonical != workspace.directory {
          workspace.directory = canonical
          recordRepair("Normalized workspace paths.")
        }
        workspace.alias = Workspace.normalizedAlias(workspace.alias)
        return workspace
      }
      return project
    }

    let validProjectIDs = Set(state.projects.map(\.id))
    let previousCollapsedProjectIDs = state.collapsedProjectIDs
    state.collapsedProjectIDs.formIntersection(validProjectIDs)
    if state.collapsedProjectIDs != previousCollapsedProjectIDs {
      recordRepair("Removed orphaned sidebar preferences.")
    }
    let workspaceOwners = Dictionary(
      uniqueKeysWithValues: state.projects.flatMap { project in
        project.workspaces.map { ($0.id, project.id) }
      })
    if let selected = state.selectedProjectID, !validProjectIDs.contains(selected) {
      state.selectedProjectID =
        state.projects.first(where: \.isShownInSidebar)?.id
        ?? state.projects.first?.id
      recordRepair("Reset an unavailable project selection.")
    }

    var recipeIDs = Set<UUID>()
    state.sessionRecipes = state.sessionRecipes.filter { recipe in
      let valid =
        recipeIDs.insert(recipe.id).inserted && validProjectIDs.contains(recipe.projectID)
        && workspaceOwners[recipe.workspaceID] == recipe.projectID
      if !valid { recordRepair("Removed orphaned session recipes.") }
      return valid
    }
    let validSessionIDs = Set(state.sessionRecipes.map(\.id))

    state.recentSessions = Array(
      state.recentSessions.prefix(100).map { original in
        var recent = original
        if recent.status == .running {
          recent.status = .failed
          recent.endedAt = recent.endedAt ?? .now
          recent.exitCode = recent.exitCode ?? -1
          recordRepair("Marked interrupted sessions as needing attention.")
        }
        return recent
      })
    let knownSessionIDs = validSessionIDs.union(state.recentSessions.map(\.id))
    state.taskBriefs = state.taskBriefs.filter { knownSessionIDs.contains($0.sessionID) }
    state.activity = Array(state.activity.prefix(500))

    state.projectLayouts = state.projectLayouts.filter { validProjectIDs.contains($0.key) }
    state.projectTabs = state.projectTabs.filter { validProjectIDs.contains($0.key) }
    state.selectedTabIDs = state.selectedTabIDs.filter { validProjectIDs.contains($0.key) }
    for projectID in state.projectTabs.keys {
      var tabIDs = Set<UUID>()
      state.projectTabs[projectID] = state.projectTabs[projectID]?.compactMap { original in
        guard tabIDs.insert(original.id).inserted else {
          recordRepair("Removed duplicate saved tabs.")
          return nil
        }
        var tab = original
        tab.splitRatios = tab.splitRatios.compactMapValues { value in
          value.isFinite ? min(0.9, max(0.1, value)) : nil
        }
        if let focused = tab.focusedSessionID, !tab.layout.contains(focused) {
          tab.focusedSessionID = tab.layout.firstTerminalID
          recordRepair("Repaired saved tab focus.")
        }
        if tab.focusedPaneID.map({ tab.layout.paneIDs.contains($0) }) != true {
          tab.focusedPaneID = tab.focusedSessionID ?? tab.layout.firstPaneID
          recordRepair("Repaired saved pane focus.")
        }
        return tab
      }
      if let selected = state.selectedTabIDs[projectID],
        state.projectTabs[projectID]?.contains(where: { $0.id == selected }) != true
      {
        state.selectedTabIDs[projectID] = state.projectTabs[projectID]?.first?.id
        recordRepair("Reset an unavailable tab selection.")
      }
    }

    state.profiles = state.profiles.filter { profile in
      guard let projectID = profile.projectID else { return true }
      guard validProjectIDs.contains(projectID) else {
        recordRepair("Removed orphaned launch profiles.")
        return false
      }
      if let workspaceID = profile.workspaceID, workspaceOwners[workspaceID] != projectID {
        recordRepair("Removed orphaned launch profiles.")
        return false
      }
      return true
    }
    let sanitizedProfiles = state.profiles.map(profileWithoutPersistedSecrets)
    if sanitizedProfiles != state.profiles {
      state.profiles = sanitizedProfiles
      recordRepair("Removed sensitive environment values from saved profiles.")
    }
    state.recentSessions = state.recentSessions.map { recent in
      var recent = recent
      let sanitized = recent.environment.map(EnvironmentSecurityPolicy.persistable)
      if sanitized != recent.environment {
        recent.environment = sanitized
        recordRepair("Removed sensitive environment values from saved sessions.")
      }
      return recent
    }
    state.sessionRecipes = state.sessionRecipes.map { recipe in
      var recipe = recipe
      let sanitized = EnvironmentSecurityPolicy.persistable(recipe.environment)
      if sanitized != recipe.environment {
        recipe.environment = sanitized
        recordRepair("Removed sensitive environment values from saved sessions.")
      }
      return recipe
    }
    var shortcutActions = Set<ShortcutAction>()
    state.shortcuts = state.shortcuts.filter { shortcut in
      let unique = shortcutActions.insert(shortcut.action).inserted
      if !unique { recordRepair("Removed duplicate keyboard shortcuts.") }
      return unique
    }
    for binding in ShortcutBinding.defaults where !shortcutActions.contains(binding.action) {
      state.shortcuts.append(binding)
    }
    if let layout = state.mainWindowLayout,
      !layout.x.isFinite || !layout.y.isFinite || !layout.width.isFinite || !layout.height.isFinite
        || layout.width < 600 || layout.height < 400
    {
      state.mainWindowLayout = nil
      recordRepair("Reset an invalid window position.")
    }
    let reasonSummary = repairReasons.sorted().joined(separator: " ")
    return (
      state,
      repairCount == 0
        ? nil
        : "Operator restored your workspace. \(reasonSummary)"
    )
  }
}
