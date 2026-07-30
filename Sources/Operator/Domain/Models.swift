import Foundation

private struct LossyDecodableArray<Element: Decodable>: Decodable {
  let elements: [Element]

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    var values: [Element] = []
    while !container.isAtEnd {
      do {
        values.append(try container.decode(Element.self))
      } catch {
        _ = try? container.decode(DiscardedValue.self)
      }
    }
    elements = values
  }
}

private struct DiscardedValue: Decodable {
  private struct Key: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
  }

  init(from decoder: any Decoder) throws {
    if var array = try? decoder.unkeyedContainer() {
      while !array.isAtEnd { _ = try? array.decode(DiscardedValue.self) }
      return
    }
    if let object = try? decoder.container(keyedBy: Key.self) {
      for key in object.allKeys { _ = try? object.decode(DiscardedValue.self, forKey: key) }
      return
    }
    let value = try decoder.singleValueContainer()
    if value.decodeNil() { return }
    if (try? value.decode(Bool.self)) != nil { return }
    if (try? value.decode(Int64.self)) != nil { return }
    if (try? value.decode(Double.self)) != nil { return }
    _ = try value.decode(String.self)
  }
}

extension KeyedDecodingContainer {
  fileprivate func decodeLossyArray<Element: Decodable>(_ type: Element.Type, forKey key: Key)
    throws
    -> [Element]
  {
    try decodeIfPresent(LossyDecodableArray<Element>.self, forKey: key)?.elements ?? []
  }
}

struct EnvironmentOverride: Codable, Hashable, Identifiable {
  var id: UUID = UUID()
  var key: String
  var value: String
}

enum EnvironmentSecurityPolicy {
  static let reservedRuntimeKeys: Set<String> = [
    "OPERATOR_SESSION_ID", "OPERATOR_SOCKET", "OPERATOR_TOKEN",
  ]

  private static let sensitiveFragments = [
    "TOKEN", "PASSWORD", "PASSWD", "PASSPHRASE", "SECRET", "API_KEY", "APIKEY",
    "PRIVATE_KEY", "ACCESS_KEY", "CREDENTIAL", "AUTHORIZATION", "COOKIE",
  ]

  static func isSensitiveKey(_ key: String) -> Bool {
    let normalized = key.uppercased().replacingOccurrences(
      of: #"[^A-Z0-9]+"#, with: "_", options: .regularExpression)
    return reservedRuntimeKeys.contains(normalized)
      || sensitiveFragments.contains { normalized.contains($0) }
  }

  static func persistable(_ environment: [String: String]) -> [String: String] {
    environment.filter { key, value in
      !isSensitiveKey(key) && !containsCredentialBearingURL(value)
    }
  }

  static func persistable(_ overrides: [EnvironmentOverride]) -> [EnvironmentOverride] {
    overrides.filter {
      !isSensitiveKey($0.key) && !containsCredentialBearingURL($0.value)
    }
  }

  private static func containsCredentialBearingURL(_ value: String) -> Bool {
    value.range(
      of: #"[A-Za-z][A-Za-z0-9+.-]*://[^/\s:@]+:[^@\s/]+@"#,
      options: .regularExpression) != nil
  }
}

struct Project: Codable, Hashable, Identifiable {
  var id: UUID
  var name: String
  var createdAt: Date
  var workspaces: [Workspace]
  var emoji: String?
  var accent: ProjectAccent
  var isShownInSidebar: Bool
  var lastOpenedAt: Date?

  enum CodingKeys: String, CodingKey {
    case id, name, createdAt, workspaces, emoji, accent, isShownInSidebar, lastOpenedAt
  }

