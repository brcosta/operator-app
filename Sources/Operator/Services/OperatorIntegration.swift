import Darwin
import Foundation

struct OperatorOpenRequest: Codable, Equatable {
  let version: Int
  let action: String
  let path: String?
  let layout: String?
  let message: String?
  let sessionID: String?
  let token: String
  let event: HarnessEventEnvelope?

  init(
    version: Int, action: String, path: String?, layout: String? = nil, message: String? = nil,
    sessionID: String? = nil, token: String, event: HarnessEventEnvelope? = nil
  ) {
    self.version = version
    self.action = action
    self.path = path
    self.layout = layout
    self.message = message
    self.sessionID = sessionID
    self.token = token
    self.event = event
  }
}

enum OperatorRuntime {
  private static let lock = NSLock()
  private static var currentEnvironment: [String: String] = [:]

  static var environment: [String: String] {
    lock.lock()
    defer { lock.unlock() }
    return currentEnvironment
  }

  static func setEnvironment(_ value: [String: String]) {
    lock.lock()
    defer { lock.unlock() }
    currentEnvironment = value
  }
}

final class OperatorIntegration {
  private let socketServer: UnixSocketServer

  init(
    executableURL: URL, supportDirectory: URL? = nil, socketDirectory: URL? = nil,
    onOpenMarkdown: @escaping (String, UUID) -> Void,
    onLayout: @escaping (String, UUID?) -> Void = { _, _ in },
    onQuestion: @escaping (UUID, String) -> Void = { _, _ in },
    onEvent: @escaping (HarnessEventEnvelope) -> Void = { _ in }
  ) throws {
    let support =
      supportDirectory
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Operator", isDirectory: true)
    let helperDirectory = support.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: helperDirectory, withIntermediateDirectories: true)
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path)
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: helperDirectory.path)

    let runtimeDirectory =
      try socketDirectory.map(OperatorRuntimeSocketDirectory.prepare)
      ?? OperatorRuntimeSocketDirectory.prepareDefault()
    let socketPath = try OperatorRuntimeSocketDirectory.makeSocketPath(in: runtimeDirectory)
    socketServer = try UnixSocketServer(
      socketPath: socketPath, onOpenMarkdown: onOpenMarkdown,
      onLayout: onLayout, onQuestion: onQuestion, onEvent: onEvent)

    let helperURL = helperDirectory.appendingPathComponent("operator")
    let script = "#!/bin/zsh\nexec \(shellQuote(executableURL.path)) \"$@\"\n"
    try script.write(to: helperURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperURL.path)

    let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
    OperatorRuntime.setEnvironment([
      "OPERATOR_SOCKET": socketPath,
      "PATH": "\(helperDirectory.path):\(inheritedPath)",
    ])
  }
}

enum OperatorRuntimeSocketDirectory {
  static let maximumSocketPathLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

  static func prepareDefault() throws -> URL {
    try prepare(
      URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("operator-\(geteuid())", isDirectory: true))
  }

  static func prepare(_ directory: URL) throws -> URL {
    let path = directory.standardizedFileURL.path
    var metadata = stat()

    if lstat(path, &metadata) != 0 {
      guard errno == ENOENT else {
        throw OperatorIPCError.socket("Could not inspect Operator's runtime directory.")
      }
      guard mkdir(path, mode_t(S_IRWXU)) == 0 || errno == EEXIST else {
        throw OperatorIPCError.socket("Could not create Operator's runtime directory.")
      }
      guard lstat(path, &metadata) == 0 else {
        throw OperatorIPCError.socket("Could not verify Operator's runtime directory.")
      }
    }

    guard metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_uid == geteuid(),
      metadata.st_mode & 0o077 == 0
    else {
      throw OperatorIPCError.socket(
        "Operator's runtime directory is not a private directory owned by this user.")
    }
    return URL(fileURLWithPath: path, isDirectory: true)
  }

