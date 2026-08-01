import AppKit
import Combine
import Darwin
import Foundation
import SwiftTerm
import SwiftUI

enum TerminalEnvironmentBuilder {
  static func build(
    inherited: [String: String], integration: [String: String],
    requestOverrides: [String: String], sessionID: UUID, token: String,
    colorForegroundBackground: String
  ) -> [String: String] {
    let safeOverrides = requestOverrides.filter {
      !EnvironmentSecurityPolicy.reservedRuntimeKeys.contains($0.key.uppercased())
    }
    var environment = inherited.merging(
      safeOverrides, uniquingKeysWith: { _, override in override })
    for (key, value) in integration where key != "PATH" {
      environment[key] = value
    }
    if let helperPath = integration["PATH"]?.split(separator: ":", maxSplits: 1).first {
      let requestedPath = environment["PATH"] ?? ""
      environment["PATH"] =
        requestedPath.isEmpty ? String(helperPath) : "\(helperPath):\(requestedPath)"
    }
    environment["OPERATOR_SESSION_ID"] = sessionID.uuidString
    environment["OPERATOR_TOKEN"] = token
    return environment.merging(
      [
        "TERM": "xterm-256color", "COLORTERM": "truecolor", "COLORFGBG": colorForegroundBackground,
        "TERM_PROGRAM": "Operator",
        "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "LC_CTYPE": "UTF-8",
      ],
      uniquingKeysWith: { _, terminalValue in terminalValue })
  }
}

/// Supplies the conventional terminal colour hint that CLI applications use to choose a
/// readable automatic theme. `COLORFGBG` deliberately describes Operator's visible pane
/// rather than impersonating another terminal application.
enum TerminalColorEnvironment {
  static let darkForegroundBackground = "15;default;0"
  static let lightForegroundBackground = "0;default;15"

  @MainActor
  static func foregroundBackground(for appearance: NSAppearance) -> String {
    switch appearance.bestMatch(from: [.darkAqua, .aqua]) {
    case .darkAqua:
      darkForegroundBackground
    default:
      lightForegroundBackground
    }
  }
}

@MainActor
final class TerminalSession: NSObject, ObservableObject, Identifiable {
  /// An interactive login shell mirrors a user's normal terminal startup and therefore loads
  /// interactive configuration such as `~/.zshrc` before it starts a harness command.
  static let interactiveLoginCommandFlag = "-ilc"

  let id: UUID
  let request: LaunchRequest
  @Published private(set) var title: String
  @Published private(set) var status: SessionStatus = .running
  @Published private(set) var exitCode: Int32?
  @Published private(set) var changedFiles: [GitChangedFile] = []
  @Published private(set) var resourceSnapshot = ProcessResourceSnapshot.unavailable
  @Published private(set) var isResourcePaused = false

  fileprivate var terminalView: LocalProcessTerminalView?
  fileprivate var terminalDelegate: TerminalHost.Coordinator?
  private let onFinish: (UUID, Int32, Bool) -> Void
  private let onFilesChanged: (UUID, [GitChangedFile]) -> Void
  private let onFocus: (UUID) -> Void
  private let onOutput: (UUID) -> Void
  private var fileRadar: SessionFileRadar?
  private let integrationPreferences: OperatorIntegrationPreferences
  private var isFileWatchingEnabled: Bool
  private let ipcToken: String

  init(
    id: UUID = UUID(), request: LaunchRequest, onFinish: @escaping (UUID, Int32, Bool) -> Void,
    onFilesChanged: @escaping (UUID, [GitChangedFile]) -> Void,
    onFocus: @escaping (UUID) -> Void = { _ in },
    onOutput: @escaping (UUID) -> Void = { _ in },
    integrationPreferences: OperatorIntegrationPreferences = .default
  ) {
    self.id = id
    self.request = request
    self.title = request.title
    self.onFinish = onFinish
    self.onFilesChanged = onFilesChanged
    self.onFocus = onFocus
    self.onOutput = onOutput
    self.integrationPreferences = integrationPreferences
    isFileWatchingEnabled = integrationPreferences.fileWatchingEnabled
    ipcToken = OperatorSessionCredentials.shared.register(sessionID: id)
    super.init()
    startFileRadarIfNeeded()
  }

  deinit { OperatorSessionCredentials.shared.unregister(sessionID: id) }

  func attach(_ terminalView: LocalProcessTerminalView, delegate: TerminalHost.Coordinator) {
    if let terminalView = terminalView as? OperatorTerminalView {
      terminalView.onFocus = { [weak self] in
        guard let self else { return }
        self.onFocus(self.id)
      }
      terminalView.onOutput = { [weak self] _ in
        guard let self else { return }
        self.onOutput(self.id)
      }
    }
    terminalDelegate = delegate
    if let existingTerminal = self.terminalView {
      existingTerminal.processDelegate = delegate
      OperatorDebugLog.record("terminal.attach", "session=\(shortID) reused=true")
      return
    }
    self.terminalView = terminalView
    terminalView.processDelegate = delegate
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    let environment = launchEnvironment.map { "\($0.key)=\($0.value)" }
    let launchCommand = HarnessHookIntegration.prepare(
      request, sessionID: id, preferences: integrationPreferences
    ).command
    terminalView.startProcess(
      executable: shell, args: [Self.interactiveLoginCommandFlag, launchCommand],
      environment: environment, execName: shell,
      currentDirectory: request.directory)
    OperatorDebugLog.record("terminal.attach", "session=\(shortID) reused=false title=\(title)")
  }

  func terminate(force: Bool = false) {
    guard let view = terminalView else { return }
    if force, view.process.shellPid > 0 {
      kill(view.process.shellPid, SIGKILL)
    } else {
      view.terminate()
    }
  }

  func pauseForResourcePolicy() {
    guard status == .running, !isResourcePaused, let pid = processID, kill(pid, SIGSTOP) == 0 else {
      return
    }
    isResourcePaused = true
    OperatorDebugLog.record(
      "resource.paused", "Paused terminal process", metadata: ["session": shortID])
  }

  func resumeFromResourcePolicy() {
    guard isResourcePaused, let pid = processID, kill(pid, SIGCONT) == 0 else { return }
    isResourcePaused = false
    OperatorDebugLog.record(
      "resource.resumed", "Resumed terminal process", metadata: ["session": shortID])
  }

  func refreshResourceSnapshot(using sampler: ProcessResourceSampler, network: ResourceNetworkState)
  {
    resourceSnapshot = sampler.sample(pid: processID, network: network)
  }

  private var processID: Int32? {
    guard let terminalView, terminalView.process.shellPid > 0 else { return nil }
    return terminalView.process.shellPid
  }

  func setFileWatchingEnabled(_ enabled: Bool) {
    guard isFileWatchingEnabled != enabled else { return }
    isFileWatchingEnabled = enabled
    if enabled {
      startFileRadarIfNeeded()
    } else {
      fileRadar = nil
      changedFiles = []
    }
  }

  private func startFileRadarIfNeeded() {
    guard isFileWatchingEnabled, fileRadar == nil else { return }
    let radar = SessionFileRadar(directory: request.directory) { [weak self] files in
      Task { @MainActor in self?.updateFileChanges(files) }
    }
    fileRadar = radar
    changedFiles = radar.currentFiles
  }

  func sendInput(_ text: String) {
    terminalView?.send(txt: text)
  }

  func rename(to newTitle: String) {
    let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    title = trimmed
  }

  func didExit(code: Int32?) {
    guard status == .running else { return }
    let resolvedCode = code ?? -1
    let failed = code == nil || resolvedCode != 0
    exitCode = resolvedCode
    status = failed ? .failed : .exited
    isResourcePaused = false
    OperatorDebugLog.record(
      "terminal.exit", "session=\(shortID) code=\(resolvedCode) failed=\(failed)",
      level: failed ? .warning : .info)
    onFinish(id, resolvedCode, failed)
  }

  private var shortID: String { String(id.uuidString.prefix(8)) }

  fileprivate func updateTitle(_ value: String) {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    title = value
  }

  private func updateFileChanges(_ files: [GitChangedFile]) {
    changedFiles = files
    onFilesChanged(id, files)
  }

  var launchEnvironment: [String: String] {
    var requestOverrides = request.environment
    if request.harness == .codex {
      // Codex otherwise enables Kitty enhanced keyboard reporting. SwiftTerm supports that
      // protocol, but its AppKit text-input path can lose ownership when a live terminal is
      // re-parented between tabs. Codex officially supports this session-scoped compatibility
      // switch, which keeps its input behavior aligned with the reliable Claude/legacy path.
      requestOverrides["CODEX_TUI_DISABLE_KEYBOARD_ENHANCEMENT"] = "1"
    }
    return TerminalEnvironmentBuilder.build(
      inherited: ProcessInfo.processInfo.environment,
      integration: OperatorRuntime.environment,
      requestOverrides: requestOverrides,
      sessionID: id,
      token: ipcToken,
      colorForegroundBackground: TerminalColorEnvironment.foregroundBackground(
        for: NSApp.effectiveAppearance))
  }
}

enum WorkspaceTabTitlePolicy {
  static let maximumLength = 80

  static func normalized(_ rawTitle: String) -> String? {
    let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty, title.count <= maximumLength else { return nil }
    return title
  }
}

struct SessionOutputActivity: Equatable {
  var isProducingOutput = false
  var hasUnreadOutput = false

  static let idle = SessionOutputActivity()
}

enum NotificationPermissionPrompt: String, Identifiable {
  case request
  case denied

  var id: String { rawValue }
}

struct DeletedOpenFilePrompt: Identifiable, Equatable {
  let paneID: UUID
  let path: String

  var id: UUID { paneID }
  var title: String { URL(fileURLWithPath: path).lastPathComponent }
}

