import Foundation
import Testing

@testable import Operator

@MainActor
struct HarnessHookIntegrationTests {
  @Test func harnessSkillsAndHooksCanBeOptedOutIndependently() throws {
    let root = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(root) }
    let request = LaunchRequest(
      title: "Codex", command: "codex", directory: root.path, harness: .codex)

    let noIntegrations = HarnessHookIntegration.prepare(
      request, sessionID: UUID(),
      preferences: OperatorIntegrationPreferences(
        skillsEnabled: false, hooksEnabled: false, notificationsPermitted: true,
        fileWatchingEnabled: true),
      supportDirectory: root)
    #expect(noIntegrations.command == "codex")

    let skillOnly = HarnessHookIntegration.prepare(
      request, sessionID: UUID(),
      preferences: OperatorIntegrationPreferences(
        skillsEnabled: true, hooksEnabled: false, notificationsPermitted: true,
        fileWatchingEnabled: true),
      supportDirectory: root)
    #expect(skillOnly.command.contains("developer_instructions"))
    #expect(!skillOnly.command.contains("hooks.SessionStart"))
  }

  @Test func claudeUsesSessionScopedSettingsWithLifecycleHooks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    let request = LaunchRequest(
      title: "Claude", command: "claude -n operator-test", directory: "/tmp", harness: .claudeCode)

    let prepared = HarnessHookIntegration.prepare(
      request, sessionID: sessionID, supportDirectory: root)

    #expect(prepared.command.contains("claude --settings"))
    #expect(prepared.command.contains("-n operator-test"))
    let settings = root.appendingPathComponent(
      "HarnessHooks/\(sessionID.uuidString)/claude-settings.json")
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
    let hooks = json?["hooks"] as? [String: Any]
    #expect(hooks?["SessionStart"] != nil)
    #expect(hooks?["PreToolUse"] != nil)
    #expect(hooks?["Stop"] != nil)
    let skill = root.appendingPathComponent(
      "HarnessHooks/\(sessionID.uuidString)/operator-control.md")
    let instructions = try String(contentsOf: skill, encoding: .utf8)
    #expect(instructions == OperatorHarnessSkill.instructions)
    #expect(prepared.command.contains("--append-system-prompt-file"))
    #expect(prepared.command.contains(skill.path))
  }

  @Test func claudeHookPayloadRelaysOnlyItsValidatedSessionIdentifier() throws {
    let identifier = "4E92E921-1454-4B5D-A62A-4C71D31B47F4"
    let payload = try #require(
      """
      {
        "session_id": "\(identifier)",
        "prompt": "private user text",
        "tool_input": {"command": "cat ~/.ssh/id_ed25519"}
      }
      """.data(using: .utf8))

    #expect(
      HarnessHookIntegration.resumeIdentifier(fromHookPayload: payload, harness: .claudeCode)
        == identifier.lowercased())
    #expect(
      HarnessHookIntegration.resumeIdentifier(fromHookPayload: payload, harness: .generic) == nil)
  }

  @Test func codexHookPayloadRelaysOnlyItsValidatedThreadIdentifier() throws {
    let identifier = "0199a213-81c0-7800-8aa1-bbab2a035a53"
    let payload = try #require(
      """
      {
        "session_id": "\(identifier.uppercased())",
        "prompt": "private user text",
        "tool_input": {"command": "cat ~/.ssh/id_ed25519"},
        "transcript_path": "/private/transcript.jsonl"
      }
      """.data(using: .utf8))

    #expect(
      HarnessHookIntegration.resumeIdentifier(fromHookPayload: payload, harness: .codex)
        == identifier)
  }

  @Test func codexHookPayloadAcceptsOpaqueDocumentedIdentifiersButRejectsUnsafeValues() throws {
    let documented = try #require(#"{"session_id":"thr_123"}"#.data(using: .utf8))
    let shellSyntax = try #require(#"{"session_id":"thread;open /tmp/bad"}"#.data(using: .utf8))
    let path = try #require(#"{"session_id":"../../thread"}"#.data(using: .utf8))
    let tooLongJSON =
      #"{"session_id":""# + String(repeating: "a", count: 129) + #""}"#
    let tooLong = try #require(tooLongJSON.data(using: .utf8))

    #expect(
      HarnessHookIntegration.resumeIdentifier(fromHookPayload: documented, harness: .codex)
        == "thr_123")
    #expect(
      HarnessHookIntegration.resumeIdentifier(fromHookPayload: shellSyntax, harness: .codex) == nil)
    #expect(HarnessHookIntegration.resumeIdentifier(fromHookPayload: path, harness: .codex) == nil)
    #expect(
      HarnessHookIntegration.resumeIdentifier(fromHookPayload: tooLong, harness: .codex) == nil)
  }

  @Test func malformedOrOversizedHookPayloadCannotBecomeAResumeIdentifier() throws {
    let malformed = try #require(#"{"session_id":"../../bad\nvalue"}"#.data(using: .utf8))
    let oversized = Data(
      repeating: 0x61, count: HarnessHookIntegration.maximumHookPayloadBytes + 1)

    #expect(
      HarnessHookIntegration.resumeIdentifier(fromHookPayload: malformed, harness: .claudeCode)
        == nil)
    #expect(
      HarnessHookIntegration.resumeIdentifier(fromHookPayload: oversized, harness: .claudeCode)
        == nil)
  }

  @Test func failedClaudeResumeFallsBackToAFreshHookedSessionInTheSamePane() throws {
    let root = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(root) }
    let request = LaunchRequest(
      title: "Claude", command: "claude --resume 'missing-session'", directory: "/tmp",
      harness: .claudeCode, resumeIdentifier: "missing-session")

    let prepared = HarnessHookIntegration.prepare(
      request, sessionID: UUID(), supportDirectory: root)

    #expect(prepared.command.hasPrefix("/bin/sh -c "))
    #expect(prepared.command.contains("Operator could not resume that Claude session"))
    #expect(prepared.command.contains("interactive shell has been opened"))
    #expect(prepared.command.components(separatedBy: "--settings").count == 3)
    #expect(prepared.command.contains("--resume"))
  }

  @Test func recoveryCommandActuallyRetriesClaudeWithoutTheStaleIdentifier() throws {
    let root = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(root) }
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let log = root.appendingPathComponent("claude-invocations.log")
    let executable = bin.appendingPathComponent("claude")
    try """
    #!/bin/sh
    printf '%s\\n' "$*" >> "$OPERATOR_TEST_LOG"
    case " $* " in
      *" --resume "*) exit 42 ;;
      *) exit 0 ;;
    esac
    """.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let request = LaunchRequest(
      title: "Claude", command: "claude --resume 'missing-session'", directory: "/tmp",
      harness: .claudeCode, resumeIdentifier: "missing-session")
    let prepared = HarnessHookIntegration.prepare(
      request, sessionID: UUID(), supportDirectory: root)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", prepared.command]
    process.environment = [
      "PATH": "\(bin.path):/usr/bin:/bin",
      "OPERATOR_TEST_LOG": log.path,
    ]

    try process.run()
    process.waitUntilExit()

    #expect(process.terminationStatus == 0)
    let invocations = try String(contentsOf: log, encoding: .utf8)
      .split(separator: "\n").map(String.init)
    try #require(invocations.count == 2)
    #expect(invocations[0].contains("--resume missing-session"))
    #expect(!invocations[1].contains("--resume"))
    #expect(invocations.allSatisfy { $0.contains("--settings") })
  }

  @Test func codexLaunchCarriesOnlySessionScopedHookOverrides() {
    let request = LaunchRequest(
      title: "Codex", command: "codex --model user-choice", directory: "/tmp", harness: .codex)

    let prepared = HarnessHookIntegration.prepare(
      request, sessionID: UUID(), supportDirectory: FileManager.default.temporaryDirectory)

    #expect(prepared.command.hasPrefix("codex --config"))
    #expect(prepared.command.contains("hooks.SessionStart"))
    #expect(prepared.command.contains("startup|resume|clear"))
    #expect(!prepared.command.contains("startup|resume|clear|compact"))
    #expect(prepared.command.contains("hooks.PreToolUse"))
    #expect(prepared.command.contains("hooks.Stop"))
    #expect(prepared.command.contains("developer_instructions="))
    #expect(prepared.command.contains("Operator control skill"))
    #expect(prepared.command.hasSuffix("--model user-choice"))
    #expect(!prepared.command.contains("model="))
  }

  @Test func operatorControlSkillDocumentsOnlySupportedSessionCommands() {
    let instructions = OperatorHarnessSkill.instructions
    #expect(instructions.contains("operator open <path.md>"))
    #expect(instructions.contains("operator layout split-right"))
    #expect(instructions.contains("operator question <message>"))
    #expect(instructions.contains("operator artifact open <path> [kind]"))
    #expect(instructions.contains("operator help"))
    #expect(!instructions.contains("operator rename"))
  }

  @Test func failedCodexResumeFallsBackToAFreshHookedThreadInTheSamePane() throws {
    let root = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(root) }
    let request = LaunchRequest(
      title: "Codex", command: "codex resume 'missing-thread'", directory: "/tmp",
      harness: .codex, resumeIdentifier: "missing-thread")

    let prepared = HarnessHookIntegration.prepare(
      request, sessionID: UUID(), supportDirectory: root)

    #expect(prepared.command.hasPrefix("/bin/sh -c "))
    #expect(prepared.command.contains("Operator could not resume that Codex thread"))
    #expect(prepared.command.contains("interactive shell has been opened"))
    #expect(prepared.command.components(separatedBy: "hooks.SessionStart").count == 3)
    #expect(prepared.command.contains("resume"))
  }

  @Test func recoveryCommandActuallyRetriesCodexWithoutTheStaleIdentifier() throws {
    let root = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(root) }
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let log = root.appendingPathComponent("codex-invocations.log")
    let executable = bin.appendingPathComponent("codex")
    try """
    #!/bin/sh
    printf '%s\\n' "$*" >> "$OPERATOR_TEST_LOG"
    case " $* " in
      *" resume "*) exit 42 ;;
      *) exit 0 ;;
    esac
    """.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let request = LaunchRequest(
      title: "Codex", command: "codex resume 'missing-thread'", directory: "/tmp",
      harness: .codex, resumeIdentifier: "missing-thread")
    let prepared = HarnessHookIntegration.prepare(
      request, sessionID: UUID(), supportDirectory: root)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", prepared.command]
    process.environment = [
      "PATH": "\(bin.path):/usr/bin:/bin",
      "OPERATOR_TEST_LOG": log.path,
    ]

    try process.run()
    process.waitUntilExit()

    #expect(process.terminationStatus == 0)
    let invocations = try String(contentsOf: log, encoding: .utf8)
      .split(separator: "\n").map(String.init)
    try #require(invocations.count == 2)
    #expect(invocations[0].contains("resume missing-thread"))
    #expect(!invocations[1].contains(" resume "))
    #expect(invocations.allSatisfy { $0.contains("hooks.SessionStart") })
  }

  @Test func hooksMapToSafeOperatorLifecycleEvents() {
    #expect(HarnessHookIntegration.event(for: "session-start", harness: .codex) == .childStarted)
    #expect(
      HarnessHookIntegration.event(for: "tool-finished", harness: .claudeCode) == .childFinished)
    #expect(HarnessHookIntegration.event(for: "attention", harness: .codex) == .question)
    #expect(HarnessHookIntegration.event(for: "unknown", harness: .codex) == nil)
  }
}
