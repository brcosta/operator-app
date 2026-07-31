import Foundation

/// Builds session-scoped hook configuration for supported CLI harnesses.
///
/// The generated settings are passed only to a harness launched by Operator. They never modify a
/// user's global Codex or Claude Code configuration, and each hook reports through the already
/// authenticated `operator` helper available in the terminal's PATH.
enum HarnessHookIntegration {
  @MainActor static func prepare(
    _ request: LaunchRequest, sessionID: UUID,
    preferences: OperatorIntegrationPreferences = .default,
    supportDirectory: URL = HarnessHookIntegration.defaultSupportDirectory
  ) -> LaunchRequest {
    guard request.harness != .generic, preferences.skillsEnabled || preferences.hooksEnabled else {
      return request
    }

    do {
      let directory =
        supportDirectory
        .appendingPathComponent("HarnessHooks", isDirectory: true)
        .appendingPathComponent(sessionID.uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: directory.path)
      let skillURL = preferences.skillsEnabled ? try writeOperatorSkill(in: directory) : nil

      switch request.harness {
      case .claudeCode:
        var options: [String] = []
        if preferences.hooksEnabled {
          let settingsURL = directory.appendingPathComponent("claude-settings.json")
          try claudeSettingsData().write(to: settingsURL, options: .atomic)
          try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
          options += ["--settings", shellQuoted(settingsURL.path)]
        }
        if let skillURL { options += ["--append-system-prompt-file", shellQuoted(skillURL.path)] }
        return request.addingLaunchOptions(options).recoveringFailedClaudeResume(
          launchOptions: options)
      case .codex:
        let options = codexLaunchOptions(
          instructions: preferences.skillsEnabled ? OperatorHarnessSkill.instructions : nil,
          hooksEnabled: preferences.hooksEnabled)
        return request.addingLaunchOptions(options).recoveringFailedCodexResume(
          launchOptions: options)
      case .generic:
        return request
      }
    } catch {
      OperatorDebugLog.record(
        "hooks.prepare.failed",
        "session=\(sessionID.uuidString.prefix(8)) harness=\(request.harness.rawValue) error=\(error.localizedDescription)"
      )
      return request
    }
  }

  static func event(for hookName: String, harness: HarnessKind) -> HarnessEventKind? {
    switch hookName {
    case "session-start", "tool-start": return .childStarted
    case "tool-finished", "turn-stopped": return .childFinished
    case "attention": return .question
    default: return nil
    }
  }

  static func message(for hookName: String, harness: HarnessKind) -> String {
    let name = harness == .claudeCode ? "Claude Code" : "Codex"
    switch hookName {
    case "session-start": return "\(name) session started"
    case "tool-start": return "\(name) started a tool"
    case "tool-finished": return "\(name) finished a tool"
    case "turn-stopped": return "\(name) stopped and is ready for the next instruction"
    case "attention": return "\(name) needs your attention"
    default: return "\(name) hook event"
    }
  }

  /// Hook payloads contain prompts, tool arguments, and transcript paths that Operator must not keep.
  /// Decode only the harness session identifier, validate it, and discard the rest.
  static func resumeIdentifier(fromHookPayload data: Data, harness: HarnessKind) -> String? {
    guard data.count <= maximumHookPayloadBytes else { return nil }
    switch harness {
    case .claudeCode:
      guard let payload = try? JSONDecoder().decode(ClaudeHookPayload.self, from: data),
        let rawIdentifier = payload.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
        let identifier = UUID(uuidString: rawIdentifier)
      else { return nil }
      return identifier.uuidString.lowercased()
    case .codex:
      guard let payload = try? JSONDecoder().decode(CodexHookPayload.self, from: data),
        let identifier = validatedCodexResumeIdentifier(payload.sessionID)
      else { return nil }
      return identifier
    case .generic:
      return nil
    }
  }

  static let maximumHookPayloadBytes = 64 * 1_024

  private static let defaultSupportDirectory: URL = FileManager.default.urls(
    for: .applicationSupportDirectory, in: .userDomainMask
  )[0].appendingPathComponent("Operator", isDirectory: true)

  private static func claudeSettingsData() throws -> Data {
    let hooks: [String: [[String: Any]]] = [
      "SessionStart": hookEntries("session-start"),
      "PreToolUse": hookEntries("tool-start"),
      "PostToolUse": hookEntries("tool-finished"),
      "Notification": hookEntries("attention"),
      "Stop": hookEntries("turn-stopped"),
    ]
    return try JSONSerialization.data(withJSONObject: ["hooks": hooks], options: [.prettyPrinted])
  }

  private static func writeOperatorSkill(in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent("operator-control.md")
    try OperatorHarnessSkill.instructions.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return url
  }

  private static func hookEntries(_ hookName: String) -> [[String: Any]] {
    [
      [
        "matcher": "",
        "hooks": [["type": "command", "command": "operator hook claudeCode-\(hookName)"]],
      ]
    ]
  }