@MainActor
final class WorkspaceController: ObservableObject {
  @Published private(set) var sessions: [TerminalSession] = []
  @Published private(set) var tabs: [WorkspaceTab] = []
  @Published private(set) var selectedTabID: UUID?
  @Published private(set) var selectedPaneID: UUID?
  @Published var selectedSessionID: UUID?
  @Published private(set) var selectedEmptyPaneID: UUID?
  @Published private(set) var terminalLayout: TerminalLayout?
  @Published var alertMessage: String?
  @Published private(set) var markdownDocuments: [MarkdownDocument] = []
  @Published var selectedMarkdownPath: String?
  @Published private(set) var questions: [HarnessQuestion] = []
  @Published private(set) var interactions: [InteractionRecord] = []
  @Published private(set) var artifacts: [ArtifactDescriptor] = []
  @Published var selectedArtifactID: UUID?
  @Published var zoomedSessionID: UUID?
  @Published private(set) var exitClosePromptSessionID: UUID?
  @Published private(set) var sessionProgress: [UUID: Double] = [:]
  @Published private(set) var systemSurfaceRevision = 0
  @Published private(set) var focusedGitBranch: String?
  @Published private(set) var lastGitBranches: [UUID: String] = [:]
  @Published private(set) var lastGitBranchesBySession: [UUID: String] = [:]
  @Published private(set) var sessionOutputActivity: [UUID: SessionOutputActivity] = [:]
  @Published private(set) var resourceEnvironment = OperatorResourceEnvironment()
  @Published var notificationPermissionPrompt: NotificationPermissionPrompt?
  @Published var deletedOpenFilePrompt: DeletedOpenFilePrompt?

  let store: StateStore
  var notificationAuthorizationHandler: (@MainActor () async -> Bool)?
  var notificationAuthorizationStatusHandler:
    (@MainActor () async -> OperatorNotificationAuthorizationState)?
  var questionNotificationHandler: @MainActor (String, UUID, String) -> Void = {
    OperatorNotifications.postQuestion(sessionTitle: $0, sessionID: $1, message: $2)
  }
  var taskFinishedNotificationHandler: @MainActor (String, UUID, String, Int32, Bool) -> Void = {
    OperatorNotifications.postTaskFinished(
      sessionTitle: $0, sessionID: $1, workspace: $2, exitCode: $3, failed: $4)
  }
  private var activeProjectID: UUID?
  private var projectSessions: [UUID: [TerminalSession]] = [:]
  private var restoredProjectIDs = Set<UUID>()
  private var gitBranchRequestRevision = 0
  private var focusedBranchMonitor: Timer?
  private var outputIdleTimers: [UUID: Timer] = [:]
  private var harnessCompletionNotifiedSessions = Set<UUID>()
  private let resourceSampler = ProcessResourceSampler()
  private var resourceRefreshTimer: Timer?
  private var autoPausedSessionIDs = Set<UUID>()
  private var isResourceMonitoringActive = false

  init(store: StateStore, restoreAutomatically: Bool = false) {
    self.store = store
    activeProjectID = store.state.selectedProjectID
    if let projectID = store.state.selectedProjectID {
      tabs = store.state.projectTabs[projectID] ?? []
      selectedTabID = store.state.selectedTabIDs[projectID] ?? tabs.first?.id
      discardTerminallessTabs()
      terminalLayout = tabs.first(where: { $0.id == selectedTabID })?.layout
      selectedSessionID = tabs.first(where: { $0.id == selectedTabID })?.focusedSessionID
      selectedPaneID =
        tabs.first(where: { $0.id == selectedTabID })?.focusedPaneID
        ?? selectedSessionID ?? terminalLayout?.firstPaneID
      OperatorDebugLog.record(
        "controller.init",
        "project=\(shortID(projectID)) tabs=\(tabs.count) selectedTab=\(shortID(selectedTabID))")
    }
    artifacts = artifactsForActiveProject()
    if restoreAutomatically {
      Task { @MainActor [weak self] in self?.restoreSelectedProject() }
    }
    refreshFocusedGitBranch()
    startFocusedBranchMonitor()
  }

  deinit {
    focusedBranchMonitor?.invalidate()
    for timer in outputIdleTimers.values {
      timer.invalidate()
    }
    resourceRefreshTimer?.invalidate()
  }

  func handleSystemSleep() {
    guard isResourceMonitoringActive else { return }
    pauseBackgroundAgents(reason: "sleep", includeFocused: true)
  }

  func handleSystemWake() {
    guard isResourceMonitoringActive else { return }
    refreshResources()
    resumeAutoPausedAgentsIfAllowed()
  }

  func pause(_ session: TerminalSession) {
    session.pauseForResourcePolicy()
  }

  func resume(_ session: TerminalSession) {
    autoPausedSessionIDs.remove(session.id)
    session.resumeFromResourcePolicy()
  }

  func killRunaway(_ session: TerminalSession) {
    guard session.resourceSnapshot.isRunaway else { return }
    OperatorDebugLog.record(
      "resource.runaway.killed", "Force-killed runaway terminal process",
      level: .warning, metadata: ["session": shortID(session.id)])
    session.terminate(force: true)
  }

  func activateResourceMonitoring() {
    guard !isResourceMonitoringActive else { return }
    isResourceMonitoringActive = true
    resourceEnvironment.start()
    startResourceMonitoring()
  }

