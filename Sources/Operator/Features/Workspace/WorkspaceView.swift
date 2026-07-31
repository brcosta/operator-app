import AppKit
import SwiftUI

private struct TabRenameTarget: Identifiable {
  let projectID: UUID
  let tab: WorkspaceTab
  var id: UUID { tab.id }
}

enum OperatorMotion {
  static let quickDuration = 0.16
  static let standardDuration = 0.22
  static let toastDuration = 0.26
  static let recoveryToastAutoDismissSeconds: UInt64 = 5
  static let sidebarTransitionOffset: CGFloat = -5
  static let toastMaximumWidth: CGFloat = 620

  static func quick(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .easeInOut(duration: quickDuration)
  }

  static func standard(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .easeInOut(duration: standardDuration)
  }

  static func toast(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .easeOut(duration: toastDuration)
  }
}

struct WorkspaceView: View {
  @ObservedObject var controller: WorkspaceController
  @ObservedObject private var store: StateStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var paletteVisible = false
  @State private var closeTarget: TerminalSession?
  @State private var renameTabTarget: TabRenameTarget?
  @State private var briefTarget: TerminalSession?
  @State private var activityVisible = false
  @State private var shortcutsVisible = false
  @State private var resumeTarget: TerminalSession?
  @State private var splitPaneTarget: SplitPaneTarget?

  init(controller: WorkspaceController) {
    self.controller = controller
    _store = ObservedObject(wrappedValue: controller.store)
  }

  private var selectedProject: Project? {
    store.state.projects.first { $0.id == store.state.selectedProjectID }
  }

  @ViewBuilder private var reliabilityToast: some View {
    if let message = store.persistenceMessage {
      OperatorReliabilityToast(
        title: "Changes are not saved", message: message,
        symbol: "externaldrive.badge.exclamationmark", color: .red,
        details:
          "State file: \(store.stateFileURL.path)\nBackup: \(store.backupFileURL.path)",
        dismiss: store.dismissPersistenceMessage)
    } else if let message = store.recoveryMessage {
      OperatorReliabilityToast(
        title: "Workspace restored", message: message, symbol: "checkmark.shield.fill",
        color: .orange,
        details:
          "Operator validated saved projects, workspaces, sessions, and tabs before opening them.\n\nState file: \(store.stateFileURL.path)\nBackup: \(store.backupFileURL.path)",
        dismiss: store.dismissRecoveryMessage)
    }
  }