  init(
    id: UUID = UUID(), name: String, directory: String, createdAt: Date = .now,
    workspaces: [Workspace]? = nil, emoji: String? = nil, accent: ProjectAccent = .blue,
    isShownInSidebar: Bool = true, lastOpenedAt: Date? = .now
  ) {
    self.id = id
    self.name = name
    self.createdAt = createdAt
    self.workspaces = workspaces ?? [Workspace(name: name, directory: directory)]
    self.emoji = Project.normalizedEmoji(emoji)
    self.accent = accent
    self.isShownInSidebar = isShownInSidebar
    self.lastOpenedAt = lastOpenedAt
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    workspaces = try container.decodeLossyArray(Workspace.self, forKey: .workspaces)
    emoji = try container.decodeIfPresent(String.self, forKey: .emoji)
    accent = try container.decodeIfPresent(ProjectAccent.self, forKey: .accent) ?? .blue
    isShownInSidebar = try container.decodeIfPresent(Bool.self, forKey: .isShownInSidebar) ?? true
    lastOpenedAt = try container.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
  }

  var displayName: String { emoji.map { "\($0) \(name)" } ?? name }

  static func normalizedEmoji(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else { return nil }
    guard let character = trimmed.first else { return nil }
    let scalars = character.unicodeScalars
    let isEmoji =
      scalars.contains { $0.properties.isEmojiPresentation }
      || scalars.contains { $0.value == 0xFE0F }
      || (scalars.count > 1 && scalars.contains { $0.properties.isEmoji })
    return isEmoji ? String(character) : nil
  }
}

enum ProjectAccent: String, Codable, CaseIterable, Identifiable {
  case blue, purple, teal, green, orange, pink, gray
  var id: String { rawValue }
  var title: String { rawValue.capitalized }
}

enum PaneStatusBarPosition: String, Codable, CaseIterable, Identifiable {
  case top, bottom
  var id: String { rawValue }
  var title: String { rawValue.capitalized }
}

struct Workspace: Codable, Hashable, Identifiable {
  var id: UUID = UUID()
  var name: String
  var directory: String
  var createdAt: Date = .now
  var alias: String? = nil

  init(
    id: UUID = UUID(), name: String, directory: String, createdAt: Date = .now, alias: String? = nil
  ) {
    self.id = id
    self.name = name
    self.directory = directory
    self.createdAt = createdAt
    self.alias = Workspace.normalizedAlias(alias)
  }

  enum CodingKeys: String, CodingKey { case id, name, directory, createdAt, alias }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    name = try container.decode(String.self, forKey: .name)
    directory = try container.decode(String.self, forKey: .directory)
    createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
    alias = Workspace.normalizedAlias(try container.decodeIfPresent(String.self, forKey: .alias))
  }

  var displayName: String { alias ?? name }

  static func normalizedAlias(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else { return nil }
    return trimmed
  }
}

struct LaunchProfile: Codable, Hashable, Identifiable {
  var id: UUID = UUID()
  var name: String
  var command: String
  var directory: String
  var environment: [EnvironmentOverride] = []
  var projectID: UUID?
  var workspaceID: UUID?

  var environmentDictionary: [String: String] {
    Dictionary(
      uniqueKeysWithValues: environment.filter { !$0.key.isEmpty }.map { ($0.key, $0.value) })
  }

  enum CodingKeys: String, CodingKey {
    case id, name, command, directory, environment, projectID, workspaceID
  }

  init(
    id: UUID = UUID(), name: String, command: String, directory: String,
    environment: [EnvironmentOverride] = [], projectID: UUID? = nil, workspaceID: UUID? = nil
  ) {
    self.id = id
    self.name = name
    self.command = command
    self.directory = directory
    self.environment = environment
    self.projectID = projectID
    self.workspaceID = workspaceID
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    name = try container.decode(String.self, forKey: .name)
    command = try container.decode(String.self, forKey: .command)
    directory = try container.decode(String.self, forKey: .directory)
    environment =
      try container.decodeIfPresent([EnvironmentOverride].self, forKey: .environment) ?? []
    projectID = try container.decodeIfPresent(UUID.self, forKey: .projectID)
    workspaceID = try container.decodeIfPresent(UUID.self, forKey: .workspaceID)
  }
}

enum SessionStatus: String, Codable, Hashable {
  case running
  case exited
  case failed
}