  private func startResourceMonitoring() {
    refreshResources()
    resourceRefreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) {
      [weak self] _ in
      Task { @MainActor in self?.refreshResources() }
    }
  }

  private func refreshResources() {
    resourceEnvironment.refreshPowerSource()
    for session in allSessions where session.status == .running {
      session.refreshResourceSnapshot(using: resourceSampler, network: resourceEnvironment.network)
    }
    if resourceEnvironment.powerSource == .battery {
      pauseBackgroundAgents(reason: "battery", includeFocused: false)
    } else {
      resumeAutoPausedAgentsIfAllowed()
    }
  }

  private func pauseBackgroundAgents(reason: String, includeFocused: Bool) {
    for session in allSessions
    where session.status == .running && session.request.harness != .generic {
      guard includeFocused || session.id != selectedSessionID else { continue }
      guard !session.isResourcePaused else { continue }
      session.pauseForResourcePolicy()
      if session.isResourcePaused { autoPausedSessionIDs.insert(session.id) }
    }
    OperatorDebugLog.record(
      "resource.background-paused", "Paused background agents for \(reason)",
      metadata: ["count": String(autoPausedSessionIDs.count)])
  }

  private func resumeAutoPausedAgentsIfAllowed() {
    guard resourceEnvironment.powerSource != .battery else { return }
    for id in autoPausedSessionIDs {
      session(with: id)?.resumeFromResourcePolicy()
    }
    autoPausedSessionIDs.removeAll()
  }

  var selectedSession: TerminalSession? { sessions.first { $0.id == selectedSessionID } }
  var canSplitFocusedPane: Bool { selectedPaneID != nil }
  var exitClosePromptSession: TerminalSession? {
    exitClosePromptSessionID.flatMap { session(with: $0) }
  }
  var selectedTab: WorkspaceTab? { tabs.first { $0.id == selectedTabID } }
  func session(for tab: WorkspaceTab) -> TerminalSession? {
    tab.focusedSessionID.flatMap { session(with: $0) }
  }

  func outputActivity(for tab: WorkspaceTab) -> SessionOutputActivity {
    tab.layout.terminalIDs.reduce(into: .idle) { aggregate, sessionID in
      let activity = sessionOutputActivity[sessionID] ?? .idle
      aggregate.isProducingOutput =
        aggregate.isProducingOutput || activity.isProducingOutput
      aggregate.hasUnreadOutput = aggregate.hasUnreadOutput || activity.hasUnreadOutput
    }
  }

  func outputActivityDescription(for tab: WorkspaceTab) -> String {
    let activity = outputActivity(for: tab)
    if activity.isProducingOutput && activity.hasUnreadOutput {
      return "Producing unread terminal output"
    }
    if activity.isProducingOutput { return "Producing terminal output" }
    if activity.hasUnreadOutput { return "Unread terminal output" }
    return "No unread terminal output"
  }

  func questionCount(for tab: WorkspaceTab) -> Int {
    let sessionIDs = tab.layout.terminalIDs
    return questions.count { sessionIDs.contains($0.sessionID) }
  }

  func questionCount(forProjectID projectID: UUID) -> Int {
    let sessionIDs = tabs(forProjectID: projectID).reduce(into: Set<UUID>()) {
      $0.formUnion($1.layout.terminalIDs)
    }
    return questions.count { sessionIDs.contains($0.sessionID) }
  }

  func paneState(for session: TerminalSession) -> AgentPaneState {
    if session.status == .failed { return .failed }
    if questions.contains(where: { $0.sessionID == session.id }) { return .needsAnswer }
    if store.paneMetadata(for: session.id).isAwaitingReview { return .awaitingReview }
    if !session.changedFiles.isEmpty { return .changedFiles }
    if (sessionOutputActivity[session.id] ?? .idle).isProducingOutput { return .running }
    return .idle
  }

  func paneMetadata(for session: TerminalSession) -> AgentPaneMetadata {
    store.paneMetadata(for: session.id)
  }

  func setPaneNotificationPolicy(_ policy: PaneNotificationPolicy, for session: TerminalSession) {
    store.setPaneNotificationPolicy(policy, for: session.id)
    objectWillChange.send()
  }

  func markPaneReviewed(_ session: TerminalSession) {
    store.setPaneAwaitingReview(false, for: session.id)
    objectWillChange.send()
  }
  var selectedProject: Project? {
    store.state.projects.first { $0.id == store.state.selectedProjectID }
  }

  func lastGitBranch(forProjectID projectID: UUID) -> String? {
    if projectID == store.state.selectedProjectID { return focusedGitBranch }
    return lastGitBranches[projectID]
  }

  /// The last Git branch successfully read while this terminal was focused.
  func lastGitBranch(forSessionID sessionID: UUID) -> String? {
    if sessionID == selectedSessionID {
      return focusedGitBranch ?? lastGitBranchesBySession[sessionID]
    }
    return lastGitBranchesBySession[sessionID]
  }

  func activePaneCount(for projectID: UUID) -> Int {
    tabs(forProjectID: projectID).reduce(into: 0) {
      $0 += $1.layout.contentPaneIDs.count
    }
  }

  func tabs(forProjectID projectID: UUID) -> [WorkspaceTab] {
    let projectTabs =
      projectID == activeProjectID ? tabs : store.state.projectTabs[projectID] ?? []
    return projectTabs.filter { !$0.layout.contentPaneIDs.isEmpty }
  }
  var selectedMarkdownDocument: MarkdownDocument? {
    markdownDocuments.first { $0.path == selectedMarkdownPath }
  }
  var statusBarState: OperatorStatusBarState {
    OperatorStatusBarState(
      sessionTitle: selectedSession?.title,
      workspaceName: selectedSession.flatMap { workspace(for: $0)?.displayName }
        ?? selectedSession.map { URL(fileURLWithPath: $0.request.directory).lastPathComponent },
      isRunning: selectedSession?.status == .running,
      changedFileCount: selectedSession?.changedFiles.count ?? 0, agentCount: sessions.count,
      question: questions.first)
  }

  var systemSurfaceState: NativeSurfaceState {
    let liveSessions = allSessions
    let progress = liveSessions.filter { $0.status == .running }.compactMap {
      sessionProgress[$0.id]
    }
    return NativeSurfaceState(
      runningHarnessCount: liveSessions.filter { $0.status == .running }.count,
      pendingQuestionCount: questions.count,
      failedHarnessCount: liveSessions.filter { $0.status == .failed }.count,
      progressValues: progress
    )
  }

  var allSessions: [TerminalSession] {
    var sessionsByID: [UUID: TerminalSession] = [:]
    for session in sessions { sessionsByID[session.id] = session }
    for session in projectSessions.values.flatMap({ $0 }) { sessionsByID[session.id] = session }
    return Array(sessionsByID.values)
  }

  func harnessKind(for sessionID: UUID?) -> HarnessKind {
    guard let sessionID else { return .generic }
    if let active = session(with: sessionID) { return active.request.harness }
    if let recent = store.state.recentSessions.first(where: { $0.id == sessionID }) {
      return recent.harness ?? HarnessKind.detect(command: recent.command)
    }
    return .generic
  }

  private func workspace(for session: TerminalSession) -> Workspace? {
    guard let projectID = session.request.projectID, let workspaceID = session.request.workspaceID
    else { return nil }
    return store.state.projects.first(where: { $0.id == projectID })?.workspaces.first(where: {
      $0.id == workspaceID
    })
  }

  func launch(
    _ request: LaunchRequest, copying brief: TaskBrief? = nil, sessionID: UUID? = nil,
    saveRecipe: Bool = true, intoPane paneID: UUID? = nil, tabID: UUID? = nil
  ) {
    do {
      try request.validate()
      OperatorDebugLog.record(
        "launch.request",
        "title=\(request.title) harness=\(request.harness.rawValue) project=\(shortID(request.projectID)) pane=\(shortID(paneID)) tab=\(shortID(tabID))"
      )
      if let projectID = request.projectID, projectID != activeProjectID {
        selectProject(projectID)
      }
      let id = sessionID ?? UUID()
      let projectName = request.projectID.flatMap { id in
        store.state.projects.first(where: { $0.id == id })?.name
      }
      let preparedRequest = request.preparedForNewSession(id: id, projectName: projectName)
      let session = TerminalSession(
        id: id,
        request: preparedRequest,
        onFinish: { [weak self] id, code, failed in
          self?.sessionFinished(id: id, code: code, failed: failed)
        },
        onFilesChanged: { [weak self] id, files in self?.sessionFilesChanged(id: id, files: files)
        },
        onFocus: { [weak self] id in self?.selectTerminal(id) },
        onOutput: { [weak self] id in self?.recordTerminalOutput(sessionID: id) },
        integrationPreferences: store.state.integrationPreferences
      )
      sessions.append(session)
      selectedSessionID = id
      selectedPaneID = id
      selectedEmptyPaneID = nil
      insertIntoTab(id, title: preparedRequest.title, intoPane: paneID, tabID: tabID)
      OperatorDebugLog.record(
        "launch.ready",
        "session=\(shortID(id)) selectedTab=\(shortID(selectedTabID)) layoutLeaves=\(terminalLayout?.terminalIDs.count ?? 0)"
      )
      selectedMarkdownPath = nil
      refreshFocusedGitBranch()
      store.recordStart(preparedRequest, id: id)
      if saveRecipe, let projectID = preparedRequest.projectID,
        let workspaceID = preparedRequest.workspaceID
      {
        let resumeIdentifier =
          preparedRequest.resumeIdentifier ?? preparedRequest.managedSessionName
        let automaticallyRestorable =
          (preparedRequest.harness == .generic
            && InteractiveShellRestorationPolicy.isSafeInteractiveShellCommand(request.command))
          || (HarnessAdapters.adapter(for: preparedRequest.harness).capabilities.autoRestorable
            && resumeIdentifier?.isEmpty == false)
        store.saveSessionRecipe(
          SessionRecipe(
            id: id, projectID: projectID, workspaceID: workspaceID, title: preparedRequest.title,
            command: request.command, environment: preparedRequest.environment,
            harness: preparedRequest.harness, resumeIdentifier: resumeIdentifier,
            restoreOnOpen: automaticallyRestorable, tabID: selectedTabID))
        persistCurrentTabs()
      }
      if let brief {
        store.saveTaskBrief(
          sessionID: id, objective: brief.objective, constraints: brief.constraints,
          acceptanceCriteria: brief.acceptanceCriteria, title: preparedRequest.title)
      }
    } catch {
      alertMessage = error.localizedDescription
      OperatorDebugLog.record(
        "launch.failed", "title=\(request.title) error=\(error.localizedDescription)")
    }
  }

  func launchQuickHarness(_ kind: HarnessKind, intoPane paneID: UUID? = nil) {
    guard let project = selectedProject else {
      alertMessage = "Create or select a project before starting a harness."
      return
    }
    guard let workspace = project.workspaces.first else {
      alertMessage = "Add a workspace to \(project.name) before starting a harness."
      return
    }
    guard HarnessInstallation.isInstalled(kind) else {
      alertMessage = HarnessInstallation.unavailableHelp(for: kind)
      return
    }
    let command: String
    switch kind {
    case .codex: command = HarnessLaunchArguments.command("codex", arguments: store.state.integrationPreferences.codexAdditionalArguments)
    case .claudeCode: command = HarnessLaunchArguments.command("claude", arguments: store.state.integrationPreferences.claudeAdditionalArguments)
    case .generic:
      alertMessage = "Choose Codex or Claude Code from the empty workspace launcher."
      return
    }
    let existingHarnessCount = sessions.count { $0.request.harness == kind }
    let title =
      existingHarnessCount == 0
      ? kind.displayName : "\(kind.displayName) \(existingHarnessCount + 1)"
    launch(
      LaunchRequest(
        title: title, command: command, directory: workspace.directory,
        projectID: project.id, workspaceID: workspace.id, harness: kind), intoPane: paneID)
  }

  func launchShell(intoPane paneID: UUID? = nil) {
    guard let project = selectedProject else {
      alertMessage = "Create or select a project before starting a terminal."
      return
    }
    guard let workspace = project.workspaces.first else {
      alertMessage = "Add a workspace to \(project.name) before starting a terminal."
      return
    }
    let shell =
      ProcessInfo.processInfo.environment["SHELL"].flatMap { value in
        value.isEmpty ? nil : value
      } ?? "/bin/zsh"
    let existingCount = sessions.count { $0.request.harness == .generic }
    let title = existingCount == 0 ? "Terminal" : "Terminal \(existingCount + 1)"
    launch(
      LaunchRequest(
        title: title, command: shell, directory: workspace.directory,
        projectID: project.id, workspaceID: workspace.id, harness: .generic), intoPane: paneID)
  }

  func close(_ session: TerminalSession) {
    session.terminate()
    sessions.removeAll { $0.id == session.id }
    if let tabIndex = tabs.firstIndex(where: { $0.layout.contains(session.id) }) {
      if let layout = tabs[tabIndex].layout.removing(session.id), !layout.contentPaneIDs.isEmpty {
        tabs[tabIndex].layout = layout
        tabs[tabIndex].focusedSessionID = layout.firstTerminalID
        tabs[tabIndex].focusedPaneID = layout.firstPaneID
      } else {
        tabs.remove(at: tabIndex)
      }
    }
    if selectedSessionID == session.id { selectedSessionID = selectedTab?.focusedSessionID }
    if selectedTabID != nil, !tabs.contains(where: { $0.id == selectedTabID }) {
      selectedTabID = tabs.last?.id
    }
    terminalLayout = selectedTab?.layout
    selectedSessionID = selectedTab?.focusedSessionID
    selectedPaneID = selectedTab?.focusedPaneID ?? selectedSessionID ?? terminalLayout?.firstPaneID
    synchronizeSelectionFromFocusedPane()
    sessionProgress[session.id] = nil
    sessionOutputActivity[session.id] = nil
    outputIdleTimers.removeValue(forKey: session.id)?.invalidate()
    lastGitBranchesBySession[session.id] = nil
    if exitClosePromptSessionID == session.id { exitClosePromptSessionID = nil }
    store.removeSessionRecipe(session.id)
    if let projectID = session.request.projectID {
      persistCurrentTabs(for: projectID)
    }
  }

  /// Closes every pane in a tab as one explicit user action. Terminal processes are terminated
  /// through the existing session path so recipes, activity, and resource monitoring are cleaned
  /// up consistently before the tab itself is removed.
  func closeTab(_ tabID: UUID) {
    guard let originalTab = tabs.first(where: { $0.id == tabID }) else { return }
    let sessionIDs = Array(originalTab.layout.terminalIDs)
    for sessionID in sessionIDs {
      if let session = session(with: sessionID) { close(session) }
    }

    guard let remainingIndex = tabs.firstIndex(where: { $0.id == tabID }) else { return }
    let markdownPaths = originalTab.layout.panesInDisplayOrder.compactMap { pane -> String? in
      guard case .markdown(_, let path, _) = pane else { return nil }
      return path
    }
    tabs.remove(at: remainingIndex)
    if selectedTabID == tabID || selectedTabID.map({ id in !tabs.contains(where: { $0.id == id }) }) == true {
      selectedTabID = tabs.last?.id
    }
    terminalLayout = selectedTab?.layout
    selectedPaneID = selectedTab?.focusedPaneID ?? terminalLayout?.firstPaneID
    selectedSessionID = selectedTab?.focusedSessionID
    synchronizeSelectionFromFocusedPane()
    for path in markdownPaths
    where !tabs.contains(where: { $0.layout.markdownPane(forPath: path) != nil }) {
      markdownDocuments.removeAll { $0.path == path }
    }
    persistCurrentTabs()
    OperatorDebugLog.record(
      "tab.close", "tab=\(shortID(tabID)) panes=\(originalTab.layout.paneIDs.count)")
  }

  func dismissExitClosePrompt() {
    exitClosePromptSessionID = nil
  }

  func duplicate(_ session: TerminalSession) { launch(session.request) }

  func restart(_ session: TerminalSession) {
    let request = session.request
    close(session)
    launch(request)
  }

  func resume(_ recent: RecentSession) {
    guard recent.isResumable,
      let projectID = recent.projectID,
      let workspaceID = recent.workspaceID,
      let project = store.state.projects.first(where: { $0.id == projectID }),
      let workspace = project.workspaces.first(where: { $0.id == workspaceID }),
      let request = LaunchRequest.claudeResume(recent: recent, workspace: workspace)
    else {
      alertMessage =
        "This saved session no longer has its project, working directory, or managed Claude session name."
      return
    }
    do { try request.validate() } catch {
      alertMessage = error.localizedDescription
      return
    }
    launch(request, copying: store.taskBrief(for: recent.id))
  }

  func restoreSelectedProject() {
    guard let projectID = store.state.selectedProjectID,
      store.state.projects.contains(where: { $0.id == projectID })
    else { return }
    restoreProject(projectID)
  }

  private func restoreProject(_ projectID: UUID) {
    guard !restoredProjectIDs.contains(projectID),
      let project = store.state.projects.first(where: { $0.id == projectID })
    else { return }
    restoredProjectIDs.insert(projectID)
    let persistedTabs = store.state.projectTabs[projectID] ?? []
    let hasPersistedTabState = store.state.projectTabs[projectID] != nil
    let referencedSessionIDs = Set(persistedTabs.flatMap(\.layout.terminalIDs))
    let restorableRecipes = store.state.sessionRecipes.filter { recipe in
      guard recipe.projectID == projectID, recipe.isAutoRestorable,
        !hasPersistedTabState || referencedSessionIDs.contains(recipe.id),
        let workspace = project.workspaces.first(where: { $0.id == recipe.workspaceID }),
        FileManager.default.fileExists(atPath: workspace.directory)
      else { return false }
      return HarnessAdapters.adapter(for: recipe.harness).prepareResume(
        recipe: recipe, workspace: workspace) != nil
    }
    let restorableIDs = Set(restorableRecipes.map(\.id))
    tabs = persistedTabs.compactMap { original in
      var tab = original
      tab.layout = tab.layout.replacingUnavailableTerminals(
        availableSessionIDs: restorableIDs)
      // A tab named after a session is misleading once every terminal in it is unavailable.
      // Mixed layouts retain explicit empty panes, but wholly unavailable tabs are discarded.
      guard !tab.layout.contentPaneIDs.isEmpty else { return nil }
      if let focused = tab.focusedSessionID, !tab.layout.contains(focused) {
        tab.focusedSessionID = tab.layout.firstTerminalID
      }
      if tab.focusedPaneID.map({ tab.layout.paneIDs.contains($0) }) != true {
        tab.focusedPaneID = tab.focusedSessionID ?? tab.layout.firstPaneID
      }
      return tab
    }
    selectedTabID = store.state.selectedTabIDs[projectID] ?? tabs.first?.id
    terminalLayout = selectedTab?.layout
    selectedPaneID = selectedTab?.focusedPaneID ?? terminalLayout?.firstPaneID
    OperatorDebugLog.record(
      "restore.begin",
      "project=\(shortID(projectID)) tabs=\(tabs.count) recipes=\(store.state.sessionRecipes.count { $0.projectID == projectID })"
    )
    for recipe in restorableRecipes {
      guard !sessions.contains(where: { $0.id == recipe.id }),
        let workspace = project.workspaces.first(where: { $0.id == recipe.workspaceID }),
        FileManager.default.fileExists(atPath: workspace.directory)
      else { continue }
      guard
        let request = HarnessAdapters.adapter(for: recipe.harness).prepareResume(
          recipe: recipe, workspace: workspace)
      else { continue }
      let tabID = recipe.tabID ?? tabs.first(where: { $0.layout.contains(recipe.id) })?.id
      OperatorDebugLog.record(
        "restore.session",
        "session=\(shortID(recipe.id)) title=\(recipe.title) tab=\(shortID(tabID)) resumed=\(request.command != recipe.command)"
      )
      launch(request, sessionID: recipe.id, saveRecipe: false, tabID: tabID)
    }
    persistCurrentTabs(for: projectID)
  }

  func selectProject(_ projectID: UUID?) {
    if let activeProjectID { projectSessions[activeProjectID] = sessions }
    store.selectProject(projectID)
    activeProjectID = projectID
    sessions = projectID.flatMap { projectSessions.removeValue(forKey: $0) } ?? []
    artifacts = artifactsForActiveProject()
    tabs = projectID.flatMap { store.state.projectTabs[$0] } ?? []
    selectedTabID = projectID.flatMap { store.state.selectedTabIDs[$0] } ?? tabs.first?.id
    discardTerminallessTabs()
    terminalLayout = selectedTab?.layout
    selectedSessionID = selectedTab?.focusedSessionID ?? terminalLayout?.firstTerminalID
    selectedPaneID = selectedTab?.focusedPaneID ?? selectedSessionID ?? terminalLayout?.firstPaneID
    synchronizeSelectionFromFocusedPane()
    OperatorDebugLog.record(
      "project.select",
      "project=\(shortID(projectID)) tabs=\(tabs.count) selectedTab=\(shortID(selectedTabID))")
    if let projectID, sessions.isEmpty { restoreProject(projectID) }
    markTabOutputRead(selectedTabID)
    refreshFocusedGitBranch()
  }

  func openManagedProject(_ projectID: UUID) {
    store.showProjectInSidebar(projectID)
    selectProject(projectID)
  }

  func hideProjectFromSidebar(_ projectID: UUID) {
    store.hideProjectFromSidebar(projectID)
    if store.state.selectedProjectID != projectID { selectProject(store.state.selectedProjectID) }
  }

  func deleteProjectMetadata(_ projectID: UUID) {
    let wasActive = store.state.selectedProjectID == projectID
    store.deleteProjectMetadata(projectID)
    if wasActive { selectProject(store.state.selectedProjectID) }
  }

  func setResumeIdentifier(_ identifier: String?, for session: TerminalSession) {
    store.setResumeIdentifier(identifier, for: session.id)
  }

  func openMarkdown(_ rawPath: String) {
    do {
      if let workspaceDirectory = selectedProject?.workspaces.first?.directory {
        let path = try MarkdownFile.validate(rawPath, withinDirectory: workspaceDirectory)
        presentMarkdown(path, withinDirectory: workspaceDirectory)
      } else {
        let path = try MarkdownFile.validate(rawPath)
        presentMarkdown(path)
      }
    } catch {
      alertMessage = error.localizedDescription
    }
  }

  func openMarkdown(_ rawPath: String, requestedBy sessionID: UUID) {
    guard let session = session(with: sessionID) else {
      alertMessage = "The originating terminal is no longer running."
      return
    }
    do {
      let path = try MarkdownFile.validate(rawPath, withinDirectory: session.request.directory)
      presentMarkdown(path, withinDirectory: session.request.directory)
    } catch {
      alertMessage = error.localizedDescription
    }
  }

  private func presentMarkdown(_ path: String, withinDirectory: String? = nil) {
    let workspaceDirectory =
      withinDirectory ?? selectedProject?.workspaces.first?.directory
      ?? URL(fileURLWithPath: path).deletingLastPathComponent().path
    if markdownDocuments.first(where: { $0.path == path }) == nil {
      markdownDocuments.append(
        MarkdownDocument(
          path: path, allowedDirectory: workspaceDirectory,
          watchForChanges: store.state.integrationPreferences.fileWatchingEnabled))
    }
    if let emptyPaneID = selectedEmptyPaneID, let layout = terminalLayout,
      let updated = layout.replacingEmptyPane(
        emptyPaneID,
        with: .markdown(
          emptyPaneID, path: path, workspaceDirectory: workspaceDirectory))
    {
      terminalLayout = updated
      selectedPaneID = emptyPaneID
      updateSelectedTab {
        $0.layout = updated
        $0.focusedPaneID = emptyPaneID
        $0.focusedSessionID = nil
      }
      synchronizeSelectionFromFocusedPane()
      persistCurrentTabs()
      return
    }
    if let existing = tabs.first(where: { $0.layout.markdownPane(forPath: path) != nil }),
      let pane = existing.layout.markdownPane(forPath: path)
    {
      selectTab(existing.id)
      selectContentPane(pane.id)
      return
    }
    let paneID = UUID()
    let tab = WorkspaceTab(
      id: UUID(), title: URL(fileURLWithPath: path).lastPathComponent,
      layout: .markdown(paneID, path: path, workspaceDirectory: workspaceDirectory),
      focusedSessionID: nil, focusedPaneID: paneID)
    tabs.append(tab)
    selectedTabID = tab.id
    terminalLayout = tab.layout
    selectedPaneID = paneID
    selectedSessionID = nil
    selectedEmptyPaneID = nil
    selectedMarkdownPath = path
    selectedArtifactID = nil
    persistCurrentTabs()
  }

  func selectTerminal(_ sessionID: UUID) {
    if let tab = tabs.first(where: { $0.layout.contains(sessionID) }), tab.id != selectedTabID {
      selectTab(tab.id)
    }
    selectedSessionID = sessionID
    selectedPaneID = sessionID
    markSessionOutputRead(sessionID)
    selectedEmptyPaneID = nil
    updateSelectedTab {
      $0.focusedSessionID = sessionID
      $0.focusedPaneID = sessionID
    }
    persistCurrentTabs()
    selectedMarkdownPath = nil
    refreshFocusedGitBranch()
  }

  func selectEmptyPane(_ paneID: UUID) {
    guard terminalLayout?.emptyPaneIDs.contains(paneID) == true else { return }
    selectedSessionID = nil
    selectedPaneID = paneID
    selectedEmptyPaneID = paneID
    selectedMarkdownPath = nil
    updateSelectedTab {
      $0.focusedPaneID = paneID
      $0.focusedSessionID = nil
    }
    persistCurrentTabs()
    refreshFocusedGitBranch()
  }

  func selectTab(_ tabID: UUID) {
    guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
    selectedTabID = tabID
    terminalLayout = tab.layout
    // A question can arrive from a non-focused pane in a split. Prefer that
    // pane when opening the tab so the prompt is immediately answerable.
    let questionSessionID = questions.first { tab.layout.contains($0.sessionID) }?.sessionID
    selectedPaneID =
      questionSessionID ?? tab.focusedPaneID ?? tab.focusedSessionID ?? tab.layout.firstPaneID
    synchronizeSelectionFromFocusedPane()
    markTabOutputRead(tabID)
    OperatorDebugLog.record(
      "tab.select",
      "tab=\(shortID(tabID)) leaves=\(tab.layout.paneIDs.count) focused=\(shortID(selectedPaneID))"
    )
    persistCurrentTabs()
    refreshFocusedGitBranch()
  }

  func selectContentPane(_ paneID: UUID) {
    if let tab = tabs.first(where: { $0.layout.paneIDs.contains(paneID) }),
      tab.id != selectedTabID
    {
      selectTab(tab.id)
    }
    guard terminalLayout?.paneIDs.contains(paneID) == true else { return }
    selectedPaneID = paneID
    updateSelectedTab { tab in
      tab.focusedPaneID = paneID
      if case .terminal? = tab.layout.pane(withID: paneID) {
        tab.focusedSessionID = paneID
      } else {
        tab.focusedSessionID = nil
      }
    }
    synchronizeSelectionFromFocusedPane()
    presentDeletionPromptIfFocusedFileIsMissing()
    persistCurrentTabs()
  }

  private func synchronizeSelectionFromFocusedPane() {
    guard let selectedPaneID, let pane = terminalLayout?.pane(withID: selectedPaneID) else {
      selectedSessionID = nil
      selectedEmptyPaneID = nil
      selectedMarkdownPath = nil
      return
    }
    switch pane {
    case .terminal(let sessionID):
      selectedSessionID = sessionID
      selectedEmptyPaneID = nil
      selectedMarkdownPath = nil
      markSessionOutputRead(sessionID)
    case .markdown(_, let path, let workspaceDirectory):
      selectedSessionID = nil
      selectedEmptyPaneID = nil
      selectedMarkdownPath = path
      if markdownDocuments.first(where: { $0.path == path }) == nil {
        markdownDocuments.append(
          MarkdownDocument(
            path: path, allowedDirectory: workspaceDirectory,
            watchForChanges: store.state.integrationPreferences.fileWatchingEnabled))
      }
    case .file:
      selectedSessionID = nil
      selectedEmptyPaneID = nil
      selectedMarkdownPath = nil
    case .empty(let paneID):
      selectedSessionID = nil
      selectedEmptyPaneID = paneID
      selectedMarkdownPath = nil
    case .split:
      break
    }
    selectedArtifactID = nil
  }

  func openFile(_ rawPath: String) {
    guard let workspaceDirectory = selectedProject?.workspaces.first?.directory else {
      alertMessage = "Select a project with a working directory before opening files."
      return
    }
    let path: String
    do {
      path = try WorkspacePathPolicy.canonicalContainedPath(
        rawPath, within: workspaceDirectory)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
        !isDirectory.boolValue, FileManager.default.isReadableFile(atPath: path)
      else {
        throw CocoaError(.fileReadNoPermission)
      }
    } catch {
      alertMessage = error.localizedDescription
      return
    }

    // Markdown is a first-class document in Operator. Route it directly to the
    // rendered viewer instead of opening a source-file pane with a second action.
    if MarkdownFile.supportedExtensions.contains(
      URL(fileURLWithPath: path).pathExtension.lowercased())
    {
      openMarkdown(path)
      return
    }

    if tabs.contains(where: { $0.layout.firstFilePane != nil }) == false,
      let emptyPaneID = selectedEmptyPaneID, let layout = terminalLayout,
      let updated = layout.replacingEmptyPane(
        emptyPaneID,
        with: .file(emptyPaneID, path: path, workspaceDirectory: workspaceDirectory))
    {
      terminalLayout = updated
      selectedPaneID = emptyPaneID
      updateSelectedTab {
        $0.layout = updated
        $0.focusedPaneID = emptyPaneID
        $0.focusedSessionID = nil
      }
      synchronizeSelectionFromFocusedPane()
    } else if let index = tabs.firstIndex(where: { $0.layout.firstFilePane != nil }),
      let existing = tabs[index].layout.firstFilePane,
      let updated = tabs[index].layout.replacingPane(
        existing.id,
        with: .file(existing.id, path: path, workspaceDirectory: workspaceDirectory))
    {
      tabs[index].layout = updated
      tabs[index].title = URL(fileURLWithPath: path).lastPathComponent
      tabs[index].focusedPaneID = existing.id
      tabs[index].focusedSessionID = nil
      selectTab(tabs[index].id)
      selectContentPane(existing.id)
    } else {
      let paneID = UUID()
      let tab = WorkspaceTab(
        id: UUID(), title: URL(fileURLWithPath: path).lastPathComponent,
        layout: .file(paneID, path: path, workspaceDirectory: workspaceDirectory),
        focusedSessionID: nil, focusedPaneID: paneID)
      tabs.append(tab)
      selectedTabID = tab.id
      terminalLayout = tab.layout
      selectedPaneID = paneID
      synchronizeSelectionFromFocusedPane()
    }
    persistCurrentTabs()
  }

  func recordTerminalOutput(sessionID: UUID, isVisible: Bool? = nil) {
    guard let session = session(with: sessionID) else { return }
    // New output means the agent has resumed work after awaiting review.
    if store.paneMetadata(for: sessionID).isAwaitingReview {
      store.setPaneAwaitingReview(false, for: sessionID)
    }
    var activity = sessionOutputActivity[sessionID] ?? .idle
    let wasUnread = activity.hasUnreadOutput
    activity.isProducingOutput = true
    let outputIsVisible =
      isVisible
      ?? (NSRunningApplication.current.isActive
        && store.state.selectedProjectID == session.request.projectID
        && selectedTab?.layout.contains(sessionID) == true)
    if !outputIsVisible { activity.hasUnreadOutput = true }
    sessionOutputActivity[sessionID] = activity
    if !wasUnread, activity.hasUnreadOutput {
      OperatorDebugLog.record(
        "terminal.output.unread",
        "session=\(shortID(sessionID)) harness=\(session.request.harness.rawValue)")
    }

    outputIdleTimers.removeValue(forKey: sessionID)?.invalidate()
    outputIdleTimers[sessionID] = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: false) {
      [weak self] _ in
      Task { @MainActor in self?.finishTerminalOutputBurst(sessionID: sessionID) }
    }
  }

  func finishTerminalOutputBurst(sessionID: UUID) {
    outputIdleTimers.removeValue(forKey: sessionID)?.invalidate()
    guard var activity = sessionOutputActivity[sessionID] else { return }
    activity.isProducingOutput = false
    sessionOutputActivity[sessionID] = activity == .idle ? nil : activity
  }

  private func markSessionOutputRead(_ sessionID: UUID) {
    guard var activity = sessionOutputActivity[sessionID], activity.hasUnreadOutput else { return }
    activity.hasUnreadOutput = false
    sessionOutputActivity[sessionID] = activity == .idle ? nil : activity
  }

  private func markTabOutputRead(_ tabID: UUID?) {
    guard let tabID, let tab = tabs.first(where: { $0.id == tabID }) else { return }
    tab.layout.terminalIDs.forEach(markSessionOutputRead)
  }

  @discardableResult
  func renameTab(_ tabID: UUID, to rawTitle: String) -> Bool {
    guard let projectID = activeProjectID else { return false }
    return renameTab(tabID, inProject: projectID, to: rawTitle)
  }

  @discardableResult
  func renameTab(_ tabID: UUID, inProject projectID: UUID, to rawTitle: String) -> Bool {
    guard let title = WorkspaceTabTitlePolicy.normalized(rawTitle),
      store.state.projects.contains(where: { $0.id == projectID })
    else {
      OperatorDebugLog.record(
        "tab.rename.reject",
        "project=\(shortID(projectID)) tab=\(shortID(tabID)) reason=invalid",
        level: .warning)
      return false
    }

    if projectID == activeProjectID {
      guard let index = tabs.firstIndex(where: { $0.id == tabID }) else {
        OperatorDebugLog.record(
          "tab.rename.reject",
          "project=\(shortID(projectID)) tab=\(shortID(tabID)) reason=missing",
          level: .warning)
        return false
      }
      guard tabs[index].title != title else { return true }
      tabs[index].title = title
      persistCurrentTabs(for: projectID)
    } else {
      var projectTabs = store.state.projectTabs[projectID] ?? []
      guard let index = projectTabs.firstIndex(where: { $0.id == tabID }) else {
        OperatorDebugLog.record(
          "tab.rename.reject",
          "project=\(shortID(projectID)) tab=\(shortID(tabID)) reason=missing",
          level: .warning)
        return false
      }
      guard projectTabs[index].title != title else { return true }
      projectTabs[index].title = title
      store.saveTabs(
        projectTabs, selectedTabID: store.state.selectedTabIDs[projectID], for: projectID)
    }

    OperatorDebugLog.record(
      "tab.rename",
      "project=\(shortID(projectID)) tab=\(shortID(tabID)) titleLength=\(title.count)")
    return true
  }

  @discardableResult
  func selectTab(_ tabID: UUID, inProject projectID: UUID) -> Bool {
    guard store.state.projects.contains(where: { $0.id == projectID }),
      tabs(forProjectID: projectID).contains(where: { $0.id == tabID })
    else {
      OperatorDebugLog.record(
        "sidebar.tab.reject",
        "project=\(shortID(projectID)) tab=\(shortID(tabID)) reason=missing")
      return false
    }
    if activeProjectID != projectID { selectProject(projectID) }
    guard tabs.contains(where: { $0.id == tabID }) else {
      OperatorDebugLog.record(
        "sidebar.tab.reject",
        "project=\(shortID(projectID)) tab=\(shortID(tabID)) reason=unrestorable")
      return false
    }
    selectTab(tabID)
    OperatorDebugLog.record(
      "sidebar.tab.select",
      "project=\(shortID(projectID)) tab=\(shortID(tabID))")
    return selectedTabID == tabID && store.state.selectedProjectID == projectID
  }

  func splitRatio(for path: String) -> Double {
    selectedTab?.splitRatios[path] ?? 0.5
  }

  func setSplitRatio(_ ratio: Double, for path: String) {
    let bounded = min(0.9, max(0.1, ratio))
    guard abs(splitRatio(for: path) - bounded) > 0.002 else { return }
    updateSelectedTab { $0.splitRatios[path] = bounded }
    persistCurrentTabs()
  }

  func closeMarkdown(_ document: MarkdownDocument) {
    let paneIDs = tabs.compactMap { $0.layout.markdownPane(forPath: document.path)?.id }
    for paneID in paneIDs { closeContentPane(paneID) }
    if !tabs.contains(where: { $0.layout.markdownPane(forPath: document.path) != nil }) {
      markdownDocuments.removeAll { $0.path == document.path }
    }
  }

  func closeContentPane(_ paneID: UUID) {
    guard let tabIndex = tabs.firstIndex(where: { $0.layout.paneIDs.contains(paneID) }) else {
      return
    }
    let closingPath: String? = {
      guard case .markdown(_, let path, _) = tabs[tabIndex].layout.pane(withID: paneID) else {
        return nil
      }
      return path
    }()
    if let remaining = tabs[tabIndex].layout.removing(paneID),
      !remaining.contentPaneIDs.isEmpty
    {
      tabs[tabIndex].layout = remaining
      tabs[tabIndex].focusedPaneID = remaining.firstPaneID
      tabs[tabIndex].focusedSessionID = remaining.firstTerminalID
    } else {
      tabs.remove(at: tabIndex)
    }
    if selectedTabID.map({ id in tabs.contains(where: { $0.id == id }) }) != true {
      selectedTabID = tabs.last?.id
    }
    terminalLayout = selectedTab?.layout
    selectedPaneID = selectedTab?.focusedPaneID ?? terminalLayout?.firstPaneID
    if deletedOpenFilePrompt?.paneID == paneID { deletedOpenFilePrompt = nil }
    synchronizeSelectionFromFocusedPane()
    if let closingPath,
      !tabs.contains(where: { $0.layout.markdownPane(forPath: closingPath) != nil })
    {
      markdownDocuments.removeAll { $0.path == closingPath }
    }
    persistCurrentTabs()
  }

  func reportOpenFileMissing(paneID: UUID, path: String) {
    guard selectedPaneID == paneID,
      terminalLayout?.paneIDs.contains(paneID) == true,
      !FileManager.default.fileExists(atPath: path)
    else { return }
    deletedOpenFilePrompt = DeletedOpenFilePrompt(paneID: paneID, path: path)
  }

  func dismissDeletedOpenFilePrompt() {
    deletedOpenFilePrompt = nil
  }

  func closeDeletedOpenFilePrompt() {
    guard let paneID = deletedOpenFilePrompt?.paneID else { return }
    deletedOpenFilePrompt = nil
    closeContentPane(paneID)
  }

  private func presentDeletionPromptIfFocusedFileIsMissing() {
    guard let selectedPaneID,
      let pane = terminalLayout?.pane(withID: selectedPaneID)
    else {
      deletedOpenFilePrompt = nil
      return
    }
    let path: String?
    switch pane {
    case .markdown(_, let markdownPath, _):
      path = markdownPath
    case .file(_, let filePath, _):
      path = filePath
    default:
      path = nil
    }
    guard let path, !FileManager.default.fileExists(atPath: path) else {
      if deletedOpenFilePrompt?.paneID == selectedPaneID {
        deletedOpenFilePrompt = nil
      }
      return
    }
    deletedOpenFilePrompt = DeletedOpenFilePrompt(paneID: selectedPaneID, path: path)
  }

  func taskBrief(for session: TerminalSession) -> TaskBrief? { store.taskBrief(for: session.id) }

  func saveTaskBrief(
    for session: TerminalSession, objective: String, constraints: String, acceptanceCriteria: String
  ) {
    store.saveTaskBrief(
      sessionID: session.id, objective: objective, constraints: constraints,
      acceptanceCriteria: acceptanceCriteria, title: session.title)
  }

  func setNotificationsEnabled(_ enabled: Bool) {
    if !enabled {
      OperatorNotifications.deactivate()
      store.setNotificationsEnabled(false)
      notificationPermissionPrompt = nil
      return
    }
    guard store.state.integrationPreferences.notificationsPermitted else {
      store.setNotificationsEnabled(false)
      return
    }
    Task {
      guard let notificationAuthorizationHandler else {
        store.setNotificationsEnabled(false)
        alertMessage = "Notifications are unavailable in this Operator session."
        return
      }
      let granted = await notificationAuthorizationHandler()
      store.setNotificationsEnabled(granted)
      if !granted {
        let state = await notificationAuthorizationStatusHandler?()
        notificationPermissionPrompt = state == .denied ? .denied : .request
      }
    }
  }

  func applyIntegrationPreferences(_ preferences: OperatorIntegrationPreferences) {
    store.setIntegrationPreferences(preferences)
    for session in allSessions {
      session.setFileWatchingEnabled(preferences.fileWatchingEnabled)
    }
    for document in markdownDocuments {
      document.setWatching(preferences.fileWatchingEnabled)
    }
    if !preferences.notificationsPermitted {
      OperatorNotifications.deactivate()
      notificationPermissionPrompt = nil
    }
  }

  func refreshNotificationAuthorization() async {
    guard store.state.integrationPreferences.notificationsPermitted else {
      store.setNotificationsEnabled(false)
      notificationPermissionPrompt = nil
      return
    }
    guard let notificationAuthorizationStatusHandler else { return }
    let state = await notificationAuthorizationStatusHandler()
    switch state {
    case .authorized, .provisional, .ephemeral:
      guard let notificationAuthorizationHandler else { return }
      let activated = await notificationAuthorizationHandler()
      store.setNotificationsEnabled(activated)
      notificationPermissionPrompt = activated ? nil : .denied
    case .notDetermined:
      store.setNotificationsEnabled(false)
      notificationPermissionPrompt = .request
    case .denied:
      store.setNotificationsEnabled(false)
      notificationPermissionPrompt = .denied
    case .unavailable:
      store.setNotificationsEnabled(false)
      notificationPermissionPrompt = nil
    }
  }

  func dismissNotificationPermissionPrompt() {
    notificationPermissionPrompt = nil
  }

  func openNotificationSystemSettings() {
    notificationPermissionPrompt = nil
    guard
      let applicationURL = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: "com.apple.systempreferences")
    else {
      alertMessage = "Open System Settings, choose Notifications, then enable Operator."
      return
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.openApplication(
      at: applicationURL, configuration: configuration
    ) { [weak self] _, error in
      guard let error else { return }
      Task { @MainActor in
        self?.alertMessage =
          "Open System Settings, choose Notifications, then enable Operator. \(error.localizedDescription)"
      }
    }
  }

  private func sessionFinished(id: UUID, code: Int32, failed: Bool) {
    finishTerminalOutputBurst(sessionID: id)
    systemSurfaceRevision &+= 1
    store.recordFinish(id: id, exitCode: code, failed: failed)
    guard let session = session(with: id) else { return }
    if !failed, session.request.harness != .generic {
      store.setPaneAwaitingReview(true, for: id)
    }
    exitClosePromptSessionID = id
    guard shouldNotify(session, for: failed ? .failed : .awaitingReview) else { return }
    if code == 0, !failed, harnessCompletionNotifiedSessions.remove(id) != nil {
      return
    }
    taskFinishedNotificationHandler(
      session.title, id, URL(fileURLWithPath: session.request.directory).lastPathComponent, code,
      failed)
  }

  private func sessionFilesChanged(id: UUID, files: [GitChangedFile]) {
    guard let session = session(with: id) else { return }
    store.recordFileChanges(sessionID: id, title: session.title, count: files.count)
  }

  func splitFocusedTerminal(_ orientation: SplitOrientation) {
    guard let layout = terminalLayout, let focusedPaneID = selectedPaneID else { return }
    let paneID = UUID()
    let splitPath = layout.path(to: focusedPaneID) ?? "root"
    terminalLayout = layout.splitting(
      paneID: focusedPaneID, orientation: orientation, emptyPaneID: paneID)
    updateSelectedTab {
      $0.layout = terminalLayout ?? $0.layout
      // A new split always starts as an even division. Remove obsolete child values from a
      // previous layout so a collapsed/recreated pane cannot inherit a stale geometry.
      $0.splitRatios = $0.splitRatios.filter { key, _ in !key.hasPrefix("\(splitPath).") }
      $0.splitRatios[splitPath] = 0.5
    }
    persistCurrentTabs()
    OperatorDebugLog.record(
      "pane.split",
      "tab=\(shortID(selectedTabID)) focused=\(shortID(focusedPaneID)) orientation=\(orientation.rawValue) emptyPane=\(shortID(paneID))"
    )
  }

  func closeEmptyPane(_ paneID: UUID) {
    terminalLayout = terminalLayout?.removingEmptyPane(paneID)
    if let terminalLayout {
      updateSelectedTab {
        $0.layout = terminalLayout
        $0.focusedPaneID = terminalLayout.firstPaneID
        $0.focusedSessionID = terminalLayout.firstTerminalID
      }
    }
    if selectedEmptyPaneID == paneID {
      selectedPaneID = terminalLayout?.firstPaneID
      synchronizeSelectionFromFocusedPane()
    }
    persistCurrentTabs()
  }

  func applyLayout(command: String, sessionID: UUID? = nil) {
    if let sessionID, let session = session(with: sessionID) {
      if let projectID = session.request.projectID, projectID != store.state.selectedProjectID {
        selectProject(projectID)
      }
      selectTerminal(sessionID)
    }
    switch command {
    case "split-right", "split-bottom":
      splitFocusedTerminal(command == "split-right" ? .horizontal : .vertical)
      return
    default: alertMessage = "Unknown layout command: \(command)."
    }
    persistCurrentTabs()
  }

  func toggleZoom(_ sessionID: UUID) {
    zoomedSessionID = zoomedSessionID == sessionID ? nil : sessionID
    selectTerminal(sessionID)
  }

  func receiveQuestion(sessionID: UUID, message: String) {
    let cleanMessage = String(
      message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000))
    guard !cleanMessage.isEmpty,
      !questions.contains(where: { $0.sessionID == sessionID && $0.message == cleanMessage }),
      let session = enqueueQuestion(sessionID: sessionID, message: cleanMessage)
    else { return }
    if shouldNotify(session, for: .needsAnswer) {
      questionNotificationHandler(session.title, sessionID, cleanMessage)
    }
  }

  func receiveEvent(_ event: HarnessEventEnvelope) {
    guard !interactions.contains(where: { $0.id == event.id }),
      let session = session(with: event.sessionID)
    else { return }
    let projectID = session.request.projectID
    if session.request.harness != .generic, let identifier = event.resumeIdentifier {
      if store.setResumeIdentifier(identifier, for: event.sessionID) {
        OperatorDebugLog.record(
          "harness.resume-identifier.updated",
          "session=\(shortID(event.sessionID)) harness=\(session.request.harness.rawValue) identifier=\(identifier.prefix(8))"
        )
      }
    }
    switch event.kind {
    case .question:
      receiveQuestion(sessionID: event.sessionID, message: event.message ?? "Input requested")
    case .childStarted, .childFinished, .taskFinished:
      // A harness that has resumed work, completed a tool, or finished a turn has moved past
      // the previous blocking prompt. This also recovers any stale state from older hook
      // configurations that treated Claude's completion notification as a question.
      resolveQuestions(for: event.sessionID)
      if event.kind == .taskFinished {
        sessionProgress[event.sessionID] = 1
        store.setPaneAwaitingReview(true, for: event.sessionID)
        if shouldNotify(session, for: .awaitingReview) {
          harnessCompletionNotifiedSessions.insert(event.sessionID)
          taskFinishedNotificationHandler(
            session.title, event.sessionID,
            URL(fileURLWithPath: session.request.directory).lastPathComponent, 0, false)
        }
      }
    case .progress:
      if let progress = event.progress, progress.isFinite {
        sessionProgress[event.sessionID] = min(1, max(0, progress))
      }
    case .artifact:
      guard let rawPath = event.path else { return }
      let path: String
      do {
        path = try WorkspacePathPolicy.canonicalContainedPath(
          rawPath, within: session.request.directory)
      } catch {
        alertMessage = error.localizedDescription
        return
      }
      guard FileManager.default.isReadableFile(atPath: path) else {
        alertMessage = "Artifact is not readable: \(path)"
        return
      }
      let kind =
        event.artifactKind == .auto || event.artifactKind == nil
        ? Self.detectArtifactKind(path) : event.artifactKind!
      let artifact = ArtifactDescriptor(
        projectID: projectID, sessionID: event.sessionID, path: path,
        workspaceDirectory: session.request.directory, kind: kind)
      store.upsertArtifact(artifact)
      artifacts = artifactsForActiveProject()
      if kind == .markdown {
        openMarkdown(path, requestedBy: event.sessionID)
      } else {
        selectedArtifactID =
          artifacts.first(where: { $0.path == path && $0.sessionID == event.sessionID })?.id
      }
    }
    interactions.insert(
      InteractionRecord(
        id: event.id, projectID: projectID, sessionID: event.sessionID, date: event.timestamp,
        kind: event.kind, message: event.message ?? event.path ?? event.kind.rawValue,
        resolvedAt: nil), at: 0)
    interactions = Array(interactions.prefix(500))
  }

  func answerQuestion(_ question: HarnessQuestion, answer: String) {
    guard let session = session(with: question.sessionID) else {
      alertMessage = "The originating terminal is no longer running."
      return
    }
    let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    session.sendInput(trimmed + "\n")
    questions.removeAll { $0.id == question.id }
    if let index = interactions.firstIndex(where: {
      $0.sessionID == question.sessionID && $0.kind == .question && $0.resolvedAt == nil
    }) {
      interactions[index].resolvedAt = .now
    }
  }

  private func shouldNotify(_ session: TerminalSession, for state: AgentPaneState) -> Bool {
    store.state.notificationsEnabled
      && store.paneMetadata(for: session.id).notificationPolicy.permits(state)
  }

  func closeArtifact(_ artifact: ArtifactDescriptor) {
    artifacts.removeAll { $0.id == artifact.id }
    store.removeArtifact(artifact.id)
    if selectedArtifactID == artifact.id { selectedArtifactID = nil }
  }

  func setArtifactPinned(_ artifact: ArtifactDescriptor, pinned: Bool) {
    store.setArtifactPinned(pinned, id: artifact.id)
    artifacts = artifactsForActiveProject()
  }

  func attachArtifact(_ artifact: ArtifactDescriptor, to session: TerminalSession?) {
    store.attachArtifact(artifact.id, to: session?.id)
    artifacts = artifactsForActiveProject()
  }

  func revealArtifactSource(_ artifact: ArtifactDescriptor) { revealSession(artifact.sessionID) }

  func insertDroppedPaths(_ urls: [URL], into session: TerminalSession) {
    let paths = urls.filter { $0.isFileURL }.map { shellQuoted($0.path) }
    guard !paths.isEmpty else { return }
    session.sendInput(paths.joined(separator: " "))
    OperatorDebugLog.record(
      "drop.terminal.inserted", "Inserted dropped path(s) without execution",
      metadata: ["session": shortID(session.id), "count": String(paths.count)])
  }

  private func artifactsForActiveProject() -> [ArtifactDescriptor] {
    store.state.artifacts.filter { $0.projectID == activeProjectID }.sorted {
      if $0.isPinned != $1.isPinned { return $0.isPinned }
      return $0.createdAt > $1.createdAt
    }
  }

  private static func detectArtifactKind(_ path: String) -> ArtifactKind {
    switch URL(fileURLWithPath: path).pathExtension.lowercased() {
    case "md", "markdown", "mdx": .markdown
    case "png", "jpg", "jpeg", "gif", "heic": .image
    case "json": .json
    case "patch", "diff": .patch
    case "log", "out", "err": .log
    case "html", "htm": .html
    case "pdf": .pdf
    case "xml": .testReport
    default: .text
    }
  }

  private func session(with id: UUID) -> TerminalSession? {
    if let visible = sessions.first(where: { $0.id == id }) { return visible }
    for hidden in projectSessions.values {
      if let session = hidden.first(where: { $0.id == id }) { return session }
    }
    return nil
  }

  /// Git invokes a child process, so keep it out of SwiftUI's synchronous render path. A project
  /// fallback gives the sidebar a branch before a terminal has been focused.
  private func startFocusedBranchMonitor() {
    focusedBranchMonitor?.invalidate()
    focusedBranchMonitor = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) {
      [weak self] _ in
      Task { @MainActor in self?.refreshFocusedGitBranch(clearWhileLoading: false) }
    }
  }

  private func refreshFocusedGitBranch(clearWhileLoading: Bool = true) {
    gitBranchRequestRevision &+= 1
    let revision = gitBranchRequestRevision
    let projectID = store.state.selectedProjectID
    let sessionID = selectedSessionID
    let directory =
      selectedSession?.request.directory ?? selectedProject?.workspaces.first?.directory
    if clearWhileLoading { focusedGitBranch = projectID.flatMap { lastGitBranches[$0] } }
    guard let directory else { return }

    Task.detached { [weak self] in
      let branch = GitRepository.branch(containing: directory)
      await self?.applyFocusedGitBranch(
        branch, revision: revision, projectID: projectID, sessionID: sessionID)
    }
  }

  private func applyFocusedGitBranch(
    _ branch: String?, revision: Int, projectID: UUID?, sessionID: UUID?
  ) {
    guard gitBranchRequestRevision == revision,
      store.state.selectedProjectID == projectID,
      selectedSessionID == sessionID
    else { return }
    focusedGitBranch = branch
    if let sessionID {
      lastGitBranchesBySession[sessionID] = branch
    }
    if let projectID {
      if let branch {
        lastGitBranches[projectID] = branch
      } else {
        lastGitBranches[projectID] = nil
      }
    }
  }

  private func updateSelectedTab(_ update: (inout WorkspaceTab) -> Void) {
    guard let selectedTabID, let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else {
      return
    }
    update(&tabs[index])
  }

  private func discardTerminallessTabs() {
    let previousCount = tabs.count
    tabs.removeAll { $0.layout.contentPaneIDs.isEmpty }
    if selectedTabID.map({ id in tabs.contains(where: { $0.id == id }) }) != true {
      selectedTabID = tabs.first?.id
    }
    if tabs.count != previousCount { persistCurrentTabs() }
  }

  private func persistCurrentTabs(for projectID: UUID? = nil) {
    if let projectID = projectID ?? store.state.selectedProjectID {
      store.saveTabs(tabs, selectedTabID: selectedTabID, for: projectID)
    }
  }

  @discardableResult
  func enqueueQuestion(sessionID: UUID, message: String) -> TerminalSession? {
    guard let session = session(with: sessionID) else { return nil }
    questions.insert(HarnessQuestion(sessionID: sessionID, message: message), at: 0)
    questions = Array(questions.prefix(100))
    return session
  }

  private func resolveQuestions(for sessionID: UUID) {
    let pendingIDs = Set(questions.lazy.filter { $0.sessionID == sessionID }.map(\.id))
    guard !pendingIDs.isEmpty else { return }
    questions.removeAll { pendingIDs.contains($0.id) }
    for index in interactions.indices where
      interactions[index].sessionID == sessionID && interactions[index].kind == .question
        && interactions[index].resolvedAt == nil
    {
      interactions[index].resolvedAt = .now
    }
  }

  func focusQuestion(_ question: HarnessQuestion) {
    revealQuestion(question)
  }

  func focusQuestion(for sessionID: UUID) {
    if let question = questions.first(where: { $0.sessionID == sessionID }) {
      revealQuestion(question)
    } else {
      revealSession(sessionID)
    }
  }

  func retrySession(_ sessionID: UUID) {
    guard let session = session(with: sessionID) else {
      alertMessage = "The failed terminal is no longer available to retry."
      return
    }
    revealSession(sessionID)
    restart(session)
  }

  func revealQuestion(_ question: HarnessQuestion) {
    if let projectID = session(with: question.sessionID)?.request.projectID,
      projectID != store.state.selectedProjectID
    {
      selectProject(projectID)
    }
    selectTerminal(question.sessionID)
  }

  func revealSession(_ sessionID: UUID) {
    guard let session = session(with: sessionID) else {
      alertMessage = "The originating terminal is no longer available."
      return
    }
    if let projectID = session.request.projectID, projectID != store.state.selectedProjectID {
      selectProject(projectID)
    }
    selectTerminal(sessionID)
  }

  func focusAdjacentSession(_ offset: Int) {
    let paneIDs = terminalLayout?.terminalIDsInDisplayOrder ?? []
    guard !paneIDs.isEmpty else { return }
    let current = paneIDs.firstIndex(of: selectedSessionID ?? paneIDs[0]) ?? 0
    let next = (current + offset + paneIDs.count) % paneIDs.count
    selectTerminal(paneIDs[next])
  }

  func selectAdjacentProject(_ offset: Int) {
    let projects = store.state.projects
    guard !projects.isEmpty else { return }
    let current = projects.firstIndex { $0.id == store.state.selectedProjectID } ?? 0
    let next = (current + offset + projects.count) % projects.count
    selectProject(projects[next].id)
  }

  private func insertIntoTab(_ id: UUID, title: String, intoPane paneID: UUID?, tabID: UUID?) {
    if let tabID, let index = tabs.firstIndex(where: { $0.id == tabID }) {
      let layout = tabs[index].layout
      tabs[index].layout = paneID.flatMap { layout.replacingEmptyPane($0, with: id) } ?? layout
      tabs[index].focusedSessionID = id
      tabs[index].focusedPaneID = id
      selectedTabID = tabID
    } else if let paneID, let selectedTabID,
      let index = tabs.firstIndex(where: { $0.id == selectedTabID }),
      let layout = tabs[index].layout.replacingEmptyPane(paneID, with: id)
    {
      tabs[index].layout = layout
      tabs[index].focusedSessionID = id
      tabs[index].focusedPaneID = id
    } else {
      let tab = WorkspaceTab(id: UUID(), title: title, layout: .terminal(id), focusedSessionID: id)
      tabs.append(tab)
      selectedTabID = tab.id
    }
    terminalLayout = selectedTab?.layout
    selectedPaneID = id
    persistCurrentTabs()
    OperatorDebugLog.record(
      "tab.layout",
      "session=\(shortID(id)) tab=\(shortID(selectedTabID)) pane=\(shortID(paneID)) leaves=\(terminalLayout?.terminalIDs.count ?? 0)"
    )
  }

  private func shortID(_ id: UUID?) -> String {
    id.map { String($0.uuidString.prefix(8)) } ?? "none"
  }
}