  var body: some View {
    NavigationSplitView {
      SidebarView(store: store, controller: controller)
        .navigationSplitViewColumnWidth(min: 235, ideal: 255, max: 320)
    } detail: {
      ZStack(alignment: .top) {
        VStack(spacing: 0) {
          if hasOpenContent {
            sessionTabs
              .transition(.opacity.combined(with: .move(edge: .top)))
            Divider()
              .transition(.opacity)
          }
          terminalArea
        }
        .animation(
          OperatorMotion.standard(reduceMotion: reduceMotion), value: hasOpenContent)
        reliabilityToast
          .frame(maxWidth: OperatorMotion.toastMaximumWidth)
          .padding(.horizontal, 14)
          .padding(.top, 12)
          .transition(
            .move(edge: .top)
              .combined(with: .opacity)
              .combined(with: .scale(scale: 0.98, anchor: .top))
          )
          .zIndex(20)
      }
      .animation(OperatorMotion.toast(reduceMotion: reduceMotion), value: store.persistenceMessage)
      .animation(OperatorMotion.toast(reduceMotion: reduceMotion), value: store.recoveryMessage)
      .toolbar {
        ToolbarItemGroup(placement: .primaryAction) {
          if selectedProject != nil {
            Button {
              paletteVisible = true
            } label: {
              Label("Command Palette", systemImage: "command")
            }
            .operatorShortcut(controller.store.shortcut(for: .newSession))
            .help("Open Command Palette")
            .accessibilityIdentifier("operator.commandPalette")
            Button {
              activityVisible = true
            } label: {
              Label("Activity", systemImage: "clock.arrow.circlepath")
            }
            .operatorShortcut(controller.store.shortcut(for: .activity))
            .help("Show Agent Activity")
            .accessibilityIdentifier("operator.activity")
          }
          if let selectedSession = controller.selectedSession {
            Button {
              briefTarget = selectedSession
            } label: {
              Label("Task Brief", systemImage: "note.text")
            }
            .operatorShortcut(controller.store.shortcut(for: .taskBrief))
            .help("Edit Task Brief")
            if controller.canSplitFocusedPane {
              Menu {
                Button("Split Horizontally") { controller.splitFocusedTerminal(.horizontal) }
                Button("Split Vertically") { controller.splitFocusedTerminal(.vertical) }
              } label: {
                Label("Split", systemImage: "rectangle.split.2x1")
              }
              .operatorShortcut(controller.store.shortcut(for: .splitPane))
              .help("Split the focused pane")
            }
            if controller.sessions.count >= 2 {
              Button {
                controller.missionControlLayout()
              } label: {
                Label("Mission Control", systemImage: "square.grid.2x2")
              }
              .operatorShortcut(controller.store.shortcut(for: .missionControl))
              .help("Arrange panes in Mission Control")
            }
            if selectedSession.status == .running {
              Button {
                selectedSession.terminate()
              } label: {
                Label("Stop", systemImage: "stop.fill")
              }
              .help("Stop the focused terminal")
            }
            Button {
              controller.restart(selectedSession)
            } label: {
              Label("Restart", systemImage: "arrow.clockwise")
            }
            .help("Restart the focused terminal")
            Button {
              closeTarget = selectedSession
            } label: {
              Label("Close", systemImage: "xmark")
            }
            .operatorShortcut(controller.store.shortcut(for: .closePane))
            .help("Close the focused pane")
            if controller.sessions.count >= 2 {
              Button {
                controller.focusAdjacentSession(-1)
              } label: {
                Image(systemName: "chevron.left")
              }
              .operatorShortcut(controller.store.shortcut(for: .previousPane))
              .help("Focus previous pane")
              Button {
                controller.focusAdjacentSession(1)
              } label: {
                Image(systemName: "chevron.right")
              }
              .operatorShortcut(controller.store.shortcut(for: .nextPane))
              .help("Focus next pane")
            }
          }
          Button {
            shortcutsVisible = true
          } label: {
            Label("Settings", systemImage: "gearshape")
          }
          .help("Open settings and keyboard shortcuts")
          .accessibilityIdentifier("operator.shortcuts")
        }
      }
    }
    .navigationSplitViewStyle(.balanced)
    .accessibilityIdentifier("operator.workspace")
    .sheet(isPresented: $paletteVisible) {
      CommandPalette(
        store: controller.store, controller: controller, targetPaneID: nil, onDismiss: {})
    }
    .sheet(item: $splitPaneTarget) { target in
      CommandPalette(
        store: controller.store, controller: controller, targetPaneID: target.id,
        onDismiss: { splitPaneTarget = nil })
    }
    .sheet(item: $renameTabTarget) { target in
      RenameTabSheet(controller: controller, tab: target.tab, projectID: target.projectID)
    }
    .sheet(item: $briefTarget) { session in
      TaskBriefEditor(controller: controller, session: session)
    }
    .sheet(isPresented: $activityVisible) {
      ActivityTimelineView(
        controller: controller, setNotificationsEnabled: controller.setNotificationsEnabled)
    }
    .sheet(isPresented: $shortcutsVisible) { ShortcutSettingsView(store: controller.store) }
    .sheet(item: $resumeTarget) { session in
      ResumeIdentifierSheet(controller: controller, session: session)
    }
    .onReceive(NotificationCenter.default.publisher(for: .operatorNewSession)) { _ in
      paletteVisible = true
    }
    .onReceive(NotificationCenter.default.publisher(for: .operatorSettings)) { _ in
      shortcutsVisible = true
    }
    .task(id: store.recoveryMessage) {
      guard store.recoveryMessage != nil else { return }
      do {
        try await Task.sleep(
          nanoseconds: OperatorMotion.recoveryToastAutoDismissSeconds * 1_000_000_000)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      withAnimation(OperatorMotion.toast(reduceMotion: reduceMotion)) {
        store.dismissRecoveryMessage()
      }
    }
    .alert(
      "Operator",
      isPresented: Binding(
        get: { controller.alertMessage != nil }, set: { if !$0 { controller.alertMessage = nil } })
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(controller.alertMessage ?? "")
    }
    .alert(
      "Close this active terminal?",
      isPresented: Binding(get: { closeTarget != nil }, set: { if !$0 { closeTarget = nil } })
    ) {
      Button("Terminate and Close", role: .destructive) {
        if let session = closeTarget { controller.close(session) }
        closeTarget = nil
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        closeTarget?.status == .running
          ? "Its running process will receive SIGTERM." : "This session has already exited.")
    }
    .alert(
      "Command finished",
      isPresented: Binding(
        get: { controller.exitClosePromptSession != nil },
        set: { if !$0 { controller.dismissExitClosePrompt() } })
    ) {
      Button("Close Pane", role: .destructive) {
        if let session = controller.exitClosePromptSession { controller.close(session) }
        controller.dismissExitClosePrompt()
      }
      Button("Keep Pane", role: .cancel) { controller.dismissExitClosePrompt() }
    } message: {
      if let session = controller.exitClosePromptSession {
        Text("\(session.title) exited with code \(session.exitCode ?? -1). Close its pane?")
      }
    }
  }

  private var hasOpenContent: Bool {
    !controller.tabs.isEmpty || !controller.markdownDocuments.isEmpty
      || !controller.artifacts.isEmpty
  }

  private var recentCustomCommands: [RecentSession] { store.recentCustomCommands() }

  private func launchRecentCustomCommand(_ recent: RecentSession) {
    guard let project = selectedProject, let workspace = project.workspaces.first else { return }
    controller.launch(
      LaunchRequest(
        title: recent.title, command: recent.command, directory: workspace.directory,
        projectID: project.id, workspaceID: workspace.id, harness: .generic))
  }

  private var sessionTabs: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 4) {
        Menu {
          Button("Start Codex") { controller.launchQuickHarness(.codex) }
          Button("Start Claude Code") { controller.launchQuickHarness(.claudeCode) }
          Divider()
          Button("Custom Command…") { paletteVisible = true }
          if !recentCustomCommands.isEmpty {
            Divider()
            Section("Recent custom commands") {
              ForEach(recentCustomCommands) { recent in
                Button(recent.command) { launchRecentCustomCommand(recent) }
                  .help("Run in the current project's first workspace")
              }
            }
          }
        } label: {
          Label("New session", systemImage: "plus.circle.fill")
            .font(.callout.weight(.medium))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.borderlessButton)
        .disabled(selectedProject?.workspaces.isEmpty != false)
        .accessibilityIdentifier("operator.newHarness")
        Divider().frame(height: 22).padding(.horizontal, 4)
        ForEach(controller.tabs) { tab in
          let session = controller.session(for: tab)
          let activity = controller.outputActivity(for: tab)
          Button {
            controller.selectTab(tab.id)
          } label: {
            HStack(spacing: 6) {
              TerminalTabActivityIndicator(
                activity: activity, status: session?.status, accentColor: .accentColor)
              HarnessIdentityMark(kind: session?.request.harness ?? .generic)
              Text(tab.title).lineLimit(1)
              if session?.status == .failed {
                Image(systemName: "exclamationmark.triangle.fill")
                  .font(.caption2)
                  .foregroundStyle(.orange)
              }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(
              tab.id == controller.selectedTabID ? Color.accentColor.opacity(0.18) : .clear,
              in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
              RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                  tab.id == controller.selectedTabID ? Color.accentColor.opacity(0.28) : .clear)
            }
          }
          .buttonStyle(.plain)
          .animation(
            OperatorMotion.quick(reduceMotion: reduceMotion), value: controller.selectedTabID
          )
          .accessibilityIdentifier("operator.session")
          .accessibilityLabel(
            "\(tab.title), \(sessionStatusDescription(session?.status)) terminal session, \(controller.outputActivityDescription(for: tab))"
          )
          .help(
            "\(session?.request.harness.displayName ?? "Terminal") · \(sessionStatusDescription(session?.status)) · \(controller.outputActivityDescription(for: tab))"
          )
          .contextMenu {
            if let session = controller.session(for: tab) {
              Button("Duplicate") { controller.duplicate(session) }
              Button("Restart") { controller.restart(session) }
              Button("Rename Tab…") {
                if let projectID = store.state.selectedProjectID {
                  renameTabTarget = TabRenameTarget(projectID: projectID, tab: tab)
                }
              }
              if session.request.harness == .codex {
                Button("Set Codex Resume ID…") { resumeTarget = session }
              }
              Button("Focus") { controller.selectTab(tab.id) }
              Button(controller.zoomedSessionID == session.id ? "Unzoom" : "Zoom Pane") {
                controller.toggleZoom(session.id)
              }
              Divider()
              Button("Close Focused Pane", role: .destructive) { closeTarget = session }
            }
          }
          .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
        ForEach(controller.markdownDocuments) { document in
          Button {
            controller.selectedMarkdownPath = document.path
          } label: {
            HStack(spacing: 6) {
              Image(systemName: "doc.richtext")
              Text(document.title).lineLimit(1)
              Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).onTapGesture {
                controller.closeMarkdown(document)
              }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(
              document.path == controller.selectedMarkdownPath
                ? Color.accentColor.opacity(0.17) : .clear, in: Capsule())
          }
          .buttonStyle(.plain)
        }
        ForEach(controller.artifacts) { artifact in
          Button {
            controller.selectedArtifactID = artifact.id
            controller.selectedMarkdownPath = nil
          } label: {
            HStack(spacing: 6) {
              Image(systemName: "shippingbox")
              Text(artifact.title).lineLimit(1)
              Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).onTapGesture {
                controller.closeArtifact(artifact)
              }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(
              artifact.id == controller.selectedArtifactID
                ? Color.accentColor.opacity(0.17) : .clear, in: Capsule())
          }.buttonStyle(.plain)
        }
      }
      .padding(8)
      .animation(
        OperatorMotion.standard(reduceMotion: reduceMotion),
        value: controller.tabs.map(\.id))
    }
    .background(.bar)
    .overlay(alignment: .bottom) { Divider() }
    .frame(height: 48)
    .fixedSize(horizontal: false, vertical: true)
  }

  private func sessionStatusDescription(_ status: SessionStatus?) -> String {
    switch status {
    case .running: "Running"
    case .failed: "Needs attention"
    case .exited: "Finished"
    case nil: "Unavailable"
    }
  }

  @ViewBuilder private var terminalArea: some View {
    if let artifact = controller.artifacts.first(where: { $0.id == controller.selectedArtifactID })
    {
      ArtifactView(artifact: artifact)
    } else if let document = controller.selectedMarkdownDocument {
      MarkdownDocumentView(document: document)
    } else if let zoomed = controller.zoomedSessionID,
      let session = controller.sessions.first(where: { $0.id == zoomed })
    {
      terminalPane(session)
    } else if let layout = controller.terminalLayout {
      TerminalLayoutView(
        layout: layout, path: "root", controller: controller,
        openCustomLauncher: { paneID in
          splitPaneTarget = SplitPaneTarget(id: paneID)
        }, requestClose: { closeTarget = $0 })
    } else {
      EmptyWorkspaceLauncher(
        project: selectedProject,
        addProject: {
          NotificationCenter.default.post(name: .operatorNewProject, object: nil)
        },
        startHarness: { controller.launchQuickHarness($0) },
        startTerminal: { controller.launchShell() },
        runCustomCommand: { paletteVisible = true })
    }
  }

  private func terminalPane(_ session: TerminalSession) -> some View {
    TerminalPaneView(
      session: session, isFocused: controller.selectedSessionID == session.id,
      focusColor: selectedProject?.accent.color ?? .accentColor, controller: controller,
      close: { closeTarget = session },
      select: {
        controller.selectTerminal(session.id)
      })
  }
}

private struct EmptyWorkspaceLauncher: View {
  let project: Project?
  let addProject: () -> Void
  let startHarness: (HarnessKind) -> Void
  let startTerminal: () -> Void
  let runCustomCommand: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var appeared = false

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [Color.accentColor.opacity(0.055), .clear, Color.purple.opacity(0.025)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
      ScrollView {
        VStack(spacing: 20) {
          VStack(spacing: 16) {
            OperatorIconTile(
              symbol: project == nil ? "terminal.fill" : "play.fill",
              color: project?.accent.color ?? .accentColor, size: 58)
            VStack(spacing: 7) {
              Text(project == nil ? "Build your command center" : "Ready when you are")
                .font(.system(size: 28, weight: .bold, design: .rounded))
              Text(
                project == nil
                  ? "Group terminal sessions, coding harnesses, and agent activity around each project."
                  : "Start a focused harness or run any command in this workspace."
              )
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
              .frame(maxWidth: 590)
            }
            if project == nil {
              Button(action: addProject) {
                Label("Add your first project", systemImage: "folder.badge.plus")
                  .frame(minWidth: 170)
              }
              .buttonStyle(.borderedProminent)
              .controlSize(.large)
              .accessibilityIdentifier("operator.emptyWorkspace.addProject")
            } else {
              if let workspace = project?.workspaces.first {
                Label(workspace.directory, systemImage: "folder")
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
                  .truncationMode(.middle)
                  .padding(.horizontal, 12).padding(.vertical, 7)
                  .background(.quaternary, in: Capsule())
              }
              LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10
              ) {
                EmptyPaneAction(
                  title: "Codex", subtitle: "Coding agent",
                  harness: .codex, color: .blue
                ) { startHarness(.codex) }
                .accessibilityIdentifier("operator.emptyWorkspace.startCodex")
                EmptyPaneAction(
                  title: "Claude Code", subtitle: "Coding agent",
                  harness: .claudeCode, color: .green
                ) { startHarness(.claudeCode) }
                .accessibilityIdentifier("operator.emptyWorkspace.startClaude")
                EmptyPaneAction(
                  title: "Terminal", subtitle: "Your default shell", symbol: "terminal",
                  color: project?.accent.color ?? .accentColor, action: startTerminal
                )
                .accessibilityIdentifier("operator.emptyWorkspace.startTerminal")
                EmptyPaneAction(
                  title: "Custom…", subtitle: "Any command", symbol: "slider.horizontal.3",
                  color: .secondary, action: runCustomCommand
                )
                .accessibilityIdentifier("operator.emptyWorkspace.custom")
              }
              .frame(maxWidth: 500)
              .disabled(project?.workspaces.isEmpty != false)
            }
          }
          .padding(32)
          .frame(maxWidth: 760)
          .operatorCardSurface()

          if project == nil {
            HStack(spacing: 12) {
              OperatorFeatureCard(
                symbol: "rectangle.split.3x1", title: "Persistent layouts",
                detail: "Return to project tabs and split geometry automatically.")
              OperatorFeatureCard(
                symbol: "person.2.badge.gearshape", title: "Agent supervision",
                detail: "See progress, questions, failures, and generated artifacts.")
              OperatorFeatureCard(
                symbol: "bell.badge", title: "Useful notifications",
                detail: "Know when a harness needs input or a command fails.")
            }
            .frame(maxWidth: 860)
          }
        }
        .padding(36)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 8)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .contentShape(Rectangle())
    .onAppear {
      if reduceMotion {
        appeared = true
      } else {
        withAnimation(.easeOut(duration: 0.28)) { appeared = true }
      }
    }
  }
}

