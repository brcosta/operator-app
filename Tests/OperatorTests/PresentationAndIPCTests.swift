import Foundation
import Testing

@testable import Operator

#if SWIFT_PACKAGE
  import OperatorNotificationBridge
#endif

struct PresentationAndIPCTests {
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

  @Test func questionNotificationCarriesSessionRoutingPayload() {
    let sessionID = UUID()
    let content = OperatorNotifications.questionContent(
      sessionTitle: "Claude API", sessionID: sessionID, message: "Need a migration choice")
    #expect(content.title == "Question from Claude API")
    #expect(content.body == "Need a migration choice")
    #expect(content.userInfo["operatorSessionID"] as? String == sessionID.uuidString)
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
    #expect(OperatorMotion.recoveryToastAutoDismissSeconds == 5)
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