enum HarnessKind: String, Codable, Hashable, CaseIterable {
  case claudeCode
  case codex
  case generic

  static func detect(command: String) -> HarnessKind {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == "claude" || trimmed.hasPrefix("claude ") { return .claudeCode }
    if trimmed == "codex" || trimmed.hasPrefix("codex ") { return .codex }
    return .generic
  }
}

struct HarnessCapabilities: Hashable {
  let resumable: Bool
  let requiresExplicitResumeIdentifier: Bool
  let autoRestorable: Bool
}

protocol HarnessAdapter {
  var kind: HarnessKind { get }
  var capabilities: HarnessCapabilities { get }
  func detects(command: String) -> Bool
  func prepareNew(_ request: LaunchRequest, id: UUID, projectName: String?) -> LaunchRequest
  func prepareResume(recipe: SessionRecipe, workspace: Workspace) -> LaunchRequest?
}

struct ClaudeCodeAdapter: HarnessAdapter {
  let kind = HarnessKind.claudeCode
  let capabilities = HarnessCapabilities(
    resumable: true, requiresExplicitResumeIdentifier: false, autoRestorable: true)
  func detects(command: String) -> Bool { HarnessKind.detect(command: command) == kind }
  func prepareNew(_ request: LaunchRequest, id: UUID, projectName: String?) -> LaunchRequest {
    guard !request.containsManagedSessionArgument else { return request }
    let name = OperatorSessionName.make(projectName: projectName, id: id)
    var result = request
    result.harness = kind
    result.resumeIdentifier = name
    result.managedSessionName = name
    result.command = "\(request.command) -n \(shellQuoted(name))"
    return result
  }
  func prepareResume(recipe: SessionRecipe, workspace: Workspace) -> LaunchRequest? {
    guard let identifier = recipe.resumeIdentifier else { return nil }
    return LaunchRequest(
      title: recipe.title, command: "claude --resume \(shellQuoted(identifier))",
      directory: workspace.directory, environment: recipe.environment, projectID: recipe.projectID,
      workspaceID: workspace.id, harness: kind, managedSessionName: identifier,
      resumeIdentifier: identifier)
  }
}

struct CodexAdapter: HarnessAdapter {
  let kind = HarnessKind.codex
  let capabilities = HarnessCapabilities(
    resumable: true, requiresExplicitResumeIdentifier: true, autoRestorable: true)
  func detects(command: String) -> Bool { HarnessKind.detect(command: command) == kind }
  func prepareNew(_ request: LaunchRequest, id: UUID, projectName: String?) -> LaunchRequest {
    var result = request
    result.harness = kind
    return result
  }
  func prepareResume(recipe: SessionRecipe, workspace: Workspace) -> LaunchRequest? {
    guard let identifier = recipe.resumeIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
      !identifier.isEmpty
    else { return nil }
    return LaunchRequest(
      title: recipe.title, command: "codex resume \(shellQuoted(identifier))",
      directory: workspace.directory, environment: recipe.environment, projectID: recipe.projectID,
      workspaceID: workspace.id, harness: kind, resumeIdentifier: identifier)
  }
}

struct GenericHarnessAdapter: HarnessAdapter {
  let kind = HarnessKind.generic
  let capabilities = HarnessCapabilities(
    resumable: false, requiresExplicitResumeIdentifier: false, autoRestorable: false)
  func detects(command: String) -> Bool { true }
  func prepareNew(_ request: LaunchRequest, id: UUID, projectName: String?) -> LaunchRequest {
    request
  }
  func prepareResume(recipe: SessionRecipe, workspace: Workspace) -> LaunchRequest? {
    guard InteractiveShellRestorationPolicy.isSafeInteractiveShellCommand(recipe.command) else {
      return nil
    }
    return LaunchRequest(
      title: recipe.title, command: recipe.command, directory: workspace.directory,
      environment: recipe.environment, projectID: recipe.projectID, workspaceID: workspace.id,
      harness: .generic)
  }
}

