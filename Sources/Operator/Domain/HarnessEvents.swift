import Foundation

enum HarnessEventKind: String, Codable, CaseIterable {
  case progress
  case question
  case childStarted
  case childFinished
  case taskFinished
  case artifact

  init?(cliValue: String) {
    let normalized = cliValue.replacingOccurrences(of: "-", with: "").lowercased()
    guard let value = Self.allCases.first(where: { $0.rawValue.lowercased() == normalized }) else {
      return nil
    }
    self = value
  }
}

enum ArtifactKind: String, Codable, CaseIterable {
  case auto, markdown, image, json, text, testReport, patch
}

struct HarnessEventEnvelope: Codable, Hashable, Identifiable {
  var version = 2
  var id: UUID = UUID()
  var sessionID: UUID
  var timestamp: Date = .now
  var kind: HarnessEventKind
  var message: String?
  var progress: Double?
  var childID: String?
  var path: String?
  var artifactKind: ArtifactKind?
  /// The harness-native session identifier reported by a lifecycle hook.
  ///
  /// This is intentionally separate from `sessionID`, which identifies Operator's terminal pane.
  /// A harness can change its own active conversation without replacing that pane.
  var resumeIdentifier: String?
}

struct ArtifactDescriptor: Codable, Hashable, Identifiable {
  var id: UUID = UUID()
  var projectID: UUID?
  var sessionID: UUID
  var path: String
  var workspaceDirectory: String
  var kind: ArtifactKind
  var createdAt: Date = .now

  var title: String { URL(fileURLWithPath: path).lastPathComponent }
}

struct InteractionRecord: Codable, Hashable, Identifiable {
  var id: UUID
  var projectID: UUID?
  var sessionID: UUID
  var date: Date
  var kind: HarnessEventKind
  var message: String
  var resolvedAt: Date?
}

final class OperatorSessionCredentials: @unchecked Sendable {
  static let shared = OperatorSessionCredentials()
  private let lock = NSLock()
  private var tokens: [UUID: String] = [:]

  func register(sessionID: UUID) -> String {
    lock.lock()
    defer { lock.unlock() }
    let token = UUID().uuidString
    tokens[sessionID] = token
    return token
  }

  func unregister(sessionID: UUID) {
    lock.lock()
    defer { lock.unlock() }
    tokens[sessionID] = nil
  }

  func validates(_ token: String, sessionID: UUID) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return tokens[sessionID] == token
  }
}
