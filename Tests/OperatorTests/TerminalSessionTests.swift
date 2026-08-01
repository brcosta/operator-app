import Foundation
import Testing

@testable import Operator

@MainActor
struct TerminalSessionTests {
  @Test func terminalViewReportsOnlyNonemptyPTYOutputChunks() {
    let terminal = OperatorTerminalView(frame: .zero)
    var receivedByteCounts: [Int] = []
    terminal.onOutput = { receivedByteCounts.append($0) }

    terminal.dataReceived(slice: ArraySlice("ready\n".utf8))
    terminal.dataReceived(slice: ArraySlice<UInt8>())

    #expect(receivedByteCounts == [6])
  }

  @Test func launchEnvironmentAdvertisesOperatorTerminalCapabilities() {
    let session = TerminalSession(
      request: LaunchRequest(
        title: "Codex", command: "codex", directory: "/tmp",
        environment: ["TERM": "dumb", "COLORTERM": ""]),
      onFinish: { _, _, _ in }, onFilesChanged: { _, _ in })

    #expect(session.launchEnvironment["TERM"] == "xterm-256color")
    #expect(session.launchEnvironment["COLORTERM"] == "truecolor")
    #expect(session.launchEnvironment["TERM_PROGRAM"] == "Operator")
    #expect(session.launchEnvironment["LANG"] == "en_US.UTF-8")
    #expect(session.launchEnvironment["LC_ALL"] == "en_US.UTF-8")
  }

  @Test func interactiveLoginShellLoadsZshrcExportsBeforeLaunchingAHarness() throws {
    let dotDirectory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(dotDirectory) }
    try "export OPERATOR_ZSHRC_REGRESSION=available\n".write(
      to: dotDirectory.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = [
      TerminalSession.interactiveLoginCommandFlag,
      "printf %s \"$OPERATOR_ZSHRC_REGRESSION\"",
    ]
    process.environment = ProcessInfo.processInfo.environment.merging(
      ["ZDOTDIR": dotDirectory.path], uniquingKeysWith: { _, replacement in replacement })
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    process.waitUntilExit()

    #expect(process.terminationStatus == 0)
    #expect(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "available")
  }

  @Test func codexUsesClaudeCompatibleLegacyKeyboardHandlingOnlyInsideItsSession() {
    let codex = TerminalSession(
      request: LaunchRequest(
        title: "Codex", command: "codex", directory: "/tmp",
        environment: ["CODEX_TUI_DISABLE_KEYBOARD_ENHANCEMENT": "0"], harness: .codex),
      onFinish: { _, _, _ in }, onFilesChanged: { _, _ in })
    let claude = TerminalSession(
      request: LaunchRequest(
        title: "Claude", command: "claude", directory: "/tmp", harness: .claudeCode),
      onFinish: { _, _, _ in }, onFilesChanged: { _, _ in })

    #expect(codex.launchEnvironment["CODEX_TUI_DISABLE_KEYBOARD_ENHANCEMENT"] == "1")
    #expect(claude.launchEnvironment["CODEX_TUI_DISABLE_KEYBOARD_ENHANCEMENT"] == nil)
  }

  @Test func exitCallbackRecordsSuccessfulAndFailedTerminalOutcomesOnce() {
    var successful: (UUID, Int32, Bool)?
    let success = TerminalSession(
      request: LaunchRequest(title: "Success", command: "echo ok", directory: "/tmp"),
      onFinish: { id, code, failed in successful = (id, code, failed) }, onFilesChanged: { _, _ in }
    )
    success.didExit(code: 0)
    success.didExit(code: 7)
    #expect(success.status == .exited)
    #expect(success.exitCode == 0)
    #expect(successful?.0 == success.id)
    #expect(successful?.1 == 0)
    #expect(successful?.2 == false)

    var failed: (Int32, Bool)?
    let failure = TerminalSession(
      request: LaunchRequest(title: "Failure", command: "false", directory: "/tmp"),
      onFinish: { _, code, didFail in failed = (code, didFail) }, onFilesChanged: { _, _ in })
    failure.didExit(code: nil)
    #expect(failure.status == .failed)
    #expect(failure.exitCode == -1)
    #expect(failed?.0 == -1)
    #expect(failed?.1 == true)
  }

  @Test func nonzeroExitIsAVisibleFailure() {
    var result: (Int32, Bool)?
    let session = TerminalSession(
      request: LaunchRequest(title: "Compiler", command: "false", directory: "/tmp"),
      onFinish: { _, code, failed in result = (code, failed) }, onFilesChanged: { _, _ in })

    session.didExit(code: 7)

    #expect(session.status == .failed)
    #expect(session.exitCode == 7)
    #expect(result?.0 == 7)
    #expect(result?.1 == true)
  }
}
