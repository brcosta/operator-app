import Foundation

enum GitChangeSection: String, CaseIterable, Hashable {
  case staged = "Staged"
  case unstaged = "Changes"
  case untracked = "Untracked"
}

struct GitChangedFile: Hashable, Identifiable {
  let path: String
  let originalPath: String?
  let status: String
  let section: GitChangeSection

  var id: String { "\(section.rawValue):\(path)" }
  var name: String { URL(fileURLWithPath: path).lastPathComponent }
  var directory: String { URL(fileURLWithPath: path).deletingLastPathComponent().path }
}

struct GitStatusSnapshot: Hashable {
  let changes: [GitChangedFile]
  let fingerprint: String
}

enum GitRepositoryError: LocalizedError {
  case notRepository
  case commandFailed(String)

  var errorDescription: String? {
    switch self {
    case .notRepository: "This folder is not inside a Git repository."
    case .commandFailed(let message): message
    }
  }
}

enum GitRepository {
  static let executable = "/usr/bin/git"

  static func isRepository(containing rawPath: String, fileManager: FileManager = .default) -> Bool
  {
    repositoryDirectory(containing: rawPath, fileManager: fileManager) != nil
  }

  /// Uses the filesystem only, so it is safe to call while SwiftUI renders a sidebar row.
  static func repositoryDisplayName(
    containing rawPath: String, fileManager: FileManager = .default
  ) -> String? {
    repositoryDirectory(containing: rawPath, fileManager: fileManager)?.lastPathComponent
  }

  static func repositoryRoot(containing rawPath: String) throws -> String {
    let root = try run(
      directory: workingDirectory(for: rawPath).path, arguments: ["rev-parse", "--show-toplevel"]
    )
    .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !root.isEmpty else { throw GitRepositoryError.notRepository }
    return URL(fileURLWithPath: root).resolvingSymlinksInPath().path
  }

  static func status(in root: String) throws -> [GitChangedFile] {
    let output = try run(
      directory: root, arguments: ["status", "--porcelain=v1", "-z", "--untracked-files=all"])
    let records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    var files: [GitChangedFile] = []
    var index = 0
    while index < records.count {
      let record = records[index]
      guard record.count >= 3 else {
        index += 1
        continue
      }
      let characters = Array(record)
      let x = characters[0]
      let y = characters[1]
      let path = String(record.dropFirst(3))
      let renameOrCopy = x == "R" || x == "C" || y == "R" || y == "C"
      let originalPath = renameOrCopy && index + 1 < records.count ? records[index + 1] : nil
      if x == "?" && y == "?" {
        files.append(
          GitChangedFile(path: path, originalPath: nil, status: "??", section: .untracked))
      } else {
        if x != " " {
          files.append(
            GitChangedFile(
              path: path, originalPath: originalPath, status: String(x), section: .staged))
        }
        if y != " " {
          files.append(
            GitChangedFile(
              path: path, originalPath: originalPath, status: String(y), section: .unstaged))
        }
      }
      index += renameOrCopy ? 2 : 1
    }
    return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
  }

  static func statusSnapshot(in root: String) throws -> GitStatusSnapshot {
    let changes = try status(in: root)
    let staged = try run(
      directory: root,
      arguments: ["diff", "--cached", "--no-ext-diff", "--no-color", "--no-renames"])
    let unstaged = try run(
      directory: root, arguments: ["diff", "--no-ext-diff", "--no-color", "--no-renames"])
    let untrackedMetadata = changes.filter { $0.section == .untracked }.map { change -> String in
      let url = URL(fileURLWithPath: root).appendingPathComponent(change.path)
      let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
      return
        "\(change.path):\(values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0):\(values?.fileSize ?? 0)"
    }.sorted().joined(separator: "|")
    return GitStatusSnapshot(
      changes: changes,
      fingerprint: fingerprint(
        changes: changes, staged: staged, unstaged: unstaged, untrackedMetadata: untrackedMetadata))
  }

  static func branch(containing path: String) -> String? {
    guard isRepository(containing: path), let root = try? repositoryRoot(containing: path) else {
      return nil
    }
    let branch = try? run(directory: root, arguments: ["branch", "--show-current"])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let branch else { return nil }
    return branch.isEmpty ? "Detached HEAD" : branch
  }

  private static func repositoryDirectory(containing rawPath: String, fileManager: FileManager)
    -> URL?
  {
    var candidate = workingDirectory(for: rawPath, fileManager: fileManager)
    while true {
      if fileManager.fileExists(atPath: candidate.appendingPathComponent(".git").path) {
        return candidate
      }
      guard candidate.path != "/" else { return nil }
      candidate.deleteLastPathComponent()
    }
  }

  private static func workingDirectory(for rawPath: String, fileManager: FileManager = .default)
    -> URL
  {
    var candidate = URL(fileURLWithPath: rawPath).standardizedFileURL
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    {
      candidate.deleteLastPathComponent()
    }
    return candidate
  }

  private static func fingerprint(
    changes: [GitChangedFile], staged: String, unstaged: String, untrackedMetadata: String
  ) -> String {
    var hash: UInt64 = 1_469_598_103_934_665_603
    for byte
      in (changes.map { $0.id + $0.status }.sorted().joined(separator: "|") + staged + unstaged
      + untrackedMetadata).utf8
    {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return String(hash, radix: 16)
  }

  private static func run(directory: String, arguments: [String]) throws -> String {
    guard FileManager.default.isExecutableFile(atPath: executable) else {
      throw GitRepositoryError.commandFailed("Git is unavailable at \(executable).")
    }
    let result = try BoundedProcessRunner.run(
      executable: executable,
      arguments: [
        "-c", "core.fsmonitor=false",
        "-c", "core.hooksPath=/dev/null",
        "-C", directory,
      ] + arguments,
      environment: [
        "GIT_EXTERNAL_DIFF": "/usr/bin/false", "GIT_NO_REPLACE_OBJECTS": "1",
        "GIT_OPTIONAL_LOCKS": "0", "GIT_PAGER": "/usr/bin/cat", "GIT_TERMINAL_PROMPT": "0",
        "LC_ALL": "C",
      ], timeout: 15, outputLimit: 4 * 1_048_576)
    guard !result.timedOut, result.exitCode == 0 else {
      let error =
        (result.timedOut ? "Git inspection timed out." : result.standardError)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw GitRepositoryError.commandFailed(
        error.isEmpty ? "Git could not inspect this repository." : error)
    }
    guard !result.outputWasTruncated else {
      throw GitRepositoryError.commandFailed(
        "Git inspection produced more than 4 MB of output. Narrow the repository status first.")
    }
    return result.standardOutput
  }
}