private struct PaneCloseButton: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "xmark")
        .font(.caption2.weight(.bold))
        .frame(width: 18, height: 18)
        .background(.ultraThinMaterial, in: Circle())
        .overlay { Circle().stroke(.secondary.opacity(0.65), lineWidth: 1) }
    }
    .buttonStyle(.plain)
    .contentShape(Circle())
    .help("Close pane")
    .accessibilityLabel("Close pane")
  }
}

private struct PaneStatusBar: View {
  @ObservedObject var controller: WorkspaceController
  @ObservedObject var session: TerminalSession
  let close: () -> Void
  @State private var answerTarget: HarnessQuestion?

  var body: some View {
    let question = controller.questions.first { $0.sessionID == session.id }
    HStack(spacing: 8) {
      HarnessIdentityMark(kind: session.request.harness)
      Label(session.title, systemImage: session.status == .running ? "circle.fill" : "circle")
        .foregroundStyle(session.status == .running ? .green : .secondary)
        .lineLimit(1)
      Text(URL(fileURLWithPath: session.request.directory).lastPathComponent)
        .foregroundStyle(.secondary).lineLimit(1)
      if let branch = controller.lastGitBranch(forSessionID: session.id) {
        Label(branch, systemImage: "arrow.triangle.branch")
          .foregroundStyle(.secondary).lineLimit(1)
      }
      SessionRadarButton(files: session.changedFiles)
      Spacer()
      if let question {
        Button {
          controller.focusQuestion(question)
          answerTarget = question
        } label: {
          Label("Question: \(question.message)", systemImage: "questionmark.bubble.fill")
        }
        .lineLimit(1)
        .help("Focus the harness that asked this question")
      }
      if session.status != .running {
        Text(session.status == .failed ? "Process error" : "Exited \(session.exitCode ?? 0)")
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      PaneCloseButton(action: close)
        .accessibilityIdentifier("operator.closePane.\(session.id.uuidString)")
    }
    .accessibilityIdentifier("operator.paneStatusBar.\(session.id.uuidString)")
    .font(.caption2)
    .padding(.horizontal, 8).padding(.vertical, 5)
    .background(.ultraThinMaterial)
    .sheet(item: $answerTarget) { question in
      QuestionAnswerSheet(question: question) { answer in
        controller.answerQuestion(question, answer: answer)
      }
    }
  }
}

private struct TerminalLayoutView: View {
  let layout: TerminalLayout
  let path: String
  @ObservedObject var controller: WorkspaceController
  let openCustomLauncher: (UUID) -> Void
  let requestClose: (TerminalSession) -> Void

  var body: some View {
    let focusColor = controller.selectedProject?.accent.color ?? .accentColor
    switch layout {
    case .terminal(let id):
      if let session = controller.sessions.first(where: { $0.id == id }) {
        TerminalPaneView(
          session: session, isFocused: controller.selectedSessionID == id,
          focusColor: focusColor, controller: controller,
          close: { requestClose(session) },
          select: {
            controller.selectTerminal(id)
          })
      }
    case .empty(let paneID):
      EmptySplitPane(
        startHarness: { controller.launchQuickHarness($0, intoPane: paneID) },
        startTerminal: { controller.launchShell(intoPane: paneID) },
        openCustomLauncher: { openCustomLauncher(paneID) },
        close: { controller.closeEmptyPane(paneID) },
        onFocus: { controller.selectEmptyPane(paneID) },
        isFocused: controller.selectedEmptyPaneID == paneID,
        focusColor: focusColor)
    case .split(let orientation, let first, let second):
      EqualSplitView(
        orientation: orientation, ratio: controller.splitRatio(for: path),
        onRatioChanged: { controller.setSplitRatio($0, for: path) },
        first: {
          TerminalLayoutView(
            layout: first, path: "\(path).0", controller: controller,
            openCustomLauncher: openCustomLauncher, requestClose: requestClose)
        },
        second: {
          TerminalLayoutView(
            layout: second, path: "\(path).1", controller: controller,
            openCustomLauncher: openCustomLauncher, requestClose: requestClose)
        })
    }
  }
}

private struct EqualSplitView<First: View, Second: View>: NSViewControllerRepresentable {
  let orientation: SplitOrientation
  let ratio: Double
  let onRatioChanged: (Double) -> Void
  @ViewBuilder let first: () -> First
  @ViewBuilder let second: () -> Second

  func makeNSViewController(context: Context) -> EqualSplitController {
    EqualSplitController(
      orientation: orientation, ratio: ratio, onRatioChanged: onRatioChanged,
      first: AnyView(first()), second: AnyView(second()))
  }

  func updateNSViewController(_ controller: EqualSplitController, context: Context) {
    controller.update(
      orientation: orientation, ratio: ratio, onRatioChanged: onRatioChanged,
      first: AnyView(first()), second: AnyView(second()))
  }
}

private struct TerminalPaneView: View {
  @ObservedObject var session: TerminalSession
  let isFocused: Bool
  let focusColor: Color
  @ObservedObject var controller: WorkspaceController
  let close: () -> Void
  let select: () -> Void

  var body: some View {
    Group {
      if controller.store.state.paneStatusBarPosition ?? .top == .top {
        VStack(spacing: 0) {
          PaneStatusBar(controller: controller, session: session, close: close)
          terminalSurface
        }
      } else {
        VStack(spacing: 0) {
          terminalSurface
          PaneStatusBar(controller: controller, session: session, close: close)
        }
      }
    }
    .paneFocusIndicator(isFocused, color: focusColor)
  }

  private var terminalSurface: some View {
    TerminalHost(session: session, preferences: controller.store.state.terminalPreferences)
      .id(session.id)
      .onTapGesture(perform: select)
  }
}

private final class OperatorSplitView: NSSplitView {
  var onDividerDragStarted: () -> Void = {}
  var onDividerDragEnded: () -> Void = {}

  override var dividerThickness: CGFloat { 1 }

  override func drawDivider(in rect: NSRect) {
    NSColor.darkGray.setFill()
    rect.fill()
  }

  override func mouseDown(with event: NSEvent) {
    let location = convert(event.locationInWindow, from: nil)
    let isDivider = dividerHitRect?.insetBy(dx: -4, dy: -4).contains(location) == true
    if isDivider { onDividerDragStarted() }
    super.mouseDown(with: event)
    if isDivider { onDividerDragEnded() }
  }

  private var dividerHitRect: NSRect? {
    guard let first = subviews.first, subviews.count > 1 else { return nil }
    if isVertical {
      return NSRect(
        x: first.frame.maxX, y: bounds.minY, width: dividerThickness, height: bounds.height)
    }
    return NSRect(
      x: bounds.minX, y: first.frame.maxY, width: bounds.width, height: dividerThickness)
  }
}

private final class EqualSplitController: NSViewController, NSSplitViewDelegate {
  private let firstController: NSHostingController<AnyView>
  private let secondController: NSHostingController<AnyView>
  private let splitView = OperatorSplitView()
  private let initialIsVertical: Bool
  private var ratioApplicationScheduled = false
  private var isUserResizingDivider = false
  private var ratio: Double
  private var appliedRatio: Double?
  private var onRatioChanged: (Double) -> Void