final class OperatorTerminalView: LocalProcessTerminalView {
  var onFocus: () -> Void = {}
  var onOutput: (Int) -> Void = { _ in }
  private(set) var appliedPreferences: TerminalPreferences?
  private(set) var appliedColorPalette: TerminalColorPalette?

  override func layout() {
    super.layout()
    // SwiftTerm installs a legacy-width NSScroller even in overlay mode. Keep scrolling
    // available through mouse/keyboard input without reserving a gray gutter in each pane.
    for scroller in subviews.compactMap({ $0 as? NSScroller }) {
      scroller.isHidden = true
    }
  }

  override func mouseDown(with event: NSEvent) {
    onFocus()
    super.mouseDown(with: event)
    // AppKit does not automatically promote an NSView receiving a mouse event
    // to first responder. This is particularly important when the pane is
    // already selected: there is no SwiftUI state change to trigger the host's
    // selected-pane focus pass, yet Claude still needs a real text receiver.
    DispatchQueue.main.async { [weak self] in
      guard let self, let window = self.window, window.isKeyWindow else { return }
      window.makeFirstResponder(self)
    }
  }

  override func dataReceived(slice: ArraySlice<UInt8>) {
    super.dataReceived(slice: slice)
    guard !slice.isEmpty else { return }
    onOutput(slice.count)
  }

