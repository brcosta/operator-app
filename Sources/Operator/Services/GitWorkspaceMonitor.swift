import CoreServices
import Foundation

final class GitWorkspaceObservation {
  private let cancelHandler: () -> Void

  init(cancel: @escaping () -> Void) { cancelHandler = cancel }
  deinit { cancelHandler() }
}

final class GitWorkspaceMonitor {
  static let shared = GitWorkspaceMonitor()

  typealias Handler = (GitStatusSnapshot) -> Void
  private struct Entry {
    var snapshot: GitStatusSnapshot?
    var handlers: [UUID: Handler] = [:]
    var watcher: WorkspaceFileWatcher?
    var pendingPoll: DispatchWorkItem?
  }
  private let queue = DispatchQueue(label: "Operator.GitWorkspaceMonitor", qos: .utility)
  private var entries: [String: Entry] = [:]
  private var timer: DispatchSourceTimer?

  private init() {}

  func observe(rootPath: String, handler: @escaping Handler) -> GitWorkspaceObservation {
    let id = UUID()
    queue.async { [weak self] in
      guard let self else { return }
      var entry = self.entries[rootPath] ?? Entry()
      if entry.snapshot == nil { entry.snapshot = try? GitRepository.statusSnapshot(in: rootPath) }
      if entry.watcher == nil { entry.watcher = self.watch(rootPath: rootPath) }
      entry.handlers[id] = handler
      self.entries[rootPath] = entry
      self.startIfNeeded()
    }
    return GitWorkspaceObservation { [weak self] in
      self?.queue.async { self?.remove(id, from: rootPath) }
    }
  }

  private func startIfNeeded() {
    guard timer == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    // FSEvents provides immediate recursive updates; this catches changes made
    // by tools that do not generate a usable event (network volumes, some Git operations).
    timer.schedule(deadline: .now() + 5, repeating: .seconds(30))
    timer.setEventHandler { [weak self] in self?.poll() }
    self.timer = timer
    timer.resume()
  }

  private func poll() {
    for rootPath in entries.keys { poll(rootPath) }
  }

  private func poll(_ rootPath: String) {
    guard let snapshot = try? GitRepository.statusSnapshot(in: rootPath),
      var entry = entries[rootPath], let previous = entry.snapshot,
      snapshot.fingerprint != previous.fingerprint
    else { return }
    entry.snapshot = snapshot
    entries[rootPath] = entry
    for handler in entry.handlers.values {
      handler(snapshot)
    }
  }

  private func watch(rootPath: String) -> WorkspaceFileWatcher {
    WorkspaceFileWatcher(rootPath: rootPath, queue: queue) { [weak self] in
      self?.schedulePoll(rootPath)
    }
  }

  private func schedulePoll(_ rootPath: String) {
    guard var entry = entries[rootPath] else { return }
    entry.pendingPoll?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.poll(rootPath) }
    entry.pendingPoll = work
    entries[rootPath] = entry
    queue.asyncAfter(deadline: .now() + .milliseconds(250), execute: work)
  }

  private func remove(_ id: UUID, from rootPath: String) {
    guard var entry = entries[rootPath] else { return }
    entry.handlers[id] = nil
    if entry.handlers.isEmpty {
      entry.pendingPoll?.cancel()
      entry.watcher?.invalidate()
      entries[rootPath] = nil
    } else {
      entries[rootPath] = entry
    }
    if entries.isEmpty {
      timer?.cancel()
      timer = nil
    }
  }
}

private final class WorkspaceFileWatcher {
  private var stream: FSEventStreamRef?
  private let callback: () -> Void

  init(rootPath: String, queue: DispatchQueue, callback: @escaping () -> Void) {
    self.callback = callback
    let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
    var streamContext = FSEventStreamContext(
      version: 0, info: context, retain: nil, release: nil, copyDescription: nil)
    let paths = [rootPath] as CFArray
    stream = FSEventStreamCreate(
      kCFAllocatorDefault,
      { _, info, _, _, _, _ in
        guard let info else { return }
        Unmanaged<WorkspaceFileWatcher>.fromOpaque(info).takeUnretainedValue().callback()
      }, &streamContext, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15,
      FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents))
    if let stream {
      FSEventStreamSetDispatchQueue(stream, queue)
      FSEventStreamStart(stream)
    }
  }

  func invalidate() {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
    self.stream = nil
  }

  deinit { invalidate() }
}