  private static func codexLaunchOptions(instructions: String?, hooksEnabled: Bool) -> [String] {
    // Codex merges hooks across active config layers. Keep every session override under hooks.*
    // so user/project model, sandbox, MCP, plugin, UI, and existing hook settings remain intact.
    let events: [(String, String, String)] = [
      ("SessionStart", "startup|resume|clear", "session-start"),
      ("UserPromptSubmit", "", "tool-start"),
      ("PreToolUse", "", "tool-start"),
      ("PostToolUse", "", "tool-finished"),
      ("Stop", "", "turn-stopped"),
    ]
    let skillOptions: [String]
    if let instructions {
      let skillConfig = "developer_instructions=\"\(tomlEscaped(instructions))\""
      skillOptions = ["--config", shellQuoted(skillConfig)]
    } else {
      skillOptions = []
    }
    guard hooksEnabled else { return skillOptions }
    let hookOptions = events.flatMap { event, matcher, hookName in
      let command = "operator hook codex-\(hookName)"
      let config =
        "hooks.\(event)=[{matcher=\"\(matcher)\",hooks=[{type=\"command\",command=\""
        + tomlEscaped(command) + "\"}]}]"
      return ["--config", shellQuoted(config)]
    }
    return skillOptions + hookOptions
  }

  private static func tomlEscaped(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
  }

  private struct ClaudeHookPayload: Decodable {
    let sessionID: String?

    enum CodingKeys: String, CodingKey {
      case sessionID = "session_id"
    }
  }

  private struct CodexHookPayload: Decodable {
    let sessionID: String?

    enum CodingKeys: String, CodingKey {
      case sessionID = "session_id"
    }
  }

  private static func validatedCodexResumeIdentifier(_ value: String?) -> String? {
    guard let identifier = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      !identifier.isEmpty, identifier.utf8.count <= 128,
      identifier.range(
        of: #"^[A-Za-z0-9][A-Za-z0-9._:-]*$"#, options: .regularExpression) != nil
    else { return nil }
    if let uuid = UUID(uuidString: identifier) {
      return uuid.uuidString.lowercased()
    }
    return identifier
  }
}

enum OperatorHarnessSkill {
  static let instructions = """
    Operator control skill (session-scoped)

    You are running inside an Operator-managed terminal. The `operator` helper on PATH controls
    only this current session's workspace. Use it only when it makes the user's workspace easier
    to follow; it is optional and a failed request must not interrupt your primary task.

    Available commands:
    - `operator open <path.md>`: open a Markdown file inside the current workspace.
    - `operator layout split-right` or `operator layout split-bottom`: split the current pane.
    - `operator layout mission-control`: arrange the current project's active terminal panes.
    - `operator question <message>`: ask the user a decision through Operator.
    - `operator artifact open <path> [kind]`: surface a generated artifact in Operator.
    - `operator help`: display this command reference in the terminal.

    Paths must stay within the current workspace. Never inspect, print, forward, or override
    `OPERATOR_TOKEN`, `OPERATOR_SOCKET`, or `OPERATOR_SESSION_ID`; the helper uses them safely.
    Do not invent commands or issue raw socket requests. If Operator is unavailable, continue
    normally and report the non-blocking failure only when the user needs that UI action.
    """
}

extension LaunchRequest {
  fileprivate func addingLaunchOptions(_ options: [String]) -> LaunchRequest {
    guard let executable = command.split(separator: " ", maxSplits: 1).first else { return self }
    let remainder = command.dropFirst(executable.count)
    var result = self
    result.command = "\(executable) \(options.joined(separator: " "))\(remainder)"
    return result
  }

  /// A stale Claude identifier currently makes the managed shell exit immediately. Retry a new
  /// hooked Claude session in the same PTY so the next SessionStart event repairs persistence.
  fileprivate func recoveringFailedClaudeResume(launchOptions: [String]) -> LaunchRequest {
    guard harness == .claudeCode,
      command.range(of: #"(^|\s)(--resume|-r)(\s|$)"#, options: .regularExpression) != nil
    else { return self }

    let freshCommand = "claude \(launchOptions.joined(separator: " "))"
    let script = """
      \(command)
      operator_resume_status=$?
      if [ "$operator_resume_status" -eq 0 ]; then
        exit 0
      fi
      printf '\\nOperator could not resume that Claude session. Starting a new session instead.\\n' >&2
      \(freshCommand)
      operator_fallback_status=$?
      if [ "$operator_fallback_status" -ne 0 ]; then
        printf '\\nClaude could not start. An interactive shell has been opened so this pane remains usable.\\n' >&2
        exec /bin/zsh -l
      fi
      exit 0
      """
    var result = self
    result.command = "/bin/sh -c \(shellQuoted(script))"
    return result
  }

  /// A missing Codex thread exits the TUI before it can accept input. Retry as a fresh hooked
  /// Codex session in the same PTY so SessionStart can repair the persisted thread identifier.
  fileprivate func recoveringFailedCodexResume(launchOptions: [String]) -> LaunchRequest {
    guard harness == .codex,
      command.range(of: #"\sresume(\s|$)"#, options: .regularExpression) != nil
    else { return self }

    let freshCommand = "codex \(launchOptions.joined(separator: " "))"
    let script = """
      \(command)
      operator_resume_status=$?
      if [ "$operator_resume_status" -eq 0 ]; then
        exit 0
      fi
      printf '\\nOperator could not resume that Codex thread. Starting a new thread instead.\\n' >&2
      \(freshCommand)
      operator_fallback_status=$?
      if [ "$operator_fallback_status" -ne 0 ]; then
        printf '\\nCodex could not start. An interactive shell has been opened so this pane remains usable.\\n' >&2
        exec /bin/zsh -l
      fi
      exit 0
      """
    var result = self
    result.command = "/bin/sh -c \(shellQuoted(script))"
    return result
  }
}