  static func makeSocketPath(in directory: URL) throws -> String {
    let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let path = directory.appendingPathComponent("o-\(nonce).sock").path
    guard path.utf8.count <= maximumSocketPathLength else {
      throw OperatorIPCError.socket("Operator socket path is too long.")
    }
    return path
  }
}

enum OperatorCommandClient {
  static func help(arguments: [String]) -> Int32 {
    guard arguments.count == 1, ["help", "--help", "-h"].contains(arguments[0]) else {
      writeError("Usage: operator help\n")
      return 64
    }
    writeOutput(OperatorHarnessSkill.instructions + "\n")
    return 0
  }

  static func open(arguments: [String]) -> Int32 {
    guard arguments.count == 2, arguments[0] == "open" else {
      writeError("Usage: operator open <markdown-path>\n")
      return 64
    }
    return send(
      action: "openMarkdown", path: absolutePath(arguments[1]),
      sessionID: ProcessInfo.processInfo.environment["OPERATOR_SESSION_ID"])
  }

  static func layout(arguments: [String]) -> Int32 {
    guard let command = normalizedLayoutCommand(arguments: arguments) else {
      writeError(
        "Usage: operator layout <mission-control|split-right|split-bottom> (or operator split-down)\n"
      )
      return 64
    }
    return send(
      action: "layout", path: nil, layout: command,
      sessionID: ProcessInfo.processInfo.environment["OPERATOR_SESSION_ID"])
  }

  static func normalizedLayoutCommand(arguments: [String]) -> String? {
    let rawCommand: String
    if arguments.count == 2, arguments[0] == "layout" {
      rawCommand = arguments[1]
    } else if arguments.count == 1 {
      rawCommand = arguments[0]
    } else {
      return nil
    }
    switch rawCommand {
    case "mission-control", "split-right", "split-bottom": return rawCommand
    case "split-down": return "split-bottom"
    default: return nil
    }
  }

  static func question(arguments: [String]) -> Int32 {
    guard arguments.count >= 2, arguments[0] == "question",
      let sessionID = ProcessInfo.processInfo.environment["OPERATOR_SESSION_ID"]
    else {
      writeError("Usage: operator question <message>\n")
      return 64
    }
    return send(
      action: "question", path: nil, message: arguments.dropFirst().joined(separator: " "),
      sessionID: sessionID)
  }

  static func event(arguments: [String]) -> Int32 {
    guard arguments.count >= 3, arguments[0] == "event",
      let kind = HarnessEventKind(cliValue: arguments[1]),
      let rawID = ProcessInfo.processInfo.environment["OPERATOR_SESSION_ID"],
      let sessionID = UUID(uuidString: rawID)
    else {
      writeError(
        "Usage: operator event <progress|child-started|child-finished|task-finished> <message>\n")
      return 64
    }
    let message = arguments.dropFirst(2).joined(separator: " ")
    return sendEvent(HarnessEventEnvelope(sessionID: sessionID, kind: kind, message: message))
  }

  /// Receives a lifecycle callback from a session-scoped Codex or Claude Code hook.
  /// Only the harness's session identifier is decoded from the bounded input. Sensitive tool
  /// arguments, prompts, and transcript paths are neither forwarded nor persisted.
  static func hook(arguments: [String]) -> Int32 {
    guard arguments.count == 2, arguments[0] == "hook",
      let separator = arguments[1].firstIndex(of: "-"),
      let harness = HarnessKind(rawValue: String(arguments[1][..<separator])),
      let kind = HarnessHookIntegration.event(
        for: String(arguments[1][arguments[1].index(after: separator)...]), harness: harness),
      let rawID = ProcessInfo.processInfo.environment["OPERATOR_SESSION_ID"],
      let sessionID = UUID(uuidString: rawID)
    else {
      writeError("Usage: operator hook <codex|claudeCode>-<event>\n")
      return 64
    }

    let hookName = String(arguments[1][arguments[1].index(after: separator)...])
    let message = HarnessHookIntegration.message(for: hookName, harness: harness)
    let resumeIdentifier = readHookPayload().flatMap {
      HarnessHookIntegration.resumeIdentifier(fromHookPayload: $0, harness: harness)
    }
    return sendEvent(
      HarnessEventEnvelope(
        sessionID: sessionID, kind: kind, message: message,
        resumeIdentifier: resumeIdentifier))
  }

