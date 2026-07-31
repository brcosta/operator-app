import Foundation
import UserNotifications

#if SWIFT_PACKAGE
  import OperatorNotificationBridge
#endif

final class SessionFileRadar {
  let currentFiles: [GitChangedFile]
  private let rootPath: String?
  private var observation: GitWorkspaceObservation?

  init(directory: String, onChange: @escaping ([GitChangedFile]) -> Void) {
    rootPath = try? GitRepository.repositoryRoot(containing: directory)
    let snapshot = rootPath.flatMap { try? GitRepository.statusSnapshot(in: $0) }
    currentFiles = Self.uniqueFiles(from: snapshot?.changes ?? [])
    guard let rootPath else { return }

    observation = GitWorkspaceMonitor.shared.observe(rootPath: rootPath) { snapshot in
      onChange(Self.uniqueFiles(from: snapshot.changes))
    }
  }

  private static func uniqueFiles(from changes: [GitChangedFile]) -> [GitChangedFile] {
    Dictionary(grouping: changes, by: \.path).values.compactMap(\.first).sorted {
      $0.path < $1.path
    }
  }
}

struct SessionFileRadarPresentation: Equatable {
  struct Section: Equatable, Identifiable {
    let kind: GitChangeSection
    let files: [GitChangedFile]

    var id: GitChangeSection { kind }
  }

  static let maximumVisibleFiles = 200

  let files: [GitChangedFile]

  var isEmpty: Bool { files.isEmpty }
  var summary: String {
    "\(files.count) changed file\(files.count == 1 ? "" : "s")"
  }
  var accessibilityLabel: String { "Show \(summary)" }

  var visibleFiles: [GitChangedFile] {
    Array(files.prefix(Self.maximumVisibleFiles))
  }

  var overflowCount: Int {
    max(0, files.count - Self.maximumVisibleFiles)
  }

  var sections: [Section] {
    GitChangeSection.allCases.compactMap { kind in
      let matches = visibleFiles.filter { $0.section == kind }
      return matches.isEmpty ? nil : Section(kind: kind, files: matches)
    }
  }
}

enum OperatorNotificationAuthorizationState: Equatable {
  case notDetermined
  case denied
  case authorized
  case provisional
  case ephemeral
  case unavailable

  var permitsNotifications: Bool {
    switch self {
    case .authorized, .provisional, .ephemeral: true
    case .notDetermined, .denied, .unavailable: false
    }
  }
}

enum OperatorNotifications {
  enum Action: String, Sendable {
    case focusQuestion = "operator.notification.focus-question"
    case openFailedHarness = "operator.notification.open-failed-harness"
    case retry = "operator.notification.retry"
  }

  private enum Category: String {
    case question = "operator.notification.question"
    case failedHarness = "operator.notification.failed-harness"
  }

  @MainActor private static var isAvailable = true
  @MainActor private static var isActivated = false

  @MainActor
  @discardableResult
  static func installDelegate(_ delegate: UNUserNotificationCenterDelegate) -> Bool {
    guard isAvailable else { return false }
    if let error = OperatorSetNotificationCategories(notificationCategories()) {
      recordFailure(error, operation: "categories")
      return false
    }
    guard let error = OperatorInstallNotificationDelegate(delegate) else { return true }
    recordFailure(error, operation: "delegate")
    return false
  }

  @MainActor
  static func activate(delegate: UNUserNotificationCenterDelegate) async -> Bool {
    guard !isActivated, installDelegate(delegate) else { return isActivated }
    let granted = await requestPermission()
    isActivated = granted
    return granted
  }

  @MainActor
  static func deactivate() {
    isActivated = false
  }

  @MainActor
  static func authorizationState() async -> OperatorNotificationAuthorizationState {
    guard isAvailable else { return .unavailable }
    return await withCheckedContinuation { continuation in
      OperatorGetNotificationAuthorizationStatus { status, error in
        Task { @MainActor in
          if let error {
            recordFailure(error, operation: "settings")
            continuation.resume(returning: .unavailable)
            return
          }
          let state: OperatorNotificationAuthorizationState =
            switch status {
            case .notDetermined: .notDetermined
            case .denied: .denied
            case .authorized: .authorized
            case .provisional: .provisional
            case .ephemeral: .ephemeral
            @unknown default: .unavailable
            }
          continuation.resume(returning: state)
        }
      }
    }
  }