  init(
    orientation: SplitOrientation, ratio: Double, onRatioChanged: @escaping (Double) -> Void,
    first: AnyView, second: AnyView
  ) {
    firstController = NSHostingController(rootView: first)
    secondController = NSHostingController(rootView: second)
    initialIsVertical = orientation == .horizontal
    self.ratio = ratio
    self.onRatioChanged = onRatioChanged
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  override func loadView() {
    splitView.isVertical = initialIsVertical
    splitView.dividerStyle = .thin
    splitView.delegate = self
    splitView.onDividerDragStarted = { [weak self] in self?.isUserResizingDivider = true }
    splitView.onDividerDragEnded = { [weak self] in
      guard let self else { return }
      self.isUserResizingDivider = false
      self.saveCurrentRatio()
    }
    addChild(firstController)
    addChild(secondController)
    splitView.addSubview(firstController.view)
    splitView.addSubview(secondController.view)
    view = splitView
  }

  func update(
    orientation: SplitOrientation, ratio: Double, onRatioChanged: @escaping (Double) -> Void,
    first: AnyView, second: AnyView
  ) {
    let isVertical = orientation == .horizontal
    if splitView.isVertical != isVertical {
      splitView.isVertical = isVertical
    }
    self.ratio = ratio
    self.onRatioChanged = onRatioChanged
    firstController.rootView = first
    secondController.rootView = second
    scheduleRatioApplication()
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    scheduleRatioApplication()
  }

  func splitViewDidResizeSubviews(_ notification: Notification) {
    // Window creation and parent-split layout both produce resize notifications before every
    // nested pane has its final bounds. Only an explicit divider drag is allowed to change the
    // persisted ratio; otherwise the saved ratio remains the source of truth.
  }

  private func saveCurrentRatio() {
    guard splitView.subviews.count == 2 else { return }
    let available = splitLength - splitView.dividerThickness
    guard available > 0 else { return }
    let firstLength =
      splitView.isVertical
      ? splitView.subviews[0].frame.width : splitView.subviews[0].frame.height
    let newRatio = min(0.9, max(0.1, firstLength / available))
    onRatioChanged(newRatio)
  }

  private var splitLength: CGFloat {
    splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
  }

  private func scheduleRatioApplication() {
    guard !ratioApplicationScheduled, !isUserResizingDivider, splitView.subviews.count == 2,
      splitLength > 100
    else { return }
    ratioApplicationScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.ratioApplicationScheduled = false
      guard !self.isUserResizingDivider, self.view.window != nil, self.splitLength > 100 else {
        return
      }
      let available = self.splitLength - self.splitView.dividerThickness
      guard available > 0 else { return }
      let boundedRatio = min(0.9, max(0.1, self.ratio))
      let desiredPosition = available * CGFloat(boundedRatio)
      let currentPosition =
        self.splitView.isVertical
        ? self.splitView.subviews[0].frame.width : self.splitView.subviews[0].frame.height
      guard abs(currentPosition - desiredPosition) > 0.5 else { return }
      self.splitView.setPosition(desiredPosition, ofDividerAt: 0)
    }
  }

  func splitView(
    _ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat,
    ofSubviewAt dividerIndex: Int
  ) -> CGFloat {
    let minimum: CGFloat = splitView.isVertical ? 180 : 120
    let available = splitLength - splitView.dividerThickness
    guard available >= minimum * 2 else { return max(0, min(available, proposedPosition)) }
    return min(available - minimum, max(minimum, proposedPosition))
  }
}

private struct SplitPaneTarget: Identifiable {
  let id: UUID
}

private struct EmptySplitPane: View {
  let startHarness: (HarnessKind) -> Void
  let startTerminal: () -> Void
  let openCustomLauncher: () -> Void
  let close: () -> Void
  let onFocus: () -> Void
  let isFocused: Bool
  let focusColor: Color

  var body: some View {
    ZStack(alignment: .topTrailing) {
      VStack {
        Spacer(minLength: 24)
        VStack(spacing: 16) {
          OperatorIconTile(symbol: "rectangle.split.2x1", color: focusColor, size: 48)
          VStack(spacing: 5) {
            Text("Start a session in this pane")
              .font(.title3.bold())
            Text("Choose a harness, open a shell, or run a custom command.")
              .font(.callout)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
          }
          LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10
          ) {
            EmptyPaneAction(
              title: "Codex", subtitle: "Coding agent",
              harness: .codex,
              color: .blue
            ) { startHarness(.codex) }
            EmptyPaneAction(
              title: "Claude Code", subtitle: "Coding agent", harness: .claudeCode,
              color: .green
            ) { startHarness(.claudeCode) }
            EmptyPaneAction(
              title: "Terminal", subtitle: "Your default shell", symbol: "terminal",
              color: focusColor, action: startTerminal)
            EmptyPaneAction(
              title: "Custom…", subtitle: "Any command", symbol: "slider.horizontal.3",
              color: .secondary, action: openCustomLauncher)
          }
        }
        .padding(22)
        .frame(maxWidth: 460)
        .operatorCardSurface()
        Spacer(minLength: 24)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(20)
      PaneCloseButton(action: close)
        .help("Close this empty pane")
        .padding(8)
    }
    .background(focusColor.opacity(0.035))
    .contentShape(Rectangle())
    .onTapGesture(perform: onFocus)
    .paneFocusIndicator(isFocused, color: focusColor)
  }
}

private struct EmptyPaneAction: View {
  let title: String
  let subtitle: String
  var symbol: String? = nil
  var harness: HarnessKind? = nil
  let color: Color
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        if let harness {
          HarnessIdentityMark(kind: harness, size: 21)
            .frame(width: 22, height: 22)
        } else if let symbol {
          Image(systemName: symbol)
            .font(.body.weight(.semibold))
            .foregroundStyle(color)
            .frame(width: 22)
        }
        VStack(alignment: .leading, spacing: 1) {
          Text(title).font(.callout.weight(.semibold))
          Text(subtitle).font(.caption2).foregroundStyle(.secondary)
        }
        Spacer(minLength: 4)
      }
      .padding(11)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
      .overlay {
        RoundedRectangle(cornerRadius: 10)
          .strokeBorder(Color.primary.opacity(0.08))
      }
    }
    .buttonStyle(.plain)
  }
}

extension View {
  fileprivate func paneFocusIndicator(_ isFocused: Bool, color: Color) -> some View {
    overlay {
      Rectangle()
        .strokeBorder(color, lineWidth: isFocused ? 1 : 0)
        .allowsHitTesting(false)
    }
  }
}

private struct RenameTabSheet: View {
  @ObservedObject var controller: WorkspaceController
  let tab: WorkspaceTab
  let projectID: UUID?
  @Environment(\.dismiss) private var dismiss
  @State private var title = ""

  init(controller: WorkspaceController, tab: WorkspaceTab, projectID: UUID? = nil) {
    self.controller = controller
    self.tab = tab
    self.projectID = projectID
  }

  private var normalizedTitle: String? { WorkspaceTabTitlePolicy.normalized(title) }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Rename Tab").font(.title3.bold())
      TextField("Title", text: $title)
        .accessibilityIdentifier("operator.renameTab.title")
      if title.trimmingCharacters(in: .whitespacesAndNewlines).count
        > WorkspaceTabTitlePolicy.maximumLength
      {
        Text("Use \(WorkspaceTabTitlePolicy.maximumLength) characters or fewer.")
          .font(.caption)
          .foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
        Button("Save") {
          let renamed =
            projectID.map { controller.renameTab(tab.id, inProject: $0, to: title) }
            ?? controller.renameTab(tab.id, to: title)
          if renamed { dismiss() }
        }
        .disabled(normalizedTitle == nil)
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24).frame(width: 360)
    .onAppear { title = tab.title }
  }
}

enum SidebarProjectGroupLayout {
  static let contentHorizontalPadding: CGFloat = 8
  static let projectVerticalPadding: CGFloat = 5
  static let tabVerticalPadding: CGFloat = 7
  static let separatorVerticalPadding: CGFloat = 10
  static let separatorHorizontalOutset = contentHorizontalPadding
  static let separatorHitTestingEnabled = false
  static let separatorAccessibilityHidden = true
}

enum TerminalTabActivityVisualState: Equatable {
  case producingOutput
  case unreadOutput
  case idle

  init(activity: SessionOutputActivity) {
    if activity.isProducingOutput {
      self = .producingOutput
    } else if activity.hasUnreadOutput {
      self = .unreadOutput
    } else {
      self = .idle
    }
  }
}

private struct TerminalTabActivityIndicator: View {
  let activity: SessionOutputActivity
  let status: SessionStatus?
  let accentColor: Color
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let visualState = TerminalTabActivityVisualState(activity: activity)
    ZStack {
      ZStack {
        Circle()
          .stroke(accentColor.opacity(0.45), lineWidth: 2)
          .frame(width: 11, height: 11)
        Circle()
          .fill(accentColor)
          .frame(width: 6, height: 6)
      }
      .opacity(visualState == .unreadOutput ? 1 : 0)
      .scaleEffect(visualState == .unreadOutput ? 1 : 0.82)

      Image(systemName: "waveform")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(Color.green)
        .symbolEffect(
          .variableColor.iterative, options: .repeating,
          isActive: visualState == .producingOutput && !reduceMotion
        )
        .opacity(visualState == .producingOutput ? 1 : 0)
        .scaleEffect(visualState == .producingOutput ? 1 : 0.82)

      Circle()
        .fill(statusColor)
        .frame(width: 7, height: 7)
        .opacity(visualState == .idle ? 1 : 0)
        .scaleEffect(visualState == .idle ? 1 : 0.82)
    }
    .frame(width: 12, height: 12)
    .animation(OperatorMotion.quick(reduceMotion: reduceMotion), value: activity)
    .animation(OperatorMotion.quick(reduceMotion: reduceMotion), value: status)
    .accessibilityHidden(true)
  }

  private var statusColor: Color {
    switch status {
    case .running: .green
    case .failed: .orange
    case .exited, nil: .secondary
    }
  }
}

