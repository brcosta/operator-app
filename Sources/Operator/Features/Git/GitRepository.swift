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

  /// Returns the patch that represents a file's pending commit state.
  ///
  /// A file with both staged and unstaged edits is compared with `HEAD`, so the
  /// viewer shows everything that would be committed. Untracked files are
  /// compared against `/dev/null`.
  static func diff(for rawPath: String) throws -> String? {
    let root = try repositoryRoot(containing: rawPath)
    let safePath = try WorkspacePathPolicy.canonicalContainedPath(rawPath, within: root)
    let rootURL = URL(fileURLWithPath: root, isDirectory: true)
    let relativePath = String(
      safePath.dropFirst(rootURL.path.hasSuffix("/") ? root.count : root.count + 1))
    guard !relativePath.isEmpty else { return nil }

    let changes = try status(in: root).filter { $0.path == relativePath }
    guard !changes.isEmpty else { return nil }
    let hasUntracked = changes.contains { $0.section == .untracked }
    let hasStaged = changes.contains { $0.section == .staged }
    let hasUnstaged = changes.contains { $0.section == .unstaged }

    let arguments: [String]
    let allowedExitCodes: Set<Int32>
    if hasUntracked {
      arguments = [
        "diff", "--no-index", "--no-ext-diff", "--no-color", "--", "/dev/null", relativePath,
      ]
      // `git diff --no-index` returns 1 when differences are found.
      allowedExitCodes = [0, 1]
    } else if hasStaged && hasUnstaged {
      arguments = [
        "diff", "HEAD", "--no-ext-diff", "--no-color", "--no-renames", "--", relativePath,
      ]
      allowedExitCodes = [0]
    } else if hasStaged {
      arguments = [
        "diff", "--cached", "--no-ext-diff", "--no-color", "--no-renames", "--", relativePath,
      ]
      allowedExitCodes = [0]
    } else {
      arguments = [
        "diff", "--no-ext-diff", "--no-color", "--no-renames", "--", relativePath,
      ]
      allowedExitCodes = [0]
    }

    let result = try runResult(
      directory: root, arguments: arguments, allowedExitCodes: allowedExitCodes)
    return result.standardOutput.isEmpty ? nil : result.standardOutput
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

  /// Resolves a tracked local file to an immutable GitHub blob URL. Untracked files, repositories
  /// without a GitHub `origin`, and non-HTTP(S)/SSH GitHub remotes deliberately return `nil`.
  static func githubFileURL(for rawPath: String) -> URL? {
    guard
      let root = try? repositoryRoot(containing: rawPath),
      let file = try? WorkspacePathPolicy.canonicalContainedPath(rawPath, within: root)
    else { return nil }
    let rootURL = URL(fileURLWithPath: root, isDirectory: true)
    let relativePath = String(
      file.dropFirst(rootURL.path.hasSuffix("/") ? root.count : root.count + 1))
    guard !relativePath.isEmpty,
      (try? run(
        directory: root, arguments: ["ls-files", "--error-unmatch", "--", relativePath])) != nil,
      let remote = try? run(directory: root, arguments: ["remote", "get-url", "origin"])
        .trimmingCharacters(in: .whitespacesAndNewlines),
      let repositoryPath = githubRepositoryPath(from: remote),
      let revision = try? run(directory: root, arguments: ["rev-parse", "HEAD"])
        .trimmingCharacters(in: .whitespacesAndNewlines),
      revision.range(of: #"^[0-9a-fA-F]{40,64}$"#, options: .regularExpression) != nil
    else { return nil }

    let encodedPath = relativePath.split(separator: "/", omittingEmptySubsequences: false)
      .compactMap {
        String($0).addingPercentEncoding(withAllowedCharacters: urlPathComponentAllowed)
      }
      .joined(separator: "/")
    guard !encodedPath.isEmpty else { return nil }
    return URL(string: "https://github.com/\(repositoryPath)/blob/\(revision)/\(encodedPath)")
  }

  private static let urlPathComponentAllowed = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

  private static func githubRepositoryPath(from rawRemote: String) -> String? {
    let remote = rawRemote.trimmingCharacters(in: .whitespacesAndNewlines)
    let path: String?
    if let url = URL(string: remote), url.host?.lowercased() == "github.com" {
      path = url.path
    } else if remote.lowercased().hasPrefix("git@github.com:") {
      path = String(remote.dropFirst("git@github.com:".count))
    } else {
      path = nil
    }
    guard var path else { return nil }
    path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if path.hasSuffix(".git") { path.removeLast(4) }
    let components = path.split(separator: "/")
    guard components.count == 2,
      components.allSatisfy({
        !$0.isEmpty
          && $0.allSatisfy { $0.isLetter || $0.isNumber || "-._".contains($0) }
      })
    else { return nil }
    return components.map(String.init).joined(separator: "/")
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
    try runResult(directory: directory, arguments: arguments).standardOutput
  }

  private static func runResult(
    directory: String, arguments: [String], allowedExitCodes: Set<Int32> = [0]
  ) throws -> BoundedProcessResult {
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
    guard !result.timedOut, let exitCode = result.exitCode, allowedExitCodes.contains(exitCode) else {
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
    return result
  }
}
