import Foundation
import Testing

@testable import Operator

struct GitRepositoryTests {
  @Test func gitAvailabilityRecognizesRepositoriesAndNestedWorkspaces() throws {
    let directory = try TestSupport.temporaryDirectory()
    let nested = directory.appendingPathComponent("Sources/Feature")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { TestSupport.remove(directory) }

    #expect(!GitRepository.isRepository(containing: nested.path))
    try TestSupport.initializeGitRepository(at: directory)
    #expect(GitRepository.isRepository(containing: directory.path))
    #expect(GitRepository.isRepository(containing: nested.path))
  }

  @Test func repositoryDisplayNameFindsTheEnclosingRepositoryWithoutGitProcess() throws {
    let directory = try TestSupport.temporaryDirectory()
    let nested = directory.appendingPathComponent("Sources/Feature")
    defer { TestSupport.remove(directory) }
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try TestSupport.initializeGitRepository(at: directory)

    #expect(
      GitRepository.repositoryDisplayName(containing: nested.path) == directory.lastPathComponent)
    #expect(GitRepository.repositoryDisplayName(containing: "/private/tmp/no-repository") == nil)
  }

  @Test func gitStatusSnapshotDetectsRepeatedModifiedFileEdits() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    try TestSupport.initializeGitRepository(at: directory)
    let file = directory.appendingPathComponent("notes.txt")
    try "base\n".write(to: file, atomically: true, encoding: .utf8)
    try TestSupport.runGit(["add", "notes.txt"], in: directory)
    try TestSupport.runGit(["commit", "-m", "Base"], in: directory)
    let root = try GitRepository.repositoryRoot(containing: directory.path)
    try "first edit\n".write(to: file, atomically: true, encoding: .utf8)
    let first = try GitRepository.statusSnapshot(in: root)
    try "second edit\n".write(to: file, atomically: true, encoding: .utf8)
    let second = try GitRepository.statusSnapshot(in: root)
    #expect(first.changes.map(\.id) == second.changes.map(\.id))
    #expect(first.fingerprint != second.fingerprint)
  }

  @Test func gitWorktreesHaveIndependentRootsAndStatus() throws {
    let directory = try TestSupport.temporaryDirectory()
    let worktree = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      UUID().uuidString)
    defer {
      TestSupport.remove(directory)
      TestSupport.remove(worktree)
    }
    try TestSupport.initializeGitRepository(at: directory)
    try "base\n".write(
      to: directory.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
    try TestSupport.runGit(["add", "base.txt"], in: directory)
    try TestSupport.runGit(["commit", "-m", "Base"], in: directory)
    try TestSupport.runGit(
      ["worktree", "add", "-b", "operator-worktree", worktree.path], in: directory)
    try "primary\n".write(
      to: directory.appendingPathComponent("primary.txt"), atomically: true, encoding: .utf8)
    try "secondary\n".write(
      to: worktree.appendingPathComponent("secondary.txt"), atomically: true, encoding: .utf8)
    let primaryRoot = try GitRepository.repositoryRoot(containing: directory.path)
    let worktreeRoot = try GitRepository.repositoryRoot(containing: worktree.path)
    #expect(primaryRoot != worktreeRoot)
    #expect(try GitRepository.status(in: primaryRoot).contains { $0.path == "primary.txt" })
    #expect(try GitRepository.status(in: worktreeRoot).contains { $0.path == "secondary.txt" })
  }

  @Test func gitStatusRepresentsRenameDeletionAndBothStagedAndUnstagedStates() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    try TestSupport.initializeGitRepository(at: directory)
    let renamed = directory.appendingPathComponent("before.txt")
    let deleted = directory.appendingPathComponent("deleted.txt")
    let modified = directory.appendingPathComponent("modified.txt")
    try "before\n".write(to: renamed, atomically: true, encoding: .utf8)
    try "delete\n".write(to: deleted, atomically: true, encoding: .utf8)
    try "base\n".write(to: modified, atomically: true, encoding: .utf8)
    try TestSupport.runGit(["add", "."], in: directory)
    try TestSupport.runGit(["commit", "-m", "Base"], in: directory)
    try TestSupport.runGit(["mv", "before.txt", "after.txt"], in: directory)
    try TestSupport.runGit(["rm", "deleted.txt"], in: directory)
    try "staged\n".write(to: modified, atomically: true, encoding: .utf8)
    try TestSupport.runGit(["add", "modified.txt"], in: directory)
    try "unstaged\n".write(to: modified, atomically: true, encoding: .utf8)

    let changes = try GitRepository.status(in: directory.path)
    #expect(
      changes.contains {
        $0.section == .staged && $0.path == "after.txt" && $0.originalPath == "before.txt"
      })
    #expect(
      changes.contains { $0.section == .staged && $0.path == "deleted.txt" && $0.status == "D" })
    #expect(changes.contains { $0.section == .staged && $0.path == "modified.txt" })
    #expect(changes.contains { $0.section == .unstaged && $0.path == "modified.txt" })
  }

  @Test func gitRepositoryRejectsNonRepositoryDirectory() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    #expect(throws: (any Error).self) {
      try GitRepository.repositoryRoot(containing: directory.path)
    }
  }

  @Test func readOnlyInspectionDisablesRepositoryConfiguredFsMonitorCommands() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    try TestSupport.initializeGitRepository(at: directory)
    let marker = directory.appendingPathComponent("fsmonitor-ran")
    let monitor = directory.appendingPathComponent("untrusted-fsmonitor")
    try "#!/bin/sh\n/usr/bin/touch '\(marker.path)'\n".write(
      to: monitor, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: monitor.path)
    try TestSupport.runGit(["config", "core.fsmonitor", monitor.path], in: directory)

    _ = try GitRepository.status(in: directory.path)

    #expect(!FileManager.default.fileExists(atPath: marker.path))
  }

  @Test func trackedFilesResolveToSafeImmutableGitHubLinks() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    try TestSupport.initializeGitRepository(at: directory)
    let sources = directory.appendingPathComponent("src/atlas")
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    let tracked = sources.appendingPathComponent("core file.clj")
    let untracked = sources.appendingPathComponent("scratch.clj")
    try "(ns atlas.core)\n".write(to: tracked, atomically: true, encoding: .utf8)
    try "(println :scratch)\n".write(to: untracked, atomically: true, encoding: .utf8)
    try TestSupport.runGit(["add", "src/atlas/core file.clj"], in: directory)
    try TestSupport.runGit(["commit", "-m", "Add Clojure source"], in: directory)
    try TestSupport.runGit(
      ["remote", "add", "origin", "git@github.com:brcosta/operator-app.git"], in: directory)

    let url = try #require(GitRepository.githubFileURL(for: tracked.path))
    #expect(url.host == "github.com")
    #expect(url.absoluteString.hasPrefix("https://github.com/brcosta/operator-app/blob/"))
    #expect(url.absoluteString.hasSuffix("/src/atlas/core%20file.clj"))
    #expect(GitRepository.githubFileURL(for: untracked.path) == nil)

    try TestSupport.runGit(
      ["remote", "set-url", "origin", "https://example.com/brcosta/operator-app.git"],
      in: directory)
    #expect(GitRepository.githubFileURL(for: tracked.path) == nil)
  }

}
