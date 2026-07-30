import Foundation

enum OperatorDiagnostics {
  @MainActor
  static func write(to url: URL, store: StateStore) throws {
    let process = ProcessInfo.processInfo
    let bundle = Bundle.main
    let payload: [String: Any] = [
      "generatedAt": ISO8601DateFormatter().string(from: .now),
      "appVersion": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "development",
      "appBuild": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        ?? "development",
      "macOSVersion": process.operatingSystemVersionString,
      "executable": OperatorDebugLog.redact(CommandLine.arguments.first ?? "unknown"),
      "schemaVersion": store.state.schemaVersion,
      "statePath": OperatorDebugLog.redact(store.stateFileURL.path),
      "stateBackupPresent": FileManager.default.fileExists(atPath: store.backupFileURL.path),
      "stateRecoveryMessage": store.recoveryMessage as Any? ?? NSNull(),
      "statePersistenceMessage": store.persistenceMessage as Any? ?? NSNull(),
      "logPath": OperatorDebugLog.redact(OperatorDebugLog.logFileURL.path),
      "logPresent": FileManager.default.fileExists(atPath: OperatorDebugLog.logFileURL.path),
      "projectCount": store.state.projects.count,
      "workspaceCount": store.state.projects.reduce(0) { $0 + $1.workspaces.count },
      "profileCount": store.state.profiles.count,
      "savedSessionCount": store.state.sessionRecipes.count,
      "recentErrors": store.state.activity.filter { $0.kind == .failed }.prefix(20).map {
        [
          "date": ISO8601DateFormatter().string(from: $0.date), "title": $0.title,
          "detail": OperatorDebugLog.redact($0.detail),
        ]
      },
      "runtimeTrace": OperatorDebugLog.snapshot().map {
        [
          "date": ISO8601DateFormatter().string(from: $0.date), "level": $0.level.rawValue,
          "category": $0.category, "message": $0.message, "metadata": $0.metadata,
        ]
      },
      "services": [
        "git": FileManager.default.isExecutableFile(atPath: GitRepository.executable)
      ],
    ]
    let data = try JSONSerialization.data(
      withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}