  static func artifact(arguments: [String]) -> Int32 {
    guard arguments.count >= 3, arguments[0] == "artifact", arguments[1] == "open",
      let rawID = ProcessInfo.processInfo.environment["OPERATOR_SESSION_ID"],
      let sessionID = UUID(uuidString: rawID)
    else {
      writeError("Usage: operator artifact open <path> [kind]\n")
      return 64
    }
    let kind = arguments.count > 3 ? ArtifactKind(rawValue: arguments[3]) ?? .auto : .auto
    return sendEvent(
      HarnessEventEnvelope(
        sessionID: sessionID, kind: .artifact, path: absolutePath(arguments[2]), artifactKind: kind)
    )
  }

  private static func sendEvent(_ event: HarnessEventEnvelope) -> Int32 {
    guard let socketPath = ProcessInfo.processInfo.environment["OPERATOR_SOCKET"],
      let token = ProcessInfo.processInfo.environment["OPERATOR_TOKEN"]
    else { return 69 }
    do {
      let request = OperatorOpenRequest(
        version: 2, action: "event", path: nil, token: token, event: event)
      let response = try UnixSocketClient.send(request: request, socketPath: socketPath)
      return response == "OK" ? 0 : 69
    } catch {
      writeError("operator: \(error.localizedDescription)\n")
      return 69
    }
  }

  private static func send(
    action: String, path: String?, layout: String? = nil, message: String? = nil,
    sessionID: String? = nil
  ) -> Int32 {
    guard let socketPath = ProcessInfo.processInfo.environment["OPERATOR_SOCKET"],
      let token = ProcessInfo.processInfo.environment["OPERATOR_TOKEN"]
    else {
      writeError("Operator is not available in this terminal session.\n")
      return 69
    }
    let request = OperatorOpenRequest(
      version: 1, action: action, path: path, layout: layout, message: message,
      sessionID: sessionID, token: token)

    do {
      let response = try UnixSocketClient.send(request: request, socketPath: socketPath)
      guard response == "OK" else { throw OperatorIPCError.server(response) }
      return 0
    } catch {
      writeError("operator: \(error.localizedDescription)\n")
      return 69
    }
  }

  private static func absolutePath(_ rawPath: String) -> String {
    URL(
      fileURLWithPath: rawPath,
      relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    ).standardizedFileURL.path
  }

  private static func readHookPayload() -> Data? {
    guard isatty(STDIN_FILENO) == 0 else { return nil }
    let limit = HarnessHookIntegration.maximumHookPayloadBytes
    var payload = Data()
    do {
      while payload.count <= limit {
        let remaining = limit + 1 - payload.count
        let chunk = try FileHandle.standardInput.read(upToCount: min(8_192, remaining)) ?? Data()
        if chunk.isEmpty { break }
        payload.append(chunk)
      }
      return payload.count <= limit ? payload : nil
    } catch {
      return nil
    }
  }

  private static func writeError(_ text: String) {
    if let data = text.data(using: .utf8) { FileHandle.standardError.write(data) }
  }

  private static func writeOutput(_ text: String) {
    if let data = text.data(using: .utf8) { FileHandle.standardOutput.write(data) }
  }
}

enum OperatorIPCError: LocalizedError {
  case invalidRequest
  case server(String)
  case socket(String)

  var errorDescription: String? {
    switch self {
    case .invalidRequest: "Could not encode the request."
    case .server(let message), .socket(let message): message
    }
  }
}

enum OperatorIPCFrame {
  static let maximumSize = 16 * 1024

  static func encode(_ request: OperatorOpenRequest) throws -> Data {
    var data = try JSONEncoder().encode(request)
    data.append(0x0A)
    guard data.count <= maximumSize else {
      throw OperatorIPCError.socket("Operator request exceeds the 16 KB protocol limit.")
    }
    return data
  }

