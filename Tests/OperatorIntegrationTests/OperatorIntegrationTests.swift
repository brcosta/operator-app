import Foundation
import Testing

@testable import Operator

struct OperatorIntegrationTests {
  @Test func longApplicationSupportPathUsesShortPrivateRuntimeSocket() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      UUID().uuidString)
    let longSupport = (0..<6).reduce(root) { result, index in
      result.appendingPathComponent("application-support-segment-\(index)-0123456789")
    }
    defer { try? FileManager.default.removeItem(at: root) }
    let priorEnvironment = OperatorRuntime.environment
    defer { OperatorRuntime.setEnvironment(priorEnvironment) }
    let sessionID = UUID()
    let token = OperatorSessionCredentials.shared.register(sessionID: sessionID)
    defer { OperatorSessionCredentials.shared.unregister(sessionID: sessionID) }
    let handoffReceived = DispatchSemaphore(value: 0)

    let integration = try OperatorIntegration(
      executableURL: URL(fileURLWithPath: "/bin/echo"),
      supportDirectory: longSupport,
      onOpenMarkdown: { _, _ in },
      onLayout: { command, receivedSessionID in
        if command == "split-right", receivedSessionID == sessionID {
          handoffReceived.signal()
        }
      })

    withExtendedLifetime(integration) {
      let socketPath = try! #require(OperatorRuntime.environment["OPERATOR_SOCKET"])
      let runtimeDirectory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
      let attributes = try! FileManager.default.attributesOfItem(atPath: runtimeDirectory.path)
      let permissions = try! #require(attributes[.posixPermissions] as? NSNumber).intValue

      #expect(!socketPath.hasPrefix(longSupport.path))
      #expect(socketPath.utf8.count <= OperatorRuntimeSocketDirectory.maximumSocketPathLength)
      #expect(runtimeDirectory.path == "/tmp/operator-\(geteuid())")
      #expect(permissions & 0o077 == 0)

      let response = try! UnixSocketClient.send(
        request: OperatorOpenRequest(
          version: 1, action: "layout", path: nil, layout: "split-right",
          sessionID: sessionID.uuidString, token: token),
        socketPath: socketPath)
      #expect(response == "OK")
      #expect(handoffReceived.wait(timeout: .now() + 1) == .success)
    }
  }

  @Test func runtimeSocketDirectoryRejectsNonprivateDirectories() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("operator-insecure-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o755])
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(throws: OperatorIPCError.self) {
      try OperatorRuntimeSocketDirectory.prepare(directory)
    }
  }

  @Test func harnessSocketHandoffAuthenticatesAndDispatchesRequests() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let support = URL(fileURLWithPath: "/private/tmp/op-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: support) }
    let markdown = directory.appendingPathComponent("handoff.md")
    try "# Handoff".write(to: markdown, atomically: true, encoding: .utf8)

    let lock = NSLock()
    var openedMarkdown: String?
    var requestedLayout: (command: String, sessionID: UUID?)?
    var receivedQuestion: (UUID, String)?
    var receivedEvent: HarnessEventEnvelope?
    let markdownReceived = DispatchSemaphore(value: 0)
    let layoutReceived = DispatchSemaphore(value: 0)
    let questionReceived = DispatchSemaphore(value: 0)
    let eventReceived = DispatchSemaphore(value: 0)
    let priorEnvironment = OperatorRuntime.environment
    defer { OperatorRuntime.setEnvironment(priorEnvironment) }
    let integration = try OperatorIntegration(
      executableURL: URL(fileURLWithPath: "/bin/echo"),
      supportDirectory: support,
      onOpenMarkdown: { path, _ in
        lock.lock()
        openedMarkdown = path
        lock.unlock()
        markdownReceived.signal()
      },
      onLayout: { command, sessionID in
        lock.lock()
        requestedLayout = (command, sessionID)
        lock.unlock()
        layoutReceived.signal()
      },
      onQuestion: { sessionID, message in
        lock.lock()
        receivedQuestion = (sessionID, message)
        lock.unlock()
        questionReceived.signal()
      },
      onEvent: { event in
        lock.lock()
        receivedEvent = event
        lock.unlock()
        eventReceived.signal()
      }
    )
    withExtendedLifetime(integration) {
      let environment = OperatorRuntime.environment
      let socketPath = try! #require(environment["OPERATOR_SOCKET"])
      #expect(environment["OPERATOR_TOKEN"] == nil)
      let sessionID = UUID()
      let token = OperatorSessionCredentials.shared.register(sessionID: sessionID)
      defer { OperatorSessionCredentials.shared.unregister(sessionID: sessionID) }

      let markdownResponse = try! UnixSocketClient.send(
        request: OperatorOpenRequest(
          version: 1, action: "openMarkdown", path: markdown.path,
          sessionID: sessionID.uuidString, token: token),
        socketPath: socketPath)
      #expect(markdownResponse == "OK")
      #expect(markdownReceived.wait(timeout: .now() + 1) == .success)
      lock.lock()
      let receivedMarkdown = openedMarkdown
      lock.unlock()
      #expect(receivedMarkdown == markdown.resolvingSymlinksInPath().path)

      let layoutResponse = try! UnixSocketClient.send(
        request: OperatorOpenRequest(
          version: 1, action: "layout", path: nil, layout: "mission-control",
          sessionID: sessionID.uuidString, token: token),
        socketPath: socketPath)
      #expect(layoutResponse == "OK")
      #expect(layoutReceived.wait(timeout: .now() + 1) == .success)
      lock.lock()
      let receivedLayout = requestedLayout
      lock.unlock()
      #expect(receivedLayout?.command == "mission-control")
      #expect(receivedLayout?.sessionID == sessionID)

      let questionResponse = try! UnixSocketClient.send(
        request: OperatorOpenRequest(
          version: 1, action: "question", path: nil, message: "Which migration should I use?",
          sessionID: sessionID.uuidString, token: token), socketPath: socketPath)
      #expect(questionResponse == "OK")
      #expect(questionReceived.wait(timeout: .now() + 1) == .success)
      lock.lock()
      let question = receivedQuestion
      lock.unlock()
      #expect(question?.0 == sessionID)
      #expect(question?.1 == "Which migration should I use?")

      let eventSessionID = UUID()
      let eventToken = OperatorSessionCredentials.shared.register(sessionID: eventSessionID)
      defer { OperatorSessionCredentials.shared.unregister(sessionID: eventSessionID) }
      let envelope = HarnessEventEnvelope(
        sessionID: eventSessionID, kind: .progress, message: "Indexing", progress: 0.5,
        resumeIdentifier: "4e92e921-1454-4b5d-a62a-4c71d31b47f4")
      let eventResponse = try! UnixSocketClient.send(
        request: OperatorOpenRequest(
          version: 2, action: "event", path: nil, token: eventToken, event: envelope),
        socketPath: socketPath)
      #expect(eventResponse == "OK")
      #expect(eventReceived.wait(timeout: .now() + 1) == .success)
      lock.lock()
      let routedEvent = receivedEvent
      lock.unlock()
      #expect(routedEvent == envelope)
      let spoofedEvent = try! UnixSocketClient.send(
        request: OperatorOpenRequest(
          version: 2, action: "event", path: nil, token: token, event: envelope),
        socketPath: socketPath)
      #expect(spoofedEvent.hasPrefix("ERROR"))
      let invalidResumeIdentifier = try! UnixSocketClient.send(
        request: OperatorOpenRequest(
          version: 2, action: "event", path: nil, token: eventToken,
          event: HarnessEventEnvelope(
            sessionID: eventSessionID, kind: .childStarted,
            resumeIdentifier: "unsafe\nidentifier")),
        socketPath: socketPath)
      #expect(invalidResumeIdentifier.hasPrefix("ERROR"))

      let rejected = try! UnixSocketClient.send(
        request: OperatorOpenRequest(
          version: 1, action: "openMarkdown", path: markdown.path, token: "wrong"),
        socketPath: socketPath)
      #expect(rejected.hasPrefix("ERROR"))
      let unsupportedVersion = try! UnixSocketClient.send(
        request: OperatorOpenRequest(
          version: 2, action: "openMarkdown", path: markdown.path,
          sessionID: sessionID.uuidString, token: token),
        socketPath: socketPath)
      #expect(unsupportedVersion.hasPrefix("ERROR"))
      let invalidLayout = try! UnixSocketClient.send(
        request: OperatorOpenRequest(
          version: 1, action: "layout", path: nil, layout: "close-all",
          sessionID: sessionID.uuidString, token: token),
        socketPath: socketPath)
      #expect(invalidLayout.hasPrefix("ERROR"))
      let emptyQuestion = try! UnixSocketClient.send(
        request: OperatorOpenRequest(
          version: 1, action: "question", path: nil, message: "  ", sessionID: sessionID.uuidString,
          token: token), socketPath: socketPath)
      #expect(emptyQuestion.hasPrefix("ERROR"))
      let invalidQuestionID = try! UnixSocketClient.send(
        request: OperatorOpenRequest(
          version: 1, action: "question", path: nil, message: "Need input", sessionID: "not-a-uuid",
          token: token), socketPath: socketPath)
      #expect(invalidQuestionID.hasPrefix("ERROR"))
      let invalidMarkdown = try! UnixSocketClient.send(
        request: OperatorOpenRequest(
          version: 1, action: "openMarkdown", path: directory.path,
          sessionID: sessionID.uuidString, token: token),
        socketPath: socketPath)
      #expect(invalidMarkdown.hasPrefix("ERROR"))
      #expect(
        FileManager.default.isExecutableFile(
          atPath: support.appendingPathComponent("bin/operator").path))
    }
  }

  @Test func layoutCommandAliasesNormalizeWithoutLaunchingTheApp() {
    #expect(
      OperatorCommandClient.normalizedLayoutCommand(arguments: ["layout", "split-bottom"])
        == "split-bottom")
    #expect(
      OperatorCommandClient.normalizedLayoutCommand(arguments: ["split-down"]) == "split-bottom")
    #expect(
      OperatorCommandClient.normalizedLayoutCommand(arguments: ["split-right"]) == "split-right")
    #expect(
      OperatorCommandClient.normalizedLayoutCommand(arguments: ["split-down", "extra"]) == nil)
  }

  @MainActor
  @Test func missionControlBuildsAndCollapsesNativeGridLayout() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
    store.addProject(name: "Grid", directory: directory.path)
    let project = try #require(store.state.projects.first)
    let controller = WorkspaceController(store: store)
    controller.launch(
      LaunchRequest(
        title: "Agent 0", command: "echo agent", directory: project.workspaces[0].directory,
        projectID: project.id, workspaceID: project.workspaces[0].id))
    for index in 1..<4 {
      let workspace = project.workspaces[0]
      controller.splitFocusedTerminal(.horizontal)
      let paneID = try #require(controller.terminalLayout?.emptyPaneIDs.first)
      controller.launch(
        LaunchRequest(
          title: "Agent \(index)", command: "echo agent", directory: workspace.directory,
          projectID: project.id, workspaceID: workspace.id), intoPane: paneID)
    }

    controller.missionControlLayout()
    let layout = try #require(controller.terminalLayout)
    guard
      case .split(
        .vertical, .split(.horizontal, let firstA, let firstB),
        .split(.horizontal, let secondA, let secondB)) = layout
    else {
      Issue.record("Expected a 2×2 Mission Control grid")
      return
    }
    let ids = [firstA, firstB, secondA, secondB].compactMap { node -> UUID? in
      if case .terminal(let id) = node { id } else { nil }
    }
    #expect(Set(ids) == Set(controller.sessions.map(\.id)))

    let closed = controller.sessions[3]
    controller.close(closed)
    #expect(!controller.terminalLayout!.contains(closed.id))
    #expect(controller.terminalLayout != nil)
  }

  @MainActor
  @Test func configurableShortcutsPersistAndNavigateAcrossProjectsAndHarnessPanes() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      UUID().uuidString)
    let firstDirectory = root.appendingPathComponent("api")
    let secondDirectory = root.appendingPathComponent("worker")
    try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let stateURL = root.appendingPathComponent("state.json")
    let store = StateStore(fileURL: stateURL)
    store.addProject(name: "API", directory: firstDirectory.path)
    store.addProject(name: "Worker", directory: secondDirectory.path)
    let projects = store.state.projects
    let api = try #require(projects.first(where: { $0.name == "API" }))
    let worker = try #require(projects.first(where: { $0.name == "Worker" }))

    store.setShortcut(.init(action: .nextPane, key: "j", command: false, option: true))
    let restored = StateStore(fileURL: stateURL)
    let nextPane = restored.shortcut(for: .nextPane)
    #expect(nextPane.key == "j")
    #expect(!nextPane.command)
    #expect(nextPane.option)

    let controller = WorkspaceController(store: restored)
    let apiWorkspace = api.workspaces[0]
    let workerWorkspace = worker.workspaces[0]
    controller.launch(
      LaunchRequest(
        title: "API agent", command: "echo api", directory: apiWorkspace.directory,
        projectID: api.id, workspaceID: apiWorkspace.id))
    controller.launch(
      LaunchRequest(
        title: "Worker agent", command: "echo worker", directory: workerWorkspace.directory,
        projectID: worker.id, workspaceID: workerWorkspace.id))

    let firstSession = try #require(controller.sessions.first)
    let secondSession = try #require(controller.sessions.last)
    controller.selectTerminal(firstSession.id)
    controller.focusAdjacentSession(1)
    #expect(controller.selectedSessionID == secondSession.id)
    controller.focusAdjacentSession(1)
    #expect(controller.selectedSessionID == firstSession.id)

    #expect(restored.state.selectedProjectID == worker.id)
    controller.selectAdjacentProject(1)
    #expect(restored.state.selectedProjectID == api.id)
    controller.selectAdjacentProject(-1)
    #expect(restored.state.selectedProjectID == worker.id)

    restored.restoreDefaultShortcuts()
    #expect(
      restored.shortcut(for: .nextPane)
        == ShortcutBinding.defaults.first(where: { $0.action == .nextPane }))
  }

  @MainActor
  @Test func missionControlKeepsEveryHarnessReachableBeyondFourPanes() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
    store.addProject(name: "Fleet", directory: directory.path)
    let project = try #require(store.state.projects.first)
    let workspace = try #require(project.workspaces.first)
    let controller = WorkspaceController(store: store)
    controller.launch(
      LaunchRequest(
        title: "Agent 0", command: "echo agent", directory: workspace.directory,
        projectID: project.id, workspaceID: workspace.id))
    for index in 1..<5 {
      controller.splitFocusedTerminal(.horizontal)
      let paneID = try #require(controller.terminalLayout?.emptyPaneIDs.first)
      controller.launch(
        LaunchRequest(
          title: "Agent \(index)", command: "echo agent", directory: workspace.directory,
          projectID: project.id, workspaceID: workspace.id), intoPane: paneID)
    }

    controller.missionControlLayout()
    let layout = try #require(controller.terminalLayout)
    #expect(controller.sessions.allSatisfy { layout.contains($0.id) })

    controller.applyLayout(command: "split-right")
    let horizontal = try #require(controller.terminalLayout)
    #expect(horizontal.emptyPaneIDs.count == 1)
    controller.applyLayout(command: "split-bottom")
    #expect(controller.terminalLayout?.emptyPaneIDs.count == 2)
    controller.applyLayout(command: "unknown")
    #expect(controller.alertMessage == "Unknown layout command: unknown.")
  }
}
