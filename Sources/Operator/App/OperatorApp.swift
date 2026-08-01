import AppKit
import Combine
import SwiftUI
import UserNotifications

private struct MultiProjectUIStressProject: Codable, Sendable {
  let id: String
  let name: String
  let directory: String
  let splitTabID: String
  let liveSessionCount: Int
  let liveTabCount: Int
  let liveSplitPaneCount: Int
  var restoredSessionCount: Int
  var restoredTabCount: Int
  var restoredSplitPaneCount: Int
}

private struct MultiProjectUIStressReport: Codable, Sendable {
  var passed: Bool
  let generatedAt: String
  let statePath: String
  let screenshotPath: String
  let checks: [String: Bool]
  let projects: [MultiProjectUIStressProject]
  var error: String?
}

enum AppAppearanceResolver {
  static func name(for preference: AppAppearancePreference) -> NSAppearance.Name? {
    switch preference {
    case .system: nil
    case .light: .aqua
    case .dark: .darkAqua
    }
  }
}

@MainActor
final class OperatorAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
  UNUserNotificationCenterDelegate
{
  private let store = StateStore()
  private var isUITesting: Bool { ProcessInfo.processInfo.arguments.contains("--ui-testing") }
  private var isAppSmokeTesting: Bool {
    ProcessInfo.processInfo.arguments.contains("--app-smoke-test")
  }
  private var isMultiProjectUIStressTesting: Bool {
    ProcessInfo.processInfo.arguments.contains("--multi-project-ui-stress-test")
  }
  private lazy var controller = WorkspaceController(store: store, restoreAutomatically: true)
  private var window: NSWindow?
  private var integration: OperatorIntegration?
  private var systemSurfaces: OperatorSystemSurfaces?
  private var surfaceCancellables = Set<AnyCancellable>()
  private var mainMenuCancellable: AnyCancellable?
  private var projectManagerWindow: NSWindow?
  private var windowLayoutSaveTask: DispatchWorkItem?
  private var appliedAppearance: AppAppearancePreference?
  private var powerObservers: [NSObjectProtocol] = []

  func applicationDidFinishLaunching(_ notification: Notification) {
    OperatorDebugLog.record(
      "app.launch", "Operator finished launching",
      level: .info, metadata: ["uiTesting": String(isUITesting)])
    controller.notificationAuthorizationHandler = { [weak self] in
      guard let self else { return false }
      return await OperatorNotifications.activate(delegate: self)
    }
    controller.notificationAuthorizationStatusHandler = {
      await OperatorNotifications.authorizationState()
    }
    applyAppearance(store.state.appearance)
    configureDockIcon()
    configureMainMenu()
    mainMenuCancellable = store.$state
      .receive(on: RunLoop.main)
      .sink { [weak self] state in
        self?.applyAppearance(state.appearance)
        self?.configureMainMenu()
      }
    if !isUITesting { configureSystemSurfaces() }
    configurePowerObservers()
    showWorkspace()
    if !isUITesting { controller.activateResourceMonitoring() }
    if !isUITesting {
      Task { @MainActor [weak self] in
        await self?.controller.refreshNotificationAuthorization()
      }
    }
    if isAppSmokeTesting { scheduleAppSmokeTest() }
    if isMultiProjectUIStressTesting { scheduleMultiProjectUIStressTest() }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    if !flag { showWorkspace() }
    return true
  }

  func applicationWillTerminate(_ notification: Notification) {
    saveMainWindowLayout()
    OperatorDebugLog.record("app.terminate", "Operator is terminating", level: .info)
  }

  private func configurePowerObservers() {
    guard powerObservers.isEmpty else { return }
    let center = NSWorkspace.shared.notificationCenter
    powerObservers = [
      center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
        [weak self] _ in
        Task { @MainActor in self?.controller.handleSystemSleep() }
      },
      center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
        [weak self] _ in
        Task { @MainActor in self?.controller.handleSystemWake() }
      },
    ]
  }

  func showWorkspace() {
    applyAppearance(store.state.appearance)
    if let window {
      window.makeKeyAndOrderFront(nil)
    } else {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false
      )
      window.title = "Operator"
      window.titleVisibility = .hidden
      window.titlebarAppearsTransparent = true
      window.toolbarStyle = .unifiedCompact
      window.tabbingIdentifier = "operator.workspace"
      window.tabbingMode = .preferred
      window.isReleasedWhenClosed = false
      restoreMainWindowLayout(on: window)
      if integration == nil && !isUITesting {
        do {
          integration = try OperatorIntegration(
            executableURL: URL(fileURLWithPath: CommandLine.arguments[0]),
            onOpenMarkdown: { [weak self] path, sessionID in
              Task { @MainActor in
                self?.controller.openMarkdown(path, requestedBy: sessionID)
              }
            },
            onLayout: { [weak self] command, sessionID in
              Task { @MainActor in
                self?.controller.applyLayout(command: command, sessionID: sessionID)
              }
            },
            onQuestion: { [weak self] sessionID, message in
              Task { @MainActor in
                self?.controller.receiveQuestion(sessionID: sessionID, message: message)
              }
            },
            onEvent: { [weak self] event in
              Task { @MainActor in self?.controller.receiveEvent(event) }
            }
          )
        } catch {
          controller.alertMessage = "Harness handoff is unavailable: \(error.localizedDescription)"
          OperatorDebugLog.record(
            "ipc.start.failed", error.localizedDescription, level: .error)
        }
      }
      window.contentView = NSHostingView(rootView: WorkspaceView(controller: controller))
      window.delegate = self
      self.window = window
      window.makeKeyAndOrderFront(nil)
    }
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func applyAppearance(_ preference: AppAppearancePreference) {
    guard appliedAppearance != preference else { return }
    let appearance = AppAppearanceResolver.name(for: preference).flatMap(NSAppearance.init(named:))
    NSApp.appearance = appearance
    for window in NSApp.windows {
      window.appearance = appearance
      window.contentView?.needsDisplay = true
    }
    appliedAppearance = preference
    OperatorDebugLog.record(
      "appearance.applied", "Applied application appearance",
      level: .info, metadata: ["appearance": preference.rawValue])
  }

  private func configureDockIcon() {
    guard let icon = NSApp.applicationIconImage, icon.size.width > 0, icon.size.height > 0 else {
      return
    }

    let dockIcon = NSImage(size: icon.size)
    dockIcon.lockFocus()
    let bounds = NSRect(origin: .zero, size: icon.size)
    let inset = min(bounds.width, bounds.height) * 0.06
    let plate = bounds.insetBy(dx: inset, dy: inset)
    let radius = min(plate.width, plate.height) * 0.22
    NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
    NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius).fill()
    icon.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
    dockIcon.unlockFocus()
    NSApp.applicationIconImage = dockIcon
  }

  private func scheduleAppSmokeTest() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
      guard let self else { return }
      let expectedStatePath = ProcessInfo.processInfo.environment["OPERATOR_STATE_PATH"]
      let checks: [String: Bool] = [
        "windowCreated": self.window != nil,
        "windowVisible": self.window?.isVisible == true,
        "contentViewMounted": self.window?.contentView != nil,
        "minimumSize": (self.window?.frame.width ?? 0) >= 600
          && (self.window?.frame.height ?? 0) >= 400,
        "isolatedState": expectedStatePath != nil
          && self.store.stateFileURL.path == expectedStatePath,
        "emptyStateLoaded": self.store.state.projects.isEmpty,
        "emojiCatalogReady": OperatorEmojiCatalog.matching("launch").contains {
          $0.symbol == "🚀"
        },
        "emojiNormalization": Project.normalizedEmoji("🚀") == "🚀",
        "harnessBrandAssets": HarnessBrandAssets.image(for: .claudeCode) != nil
          && HarnessBrandAssets.image(for: .codex) != nil,
        "appearanceDefault": store.state.appearance == .system,
        "notificationsDefaultOff": !store.state.notificationsEnabled,
      ]
      let passed = checks.values.allSatisfy { $0 }
      let report: [String: Any] = [
        "passed": passed,
        "generatedAt": ISO8601DateFormatter().string(from: .now),
        "bundlePath": Bundle.main.bundleURL.path,
        "executable": CommandLine.arguments.first ?? "",
        "checks": checks,
      ]
      let reportPath = ProcessInfo.processInfo.environment["OPERATOR_SMOKE_REPORT"]
      do {
        guard let reportPath, !reportPath.isEmpty else {
          throw NSError(
            domain: "OperatorSmoke", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "OPERATOR_SMOKE_REPORT is missing."])
        }
        let data = try JSONSerialization.data(
          withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
        OperatorDebugLog.record(
          "app.smoke", passed ? "Packaged app smoke test passed" : "Packaged app smoke test failed",
          level: passed ? .info : .error)
      } catch {
        OperatorDebugLog.record("app.smoke.write.failed", error.localizedDescription, level: .error)
        exit(1)
      }
      if passed {
        NSApp.terminate(nil)
      } else {
        exit(1)
      }
    }
  }

  private func scheduleMultiProjectUIStressTest() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
      self?.runMultiProjectUIStressTest()
    }
  }

  private func runMultiProjectUIStressTest() {
    let environment = ProcessInfo.processInfo.environment
    let rootPath = environment["OPERATOR_MULTI_PROJECT_ROOT"] ?? ""
    let reportPath = environment["OPERATOR_MULTI_PROJECT_REPORT"] ?? ""
    let artifactPath = environment["OPERATOR_MULTI_PROJECT_ARTIFACT_DIR"] ?? ""
    do {
      guard !rootPath.isEmpty, !reportPath.isEmpty, !artifactPath.isEmpty else {
        throw multiProjectUIStressError(
          "The stress-test root, report, and artifact environment paths are required.")
      }
      guard store.state.projects.isEmpty else {
        throw multiProjectUIStressError("The multi-project UI stress test requires empty state.")
      }

      let fileManager = FileManager.default
      let root = URL(fileURLWithPath: rootPath, isDirectory: true)
      let artifactDirectory = URL(fileURLWithPath: artifactPath, isDirectory: true)
      try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
      try fileManager.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)

      let specifications: [(String, String, ProjectAccent)] = [
        ("Atlas", "🧭", .blue),
        ("Beacon", "💡", .orange),
        ("Comet", "🚀", .purple),
        ("Delta", "🧪", .green),
        ("Echo", "🤖", .teal),
      ]
      var projectResults: [MultiProjectUIStressProject] = []
      var renamedTab: (projectID: UUID, tabID: UUID)?

      for (name, emoji, accent) in specifications {
        let directory = root.appendingPathComponent(name.lowercased(), isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let projectID = store.addProject(
          name: name, directory: directory.path, emoji: emoji, accent: accent)
        guard
          let project = store.state.projects.first(where: { $0.id == projectID }),
          let workspace = project.workspaces.first
        else {
          throw multiProjectUIStressError("Operator did not retain the \(name) project.")
        }

        controller.selectProject(project.id)
        controller.launch(
          LaunchRequest(
            title: "\(name) Shell A", command: "/bin/zsh -l", directory: workspace.directory,
            projectID: project.id, workspaceID: workspace.id, harness: .generic))
        guard let splitTabID = controller.selectedTabID else {
          throw multiProjectUIStressError("\(name) did not create its first session tab.")
        }
        controller.splitFocusedTerminal(.horizontal)
        guard let emptyPaneID = controller.terminalLayout?.emptyPaneIDs.first else {
          throw multiProjectUIStressError("\(name) did not create a horizontal split pane.")
        }
        controller.launch(
          LaunchRequest(
            title: "\(name) Split Shell", command: "/bin/zsh -l",
            directory: workspace.directory, projectID: project.id, workspaceID: workspace.id,
            harness: .generic),
          intoPane: emptyPaneID)
        controller.launch(
          LaunchRequest(
            title: "\(name) Shell B", command: "/bin/zsh -l", directory: workspace.directory,
            projectID: project.id, workspaceID: workspace.id, harness: .generic))
        if name == "Atlas", let tabID = controller.selectedTabID {
          guard controller.renameTab(tabID, to: "Planning") else {
            throw multiProjectUIStressError("Operator could not rename the Atlas tab.")
          }
          renamedTab = (project.id, tabID)
        }
        controller.selectTab(splitTabID)

        let splitPaneCount =
          controller.tabs.first(where: { $0.id == splitTabID })?.layout.terminalIDs.count ?? 0
        projectResults.append(
          MultiProjectUIStressProject(
            id: project.id.uuidString, name: name, directory: workspace.directory,
            splitTabID: splitTabID.uuidString, liveSessionCount: controller.sessions.count,
            liveTabCount: controller.tabs.count, liveSplitPaneCount: splitPaneCount,
            restoredSessionCount: 0, restoredTabCount: 0, restoredSplitPaneCount: 0))
      }

      var liveSwitchingIsIndependent = true
      for result in projectResults {
        guard let projectID = UUID(uuidString: result.id) else { continue }
        controller.selectProject(projectID)
        let splitPaneCount =
          controller.tabs.first(where: { $0.id.uuidString == result.splitTabID })?
          .layout.terminalIDs.count ?? 0
        liveSwitchingIsIndependent =
          liveSwitchingIsIndependent && controller.sessions.count == 3
          && controller.tabs.count == 2 && splitPaneCount == 2
      }

      let projectTabsDefaultedOpen = projectResults.allSatisfy {
        UUID(uuidString: $0.id).map(store.isProjectExpanded) == true
      }
      guard
        let collapsedPreviewProjectID = projectResults.dropFirst().first.flatMap({
          UUID(uuidString: $0.id)
        })
      else {
        throw multiProjectUIStressError("The stress test could not select a collapse target.")
      }
      store.setProjectExpanded(false, for: collapsedPreviewProjectID)

      let reloadedStore = StateStore(fileURL: store.stateFileURL)
      let reloadedController = WorkspaceController(store: reloadedStore)
      let tabRenamePersisted =
        renamedTab.flatMap { renamed in
          reloadedStore.state.projectTabs[renamed.projectID]?.first(where: {
            $0.id == renamed.tabID
          })?.title
        } == "Planning"
      for index in projectResults.indices {
        guard let projectID = UUID(uuidString: projectResults[index].id) else { continue }
        reloadedController.selectProject(projectID)
        projectResults[index].restoredSessionCount = reloadedController.sessions.count
        projectResults[index].restoredTabCount = reloadedController.tabs.count
        projectResults[index].restoredSplitPaneCount =
          reloadedController.tabs.first(where: {
            $0.id.uuidString == projectResults[index].splitTabID
          })?.layout.terminalIDs.count ?? 0
      }

      guard
        let firstProjectID = projectResults.first.flatMap({ UUID(uuidString: $0.id) }),
        let firstSplitTabID = projectResults.first.flatMap({ UUID(uuidString: $0.splitTabID) })
      else {
        throw multiProjectUIStressError("The stress test did not create a visible project.")
      }
      let sidebarTabNavigationSucceeded = controller.selectTab(
        firstSplitTabID, inProject: firstProjectID)
      let selectedActivityTab = controller.tabs.first(where: { $0.id == firstSplitTabID })
      let unreadActivityTab = controller.tabs.first(where: { $0.title == "Planning" })
      if let sessionID = selectedActivityTab?.focusedSessionID {
        controller.recordTerminalOutput(sessionID: sessionID, isVisible: true)
      }
      if let sessionID = unreadActivityTab?.focusedSessionID {
        controller.recordTerminalOutput(sessionID: sessionID, isVisible: false)
      }
      let selectedTabShowsActiveOutput =
        selectedActivityTab.map(controller.outputActivity(for:)).map {
          $0.isProducingOutput && !$0.hasUnreadOutput
        } == true
      let backgroundTabShowsUnreadOutput =
        unreadActivityTab.map(controller.outputActivity(for:)).map(\.hasUnreadOutput) == true
      store.presentRecoveryMessageForMountedUITest(
        "Operator restored your workspace. Interrupted sessions were marked as needing attention.")
      let recoveryToastPresented = store.recoveryMessage != nil
      var previewFilePresented = true
      if let previewPath = environment["OPERATOR_MULTI_PROJECT_PREVIEW_FILE"],
        !previewPath.isEmpty
      {
        controller.openFile(previewPath)
        previewFilePresented =
          controller.selectedTab?.layout.firstFilePane?.path
          == URL(fileURLWithPath: previewPath).standardizedFileURL.resolvingSymlinksInPath().path
        if !previewFilePresented {
          throw multiProjectUIStressError(
            controller.alertMessage ?? "Operator could not open the requested preview file.")
        }
        if let markdownPath = environment["OPERATOR_MULTI_PROJECT_SPLIT_MARKDOWN"],
          !markdownPath.isEmpty
        {
          controller.splitFocusedTerminal(.horizontal)
          guard let emptyPaneID = controller.terminalLayout?.emptyPaneIDs.first else {
            throw multiProjectUIStressError("Operator could not create the preview split.")
          }
          controller.selectEmptyPane(emptyPaneID)
          controller.openMarkdown(markdownPath)
          let markdownPath = URL(fileURLWithPath: markdownPath).standardizedFileURL
            .resolvingSymlinksInPath().path
          previewFilePresented =
            controller.selectedTab?.contentKind == .mixed
            && controller.terminalLayout?.markdownPane(forPath: markdownPath)?.id == emptyPaneID
        }
        store.dismissRecoveryMessage()
      }

      let screenshotURL = artifactDirectory.appendingPathComponent(
        "five-projects-split-pane.png")
      let checks: [String: Bool] = [
        "windowMounted": window?.contentView != nil,
        "createdFiveProjects": store.state.projects.count == 5,
        "uniqueWorkingDirectories": Set(projectResults.map(\.directory)).count == 5,
        "threeLiveSessionsPerProject": projectResults.allSatisfy { $0.liveSessionCount == 3 },
        "twoLiveTabsPerProject": projectResults.allSatisfy { $0.liveTabCount == 2 },
        "twoPanesInSplitTabPerProject": projectResults.allSatisfy {
          $0.liveSplitPaneCount == 2
        },
        "projectSwitchingIsIndependent": liveSwitchingIsIndependent,
        "sidebarTabNavigationSelectsProjectAndTab": sidebarTabNavigationSucceeded,
        "selectedTabShowsActiveOutput": selectedTabShowsActiveOutput,
        "backgroundTabShowsUnreadOutput": backgroundTabShowsUnreadOutput,
        "floatingRecoveryToastPresented": recoveryToastPresented,
        "previewFilePresented": previewFilePresented,
        "tabRenamePersists": tabRenamePersisted,
        "projectTabsDefaultOpen": projectTabsDefaultedOpen,
        "sidebarExpansionStatePersists":
          !reloadedStore.isProjectExpanded(collapsedPreviewProjectID),
        "fifteenSessionsRetainedAcrossProjects": controller.allSessions.count == 15,
        "stateFileSaved": fileManager.fileExists(atPath: store.stateFileURL.path),
        "reloadedFiveProjects": reloadedStore.state.projects.count == 5,
        "restoredThreeSessionsPerProject": projectResults.allSatisfy {
          $0.restoredSessionCount == 3
        },
        "restoredTwoTabsPerProject": projectResults.allSatisfy { $0.restoredTabCount == 2 },
        "restoredSplitPanePerProject": projectResults.allSatisfy {
          $0.restoredSplitPaneCount == 2
        },
      ]
      let passed = checks.values.allSatisfy { $0 }
      let baseReport = MultiProjectUIStressReport(
        passed: passed, generatedAt: ISO8601DateFormatter().string(from: .now),
        statePath: store.stateFileURL.path, screenshotPath: screenshotURL.path, checks: checks,
        projects: projectResults, error: nil)

      let screenshotDelay =
        environment["OPERATOR_MULTI_PROJECT_SPLIT_MARKDOWN"]?.isEmpty == false ? 1.8 : 0.6
      DispatchQueue.main.asyncAfter(deadline: .now() + screenshotDelay) { [weak self] in
        guard let self else { return }
        var report = baseReport
        do {
          try self.captureWorkspaceWindow(to: screenshotURL)
        } catch {
          report.passed = false
          report.error = "Screenshot failed: \(error.localizedDescription)"
        }
        self.finishMultiProjectUIStressTest(report, reportPath: reportPath)
      }
    } catch {
      let report = MultiProjectUIStressReport(
        passed: false, generatedAt: ISO8601DateFormatter().string(from: .now),
        statePath: store.stateFileURL.path, screenshotPath: "", checks: [:], projects: [],
        error: error.localizedDescription)
      finishMultiProjectUIStressTest(report, reportPath: reportPath)
    }
  }

  private func captureWorkspaceWindow(to url: URL) throws {
    guard let contentView = window?.contentView else {
      throw multiProjectUIStressError("Operator's workspace window is unavailable.")
    }
    contentView.layoutSubtreeIfNeeded()
    contentView.displayIfNeeded()
    guard
      let representation = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds)
    else {
      throw multiProjectUIStressError("Operator could not allocate a window snapshot.")
    }
    contentView.cacheDisplay(in: contentView.bounds, to: representation)
    guard let data = representation.representation(using: .png, properties: [:]) else {
      throw multiProjectUIStressError("Operator could not encode its window snapshot.")
    }
    try data.write(to: url, options: .atomic)
  }

  private func finishMultiProjectUIStressTest(
    _ report: MultiProjectUIStressReport, reportPath: String
  ) {
    do {
      guard !reportPath.isEmpty else {
        throw multiProjectUIStressError("OPERATOR_MULTI_PROJECT_REPORT is missing.")
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      let data = try encoder.encode(report)
      try data.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
      OperatorDebugLog.record(
        "app.multi-project-ui-stress",
        report.passed
          ? "Five-project UI stress test passed" : "Five-project UI stress test failed",
        level: report.passed ? .info : .error)
    } catch {
      OperatorDebugLog.record(
        "app.multi-project-ui-stress.write.failed", error.localizedDescription, level: .error)
      exit(1)
    }
    if report.passed {
      if !ProcessInfo.processInfo.arguments.contains("--hold-ui-stress-preview") {
        NSApp.terminate(nil)
      }
    } else {
      exit(1)
    }
  }

  private func multiProjectUIStressError(_ description: String) -> NSError {
    NSError(
      domain: "OperatorMultiProjectUIStress", code: 1,
      userInfo: [NSLocalizedDescriptionKey: description])
  }

  func windowDidMove(_ notification: Notification) { scheduleMainWindowLayoutSave() }
  func windowDidEndLiveResize(_ notification: Notification) { scheduleMainWindowLayoutSave() }
  func windowDidMiniaturize(_ notification: Notification) { saveMainWindowLayout() }
  func windowDidDeminiaturize(_ notification: Notification) { scheduleMainWindowLayoutSave() }
  func windowDidEnterFullScreen(_ notification: Notification) { saveMainWindowLayout() }
  func windowDidExitFullScreen(_ notification: Notification) { saveMainWindowLayout() }
  func windowDidResize(_ notification: Notification) { scheduleMainWindowLayoutSave() }
  func windowWillClose(_ notification: Notification) { saveMainWindowLayout() }

  private func restoreMainWindowLayout(on window: NSWindow) {
    guard let layout = store.state.mainWindowLayout,
      layout.width >= 600, layout.height >= 400
    else {
      window.center()
      return
    }
    let frame = NSRect(x: layout.x, y: layout.y, width: layout.width, height: layout.height)
    guard NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else {
      window.center()
      return
    }
    window.setFrame(frame, display: false)
    if layout.isZoomed {
      DispatchQueue.main.async { window.zoom(nil) }
    }
    if layout.isFullScreen {
      DispatchQueue.main.async { window.toggleFullScreen(nil) }
    }
  }

  private func scheduleMainWindowLayoutSave() {
    windowLayoutSaveTask?.cancel()
    let task = DispatchWorkItem { [weak self] in self?.saveMainWindowLayout() }
    windowLayoutSaveTask = task
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: task)
  }

  private func saveMainWindowLayout() {
    guard let window, !window.isMiniaturized else { return }
    let frame = window.frame
    store.saveMainWindowLayout(
      OperatorWindowLayout(
        x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height,
        isZoomed: window.isZoomed, isFullScreen: window.styleMask.contains(.fullScreen)))
  }

  func focusQuestion(id: UUID) {
    showWorkspace()
    if let question = controller.questions.first(where: { $0.id == id }) {
      controller.revealQuestion(question)
    }
  }

  func showProjectManager() {
    if let projectManagerWindow {
      projectManagerWindow.makeKeyAndOrderFront(nil)
      return
    }
    let manager = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
      defer: false)
    manager.title = "Project Manager"
    manager.isReleasedWhenClosed = false
    manager.contentView = NSHostingView(
      rootView: ProjectManagerView(
        store: store, controller: controller,
        revealWorkspace: { [weak self] in
          self?.showWorkspace()
        }))
    manager.center()
    projectManagerWindow = manager
    manager.makeKeyAndOrderFront(nil)
  }

  private func configureMainMenu() {
    let mainMenu = NSMenu()
    let appMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)
    let appMenu = NSMenu(title: "Operator")
    appMenu.addItem(
      withTitle: "About Operator",
      action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(
      withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
    appMenu.addItem(.separator())
    appMenu.addItem(
      withTitle: "Quit Operator", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
    )
    appMenuItem.submenu = appMenu

    let fileMenu = NSMenu(title: "File")
    fileMenu.addItem(withTitle: "New Project…", action: #selector(newProject), keyEquivalent: "n")
    fileMenu.addItem(withTitle: "New Session…", action: #selector(newHarness), keyEquivalent: "k")
    fileMenu.addItem(.separator())
    fileMenu.addItem(
      withTitle: "Project Manager…", action: #selector(openProjectManager), keyEquivalent: "")
    let recentItem = NSMenuItem(title: "Recent Projects", action: nil, keyEquivalent: "")
    recentItem.submenu = recentProjectsMenu()
    fileMenu.addItem(recentItem)
    addTopLevelMenu(fileMenu, to: mainMenu)

    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Cut", action: #selector(NSTextView.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSTextView.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(
      withTitle: "Paste", action: #selector(NSTextView.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(.separator())
    editMenu.addItem(
      withTitle: "Select All", action: #selector(NSTextView.selectAll(_:)), keyEquivalent: "a")
    addTopLevelMenu(editMenu, to: mainMenu)

    let viewMenu = NSMenu(title: "View")
    let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
    let appearanceMenu = NSMenu(title: "Appearance")
    for preference in AppAppearancePreference.allCases {
      let item = NSMenuItem(
        title: preference.title, action: #selector(changeAppearance(_:)), keyEquivalent: "")
      item.image = NSImage(systemSymbolName: preference.systemImage, accessibilityDescription: nil)
      item.representedObject = preference.rawValue
      item.state = store.state.appearance == preference ? .on : .off
      appearanceMenu.addItem(item)
    }
    appearanceItem.submenu = appearanceMenu
    viewMenu.addItem(appearanceItem)
    addTopLevelMenu(viewMenu, to: mainMenu)

    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(
      withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
    windowMenu.addItem(
      withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    windowMenu.addItem(.separator())
    windowMenu.addItem(
      withTitle: "Operator Workspace", action: #selector(openWorkspace), keyEquivalent: "0")
    windowMenu.addItem(
      withTitle: "Project Manager", action: #selector(openProjectManager), keyEquivalent: "")
    addTopLevelMenu(windowMenu, to: mainMenu)
    NSApp.mainMenu = mainMenu
  }

  private func addTopLevelMenu(_ menu: NSMenu, to mainMenu: NSMenu) {
    let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
    item.submenu = menu
    mainMenu.addItem(item)
  }

  private func recentProjectsMenu() -> NSMenu {
    let menu = NSMenu(title: "Recent Projects")
    let projects = store.recentProjects
    guard !projects.isEmpty else {
      let empty = NSMenuItem(title: "No Recent Projects", action: nil, keyEquivalent: "")
      empty.isEnabled = false
      menu.addItem(empty)
      return menu
    }
    for project in projects {
      let item = NSMenuItem(
        title: project.displayName, action: #selector(openRecentProject(_:)), keyEquivalent: "")
      item.representedObject = project.id.uuidString
      item.toolTip = project.workspaces.first?.directory
      menu.addItem(item)
    }
    return menu
  }

  @objc private func newProject() {
    showWorkspace()
    NotificationCenter.default.post(name: .operatorNewProject, object: nil)
  }

  @objc private func newHarness() {
    showWorkspace()
    NotificationCenter.default.post(name: .operatorNewSession, object: nil)
  }

  @objc private func openWorkspace() { showWorkspace() }
  @objc private func openProjectManager() { showProjectManager() }
  @objc private func openSettings() {
    showWorkspace()
    NotificationCenter.default.post(name: .operatorSettings, object: nil)
  }

  @objc private func changeAppearance(_ item: NSMenuItem) {
    guard let rawValue = item.representedObject as? String,
      let preference = AppAppearancePreference(rawValue: rawValue)
    else { return }
    store.setAppearance(preference)
  }

  @objc private func openRecentProject(_ item: NSMenuItem) {
    guard let rawID = item.representedObject as? String, let projectID = UUID(uuidString: rawID)
    else {
      return
    }
    controller.openManagedProject(projectID)
    showWorkspace()
  }

  private func configureSystemSurfaces() {
    systemSurfaces = OperatorSystemSurfaces(appDelegate: self)
    let updates = Publishers.MergeMany(
      controller.$sessions.map { _ in () }.eraseToAnyPublisher(),
      controller.$questions.map { _ in () }.eraseToAnyPublisher(),
      controller.$sessionProgress.map { _ in () }.eraseToAnyPublisher(),
      controller.$systemSurfaceRevision.map { _ in () }.eraseToAnyPublisher()
    )
    updates
      .receive(on: RunLoop.main)
      .sink { [weak self] in self?.updateSystemSurfaces() }
      .store(in: &surfaceCancellables)
    updateSystemSurfaces()
  }

  private func updateSystemSurfaces() {
    systemSurfaces?.update(
      state: controller.systemSurfaceState, questions: controller.questions,
      sessions: controller.allSessions)
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let rawID = response.notification.request.content.userInfo["operatorSessionID"] as? String
    Task { @MainActor [weak self] in
      if let rawID, let sessionID = UUID(uuidString: rawID) {
        self?.showWorkspace()
        switch response.actionIdentifier {
        case OperatorNotifications.Action.retry.rawValue:
          self?.controller.retrySession(sessionID)
        case OperatorNotifications.Action.focusQuestion.rawValue:
          self?.controller.focusQuestion(for: sessionID)
        case OperatorNotifications.Action.openFailedHarness.rawValue:
          self?.controller.revealSession(sessionID)
        default:
          if let question = self?.controller.questions.first(where: { $0.sessionID == sessionID }) {
            self?.controller.revealQuestion(question)
          } else {
            self?.controller.revealSession(sessionID)
          }
        }
      }
      completionHandler()
    }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }
}