enum InteractiveShellRestorationPolicy {
  private static let shellNames: Set<String> = [
    "bash", "csh", "dash", "fish", "ksh", "nu", "sh", "tcsh", "xonsh", "zsh",
  ]
  private static let safeArguments: Set<String> = [
    "-f", "-i", "-l", "--interactive", "--login", "--no-config", "--private",
  ]

  static func isSafeInteractiveShellCommand(_ command: String) -> Bool {
    let components = command.split(whereSeparator: \.isWhitespace).map(String.init)
    guard let executable = components.first, !executable.isEmpty else { return false }
    let executableName = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
    guard shellNames.contains(executableName) else { return false }
    return components.dropFirst().allSatisfy(safeArguments.contains)
  }
}

enum HarnessAdapters {
  static let all: [any HarnessAdapter] = [
    ClaudeCodeAdapter(), CodexAdapter(), GenericHarnessAdapter(),
  ]
  static func adapter(for command: String) -> any HarnessAdapter {
    all.first { $0.detects(command: command) }!
  }
  static func adapter(for kind: HarnessKind) -> any HarnessAdapter {
    all.first { $0.kind == kind }!
  }
}

struct RecentSession: Codable, Hashable, Identifiable {
  var id: UUID
  var title: String
  var command: String
  var projectID: UUID?
  var workspaceID: UUID?
  var directory: String
  var startedAt: Date
  var endedAt: Date?
  var exitCode: Int32?
  var status: SessionStatus
  var harness: HarnessKind?
  var managedSessionName: String?
  var environment: [String: String]?
  var resumeIdentifier: String? = nil

  var isResumable: Bool {
    guard let harness else { return false }
    return HarnessAdapters.adapter(for: harness).capabilities.resumable
      && (resumeIdentifier ?? managedSessionName) != nil
  }
}

struct SessionRecipe: Codable, Hashable, Identifiable {
  var id: UUID
  var projectID: UUID
  var workspaceID: UUID
  var title: String
  var command: String
  var environment: [String: String]
  var harness: HarnessKind
  var resumeIdentifier: String?
  var restoreOnOpen: Bool
  var tabID: UUID? = nil

  var isAutoRestorable: Bool {
    if harness == .generic {
      return InteractiveShellRestorationPolicy.isSafeInteractiveShellCommand(command)
    }
    return HarnessAdapters.adapter(for: harness).capabilities.autoRestorable
      && resumeIdentifier?.isEmpty == false && restoreOnOpen
  }
}

struct TaskBrief: Codable, Hashable, Identifiable {
  var id: UUID { sessionID }
  var sessionID: UUID
  var objective: String
  var constraints: String
  var acceptanceCriteria: String
  var updatedAt: Date = .now

  var summary: String {
    let firstLine = objective.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    return firstLine.isEmpty ? "No task brief" : firstLine
  }

  enum CodingKeys: String, CodingKey {
    case sessionID, objective, constraints, acceptanceCriteria, updatedAt
  }

  init(
    sessionID: UUID, objective: String, constraints: String, acceptanceCriteria: String,
    updatedAt: Date = .now
  ) {
    self.sessionID = sessionID
    self.objective = objective
    self.constraints = constraints
    self.acceptanceCriteria = acceptanceCriteria
    self.updatedAt = updatedAt
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sessionID = try container.decode(UUID.self, forKey: .sessionID)
    objective = try container.decodeIfPresent(String.self, forKey: .objective) ?? ""
    constraints = try container.decodeIfPresent(String.self, forKey: .constraints) ?? ""
    acceptanceCriteria =
      try container.decodeIfPresent(String.self, forKey: .acceptanceCriteria) ?? ""
    updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
  }
}

enum ActivityKind: String, Codable, Hashable {
  case launched, exited, failed, taskBriefUpdated, filesChanged

  var symbolName: String {
    switch self {
    case .launched: "play.circle.fill"
    case .exited: "checkmark.circle.fill"
    case .failed: "exclamationmark.triangle.fill"
    case .taskBriefUpdated: "note.text"
    case .filesChanged: "doc.badge.gearshape"
    }
  }
}