private struct SidebarView: View {
  @ObservedObject var store: StateStore
  @ObservedObject var controller: WorkspaceController
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var addingProject = false
  @State private var repositoryProject: Project?
  @State private var renameProject: Project?
  @State private var renameTabTarget: TabRenameTarget?
  @State private var appearanceProject: Project?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        sidebarSectionHeader("Projects")
        let sidebarProjects = store.sidebarProjects
        ForEach(Array(sidebarProjects.enumerated()), id: \.element.id) { index, project in
          let projectTabs = controller.tabs(forProjectID: project.id)
          let isExpanded = !projectTabs.isEmpty && store.isProjectExpanded(project.id)

          VStack(alignment: .leading, spacing: 0) {
            projectRow(project, hasTabs: !projectTabs.isEmpty)
              .accessibilityIdentifier("operator.project.\(project.id.uuidString)")
              .accessibilityLabel(project.name)
              .help(project.workspaces.first?.directory ?? "")
              .contextMenu {
                Button("Add Workspace") { repositoryProject = project }
                Button("Rename") { renameProject = project }
                Button("Customize Appearance…") { appearanceProject = project }
                Divider()
                Button("Remove from Sidebar") { controller.hideProjectFromSidebar(project.id) }
              }

            if isExpanded {
              VStack(alignment: .leading, spacing: 0) {
                ForEach(projectTabs) { tab in
                  sidebarTabRow(tab, project: project)
                }
              }
              .transition(
                .opacity.combined(
                  with: .offset(y: OperatorMotion.sidebarTransitionOffset))
              )
              .clipped()
            }
          }
          .animation(OperatorMotion.standard(reduceMotion: reduceMotion), value: isExpanded)

          if index < sidebarProjects.count - 1 {
            projectSeparator
          }
        }

        if !store.state.profiles.isEmpty {
          sidebarSectionHeader("Launch profiles")
            .padding(.top, 8)
          ForEach(store.state.profiles) { profile in
            Button {
              controller.launch(
                LaunchRequest(
                  title: profile.name, command: profile.command, directory: profile.directory,
                  environment: profile.environmentDictionary, projectID: profile.projectID,
                  workspaceID: profile.workspaceID))
            } label: {
              Label(profile.name, systemImage: "play.circle")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
              Button("Delete Profile", role: .destructive) { store.removeProfile(profile.id) }
            }
          }
        }
      }
      .padding(.horizontal, SidebarProjectGroupLayout.contentHorizontalPadding)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .animation(
      OperatorMotion.quick(reduceMotion: reduceMotion), value: store.sidebarProjects.map(\.id)
    )
    .navigationTitle("Operator")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          addingProject = true
        } label: {
          Image(systemName: "folder.badge.plus")
        }
        .operatorShortcut(store.shortcut(for: .newProject))
        .accessibilityIdentifier("operator.newProject")
      }
    }
    .sheet(isPresented: $addingProject) {
      ProjectEditor(store: store, didCreateProject: controller.selectProject)
    }
    .sheet(item: $repositoryProject) { project in RepositoryEditor(store: store, project: project) }
    .sheet(item: $renameProject) { project in RenameProjectSheet(store: store, project: project) }
    .sheet(item: $renameTabTarget) { target in
      RenameTabSheet(controller: controller, tab: target.tab, projectID: target.projectID)
    }
    .sheet(item: $appearanceProject) { project in
      ProjectAppearanceSheet(store: store, project: project)
    }
    .onReceive(NotificationCenter.default.publisher(for: .operatorNewProject)) { _ in
      addingProject = true
    }
    .background {
      HStack(spacing: 0) {
        Button {
          controller.selectAdjacentProject(-1)
        } label: {
          Color.clear.frame(width: 1, height: 1)
        }
        .buttonStyle(.plain)
        .frame(width: 1, height: 1)
        .opacity(0.001)
        .operatorShortcut(store.shortcut(for: .previousProject))
        Button {
          controller.selectAdjacentProject(1)
        } label: {
          Color.clear.frame(width: 1, height: 1)
        }
        .buttonStyle(.plain)
        .frame(width: 1, height: 1)
        .opacity(0.001)
        .operatorShortcut(store.shortcut(for: .nextProject))
      }
    }
  }

  private func sidebarSectionHeader(_ title: String) -> some View {
    Text(title)
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 6)
      .padding(.bottom, 6)
      .accessibilityAddTraits(.isHeader)
  }

  private var projectSeparator: some View {
    Divider()
      .opacity(0.55)
      .padding(.horizontal, -SidebarProjectGroupLayout.separatorHorizontalOutset)
      .padding(.vertical, SidebarProjectGroupLayout.separatorVerticalPadding)
      .allowsHitTesting(SidebarProjectGroupLayout.separatorHitTestingEnabled)
      .accessibilityHidden(SidebarProjectGroupLayout.separatorAccessibilityHidden)
  }

  private func projectRow(_ project: Project, hasTabs: Bool) -> some View {
    let isExpanded = store.isProjectExpanded(project.id)
    let isSelected = store.state.selectedProjectID == project.id
    return HStack(spacing: 10) {
      Button {
        controller.selectProject(project.id)
      } label: {
        HStack(spacing: 10) {
          ProjectIdentityMark(project: project, size: 22)
          Text(project.name)
            .font(.callout.weight(.semibold))
            .lineLimit(1)
        }
      }
      .buttonStyle(.plain)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      Spacer(minLength: 6)
      let paneCount = controller.activePaneCount(for: project.id)
      if paneCount > 0 {
        Text("\(paneCount)")
          .font(.caption2.weight(.semibold))
          .monospacedDigit()
          .contentTransition(.numericText())
          .foregroundStyle(project.accent.color)
          .padding(.horizontal, 7).padding(.vertical, 3)
          .background(project.accent.color.opacity(0.1), in: Capsule())
          .animation(
            OperatorMotion.quick(reduceMotion: reduceMotion), value: paneCount
          )
          .accessibilityLabel("\(paneCount) active panes")
      }
      if hasTabs {
        Button {
          withAnimation(OperatorMotion.standard(reduceMotion: reduceMotion)) {
            store.setProjectExpanded(!isExpanded, for: project.id)
          }
        } label: {
          Image(systemName: "chevron.right")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .animation(OperatorMotion.quick(reduceMotion: reduceMotion), value: isExpanded)
            .frame(width: 20, height: 20)
            .background(.secondary.opacity(0.1), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("operator.projectDisclosure.\(project.id.uuidString)")
        .accessibilityLabel(
          isExpanded ? "Collapse \(project.name) tabs" : "Expand \(project.name) tabs"
        )
        .help(isExpanded ? "Hide project tabs" : "Show project tabs")
      } else {
        Color.clear.frame(width: 20, height: 20)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, SidebarProjectGroupLayout.projectVerticalPadding)
    .background(
      isSelected ? Color.primary.opacity(0.08) : .clear,
      in: RoundedRectangle(cornerRadius: 8)
    )
    .animation(OperatorMotion.quick(reduceMotion: reduceMotion), value: isSelected)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(projectAccessibilityLabel(project))
    .accessibilityValue(isSelected ? "Selected" : "Not selected")
  }

  private func sidebarTabRow(_ tab: WorkspaceTab, project: Project) -> some View {
    let isSelected =
      store.state.selectedProjectID == project.id && controller.selectedTabID == tab.id
    let session = controller.session(for: tab)
    let activity = controller.outputActivity(for: tab)
    return VStack(spacing: 0) {
      Button {
        controller.selectTab(tab.id, inProject: project.id)
      } label: {
        HStack(spacing: 7) {
          RoundedRectangle(cornerRadius: 2)
            .fill(isSelected ? project.accent.color : .clear)
            .frame(width: 3, height: 18)
          TerminalTabActivityIndicator(
            activity: activity, status: session?.status, accentColor: project.accent.color)
          Text(tab.title)
            .font(.callout.weight(.medium))
            .lineLimit(1)
          Spacer(minLength: 4)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, SidebarProjectGroupLayout.tabVerticalPadding)
        .background(
          isSelected ? project.accent.color.opacity(0.13) : .clear,
          in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .animation(OperatorMotion.quick(reduceMotion: reduceMotion), value: isSelected)
      .accessibilityIdentifier(
        "operator.sidebarTab.\(project.id.uuidString).\(tab.id.uuidString)"
      )
      .accessibilityLabel(tabAccessibilityLabel(tab, session: session))
      .help(tabHelp(tab, project: project, session: session))
      .contextMenu {
        Button("Rename Tab…") {
          renameTabTarget = TabRenameTarget(projectID: project.id, tab: tab)
        }
      }
    }
  }

  private func projectAccessibilityLabel(_ project: Project) -> String {
    let paneCount = controller.activePaneCount(for: project.id)
    let directory = project.workspaces.first?.directory ?? "No workspace"
    let branch = controller.lastGitBranch(forProjectID: project.id)
    return [
      project.name,
      paneCount == 1 ? "1 active pane" : "\(paneCount) active panes",
      directory,
      branch.map { "Git branch \($0)" },
    ]
    .compactMap { $0 }
    .joined(separator: ", ")
  }

  private func tabAccessibilityLabel(_ tab: WorkspaceTab, session: TerminalSession?) -> String {
    let paneCount = tab.layout.terminalIDs.count
    return [
      tab.title,
      sessionStatusDescription(session?.status),
      controller.outputActivityDescription(for: tab),
      paneCount == 1 ? "1 pane" : "\(paneCount) panes",
      session?.request.harness.displayName,
    ]
    .compactMap { $0 }
    .joined(separator: ", ")
  }

  private func tabHelp(_ tab: WorkspaceTab, project: Project, session: TerminalSession?) -> String {
    "\(project.name) · \(session?.request.harness.displayName ?? "Terminal") · \(sessionStatusDescription(session?.status)) · \(controller.outputActivityDescription(for: tab)) · \(tab.layout.terminalIDs.count) \(tab.layout.terminalIDs.count == 1 ? "pane" : "panes")"
  }

  private func sessionStatusDescription(_ status: SessionStatus?) -> String {
    switch status {
    case .running: "Running"
    case .failed: "Needs attention"
    case .exited: "Finished"
    case nil: "Unavailable"
    }
  }

}

private struct RenameProjectSheet: View {
  @ObservedObject var store: StateStore
  let project: Project
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Rename Project").font(.title2.bold())
      TextField("Name", text: $name)
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
        Button("Save") {
          store.renameProject(project.id, to: name)
          dismiss()
        }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }.padding(24).frame(width: 400).onAppear { name = project.name }
  }
}

private struct ProjectAppearanceSheet: View {
  @ObservedObject var store: StateStore
  let project: Project
  @Environment(\.dismiss) private var dismiss
  @State private var emoji = ""
  @State private var accent: ProjectAccent = .blue

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Project Appearance").font(.title2.bold())
      Text(project.name).foregroundStyle(.secondary)
      HStack(spacing: 12) {
        ProjectIdentityMark(project: preview, size: 30)
        ProjectEmojiPicker(emoji: $emoji)
          .accessibilityIdentifier("operator.projectAppearance.emoji")
        if !emoji.isEmpty {
          Button("Clear") { emoji = "" }
            .buttonStyle(.borderless)
        }
      }
      Text("Accent color").font(.headline)
      HStack(spacing: 10) {
        ForEach(ProjectAccent.allCases) { choice in
          Button {
            accent = choice
          } label: {
            Circle()
              .fill(choice.color)
              .frame(width: 22, height: 22)
              .overlay {
                if accent == choice {
                  Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                }
              }
              .shadow(color: choice.color.opacity(0.25), radius: accent == choice ? 4 : 0)
          }
          .buttonStyle(.plain)
          .help(choice.title)
          .accessibilityLabel(choice.title)
        }
      }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
        Button("Save") {
          store.updateProjectIdentity(project.id, emoji: emoji, accent: accent)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("operator.projectAppearance.save")
      }
    }
    .padding(24)
    .frame(width: 380)
    .onAppear {
      emoji = project.emoji ?? ""
      accent = project.accent
    }
  }

  private var preview: Project {
    Project(
      id: project.id, name: project.name, directory: project.workspaces.first?.directory ?? "",
      createdAt: project.createdAt, workspaces: project.workspaces, emoji: emoji, accent: accent)
  }
}