  @MainActor
  private static func requestPermission() async -> Bool {
    guard isAvailable else { return false }
    return await withCheckedContinuation { continuation in
      OperatorRequestNotificationAuthorization([.alert, .sound]) { granted, error in
        Task { @MainActor in
          if let error { recordFailure(error, operation: "authorization") }
          continuation.resume(returning: granted && error == nil)
        }
      }
    }
  }

  @MainActor
  static func post(title: String, body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    submit(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
  }

  @MainActor
  static func postQuestion(sessionTitle: String, sessionID: UUID, message: String) {
    let content = questionContent(
      sessionTitle: sessionTitle, sessionID: sessionID, message: message)
    submit(
      UNNotificationRequest(
        identifier: "operator-question-\(UUID().uuidString)", content: content, trigger: nil))
  }

  @MainActor
  static func postTaskFinished(
    sessionTitle: String, sessionID: UUID, workspace: String, exitCode: Int32, failed: Bool
  ) {
    let content = taskFinishedContent(
      sessionTitle: sessionTitle, sessionID: sessionID, workspace: workspace, exitCode: exitCode,
      failed: failed)
    submit(
      UNNotificationRequest(
        identifier: "operator-finished-\(UUID().uuidString)", content: content, trigger: nil))
  }

  @MainActor
  private static func submit(_ request: UNNotificationRequest) {
    guard isAvailable, isActivated else { return }
    OperatorSubmitNotificationRequest(request) { error in
      guard let error else { return }
      Task { @MainActor in recordFailure(error, operation: "submission") }
    }
  }

  @MainActor
  private static func recordFailure(_ error: Error, operation: String) {
    let nsError = error as NSError
    if nsError.domain == OperatorNotificationBridgeErrorDomain {
      isAvailable = false
      isActivated = false
    }
    OperatorDebugLog.record(
      "notifications.unavailable", "System notifications are unavailable; Operator will continue.",
      level: .warning,
      metadata: [
        "operation": operation,
        "domain": nsError.domain,
        "code": String(nsError.code),
        "reason": nsError.localizedDescription,
      ])
  }

  static func taskFinishedContent(
    sessionTitle: String, sessionID: UUID, workspace: String, exitCode: Int32, failed: Bool
  ) -> UNMutableNotificationContent {
    let content = UNMutableNotificationContent()
    content.title =
      failed || exitCode != 0
      ? "Task needs attention: \(sessionTitle)" : "Task finished: \(sessionTitle)"
    content.body = "\(workspace) · \(failed ? "process error" : "exit code \(exitCode)")"
    content.userInfo = ["operatorSessionID": sessionID.uuidString]
    if failed || exitCode != 0 {
      content.categoryIdentifier = Category.failedHarness.rawValue
    }
    content.sound = .default
    return content
  }

  static func questionContent(sessionTitle: String, sessionID: UUID, message: String)
    -> UNMutableNotificationContent
  {
    let content = UNMutableNotificationContent()
    content.title = "Question from \(sessionTitle)"
    content.body = message
    content.userInfo = ["operatorSessionID": sessionID.uuidString]
    content.categoryIdentifier = Category.question.rawValue
    content.sound = .default
    return content
  }

  static func notificationCategories() -> Set<UNNotificationCategory> {
    let focusQuestion = UNNotificationAction(
      identifier: Action.focusQuestion.rawValue,
      title: "Focus Question",
      options: [.foreground])
    let openFailedHarness = UNNotificationAction(
      identifier: Action.openFailedHarness.rawValue,
      title: "Open Failed Harness",
      options: [.foreground])
    let retry = UNNotificationAction(
      identifier: Action.retry.rawValue,
      title: "Retry",
      options: [.foreground])
    return [
      UNNotificationCategory(
        identifier: Category.question.rawValue, actions: [focusQuestion],
        intentIdentifiers: [], options: []),
      UNNotificationCategory(
        identifier: Category.failedHarness.rawValue, actions: [openFailedHarness, retry],
        intentIdentifiers: [], options: []),
    ]
  }
}