struct ActivityEvent: Codable, Hashable, Identifiable {
  var id: UUID = UUID()
  var date: Date = .now
  var kind: ActivityKind
  var sessionID: UUID?
  var projectID: UUID?
  var title: String
  var detail: String
}

struct HarnessQuestion: Identifiable, Hashable, Codable {
  var id = UUID()
  let sessionID: UUID
  let message: String
  var answeredAt: Date? = nil
  var answer: String? = nil
}

struct OperatorStatusBarState: Equatable {
  let sessionTitle: String?
  let workspaceName: String?
  let isRunning: Bool
  let changedFileCount: Int
  let agentCount: Int
  let question: HarnessQuestion?
}

enum SplitOrientation: String, Codable {
  case horizontal
  case vertical
}

struct WorkspaceTab: Codable, Hashable, Identifiable {
  var id: UUID
  var title: String
  var layout: TerminalLayout
  var focusedSessionID: UUID?
  var splitRatios: [String: Double] = [:]

  enum CodingKeys: String, CodingKey { case id, title, layout, focusedSessionID, splitRatios }

  init(
    id: UUID, title: String, layout: TerminalLayout, focusedSessionID: UUID?,
    splitRatios: [String: Double] = [:]
  ) {
    self.id = id
    self.title = title
    self.layout = layout
    self.focusedSessionID = focusedSessionID
    self.splitRatios = splitRatios
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    title = try container.decode(String.self, forKey: .title)
    layout = try container.decode(TerminalLayout.self, forKey: .layout)
    focusedSessionID = try container.decodeIfPresent(UUID.self, forKey: .focusedSessionID)
    splitRatios = try container.decodeIfPresent([String: Double].self, forKey: .splitRatios) ?? [:]
  }
}

enum AppAppearancePreference: String, CaseIterable, Codable, Hashable, Identifiable {
  case system
  case light
  case dark

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }

  var systemImage: String {
    switch self {
    case .system: "circle.lefthalf.filled"
    case .light: "sun.max.fill"
    case .dark: "moon.fill"
    }
  }
}

struct PersistedState: Codable {
  static let currentSchemaVersion = 10

  var schemaVersion = currentSchemaVersion
  var projects: [Project] = []
  var profiles: [LaunchProfile] = []
  var recentSessions: [RecentSession] = []
  var selectedProjectID: UUID?
  var splitOrientation: SplitOrientation?
  var taskBriefs: [TaskBrief] = []
  var activity: [ActivityEvent] = []
  var notificationsEnabled = false
  var paneStatusBarPosition: PaneStatusBarPosition?
  var shortcuts: [ShortcutBinding] = ShortcutBinding.defaults
  var sessionRecipes: [SessionRecipe] = []
  var projectLayouts: [UUID: TerminalLayout] = [:]
  var projectTabs: [UUID: [WorkspaceTab]] = [:]
  var selectedTabIDs: [UUID: UUID] = [:]
  var collapsedProjectIDs: Set<UUID> = []
  var mainWindowLayout: OperatorWindowLayout?
  var appearance: AppAppearancePreference = .system
  var terminalPreferences: TerminalPreferences = .default

  enum CodingKeys: String, CodingKey {
    case schemaVersion, projects, profiles, recentSessions, selectedProjectID, splitOrientation
    case taskBriefs, activity, notificationsEnabled, paneStatusBarPosition, shortcuts
    case sessionRecipes, projectLayouts, projectTabs, selectedTabIDs
    case collapsedProjectIDs, mainWindowLayout, appearance, terminalPreferences
  }

