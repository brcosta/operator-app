import Foundation
import Testing

@testable import Operator

struct LaunchRequestTests {
  @Test func profileEnvironmentOmitsBlankKeys() {
    let profile = LaunchProfile(
      name: "Codex", command: "codex", directory: "/tmp",
      environment: [
        EnvironmentOverride(key: "TERM", value: "xterm-256color"),
        EnvironmentOverride(key: "", value: "ignored"),
      ])
    #expect(profile.environmentDictionary == ["TERM": "xterm-256color"])
  }

  @Test func persistencePolicyDropsCredentialsAndCredentialBearingURLs() {
    let environment = [
      "SAFE_FLAG": "enabled",
      "GITHUB_TOKEN": "ghp_secret",
      "DATABASE_URL": "postgres://user:password@example.com/database",
      "SSH_AUTH_SOCK": "/private/tmp/agent.sock",
    ]

    #expect(
      EnvironmentSecurityPolicy.persistable(environment) == [
        "SAFE_FLAG": "enabled",
        "SSH_AUTH_SOCK": "/private/tmp/agent.sock",
      ])
  }

  @Test func runtimeCredentialsCannotBeOverriddenByLaunchProfiles() {
    let sessionID = UUID()
    let environment = TerminalEnvironmentBuilder.build(
      inherited: ["PATH": "/usr/bin"],
      integration: [
        "OPERATOR_SOCKET": "/private/tmp/operator.sock",
        "PATH": "/trusted/operator/bin:/usr/bin",
      ],
      requestOverrides: [
        "OPERATOR_SESSION_ID": "spoofed",
        "OPERATOR_SOCKET": "/private/tmp/attacker.sock",
        "OPERATOR_TOKEN": "spoofed",
        "PATH": "/custom/bin",
      ],
      sessionID: sessionID,
      token: "session-token")

    #expect(environment["OPERATOR_SESSION_ID"] == sessionID.uuidString)
    #expect(environment["OPERATOR_SOCKET"] == "/private/tmp/operator.sock")
    #expect(environment["OPERATOR_TOKEN"] == "session-token")
    #expect(environment["PATH"] == "/trusted/operator/bin:/custom/bin")
  }

  @Test func launchRequestRejectsEmptyCommand() {
    #expect(throws: LaunchValidationError.emptyCommand) {
      try LaunchRequest(title: "Test", command: "  ", directory: "/tmp").validate()
    }
  }

  @Test func launchRequestRejectsMissingDirectory() {
    let path = "/tmp/operator-not-a-directory"
    #expect(throws: LaunchValidationError.missingDirectory(path)) {
      try LaunchRequest(title: "Test", command: "echo hi", directory: path).validate()
    }
  }

  @Test func freshClaudeLaunchGetsOperatorManagedName() {
    let id = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
    let request = LaunchRequest(title: "Claude", command: "claude", directory: "/tmp")
      .preparedForNewSession(id: id, projectName: "API Gateway")
    #expect(request.harness == .claudeCode)
    #expect(request.managedSessionName == "operator-api-gateway-01234567")
    #expect(request.command == "claude -n 'operator-api-gateway-01234567'")
  }

  @Test func existingClaudeResumeCommandIsNotModified() {
    let request = LaunchRequest(
      title: "Claude", command: "claude --resume operator-api-123", directory: "/tmp",
      harness: .claudeCode, managedSessionName: "operator-api-123"
    )
    .preparedForNewSession(id: UUID(), projectName: "API")
    #expect(request.command == "claude --resume operator-api-123")
    #expect(request.managedSessionName == "operator-api-123")
  }

  @Test func recentClaudeResumePrefersTheLatestHarnessIdentifier() {
    let recent = RecentSession(
      id: UUID(), title: "Claude", command: "claude", directory: "/tmp", startedAt: .now,
      status: .running, harness: .claudeCode, managedSessionName: "operator-api-original",
      resumeIdentifier: "4e92e921-1454-4b5d-a62a-4c71d31b47f4")
    let request = LaunchRequest.claudeResume(
      recent: recent, workspace: Workspace(name: "API", directory: "/tmp"))

    #expect(
      request?.command
        == "claude --resume '4e92e921-1454-4b5d-a62a-4c71d31b47f4'")
    #expect(request?.resumeIdentifier == "4e92e921-1454-4b5d-a62a-4c71d31b47f4")
  }

  @Test func shellQuotingRoundTripsApostrophesWithoutExecutingThem() throws {
    let expected = "it's $(not-a-command)"
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "printf '%s' \(shellQuoted(expected))"]
    process.standardOutput = output

    try process.run()
    process.waitUntilExit()

    #expect(process.terminationStatus == 0)
    #expect(
      String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) == expected)
  }
}
