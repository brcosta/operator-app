import Foundation
import OSLog

enum OperatorLogLevel: String, Codable, CaseIterable {
  case debug, info, warning, error
}

struct OperatorDebugEntry: Codable, Hashable, Identifiable {
  let id: UUID
  let date: Date
  let level: OperatorLogLevel
  let category: String
  let message: String
  let metadata: [String: String]
}

@MainActor
enum OperatorDebugLog {
  private static let logger = Logger(subsystem: "com.brcosta.Operator", category: "runtime")
  private static var entries: [OperatorDebugEntry] = []
  private static let maximumEntries = 500
  static let maximumFileSize = 1_048_576
  private static let rotatedFileCount = 3

  static var logFileURL: URL {
    if let override = ProcessInfo.processInfo.environment["OPERATOR_LOG_PATH"], !override.isEmpty {
      return URL(fileURLWithPath: override)
    }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Operator/Logs/operator.jsonl")
  }

  static func record(
    _ category: String, _ message: String, level: OperatorLogLevel = .debug,
    metadata: [String: String] = [:]
  ) {
    let safeCategory = String(category.prefix(100))
    let safeMessage = redact(String(message.prefix(8_000)))
    let safeMetadata = Dictionary(
      uniqueKeysWithValues: metadata.prefix(30).map { key, value in
        let sensitive = sensitiveKeyPattern.contains {
          key.localizedCaseInsensitiveContains($0)
        }
        return (
          String(key.prefix(100)),
          sensitive ? "<redacted>" : redact(String(value.prefix(2_000)))
        )
      })
    let entry = OperatorDebugEntry(
      id: UUID(), date: .now, level: level, category: safeCategory, message: safeMessage,
      metadata: safeMetadata)
    switch level {
    case .debug:
      logger.debug("[\(safeCategory, privacy: .public)] \(safeMessage, privacy: .private)")
    case .info:
      logger.info("[\(safeCategory, privacy: .public)] \(safeMessage, privacy: .private)")
    case .warning:
      logger.warning("[\(safeCategory, privacy: .public)] \(safeMessage, privacy: .private)")
    case .error:
      logger.error("[\(safeCategory, privacy: .public)] \(safeMessage, privacy: .private)")
    }
    entries.append(entry)
    if entries.count > maximumEntries { entries.removeFirst(entries.count - maximumEntries) }
    persist(entry)
  }

  static func snapshot() -> [OperatorDebugEntry] { entries }

  static func redact(_ value: String) -> String {
    var result = value.replacingOccurrences(
      of: #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#, with: "Bearer <redacted>",
      options: .regularExpression)
    result = result.replacingOccurrences(
      of:
        #"(?i)\b(token|password|passwd|passphrase|secret|api[_-]?key|authorization|credential|private[_-]?key|access[_-]?key)\b\s*[:=]\s*[^\s,;]+"#,
      with: "$1=<redacted>", options: .regularExpression)
    let providerTokenPattern =
      #"\b(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}"#
      + #"|sk-[A-Za-z0-9_-]{16,}|AKIA[0-9A-Z]{16})\b"#
    result = result.replacingOccurrences(
      of: providerTokenPattern, with: "<redacted>", options: .regularExpression)
    result = result.replacingOccurrences(
      of: #"(?s)-----BEGIN [^-]*PRIVATE KEY-----.*?-----END [^-]*PRIVATE KEY-----"#,
      with: "<redacted-private-key>", options: .regularExpression)
    result = result.replacingOccurrences(
      of: #"([A-Za-z][A-Za-z0-9+.-]*://)[^/\s:@]+:[^@\s/]+@"#,
      with: "$1<redacted>@", options: .regularExpression)
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if !home.isEmpty { result = result.replacingOccurrences(of: home, with: "~") }
    return result
  }

  private static let sensitiveKeyPattern = [
    "token", "password", "passwd", "passphrase", "secret", "authorization", "api_key", "apikey",
    "credential", "private_key", "access_key", "cookie",
  ]

  private static func persist(_ entry: OperatorDebugEntry) {
    do {
      let url = logFileURL
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
      if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
        size >= maximumFileSize
      {
        try rotate(url)
      }
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.sortedKeys]
      var data = try encoder.encode(entry)
      data.append(0x0A)
      if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
      }
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch {
      logger.error(
        "Could not persist Operator diagnostics: \(error.localizedDescription, privacy: .private)")
    }
  }

  private static func rotate(_ url: URL) throws {
    let fileManager = FileManager.default
    for index in stride(from: rotatedFileCount, through: 1, by: -1) {
      let source =
        index == 1
        ? url : url.deletingPathExtension().appendingPathExtension("\(index - 1).jsonl")
      let destination = url.deletingPathExtension().appendingPathExtension("\(index).jsonl")
      guard fileManager.fileExists(atPath: source.path) else { continue }
      if fileManager.fileExists(atPath: destination.path) {
        try fileManager.removeItem(at: destination)
      }
      try fileManager.moveItem(at: source, to: destination)
    }
  }
}
