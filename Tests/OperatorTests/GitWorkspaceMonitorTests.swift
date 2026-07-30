import Foundation
import Testing

@testable import Operator

struct GitWorkspaceMonitorTests {
  @Test func sharedMonitorNotifiesAllObserversWhenRepositoryFingerprintChanges() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    try TestSupport.initializeGitRepository(at: directory)
    let file = directory.appendingPathComponent("tracked.txt")
    try "base\n".write(to: file, atomically: true, encoding: .utf8)
    try TestSupport.runGit(["add", "tracked.txt"], in: directory)
    try TestSupport.runGit(["commit", "-m", "Base"], in: directory)

    let first = DispatchSemaphore(value: 0)
    let second = DispatchSemaphore(value: 0)
    let observationA = GitWorkspaceMonitor.shared.observe(rootPath: directory.path) { _ in
      first.signal()
    }
    let observationB = GitWorkspaceMonitor.shared.observe(rootPath: directory.path) { _ in
      second.signal()
    }
    withExtendedLifetime((observationA, observationB)) {
      Thread.sleep(forTimeInterval: 0.25)
      try! "changed\n".write(to: file, atomically: true, encoding: .utf8)
      #expect(first.wait(timeout: .now() + 4) == .success)
      #expect(second.wait(timeout: .now() + 4) == .success)
    }
  }

  @Test func recursiveNativeWatcherSeesChangesBelowRepositoryRoot() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    try TestSupport.initializeGitRepository(at: directory)
    let nested = directory.appendingPathComponent("Sources/Feature", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let file = nested.appendingPathComponent("tracked.txt")
    try "base\n".write(to: file, atomically: true, encoding: .utf8)
    try TestSupport.runGit(["add", "."], in: directory)
    try TestSupport.runGit(["commit", "-m", "Base"], in: directory)

    let changed = DispatchSemaphore(value: 0)
    let observation = GitWorkspaceMonitor.shared.observe(rootPath: directory.path) { _ in
      changed.signal()
    }
    withExtendedLifetime(observation) {
      Thread.sleep(forTimeInterval: 0.3)
      try! "changed\n".write(to: file, atomically: true, encoding: .utf8)
      #expect(changed.wait(timeout: .now() + 4) == .success)
    }
  }
}