  func apply(
    _ rawPreferences: TerminalPreferences,
    palette: TerminalColorPalette = .iTermDark
  ) {
    if appliedColorPalette != palette {
      palette.apply(to: self)
      appliedColorPalette = palette
    }

    let preferences = rawPreferences.normalized
    guard appliedPreferences != preferences else { return }
    font = TerminalFontResolver.font(for: preferences)
    terminal.changeScrollback(preferences.scrollbackLines)
    // SwiftTerm otherwise asks AppKit to redraw the complete terminal for small updates on modern
    // macOS. Limiting invalidation to dirty rows makes output and scrollback noticeably smoother.
    disableFullRedrawOnAnyChanges = true
    appliedPreferences = preferences
  }

}

@MainActor
final class TerminalContainerView: NSView {
  private(set) weak var mountedTerminal: LocalProcessTerminalView?

  func mount(_ terminal: LocalProcessTerminalView) {
    guard terminal.superview !== self else {
      mountedTerminal = terminal
      terminal.frame = bounds
      return
    }

    terminal.removeFromSuperview()
    terminal.frame = bounds
    terminal.autoresizingMask = [.width, .height]
    addSubview(terminal)
    mountedTerminal = terminal
  }

  /// Removes the terminal only when this container still owns it. SwiftUI can dismantle an
  /// outgoing tab after the same persistent terminal has already mounted in the incoming tab.
  /// An unconditional removal here would detach the newly focused terminal.
  func unmountIfOwned(_ terminal: LocalProcessTerminalView) {
    guard terminal.superview === self else { return }
    terminal.removeFromSuperview()
    if mountedTerminal === terminal {
      mountedTerminal = nil
    }
  }