private struct QuestionAnswerSheet: View {
  let question: HarnessQuestion
  let answer: (String) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var value = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Harness question").font(.title2.bold())
      Text(question.message).textSelection(.enabled)
      TextField("Answer", text: $value, axis: .vertical).lineLimit(2...6)
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
        Button("Send to Terminal") {
          answer(value)
          dismiss()
        }.disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(
          .defaultAction)
      }
    }.padding(24).frame(width: 520)
  }
}

private struct ResumeIdentifierSheet: View {
  @ObservedObject var controller: WorkspaceController
  let session: TerminalSession
  @Environment(\.dismiss) private var dismiss
  @State private var identifier = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Codex Resume Identifier").font(.title2.bold())
      Text("Enter the session UUID or session name accepted by `codex resume`.").foregroundStyle(
        .secondary)
      TextField("Session UUID or name", text: $identifier)
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
        Button("Save") {
          controller.setResumeIdentifier(identifier, for: session)
          dismiss()
        }.disabled(identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }.padding(24).frame(width: 480)
  }
}

private struct RepositoryEditor: View {
  @ObservedObject var store: StateStore
  let project: Project
  @Environment(\.dismiss) private var dismiss
  @State private var alias = ""
  @State private var directory = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Add Workspace").font(.title2.bold())
      Text(project.name).foregroundStyle(.secondary)
      TextField("Workspace alias (optional)", text: $alias)
      HStack {
        TextField("Working directory", text: $directory)
        Button("Choose…") { chooseDirectory() }
      }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
        Button("Add") {
          store.addWorkspace(
            name: URL(fileURLWithPath: directory).lastPathComponent, directory: directory,
            to: project.id, alias: alias)
          dismiss()
        }.disabled(directory.isEmpty)
      }
    }
    .padding(24).frame(width: 500)
  }

  private func chooseDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK { directory = panel.url?.path ?? directory }
  }
}

private struct ProjectEditor: View {
  @ObservedObject var store: StateStore
  let didCreateProject: (UUID) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var directory = ""
  @State private var emoji = ""
  @State private var accent: ProjectAccent = .blue
  @State private var errorMessage: String?
  @FocusState private var nameFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 14) {
        OperatorIconTile(symbol: "folder.badge.plus", color: accent.color, size: 48)
        VStack(alignment: .leading, spacing: 3) {
          Text("New Project")
            .font(.title2.bold())
            .accessibilityIdentifier("operator.projectEditor.title")
          Text("Choose a workspace and give it an identity you can spot at a glance.")
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(24)
      .background(.ultraThinMaterial)

      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          VStack(alignment: .leading, spacing: 9) {
            Label("Working directory", systemImage: "folder")
              .font(.headline)
            Button(action: chooseDirectory) {
              HStack(spacing: 12) {
                Image(systemName: directory.isEmpty ? "folder.badge.plus" : "folder.fill")
                  .font(.title3)
                  .foregroundStyle(accent.color)
                VStack(alignment: .leading, spacing: 2) {
                  Text(
                    directory.isEmpty
                      ? "Choose a folder…" : URL(fileURLWithPath: directory).lastPathComponent
                  )
                  .fontWeight(.semibold)
                  Text(
                    directory.isEmpty
                      ? "Operator will launch sessions from this location."
                      : directory
                  )
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
                  .truncationMode(.middle)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
              }
              .padding(14)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .operatorCardSurface()
            Text("Or enter a path manually")
              .font(.caption)
              .foregroundStyle(.secondary)
            TextField("Working directory", text: $directory)
              .textFieldStyle(.roundedBorder)
              .accessibilityIdentifier("operator.projectEditor.directory")
              .onChange(of: directory) { _, newValue in
                guard name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                let inferred = URL(fileURLWithPath: newValue).lastPathComponent
                if !inferred.isEmpty { name = inferred }
              }
          }

          VStack(alignment: .leading, spacing: 9) {
            Text("Project name").font(.headline)
            TextField("For example, Operator", text: $name)
              .textFieldStyle(.roundedBorder)
              .focused($nameFocused)
              .accessibilityIdentifier("operator.projectEditor.name")
            Text("Used in the sidebar, session names, and notifications.")
              .font(.caption).foregroundStyle(.secondary)
          }

          VStack(alignment: .leading, spacing: 10) {
            Text("Emoji and accent").font(.headline)
            HStack(spacing: 14) {
              ProjectEmojiPicker(emoji: $emoji)
                .accessibilityIdentifier("operator.projectEditor.emoji")
                .accessibilityValue(emoji.isEmpty ? "None selected" : emoji)
              Spacer()
              ForEach(ProjectAccent.allCases) { choice in
                Button {
                  accent = choice
                } label: {
                  Circle()
                    .fill(choice.color)
                    .frame(width: 24, height: 24)
                    .overlay {
                      if accent == choice {
                        Image(systemName: "checkmark")
                          .font(.caption.bold()).foregroundStyle(.white)
                      }
                    }
                    .overlay {
                      Circle().strokeBorder(
                        accent == choice ? Color.primary.opacity(0.35) : .clear, lineWidth: 2)
                    }
                }
                .buttonStyle(.plain)
                .help(choice.title)
                .accessibilityLabel("\(choice.title) accent")
              }
            }
          }

          HStack(spacing: 12) {
            ProjectIdentityMark(project: preview, size: 25)
            VStack(alignment: .leading, spacing: 2) {
              Text(preview.name).fontWeight(.semibold)
              Text(
                directory.isEmpty
                  ? "Your project preview" : URL(fileURLWithPath: directory).lastPathComponent
              )
              .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(accent.title)
              .font(.caption.weight(.medium))
              .foregroundStyle(accent.color)
          }
          .padding(14)
          .background(accent.color.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))

          if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
              .font(.callout)
              .foregroundStyle(.red)
              .padding(12)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
              .accessibilityIdentifier("operator.projectEditor.error")
          }
        }
        .padding(24)
      }

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .accessibilityIdentifier("operator.projectEditor.cancel")
        Button("Add Project", action: addProject)
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(directory.isEmpty)
          .accessibilityIdentifier("operator.projectEditor.add")
      }
      .padding(18)
      .background(.bar)
    }
    .frame(width: 600, height: 620)
  }

  private func chooseDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url {
      directory = url.path
      if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        name = url.lastPathComponent
      }
      errorMessage = nil
      nameFocused = true
    }
  }

  private func addProject() {
    do {
      let draft = try ProjectDraftValidator.validate(
        name: name, directory: directory, emoji: emoji,
        existingProjects: store.state.projects)
      let projectID = store.addProject(
        name: draft.name, directory: draft.directory, emoji: draft.emoji, accent: accent)
      didCreateProject(projectID)
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private var preview: Project {
    Project(
      name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "Your project" : name,
      directory: directory, emoji: Project.normalizedEmoji(emoji), accent: accent)
  }
}

private struct ProjectIdentityHeader: View {
  let project: Project

  var body: some View {
    HStack(spacing: 9) {
      ProjectIdentityMark(project: project, size: 18)
      Text(project.name).font(.subheadline.weight(.semibold))
      if let workspace = project.workspaces.first, workspace.displayName != project.name {
        Text(workspace.displayName).foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(.horizontal, 14).frame(height: 42)
    .background(project.accent.color.opacity(0.07))
  }
}

struct ProjectIdentityMark: View {
  let project: Project
  var size: CGFloat = 11

  var body: some View {
    let boxSize = max(size + 6, 20)
    Group {
      if let emoji = project.emoji {
        Text(emoji)
          .font(.system(size: max(size + 4, 17)))
          .lineLimit(1)
          .fixedSize()
      } else {
        Circle()
          .fill(project.accent.color)
          .frame(width: size, height: size)
      }
    }
    .frame(width: boxSize, height: boxSize)
    .accessibilityLabel(project.displayName)
  }
}

private struct OperatorIconTile: View {
  let symbol: String
  let color: Color
  let size: CGFloat

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: size * 0.39, weight: .semibold))
      .foregroundStyle(color)
      .frame(width: size, height: size)
      .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: size * 0.28))
      .overlay {
        RoundedRectangle(cornerRadius: size * 0.28)
          .strokeBorder(color.opacity(0.12), lineWidth: 1)
      }
  }
}