  static func firstMessage(in data: Data) -> Data? {
    guard data.count <= maximumSize, let end = data.firstIndex(of: 0x0A) else { return nil }
    return data.prefix(upTo: end)
  }
}

private final class UnixSocketServer {
  private let descriptor: Int32
  private let source: DispatchSourceRead
  private let socketPath: String
  private let onOpenMarkdown: (String, UUID) -> Void
  private let onLayout: (String, UUID?) -> Void
  private let onQuestion: (UUID, String) -> Void
  private let onEvent: (HarnessEventEnvelope) -> Void
  private let connectionQueue = DispatchQueue(
    label: "local.operator.ipc.connections", qos: .userInitiated, attributes: .concurrent)

  init(
    socketPath: String, onOpenMarkdown: @escaping (String, UUID) -> Void,
    onLayout: @escaping (String, UUID?) -> Void,
    onQuestion: @escaping (UUID, String) -> Void, onEvent: @escaping (HarnessEventEnvelope) -> Void
  ) throws {
    self.socketPath = socketPath
    self.onOpenMarkdown = onOpenMarkdown
    self.onLayout = onLayout
    self.onQuestion = onQuestion
    self.onEvent = onEvent
    unlink(socketPath)
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      throw OperatorIPCError.socket("Could not create Operator socket.")
    }
    do {
      try withUnixAddress(socketPath) { address, length in
        guard bind(descriptor, address, length) == 0 else {
          throw OperatorIPCError.socket("Could not bind Operator socket.")
        }
      }
      guard listen(descriptor, 8) == 0 else {
        throw OperatorIPCError.socket("Could not listen on Operator socket.")
      }
      guard chmod(socketPath, S_IRUSR | S_IWUSR) == 0 else {
        throw OperatorIPCError.socket("Could not secure Operator socket permissions.")
      }
    } catch {
      close(descriptor)
      throw error
    }
    self.descriptor = descriptor
    source = DispatchSource.makeReadSource(
      fileDescriptor: descriptor, queue: DispatchQueue.global(qos: .userInitiated))
    source.setEventHandler { [weak self] in self?.acceptRequest() }
    source.setCancelHandler { [descriptor, socketPath] in
      close(descriptor)
      unlink(socketPath)
    }
    source.resume()
  }

  deinit { source.cancel() }

  private func acceptRequest() {
    let client = accept(descriptor, nil, nil)
    guard client >= 0 else { return }
    connectionQueue.async { [weak self] in
      guard let self else {
        close(client)
        return
      }
      self.handleRequest(client)
    }
  }

  private func handleRequest(_ client: Int32) {
    defer { close(client) }
    configureSocket(client)
    guard let data = readFrame(from: client) else { return }
    let response: String
    do {
      let request = try JSONDecoder().decode(OperatorOpenRequest.self, from: data)
      let sessionID = request.event?.sessionID ?? request.sessionID.flatMap(UUID.init(uuidString:))
      guard let sessionID,
        [1, 2].contains(request.version),
        OperatorSessionCredentials.shared.validates(request.token, sessionID: sessionID)
      else {
        throw OperatorIPCError.server("Request rejected.")
      }
      guard
        (request.action == "event" && request.version == 2)
          || (request.action != "event" && request.version == 1)
      else {
        throw OperatorIPCError.server("Unsupported protocol version.")
      }
      switch request.action {
      case "openMarkdown":
        guard let requestedPath = request.path, requestedPath.count <= 4_096 else {
          throw OperatorIPCError.invalidRequest
        }
        let path = try MarkdownFile.validate(requestedPath)
        onOpenMarkdown(path, sessionID)
      case "layout":
        guard let layout = request.layout,
          ["mission-control", "split-right", "split-bottom"].contains(layout)
        else { throw OperatorIPCError.invalidRequest }
        onLayout(layout, sessionID)
      case "question":
        guard let message = request.message?.trimmingCharacters(in: .whitespacesAndNewlines),
          !message.isEmpty, message.count <= 4_000
        else { throw OperatorIPCError.invalidRequest }
        onQuestion(sessionID, message)
      case "event":
        guard request.version == 2, let event = request.event, event.version == 2,
          OperatorSessionCredentials.shared.validates(request.token, sessionID: event.sessionID),
          (event.message?.count ?? 0) <= 4_000, (event.path?.count ?? 0) <= 4_096,
          (event.childID?.count ?? 0) <= 256, (event.resumeIdentifier?.count ?? 0) <= 256,
          event.resumeIdentifier?.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
          }) != true,
          event.progress?.isFinite != false
        else { throw OperatorIPCError.invalidRequest }
        onEvent(event)
      default:
        throw OperatorIPCError.server("Request rejected.")
      }
      response = "OK"
    } catch {
      response = "ERROR \(error.localizedDescription)"
    }
    _ = try? sendAll(Data(response.utf8), to: client)
  }

  private func readFrame(from client: Int32) -> Data? {
    var received = Data()
    var bytes = [UInt8](repeating: 0, count: 1024)
    while received.count <= OperatorIPCFrame.maximumSize {
      let count = recv(client, &bytes, bytes.count, 0)
      guard count > 0 else { return nil }
      received.append(bytes, count: Int(count))
      if let message = OperatorIPCFrame.firstMessage(in: received) { return message }
    }
    return nil
  }
}