  override func layout() {
    super.layout()
    mountedTerminal?.frame = bounds
  }
}

struct TerminalHost: NSViewRepresentable {
  @ObservedObject var session: TerminalSession
  @Environment(\.colorScheme) private var colorScheme
  let preferences: TerminalPreferences
  let shouldFocus: Bool

  private var colorPalette: TerminalColorPalette {
    TerminalColorPalette.resolved(for: colorScheme, preferences: preferences)
  }

  func makeCoordinator() -> Coordinator { Coordinator(session: session) }

  @MainActor func makeNSView(context: Context) -> TerminalContainerView {
    let container = TerminalContainerView(frame: .zero)
    let terminal = session.terminalView ?? makeTerminalView()
    (terminal as? OperatorTerminalView)?.apply(preferences, palette: colorPalette)
    session.attach(terminal, delegate: context.coordinator)
    container.mount(terminal)
    context.coordinator.focus(terminal, in: container, when: shouldFocus)
    return container
  }

  @MainActor func updateNSView(_ nsView: TerminalContainerView, context: Context) {
    let terminal = session.terminalView ?? makeTerminalView()
    session.attach(terminal, delegate: context.coordinator)
    nsView.mount(terminal)
    (terminal as? OperatorTerminalView)?.apply(preferences, palette: colorPalette)
    context.coordinator.focus(terminal, in: nsView, when: shouldFocus)
  }