  init() {}

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion =
      try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
      ?? PersistedState.currentSchemaVersion
    projects = try container.decodeLossyArray(Project.self, forKey: .projects)
    profiles = try container.decodeLossyArray(LaunchProfile.self, forKey: .profiles)
    recentSessions = try container.decodeLossyArray(RecentSession.self, forKey: .recentSessions)
    selectedProjectID = try container.decodeIfPresent(UUID.self, forKey: .selectedProjectID)
    splitOrientation =
      try container.decodeIfPresent(SplitOrientation.self, forKey: .splitOrientation)
    taskBriefs = try container.decodeLossyArray(TaskBrief.self, forKey: .taskBriefs)
    activity = try container.decodeLossyArray(ActivityEvent.self, forKey: .activity)
    // Notification infrastructure is optional and has caused launch-time exceptions on some
    // machines. Never carry an enabled value across launches: each process requires explicit
    // opt-in after the workspace is already usable.
    notificationsEnabled = false
    paneStatusBarPosition =
      try container.decodeIfPresent(PaneStatusBarPosition.self, forKey: .paneStatusBarPosition)
    let decodedShortcuts = try container.decodeLossyArray(
      ShortcutBinding.self, forKey: .shortcuts)
    shortcuts = decodedShortcuts.isEmpty ? ShortcutBinding.defaults : decodedShortcuts
    sessionRecipes = try container.decodeLossyArray(SessionRecipe.self, forKey: .sessionRecipes)
    projectLayouts =
      try container.decodeIfPresent([UUID: TerminalLayout].self, forKey: .projectLayouts) ?? [:]
    projectTabs =
      try container.decodeIfPresent([UUID: [WorkspaceTab]].self, forKey: .projectTabs) ?? [:]
    selectedTabIDs =
      try container.decodeIfPresent([UUID: UUID].self, forKey: .selectedTabIDs) ?? [:]
    collapsedProjectIDs =
      try container.decodeIfPresent(Set<UUID>.self, forKey: .collapsedProjectIDs) ?? []
    mainWindowLayout =
      try container.decodeIfPresent(OperatorWindowLayout.self, forKey: .mainWindowLayout)
    appearance =
      (try? container.decodeIfPresent(AppAppearancePreference.self, forKey: .appearance)) ?? .system
    terminalPreferences =
      ((try? container.decodeIfPresent(TerminalPreferences.self, forKey: .terminalPreferences))
      ?? .default).normalized
  }
}

struct OperatorWindowLayout: Codable, Equatable {
  var x: Double
  var y: Double
  var width: Double
  var height: Double
  var isZoomed: Bool
  var isFullScreen: Bool

}

struct OperatorConfiguration: Codable, Hashable {
  var version = 1
  var projects: [Project]
  var profiles: [LaunchProfile]
  var shortcuts: [ShortcutBinding]
  var notificationsEnabled: Bool
  var terminalPreferences: TerminalPreferences?
}

enum WorkspaceFileAccessError: LocalizedError, Equatable {
  case outsideWorkspace

  var errorDescription: String? {
    "Operator only opens files inside the terminal's working directory."
  }
}

enum WorkspacePathPolicy {
  static func canonicalContainedPath(_ rawPath: String, within rawDirectory: String) throws
    -> String
  {
    let root = URL(fileURLWithPath: rawDirectory, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath().path
    let candidate = URL(fileURLWithPath: rawPath)
      .standardizedFileURL.resolvingSymlinksInPath().path
    let isContained =
      root == "/" ? candidate.hasPrefix("/") : candidate.hasPrefix(root + "/")
    guard isContained else { throw WorkspaceFileAccessError.outsideWorkspace }
    return candidate
  }
}

enum LaunchValidationError: LocalizedError, Equatable {
  case emptyCommand
  case missingDirectory(String)

  var errorDescription: String? {
    switch self {
    case .emptyCommand: "Enter a command to launch."
    case .missingDirectory(let path): "The working directory does not exist: \(path)"
    }
  }
}

enum ProjectCreationError: LocalizedError, Equatable {
  case missingDirectory
  case unreadableDirectory(String)
  case duplicateDirectory
  case emptyName
  case nameTooLong
  case invalidEmoji

