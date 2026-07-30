import Foundation

enum TestSupport {
  static func temporaryDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  static func remove(_ directory: URL) {
    try? FileManager.default.removeItem(at: directory)
  }

  static func runGit(_ arguments: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.currentDirectoryURL = directory
    process.arguments = arguments
    let errors = Pipe()
    process.standardError = errors
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let message = String(
        decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      throw NSError(
        domain: "OperatorTests", code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: message])
    }
  }

  static func initializeGitRepository(at directory: URL) throws {
    try runGit(["init"], in: directory)
    try runGit(["config", "user.email", "operator@example.test"], in: directory)
    try runGit(["config", "user.name", "Operator Test"], in: directory)
  }
}