  @MainActor static func dismantleNSView(
    _ nsView: TerminalContainerView, coordinator: Coordinator
  ) {
    if let terminal = nsView.mountedTerminal {
      nsView.unmountIfOwned(terminal)
    }
  }

  final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
    weak var session: TerminalSession?
    init(session: TerminalSession) { self.session = session }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
      Task { @MainActor in self.session?.updateTitle(title) }
    }
    func processTerminated(source: TerminalView, exitCode: Int32?) {
      Task { @MainActor in self.session?.didExit(code: exitCode) }
    }

    /// The only programmatic focus path: wait until SwiftUI has mounted the selected terminal
    /// into this exact visible container, then let AppKit make it the first responder.
    @MainActor
    func focus(_ terminal: LocalProcessTerminalView, in container: TerminalContainerView, when selected: Bool) {
      guard selected else { return }
      DispatchQueue.main.async { [weak terminal, weak container] in
        guard let terminal, let container, terminal.superview === container,
          let window = container.window, window.isKeyWindow, window.attachedSheet == nil
        else { return }
        window.makeFirstResponder(terminal)
      }
    }
  }

  @MainActor private func makeTerminalView() -> LocalProcessTerminalView {
    let terminal = OperatorTerminalView(frame: .zero)
    terminal.autoresizingMask = [.width, .height]
    terminal.apply(preferences, palette: colorPalette)
    return terminal
  }
}