  var errorDescription: String? {
    switch self {
    case .missingDirectory: "Choose an existing working directory."
    case .unreadableDirectory(let path): "Operator cannot read the selected directory: \(path)"
    case .duplicateDirectory: "That working directory is already part of an Operator project."
    case .emptyName: "Enter a project name."
    case .nameTooLong: "Keep the project name to 80 characters or fewer."
    case .invalidEmoji: "Choose an emoji, or leave the project icon empty."
    }
  }
}

struct ValidatedProjectDraft: Equatable {
  let name: String
  let directory: String
  let emoji: String?
}

struct ProjectDraftValidator {
  static func validate(
    name: String, directory: String, emoji: String?, existingProjects: [Project],
    fileManager: FileManager = .default
  ) throws -> ValidatedProjectDraft {
    let rawDirectory = directory.trimmingCharacters(in: .whitespacesAndNewlines)
    var isDirectory: ObjCBool = false
    guard !rawDirectory.isEmpty,
      fileManager.fileExists(atPath: rawDirectory, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw ProjectCreationError.missingDirectory }

    let canonicalDirectory = URL(fileURLWithPath: rawDirectory, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath().path
    guard fileManager.isReadableFile(atPath: canonicalDirectory) else {
      throw ProjectCreationError.unreadableDirectory(canonicalDirectory)
    }
    let existingDirectories = Set(
      existingProjects.flatMap(\.workspaces).map {
        URL(fileURLWithPath: $0.directory, isDirectory: true)
          .standardizedFileURL.resolvingSymlinksInPath().path
      })
    guard !existingDirectories.contains(canonicalDirectory) else {
      throw ProjectCreationError.duplicateDirectory
    }

    let inferredName = URL(fileURLWithPath: canonicalDirectory).lastPathComponent
    let requestedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanName = requestedName.isEmpty ? inferredName : requestedName
    guard !cleanName.isEmpty else { throw ProjectCreationError.emptyName }
    guard cleanName.count <= 80 else { throw ProjectCreationError.nameTooLong }

    let cleanEmoji = Project.normalizedEmoji(emoji)
    if emoji?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
      cleanEmoji == nil
    {
      throw ProjectCreationError.invalidEmoji
    }
    return ValidatedProjectDraft(
      name: cleanName, directory: canonicalDirectory, emoji: cleanEmoji)
  }
}

struct LaunchRequest: Hashable {
  var title: String
  var command: String
  var directory: String
  var environment: [String: String] = [:]
  var projectID: UUID?
  var workspaceID: UUID?
  var harness: HarnessKind = .generic
  var managedSessionName: String?
  var resumeIdentifier: String? = nil

  func validate(fileManager: FileManager = .default) throws {
    guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw LaunchValidationError.emptyCommand
    }
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: directory, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw LaunchValidationError.missingDirectory(directory)
    }
  }

  func preparedForNewSession(id: UUID, projectName: String?) -> LaunchRequest {
    HarnessAdapters.adapter(for: command).prepareNew(self, id: id, projectName: projectName)
  }

  static func claudeResume(recent: RecentSession, workspace: Workspace) -> LaunchRequest? {
    guard let resumeIdentifier = recent.resumeIdentifier ?? recent.managedSessionName else {
      return nil
    }
    return LaunchRequest(
      title: recent.title,
      command: "claude --resume \(shellQuoted(resumeIdentifier))",
      directory: workspace.directory,
      environment: recent.environment ?? [:],
      projectID: recent.projectID,
      workspaceID: workspace.id,
      harness: .claudeCode,
      managedSessionName: recent.managedSessionName,
      resumeIdentifier: resumeIdentifier
    )
  }

  var containsManagedSessionArgument: Bool {
    [" -n ", " --name ", " --resume", " -r ", " --continue", " -c"].contains {
      command.contains($0)
    }
  }
}

enum OperatorSessionName {
  static func make(projectName: String?, id: UUID) -> String {
    let slug = (projectName ?? "project")
      .lowercased()
      .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return "operator-\(slug.isEmpty ? "project" : slug)-\(id.uuidString.prefix(8).lowercased())"
  }
}

func shellQuoted(_ value: String) -> String {
  "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
}
