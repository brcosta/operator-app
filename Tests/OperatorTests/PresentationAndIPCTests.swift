import Foundation
import SwiftUI
import Testing
import WebKit

@testable import Operator

#if SWIFT_PACKAGE
  import OperatorNotificationBridge
#endif

struct PresentationAndIPCTests {
  @Test func harnessInstallationFindsExecutableAndExplainsMissingCommand() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let executable = directory.appendingPathComponent("codex")
    try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: executable.path)

    #expect(
      HarnessInstallation.executableURL(
        for: .codex, environment: ["PATH": directory.path], homeDirectory: directory)
        == executable.standardizedFileURL)
    #expect(
      HarnessInstallation.executableURL(
        for: .claudeCode, environment: ["PATH": directory.path], homeDirectory: directory) == nil)
    #expect(HarnessInstallation.unavailableHelp(for: .claudeCode).contains("“claude”"))
  }

  @Test func openFileSnapshotDetectsReplacementAndDeletion() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let file = directory.appendingPathComponent("sample.clj")
    try "x".write(to: file, atomically: true, encoding: .utf8)
    let initial = OpenFileSnapshot.capture(file.path)
    #expect(initial.exists)
    #expect(initial.fileSize == 1)

    try "longer".write(to: file, atomically: true, encoding: .utf8)
    let changed = OpenFileSnapshot.capture(file.path)
    #expect(changed.exists)
    #expect(changed.fileSize == 6)
    #expect(changed != initial)

    try FileManager.default.removeItem(at: file)
    #expect(OpenFileSnapshot.capture(file.path).exists == false)
  }

  @Test func destructiveModalActionsUseHighContrastNativeLabelColor() {
    #expect(OperatorAlertActionStyle.destructiveRole == nil)
  }

  @Test func settingsAreSeparatedIntoFocusedDestinations() {
    #expect(
      OperatorSettingsSection.allCases.map(\.title)
        == ["General", "Terminal", "Privacy & Integrations", "Shortcuts", "Data & Diagnostics"])
    #expect(Set(OperatorSettingsSection.allCases.map(\.systemImage)).count == 5)
    #expect(OperatorSettingsSection.allCases.allSatisfy { !$0.subtitle.isEmpty })
  }

  @Test func markdownValidationCanonicalizesReadableMarkdown() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let markdown = directory.appendingPathComponent("notes.md")
    try "# Notes".write(to: markdown, atomically: true, encoding: .utf8)
    #expect(try MarkdownFile.validate(markdown.path) == markdown.resolvingSymlinksInPath().path)
  }

  @Test func markdownRendererSupportsGFMTableAndTaskList() {
    let html = MarkdownRenderer.documentHTML(
      for: "| Name | Done |\n| --- | --- |\n| Viewer | yes |\n\n- [x] Render")
    #expect(html.contains("<table>"))
    #expect(html.contains("checkbox"))
    #expect(html.contains("Viewer"))
  }

  @Test func markdownRendererUsesTheSelectedAppAppearancePalette() {
    let light = MarkdownRenderer.documentHTML(for: "# Light", colorScheme: .light)
    let dark = MarkdownRenderer.documentHTML(for: "# Dark", colorScheme: .dark)

    #expect(light.contains("color-scheme: light"))
    #expect(light.contains("background: #f6f8fa"))
    #expect(light.contains("color: #24292f"))
    #expect(dark.contains("color-scheme: dark"))
    #expect(dark.contains("background: #161b22"))
    #expect(dark.contains("color: #e6edf3"))
  }

  @Test func markdownWebViewReloadsWhenTheAppearanceChanges() {
    let coordinator = MarkdownWebView.Coordinator()
    let light = MarkdownPalette(colorScheme: .light)
    let dark = MarkdownPalette(colorScheme: .dark)

    #expect(coordinator.shouldReload(revision: 1, palette: light))
    coordinator.revision = 1
    coordinator.palette = light
    #expect(!coordinator.shouldReload(revision: 1, palette: light))
    #expect(coordinator.shouldReload(revision: 1, palette: dark))
  }

  @Test func markdownNavigationAllowsOnlyItsSyntheticDocumentLoad() {
    let baseURL = URL(fileURLWithPath: "/private/tmp/operator-markdown-test", isDirectory: true)

    #expect(MarkdownNavigationPolicy.allowsDocumentLoad(baseURL, baseURL: baseURL))
    #expect(
      MarkdownNavigationPolicy.allowsDocumentLoad(
        URL(string: "about:blank")!, baseURL: baseURL))
    #expect(
      !MarkdownNavigationPolicy.allowsDocumentLoad(
        baseURL.appendingPathComponent("secret.md"), baseURL: baseURL))
    #expect(
      !MarkdownNavigationPolicy.allowsDocumentLoad(
        URL(string: "https://example.com")!, baseURL: baseURL))
  }

  @MainActor
  @Test func markdownWebViewLoadsRenderedContentWithTheDarkPalette() async throws {
    let webView = WKWebView(frame: .init(x: 0, y: 0, width: 800, height: 600))
    let coordinator = MarkdownWebView.Coordinator()
    webView.navigationDelegate = coordinator
    let baseURL = URL(fileURLWithPath: "/private/tmp/operator-markdown-test", isDirectory: true)
    coordinator.load(
      html: MarkdownRenderer.documentHTML(
        for: "# Delta\n\nA simple project.", colorScheme: .dark),
      baseURL: baseURL,
      backgroundColor: MarkdownPalette(colorScheme: .dark).backgroundColor,
      in: webView)

    let bodyText = try await waitForJavaScriptString(
      "document.body && document.body.innerText", in: webView)
    let background = try await waitForJavaScriptString(
      "document.body && getComputedStyle(document.body).backgroundColor", in: webView)

    #expect(bodyText.contains("Delta"))
    #expect(bodyText.contains("A simple project."))
    #expect(background == "rgb(22, 27, 34)")
  }

  @Test func markdownRendererBlocksActiveContentAndRemoteResources() {
    let html = MarkdownRenderer.documentHTML(
      for: "<script>alert('unsafe')</script>\n\n![tracker](https://example.com/pixel.png)")

    #expect(!html.contains("<script>"))
    #expect(html.contains("default-src 'none'"))
    #expect(html.contains("img-src file: data:"))
    #expect(!html.contains("img-src https:"))
    #expect(MarkdownNavigationPolicy.allowsExternalOpen(URL(string: "https://example.com")!))
    #expect(MarkdownNavigationPolicy.allowsExternalOpen(URL(string: "mailto:test@example.com")!))
    #expect(!MarkdownNavigationPolicy.allowsExternalOpen(URL(string: "file:///etc/passwd")!))
    #expect(!MarkdownNavigationPolicy.allowsExternalOpen(URL(string: "javascript:alert(1)")!))
  }

  @Test func secureHTMLRendererDisablesActiveContentAndAppliesTheAppPalette() {
    let html = SecureHTMLRenderer.documentHTML(
      for:
        "<html><head><title>Preview</title></head><body><script>alert(1)</script><img src=\"https://example.com/pixel\"></body></html>",
      colorScheme: .dark)

    #expect(HTMLFile.isSupported(path: "/tmp/preview.html"))
    #expect(HTMLFile.isSupported(path: "/tmp/preview.HTM"))
    #expect(!HTMLFile.isSupported(path: "/tmp/preview.md"))
    #expect(html.contains("script-src 'none'"))
    #expect(html.contains("connect-src 'none'"))
    #expect(html.contains("base-uri 'none'"))
    #expect(html.contains("img-src operator-html: data:"))
    #expect(html.contains("color-scheme: dark"))
    #expect(html.contains("background: #161b22"))
  }

  @Test func secureHTMLNavigationNeverRendersExternalOrArbitraryLocalDocuments() {
    #expect(
      SecureHTMLNavigationPolicy.allowsInternalDocumentLoad(
        URL(string: "operator-html://document/view.html")!))
    #expect(
      !SecureHTMLNavigationPolicy.allowsInternalDocumentLoad(
        URL(string: "operator-html://document/private.txt")!))
    #expect(
      !SecureHTMLNavigationPolicy.allowsInternalDocumentLoad(
        URL(string: "file:///etc/passwd")!))
    #expect(
      SecureHTMLNavigationPolicy.allowsExternalOpen(
        URL(string: "https://example.com")!))
    #expect(
      !SecureHTMLNavigationPolicy.allowsExternalOpen(
        URL(string: "operator-html://document/view.html")!))
  }

  @MainActor
  private func waitForJavaScriptString(
    _ script: String,
    in webView: WKWebView
  ) async throws -> String {
    for _ in 0..<100 {
      if let value = try? await webView.evaluateJavaScript(script) as? String, !value.isEmpty {
        return value
      }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw CocoaError(.coderReadCorrupt)
  }

  @Test func workspaceFilePolicyRejectsSymlinkEscapes() throws {
    let root = try TestSupport.temporaryDirectory()
    let outside = try TestSupport.temporaryDirectory()
    defer {
      TestSupport.remove(root)
      TestSupport.remove(outside)
    }
    let outsideMarkdown = outside.appendingPathComponent("secret.md")
    try "# outside".write(to: outsideMarkdown, atomically: true, encoding: .utf8)
    let link = root.appendingPathComponent("linked.md")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideMarkdown)

    #expect(throws: WorkspaceFileAccessError.outsideWorkspace) {
      try MarkdownFile.validate(link.path, withinDirectory: root.path)
    }
  }

  @Test func projectFileTreeSkipsPrivateBuildAndSymlinkContentAndFiltersRecursively() throws {
    let root = try TestSupport.temporaryDirectory()
    let outside = try TestSupport.temporaryDirectory()
    defer {
      TestSupport.remove(root)
      TestSupport.remove(outside)
    }
    let sources = root.appendingPathComponent("Sources")
    let git = root.appendingPathComponent(".git")
    let modules = root.appendingPathComponent("node_modules")
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
    try "struct App {}".write(
      to: sources.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
    try "private".write(
      to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    try "ignored".write(
      to: modules.appendingPathComponent("package.js"), atomically: true, encoding: .utf8)
    let outsideFile = outside.appendingPathComponent("secret.swift")
    try "let secret = true".write(to: outsideFile, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("linked.swift"), withDestinationURL: outsideFile)

    let nodes = try ProjectFileTreeLoader.load(root: root.path)
    #expect(nodes.map(\.name) == ["Sources"])
    let filtered = ProjectFileTreeLoader.filtering(nodes, query: "app")
    #expect(filtered.map(\.name) == ["Sources"])
    #expect(filtered.first?.children?.map(\.name) == ["App.swift"])
    #expect(ProjectFileTreeLoader.filtering(nodes, query: "missing").isEmpty)
  }

  @Test func fileNavigatorParentNavigationUsesCanonicalReadableDirectories() throws {
    let root = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(root) }
    let child = root.appendingPathComponent("child", isDirectory: true)
    let file = root.appendingPathComponent("notes.txt")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    try "notes".write(to: file, atomically: true, encoding: .utf8)

    let canonicalChild = try FileNavigatorDirectoryPolicy.readableDirectory(child.path)
    #expect(canonicalChild.path == child.resolvingSymlinksInPath().path)
    #expect(FileNavigatorDirectoryPolicy.parent(of: child.path)?.path == root.path)
    #expect(FileNavigatorDirectoryPolicy.parent(of: "/") == nil)
    #expect(throws: FileNavigatorAccessError.self) {
      try FileNavigatorDirectoryPolicy.readableDirectory(file.path)
    }
  }

  @Test func syntaxHighlighterPreservesSourceTextAcrossAdaptivePalettes() {
    let source = "let value = 42 // answer"
    for scheme in [ColorScheme.light, .dark] {
      let highlighted = CodeSyntaxHighlighter.highlight(
        source, path: "Example.swift", colorScheme: scheme)
      #expect(String(highlighted.characters) == source)
    }
  }

  @Test func syntaxHighlighterRecognizesClojureFormsKeywordsAndComments() {
    let source = "(defn greet [name]\n  ;; friendly greeting\n  {:message \"Hello\" :count 42})"
    let highlighted = NSAttributedString(
      CodeSyntaxHighlighter.highlight(source, path: "core.clj", colorScheme: .dark))
    let defnRange = (source as NSString).range(of: "defn")
    let keywordRange = (source as NSString).range(of: ":message")
    let stringRange = (source as NSString).range(of: "\"Hello\"")
    let commentRange = (source as NSString).range(of: ";; friendly greeting")

    let defnColor = highlighted.attribute(
      .foregroundColor, at: defnRange.location, effectiveRange: nil)
    let keywordColor = highlighted.attribute(
      .foregroundColor, at: keywordRange.location, effectiveRange: nil)
    let stringColor = highlighted.attribute(
      .foregroundColor, at: stringRange.location, effectiveRange: nil)
    let commentColor = highlighted.attribute(
      .foregroundColor, at: commentRange.location, effectiveRange: nil)
    #expect(defnColor != nil)
    #expect(keywordColor != nil)
    #expect(stringColor != nil)
    #expect(commentColor != nil)
    #expect(String(highlighted.string) == source)
  }

  @Test func sourceEditorLineNumbersIncludeBlankAndTrailingLines() {
    #expect(SourceEditorPresentation.lineNumbers(for: "") == "1")
    #expect(SourceEditorPresentation.lineNumbers(for: "one") == "1")
    #expect(SourceEditorPresentation.lineNumbers(for: "one\n\ntwo\n") == "1\n2\n3\n4")
  }

  @Test func questionNotificationCarriesSessionRoutingPayload() {
    let sessionID = UUID()
    let content = OperatorNotifications.questionContent(
      sessionTitle: "Claude API", sessionID: sessionID, message: "Need a migration choice")
    #expect(content.title == "Question from Claude API")
    #expect(content.body == "Need a migration choice")
    #expect(content.userInfo["operatorSessionID"] as? String == sessionID.uuidString)
    #expect(content.categoryIdentifier == "operator.notification.question")
  }

  @Test func taskFinishedNotificationCarriesSessionRoutingPayload() {
    let sessionID = UUID()
    let content = OperatorNotifications.taskFinishedContent(
      sessionTitle: "Codex", sessionID: sessionID, workspace: "api", exitCode: 0, failed: false)
    #expect(content.title == "Task finished: Codex")
    #expect(content.body.contains("exit code 0"))
    #expect(content.userInfo["operatorSessionID"] as? String == sessionID.uuidString)
  }

  @Test func failedTaskNotificationIdentifiesFailureAndRetainsRoutingPayload() {
    let sessionID = UUID()
    let content = OperatorNotifications.taskFinishedContent(
      sessionTitle: "Codex", sessionID: sessionID, workspace: "api", exitCode: 17, failed: true)
    #expect(content.title == "Task needs attention: Codex")
    #expect(content.body.contains("process error"))
    #expect(content.userInfo["operatorSessionID"] as? String == sessionID.uuidString)
    #expect(content.categoryIdentifier == "operator.notification.failed-harness")
  }

  @Test func notificationCategoriesExposeQuestionFocusAndFailedHarnessRecoveryActions() {
    let categories = Dictionary(
      uniqueKeysWithValues:
        OperatorNotifications.notificationCategories().map { ($0.identifier, $0) })
    #expect(
      categories["operator.notification.question"]?.actions.map(\.identifier) == [
        "operator.notification.focus-question"
      ])
    #expect(
      categories["operator.notification.failed-harness"]?.actions.map(\.identifier)
        == ["operator.notification.open-failed-harness", "operator.notification.retry"])
  }

  #if SWIFT_PACKAGE
    @Test func notificationBridgeConvertsObjectiveCExceptionsIntoErrors() {
      let error = OperatorNotificationBridgeExceptionProbe()
      let nsError = error as NSError

      #expect(nsError.domain == OperatorNotificationBridgeErrorDomain)
      #expect(nsError.localizedDescription == "Objective-C exception barrier probe.")
      #expect(nsError.userInfo["exceptionName"] as? String == "OperatorNotificationBridgeProbe")
    }
  #endif

  @Test func ipcFramesHandlePartialAndMultipleMessages() throws {
    let request = OperatorOpenRequest(
      version: 1, action: "openMarkdown", path: "/tmp/notes.md", token: "token")
    let frame = try OperatorIPCFrame.encode(request)
    #expect(OperatorIPCFrame.firstMessage(in: frame.prefix(frame.count - 1)) == nil)
    let message = try #require(OperatorIPCFrame.firstMessage(in: frame + frame))
    #expect(try JSONDecoder().decode(OperatorOpenRequest.self, from: message) == request)
  }

  @Test func ipcFramesRejectOversizedRequestsBeforeAllocationOrDispatch() {
    let oversized = OperatorOpenRequest(
      version: 1, action: "openMarkdown", path: String(repeating: "x", count: 20_000),
      token: "token")

    #expect(throws: OperatorIPCError.self) {
      try OperatorIPCFrame.encode(oversized)
    }
    #expect(OperatorIPCFrame.firstMessage(in: Data(repeating: 0x61, count: 20_000)) == nil)
  }

  @MainActor
  @Test func debugLogRedactsSecretsAndUserHome() {
    let secret =
      "token=super-secret password: hunter2 Authorization: Bearer abc.def.ghi "
      + "github_pat_123456789012345678901234567890 database=https://user:pass@example.com/db"
    let value = "\(secret) \(FileManager.default.homeDirectoryForCurrentUser.path)/project"
    let redacted = OperatorDebugLog.redact(value)

    #expect(!redacted.contains("super-secret"))
    #expect(!redacted.contains("hunter2"))
    #expect(!redacted.contains("abc.def.ghi"))
    #expect(!redacted.contains("github_pat_"))
    #expect(!redacted.contains("user:pass"))
    #expect(!redacted.contains(FileManager.default.homeDirectoryForCurrentUser.path))
    #expect(redacted.contains("<redacted>"))
    #expect(redacted.contains("~/project"))
  }

  @Test func emojiCatalogSearchIsDeterministicAndDiscoverable() {
    #expect(OperatorEmojiCatalog.matching("launch").contains { $0.symbol == "🚀" })
    #expect(OperatorEmojiCatalog.matching("security").contains { $0.symbol == "🔒" })
    #expect(OperatorEmojiCatalog.matching("coding agent").contains { $0.symbol == "🤖" })
    #expect(OperatorEmojiCatalog.matching("definitely-not-an-emoji").isEmpty)
    #expect(Set(OperatorEmojiCatalog.all.map(\.id)).count == OperatorEmojiCatalog.all.count)
  }

  @Test func emojiPickerGridPreservesItsHorizontalPadding() {
    #expect(
      OperatorEmojiPickerLayout.requiredGridWidth
        <= OperatorEmojiPickerLayout.availableContentWidth)
    #expect(
      OperatorEmojiPickerLayout.availableContentWidth
        - OperatorEmojiPickerLayout.requiredGridWidth >= 12)
  }

  @Test func expandedSidebarProjectsReceiveStrongerVisualSeparation() {
    #expect(SidebarProjectGroupLayout.projectVerticalPadding >= 5)
    #expect(SidebarProjectGroupLayout.tabVerticalPadding >= 7)
    #expect(SidebarProjectGroupLayout.separatorVerticalPadding >= 10)
    #expect(SidebarProjectGroupLayout.separatorHorizontalOutset >= 8)
    #expect(
      SidebarProjectGroupLayout.separatorHorizontalOutset
        == SidebarProjectGroupLayout.contentHorizontalPadding)
    #expect(!SidebarProjectGroupLayout.separatorHitTestingEnabled)
    #expect(SidebarProjectGroupLayout.separatorAccessibilityHidden)
  }

  @Test func interfaceMotionStaysSubtleAndToastSizedForTheWorkspace() {
    #expect(OperatorMotion.quickDuration >= 0.12)
    #expect(OperatorMotion.quickDuration <= 0.2)
    #expect(OperatorMotion.standardDuration >= OperatorMotion.quickDuration)
    #expect(OperatorMotion.standardDuration <= 0.26)
    #expect(OperatorMotion.toastDuration <= 0.3)
    #expect(abs(OperatorMotion.sidebarTransitionOffset) <= 6)
    #expect(OperatorMotion.toastMaximumWidth >= 480)
    #expect(OperatorMotion.toastMaximumWidth <= 640)
    #expect(OperatorMotion.recoveryToastAutoDismissSeconds == 3)
    #expect(OperatorMotion.remainingRecoveryToastTicks(12, isHovered: true) == 12)
    #expect(OperatorMotion.remainingRecoveryToastTicks(12, isHovered: false) == 11)
    #expect(OperatorMotion.remainingRecoveryToastTicks(0, isHovered: false) == 0)
    #expect(OperatorMotion.standard(reduceMotion: false) != nil)
    #expect(OperatorMotion.standard(reduceMotion: true) == nil)
  }

  @Test func sessionFileRadarPresentationHandlesEmptyAndSingularStates() {
    let empty = SessionFileRadarPresentation(files: [])
    #expect(empty.isEmpty)
    #expect(empty.summary == "0 changed files")
    #expect(empty.sections.isEmpty)
    #expect(empty.overflowCount == 0)

    let file = GitChangedFile(
      path: "Sources/Operator/App.swift", originalPath: nil, status: " M",
      section: .unstaged)
    let singular = SessionFileRadarPresentation(files: [file])
    #expect(!singular.isEmpty)
    #expect(singular.summary == "1 changed file")
    #expect(singular.accessibilityLabel == "Show 1 changed file")
    #expect(singular.sections == [.init(kind: .unstaged, files: [file])])
  }

  @Test func sessionFileRadarPresentationGroupsFilesInStableGitOrder() {
    let unstaged = GitChangedFile(
      path: "Sources/App.swift", originalPath: nil, status: " M", section: .unstaged)
    let untracked = GitChangedFile(
      path: "Notes.md", originalPath: nil, status: "??", section: .untracked)
    let staged = GitChangedFile(
      path: "README.md", originalPath: nil, status: "M ", section: .staged)
    let presentation = SessionFileRadarPresentation(files: [unstaged, untracked, staged])

    #expect(presentation.summary == "3 changed files")
    #expect(presentation.sections.map(\.kind) == [.staged, .unstaged, .untracked])
    #expect(presentation.sections.flatMap(\.files) == [staged, unstaged, untracked])
  }

  @Test func sessionFileRadarPresentationCapsExceptionallyLargeWorktrees() {
    let files = (0..<(SessionFileRadarPresentation.maximumVisibleFiles + 17)).map { index in
      GitChangedFile(
        path: "generated/file-\(index).txt", originalPath: nil, status: "??",
        section: .untracked)
    }
    let presentation = SessionFileRadarPresentation(files: files)

    #expect(presentation.visibleFiles.count == SessionFileRadarPresentation.maximumVisibleFiles)
    #expect(presentation.sections.flatMap(\.files).count == presentation.visibleFiles.count)
    #expect(presentation.overflowCount == 17)
    #expect(presentation.summary == "\(files.count) changed files")
  }
}