private struct OperatorFeatureCard: View {
  let symbol: String
  let title: String
  let detail: String

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Image(systemName: symbol)
        .font(.title3.weight(.semibold))
        .foregroundStyle(Color.accentColor)
      Text(title).font(.headline)
      Text(detail)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
    .padding(16)
    .operatorCardSurface()
  }
}

private struct OperatorReliabilityToast: View {
  let title: String
  let message: String
  let symbol: String
  let color: Color
  let details: String?
  let dismiss: () -> Void
  @State private var showingDetails = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(alignment: .top, spacing: 11) {
      Image(systemName: symbol)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(color)
        .frame(width: 22, height: 22)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.callout.weight(.semibold))
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      if details != nil {
        Button("Details") { showingDetails = true }
          .buttonStyle(.plain)
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 7)
          .padding(.vertical, 4)
          .background(Color.primary.opacity(0.055), in: Capsule())
          .contentShape(Capsule())
          .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
              Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(color)
              Text(message)
              if let details {
                Text(details)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .textSelection(.enabled)
              }
            }
            .padding(16)
            .frame(width: 420, alignment: .leading)
          }
      }
      Button {
        withAnimation(OperatorMotion.toast(reduceMotion: reduceMotion)) {
          dismiss()
        }
      } label: {
        Image(systemName: "xmark")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .frame(width: 22, height: 22)
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .background(Color.primary.opacity(0.045), in: Circle())
      .accessibilityLabel("Dismiss")
    }
    .padding(.horizontal, 13)
    .padding(.vertical, 11)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
    .overlay {
      RoundedRectangle(cornerRadius: 13)
        .strokeBorder(color.opacity(0.22), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
    .accessibilityIdentifier("operator.reliabilityToast")
  }
}

extension View {
  fileprivate func operatorCardSurface() -> some View {
    background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
      .overlay {
        RoundedRectangle(cornerRadius: 14)
          .strokeBorder(Color.primary.opacity(0.085), lineWidth: 1)
      }
      .shadow(color: .black.opacity(0.045), radius: 12, y: 4)
  }
}

struct OperatorEmojiOption: Identifiable, Hashable {
  let symbol: String
  let name: String
  let keywords: [String]
  var id: String { name }
}

enum OperatorEmojiCatalog {
  static let all: [OperatorEmojiOption] = [
    .init(symbol: "🚀", name: "Rocket", keywords: ["launch", "space", "ship"]),
    .init(symbol: "🛠️", name: "Tools", keywords: ["build", "work", "engineering"]),
    .init(symbol: "💻", name: "Laptop", keywords: ["code", "computer", "development"]),
    .init(symbol: "⌨️", name: "Keyboard", keywords: ["terminal", "type", "input"]),
    .init(symbol: "🧠", name: "Brain", keywords: ["ai", "agent", "thinking"]),
    .init(symbol: "🤖", name: "Robot", keywords: ["ai", "agent", "automation", "coding"]),
    .init(symbol: "✨", name: "Sparkles", keywords: ["new", "magic", "polish"]),
    .init(symbol: "⚡️", name: "Lightning", keywords: ["fast", "energy", "power"]),
    .init(symbol: "🔥", name: "Fire", keywords: ["hot", "active", "important"]),
    .init(symbol: "💡", name: "Idea", keywords: ["light", "concept", "innovation"]),
    .init(symbol: "🎯", name: "Target", keywords: ["goal", "focus", "objective"]),
    .init(symbol: "📦", name: "Package", keywords: ["release", "bundle", "shipping"]),
    .init(symbol: "🧪", name: "Experiment", keywords: ["test", "science", "lab"]),
    .init(symbol: "🔬", name: "Microscope", keywords: ["inspect", "research", "debug"]),
    .init(symbol: "🔧", name: "Wrench", keywords: ["fix", "tool", "maintenance"]),
    .init(symbol: "⚙️", name: "Gear", keywords: ["settings", "system", "automation"]),
    .init(symbol: "🔒", name: "Lock", keywords: ["security", "private", "auth"]),
    .init(symbol: "🛡️", name: "Shield", keywords: ["security", "protect", "safe"]),
    .init(symbol: "🔑", name: "Key", keywords: ["access", "auth", "secret"]),
    .init(symbol: "🌐", name: "Globe", keywords: ["web", "network", "internet"]),
    .init(symbol: "☁️", name: "Cloud", keywords: ["server", "hosting", "remote"]),
    .init(symbol: "🗄️", name: "Database", keywords: ["data", "storage", "server"]),
    .init(symbol: "📱", name: "Phone", keywords: ["mobile", "ios", "app"]),
    .init(symbol: "🖥️", name: "Desktop", keywords: ["mac", "computer", "app"]),
    .init(symbol: "🎨", name: "Palette", keywords: ["design", "ui", "color"]),
    .init(symbol: "🧩", name: "Puzzle", keywords: ["plugin", "integration", "module"]),
    .init(symbol: "🔌", name: "Plug", keywords: ["plugin", "integration", "connect"]),
    .init(symbol: "🏗️", name: "Construction", keywords: ["architecture", "build", "infra"]),
    .init(symbol: "🏠", name: "Home", keywords: ["personal", "house", "local"]),
    .init(symbol: "🏢", name: "Office", keywords: ["company", "business", "work"]),
    .init(symbol: "📊", name: "Chart", keywords: ["analytics", "metrics", "dashboard"]),
    .init(symbol: "📈", name: "Growth", keywords: ["analytics", "up", "metrics"]),
    .init(symbol: "📝", name: "Notes", keywords: ["docs", "writing", "plan"]),
    .init(symbol: "📚", name: "Books", keywords: ["docs", "knowledge", "learning"]),
    .init(symbol: "🔍", name: "Search", keywords: ["find", "inspect", "lookup"]),
    .init(symbol: "🧭", name: "Compass", keywords: ["navigate", "direction", "explore"]),
    .init(symbol: "🗺️", name: "Map", keywords: ["navigate", "plan", "location"]),
    .init(symbol: "⏱️", name: "Timer", keywords: ["time", "performance", "speed"]),
    .init(symbol: "🔔", name: "Bell", keywords: ["notification", "alert", "attention"]),
    .init(symbol: "✅", name: "Complete", keywords: ["done", "success", "check"]),
    .init(symbol: "🟢", name: "Green", keywords: ["running", "ready", "healthy"]),
    .init(symbol: "🟡", name: "Yellow", keywords: ["waiting", "warning", "pause"]),
    .init(symbol: "🔴", name: "Red", keywords: ["failure", "stop", "error"]),
    .init(symbol: "🟣", name: "Purple", keywords: ["status", "color", "agent"]),
    .init(symbol: "🌟", name: "Star", keywords: ["favorite", "important", "quality"]),
    .init(symbol: "🏆", name: "Trophy", keywords: ["success", "winner", "achievement"]),
    .init(symbol: "💎", name: "Gem", keywords: ["quality", "valuable", "premium"]),
    .init(symbol: "🌱", name: "Seedling", keywords: ["new", "growth", "green"]),
    .init(symbol: "🌲", name: "Tree", keywords: ["nature", "branch", "growth"]),
    .init(symbol: "🌊", name: "Wave", keywords: ["water", "flow", "blue"]),
    .init(symbol: "☀️", name: "Sun", keywords: ["bright", "day", "energy"]),
    .init(symbol: "🌙", name: "Moon", keywords: ["night", "dark", "quiet"]),
    .init(symbol: "🪐", name: "Planet", keywords: ["space", "orbit", "world"]),
    .init(symbol: "🛰️", name: "Satellite", keywords: ["space", "network", "remote"]),
    .init(symbol: "🚢", name: "Ship", keywords: ["deploy", "shipping", "release"]),
    .init(symbol: "✈️", name: "Plane", keywords: ["travel", "launch", "fast"]),
    .init(symbol: "🚗", name: "Car", keywords: ["vehicle", "drive", "transport"]),
    .init(symbol: "🎮", name: "Game", keywords: ["play", "gaming", "controller"]),
    .init(symbol: "🎵", name: "Music", keywords: ["audio", "sound", "song"]),
    .init(symbol: "📷", name: "Camera", keywords: ["photo", "image", "media"]),
    .init(symbol: "🎬", name: "Movie", keywords: ["video", "film", "media"]),
    .init(symbol: "❤️", name: "Heart", keywords: ["favorite", "love", "health"]),
    .init(symbol: "🙌", name: "Celebrate", keywords: ["success", "hands", "done"]),
    .init(symbol: "👀", name: "Eyes", keywords: ["watch", "monitor", "review"]),
  ]