enum UnixSocketClient {
  static func send(request: OperatorOpenRequest, socketPath: String) throws -> String {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw OperatorIPCError.socket("Could not connect to Operator.") }
    defer { close(descriptor) }
    configureSocket(descriptor)
    try withUnixAddress(socketPath) { address, length in
      guard connect(descriptor, address, length) == 0 else {
        throw OperatorIPCError.socket("Operator is not running.")
      }
    }
    let data = try OperatorIPCFrame.encode(request)
    try sendAll(data, to: descriptor)
    var bytes = [UInt8](repeating: 0, count: 1024)
    let count = recv(descriptor, &bytes, bytes.count, 0)
    guard count > 0 else {
      throw OperatorIPCError.socket(
        errno == EAGAIN || errno == EWOULDBLOCK
          ? "Operator did not answer within 2 seconds." : "Operator did not answer.")
    }
    return String(decoding: bytes.prefix(Int(count)), as: UTF8.self)
  }
}

private func configureSocket(_ descriptor: Int32) {
  var timeout = timeval(tv_sec: 2, tv_usec: 0)
  var noSignal: Int32 = 1
  _ = setsockopt(
    descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
  _ = setsockopt(
    descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
  _ = setsockopt(
    descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
}

private func sendAll(_ data: Data, to descriptor: Int32) throws {
  var offset = 0
  while offset < data.count {
    let sent = data.withUnsafeBytes { buffer -> Int in
      guard let baseAddress = buffer.baseAddress else { return -1 }
      return Darwin.send(descriptor, baseAddress.advanced(by: offset), data.count - offset, 0)
    }
    if sent > 0 {
      offset += sent
      continue
    }
    if sent < 0 && errno == EINTR { continue }
    throw OperatorIPCError.socket(
      errno == EAGAIN || errno == EWOULDBLOCK
        ? "Operator socket write timed out." : "Could not send request to Operator.")
  }
}

private func withUnixAddress<T>(
  _ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
) throws -> T {
  guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
    throw OperatorIPCError.socket("Operator socket path is too long.")
  }
  var address = sockaddr_un()
  address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  address.sun_family = sa_family_t(AF_UNIX)
  let bytes = Array(path.utf8) + [0]
  withUnsafeMutableBytes(of: &address.sun_path) { destination in
    bytes.withUnsafeBytes { source in destination.copyBytes(from: source) }
  }
  return try withUnsafePointer(to: &address) { pointer in
    try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
}

private func shellQuote(_ value: String) -> String {
  "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
}