  static func matching(_ query: String) -> [OperatorEmojiOption] {
    let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    guard !terms.isEmpty else { return all }
    return all.filter { option in
      let haystack = ([option.name, option.symbol] + option.keywords).joined(separator: " ")
        .lowercased()
      return terms.allSatisfy(haystack.contains)
    }
  }
}

enum OperatorEmojiPickerLayout {
  static let popoverWidth: CGFloat = 340
  static let contentPadding: CGFloat = 16
  static let columnCount = 7
  static let itemWidth: CGFloat = 36
  static let columnSpacing: CGFloat = 7

  static var availableContentWidth: CGFloat {
    popoverWidth - (contentPadding * 2)
  }

  static var requiredGridWidth: CGFloat {
    (CGFloat(columnCount) * itemWidth) + (CGFloat(columnCount - 1) * columnSpacing)
  }
}

private struct ProjectEmojiPicker: View {
  @Binding var emoji: String
  @State private var isPresented = false

  var body: some View {
    Button {
      isPresented.toggle()
    } label: {
      HStack(spacing: 9) {
        if emoji.isEmpty {
          Image(systemName: "face.smiling")
            .foregroundStyle(Color.accentColor)
        } else {
          Text(emoji).font(.title3)
        }
        Text(emoji.isEmpty ? "Choose emoji" : "Change emoji")
          .font(.callout.weight(.medium))
        Spacer(minLength: 8)
        Image(systemName: "chevron.down")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 12)
      .frame(width: 190, height: 36)
      .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
      .overlay {
        RoundedRectangle(cornerRadius: 9)
          .strokeBorder(Color.primary.opacity(0.1))
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(emoji.isEmpty ? "Choose project emoji" : "Change project emoji")
    .accessibilityValue(emoji.isEmpty ? "None selected" : emoji)
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      OperatorEmojiPickerPopover(emoji: $emoji, isPresented: $isPresented)
    }
  }
}

private struct OperatorEmojiPickerPopover: View {
  @Binding var emoji: String
  @Binding var isPresented: Bool
  @State private var search = ""
  @State private var customEmoji = ""

  private var matches: [OperatorEmojiOption] { OperatorEmojiCatalog.matching(search) }
  private var normalizedCustomEmoji: String? { Project.normalizedEmoji(customEmoji) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Project emoji").font(.headline)
          Text("Choose a recognizable project mark.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if !emoji.isEmpty {
          Button("Remove") {
            emoji = ""
            isPresented = false
          }
          .buttonStyle(.borderless)
        }
      }
      TextField("Search emoji", text: $search)
        .textFieldStyle(.roundedBorder)
        .accessibilityIdentifier("operator.emoji.search")
      ScrollView {
        if matches.isEmpty {
          ContentUnavailableView(
            "No matching emoji", systemImage: "magnifyingglass",
            description: Text("Try a broader search or paste one below.")
          )
          .frame(maxWidth: .infinity, minHeight: 150)
        } else {
          LazyVGrid(
            columns: Array(
              repeating: GridItem(
                .fixed(OperatorEmojiPickerLayout.itemWidth),
                spacing: OperatorEmojiPickerLayout.columnSpacing),
              count: OperatorEmojiPickerLayout.columnCount),
            spacing: OperatorEmojiPickerLayout.columnSpacing
          ) {
            ForEach(matches) { option in
              Button {
                emoji = option.symbol
                isPresented = false
              } label: {
                Text(option.symbol)
                  .font(.system(size: 23))
                  .frame(width: 34, height: 34)
                  .background(
                    emoji == option.symbol ? Color.accentColor.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
              }
              .buttonStyle(.plain)
              .help(option.name)
              .accessibilityLabel(option.name)
              .accessibilityIdentifier("operator.emoji.\(option.name.lowercased())")
            }
          }
          .padding(.vertical, 2)
        }
      }
      .frame(height: 190)
      Divider()
      HStack(spacing: 8) {
        TextField("Paste any emoji", text: $customEmoji)
          .textFieldStyle(.roundedBorder)
          .onSubmit(applyCustomEmoji)
          .accessibilityIdentifier("operator.emoji.custom")
        Button("Use", action: applyCustomEmoji)
          .disabled(normalizedCustomEmoji == nil)
          .accessibilityIdentifier("operator.emoji.useCustom")
      }
      Text("Selection is handled inside Operator and does not depend on Character Viewer focus.")
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
    .padding(OperatorEmojiPickerLayout.contentPadding)
    .frame(width: OperatorEmojiPickerLayout.popoverWidth)
  }

  private func applyCustomEmoji() {
    guard let normalizedCustomEmoji else { return }
    emoji = normalizedCustomEmoji
    isPresented = false
  }
}

extension ProjectAccent {
  var color: Color {
    switch self {
    case .blue: Color(nsColor: .systemBlue)
    case .purple: Color(nsColor: .systemPurple)
    case .teal: Color(nsColor: .systemTeal)
    case .green: Color(nsColor: .systemGreen)
    case .orange: Color(nsColor: .systemOrange)
    case .pink: Color(nsColor: .systemPink)
    case .gray: Color(nsColor: .systemGray)
    }
  }
}

extension HarnessKind {
  var displayName: String {
    switch self {
    case .claudeCode: "Claude Code"
    case .codex: "Codex"
    case .generic: "Terminal"
    }
  }

  var symbolName: String {
    switch self {
    case .claudeCode: "sparkles"
    case .codex: "chevron.left.forwardslash.chevron.right"
    case .generic: "terminal"
    }
  }

  var accentColor: Color {
    switch self {
    case .claudeCode: Color(nsColor: .systemOrange)
    case .codex: Color(nsColor: .systemIndigo)
    case .generic: Color.secondary
    }
  }
}

struct HarnessIdentityMark: View {
  let kind: HarnessKind
  var size: CGFloat = 12

  var body: some View {
    Group {
      if let image = HarnessBrandAssets.image(for: kind) {
        Image(nsImage: image)
          .resizable()
          .renderingMode(kind == .codex ? .template : .original)
          .foregroundStyle(kind.accentColor)
          .aspectRatio(contentMode: .fit)
      } else {
        Image(systemName: kind.symbolName)
          .font(.system(size: size * 0.8, weight: .semibold))
          .foregroundStyle(kind.accentColor)
      }
    }
    .frame(width: size, height: size)
    .help(kind.displayName)
    .accessibilityLabel(kind.displayName)
  }
}

enum HarnessBrandAssets {
  static func resourceURL(for kind: HarnessKind) -> URL? {
    let assetName: String
    switch kind {
    case .claudeCode: assetName = "claude-code"
    case .codex: assetName = "codex"
    case .generic: return nil
    }
    return resourceBundle.url(forResource: assetName, withExtension: "svg")
  }

  static func image(for kind: HarnessKind) -> NSImage? {
    guard let url = resourceURL(for: kind), let image = NSImage(contentsOf: url) else { return nil }
    if kind == .codex { image.isTemplate = true }
    return image
  }

  private static let resourceBundle: Bundle = {
    #if SWIFT_PACKAGE
      .module
    #else
      .main
    #endif
  }()
}
