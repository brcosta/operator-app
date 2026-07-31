import Foundation

indirect enum TerminalLayout: Hashable, Codable {
  case terminal(UUID)
  case markdown(UUID, path: String, workspaceDirectory: String)
  case file(UUID, path: String, workspaceDirectory: String)
  case empty(UUID)
  case split(SplitOrientation, TerminalLayout, TerminalLayout)

  var isSplit: Bool {
    if case .split = self { return true }
    return false
  }

  func removing(_ id: UUID) -> TerminalLayout? {
    switch self {
    case .terminal(let sessionID): return sessionID == id ? nil : self
    case .markdown(let paneID, _, _), .file(let paneID, _, _):
      return paneID == id ? nil : self
    case .empty: return self
    case .split(let orientation, let first, let second):
      switch (first.removing(id), second.removing(id)) {
      case (.some(let left), .some(let right)): return .split(orientation, left, right)
      case (.some(let remaining), nil), (nil, .some(let remaining)): return remaining
      case (nil, nil): return nil
      }
    }
  }

  func contains(_ id: UUID) -> Bool {
    switch self {
    case .terminal(let sessionID): sessionID == id
    case .markdown(let paneID, _, _), .file(let paneID, _, _): paneID == id
    case .empty: false
    case .split(_, let first, let second): first.contains(id) || second.contains(id)
    }
  }

  func replacingEmptyPane(_ paneID: UUID, with sessionID: UUID) -> TerminalLayout? {
    replacingEmptyPane(paneID, with: .terminal(sessionID))
  }

  func replacingEmptyPane(_ paneID: UUID, with replacement: TerminalLayout) -> TerminalLayout? {
    switch self {
    case .empty(let id): return id == paneID ? replacement : nil
    case .terminal, .markdown, .file: return nil
    case .split(let orientation, let first, let second):
      if let updated = first.replacingEmptyPane(paneID, with: replacement) {
        return .split(orientation, updated, second)
      }
      if let updated = second.replacingEmptyPane(paneID, with: replacement) {
        return .split(orientation, first, updated)
      }
      return nil
    }
  }

  func splitting(sessionID: UUID, orientation: SplitOrientation, emptyPaneID: UUID)
    -> TerminalLayout?
  {
    switch self {
    case .terminal(let id):
      return id == sessionID ? .split(orientation, .terminal(id), .empty(emptyPaneID)) : nil
    case .markdown, .file, .empty: return nil
    case .split(let currentOrientation, let first, let second):
      if let replacement = first.splitting(
        sessionID: sessionID, orientation: orientation, emptyPaneID: emptyPaneID)
      {
        return .split(currentOrientation, replacement, second)
      }
      if let replacement = second.splitting(
        sessionID: sessionID, orientation: orientation, emptyPaneID: emptyPaneID)
      {
        return .split(currentOrientation, first, replacement)
      }
      return nil
    }
  }

  func splitting(emptyPaneID: UUID, orientation: SplitOrientation, newEmptyPaneID: UUID)
    -> TerminalLayout?
  {
    switch self {
    case .terminal, .markdown, .file: return nil
    case .empty(let id):
      return id == emptyPaneID ? .split(orientation, .empty(id), .empty(newEmptyPaneID)) : nil
    case .split(let currentOrientation, let first, let second):
      if let replacement = first.splitting(
        emptyPaneID: emptyPaneID, orientation: orientation, newEmptyPaneID: newEmptyPaneID)
      {
        return .split(currentOrientation, replacement, second)
      }
      if let replacement = second.splitting(
        emptyPaneID: emptyPaneID, orientation: orientation, newEmptyPaneID: newEmptyPaneID)
      {
        return .split(currentOrientation, first, replacement)
      }
      return nil
    }
  }

  func path(toEmptyPane paneID: UUID, from path: String = "root") -> String? {
    switch self {
    case .terminal, .markdown, .file: return nil
    case .empty(let id): return id == paneID ? path : nil
    case .split(_, let first, let second):
      return first.path(toEmptyPane: paneID, from: "\(path).0")
        ?? second.path(toEmptyPane: paneID, from: "\(path).1")
    }
  }

  func path(to sessionID: UUID, from path: String = "root") -> String? {
    switch self {
    case .terminal(let id): return id == sessionID ? path : nil
    case .markdown(let id, _, _), .file(let id, _, _): return id == sessionID ? path : nil
    case .empty: return nil
    case .split(_, let first, let second):
      return first.path(to: sessionID, from: "\(path).0")
        ?? second.path(to: sessionID, from: "\(path).1")
    }
  }

  func removingEmptyPane(_ paneID: UUID) -> TerminalLayout? {
    switch self {
    case .empty(let id): return id == paneID ? nil : self
    case .terminal, .markdown, .file: return self
    case .split(let orientation, let first, let second):
      switch (first.removingEmptyPane(paneID), second.removingEmptyPane(paneID)) {
      case (.some(let left), .some(let right)): return .split(orientation, left, right)
      case (.some(let remaining), nil), (nil, .some(let remaining)): return remaining
      case (nil, nil): return nil
      }
    }
  }

  func replacingTerminal(_ currentID: UUID, with replacementID: UUID) -> TerminalLayout? {
    switch self {
    case .terminal(let id): return id == currentID ? .terminal(replacementID) : nil
    case .markdown, .file, .empty: return nil
    case .split(let orientation, let first, let second):
      if let replacement = first.replacingTerminal(currentID, with: replacementID) {
        return .split(orientation, replacement, second)
      }
      if let replacement = second.replacingTerminal(currentID, with: replacementID) {
        return .split(orientation, first, replacement)
      }
      return nil
    }
  }

  /// Keeps the saved split geometry while turning terminals that cannot be safely resumed into
  /// explicit launch targets. Interactive shells and resumable harnesses remain available.
  func replacingUnavailableTerminals(availableSessionIDs: Set<UUID>) -> TerminalLayout {
    switch self {
    case .terminal(let id):
      return availableSessionIDs.contains(id) ? self : .empty(id)
    case .markdown, .file, .empty:
      return self
    case .split(let orientation, let first, let second):
      return .split(
        orientation, first.replacingUnavailableTerminals(availableSessionIDs: availableSessionIDs),
        second.replacingUnavailableTerminals(availableSessionIDs: availableSessionIDs))
    }
  }

  var firstTerminalID: UUID? {
    switch self {
    case .terminal(let id): return id
    case .markdown, .file, .empty: return nil
    case .split(_, let first, let second): return first.firstTerminalID ?? second.firstTerminalID
    }
  }

  var firstPaneID: UUID? {
    switch self {
    case .terminal(let id), .markdown(let id, _, _), .file(let id, _, _), .empty(let id):
      return id
    case .split(_, let first, let second):
      return first.firstPaneID ?? second.firstPaneID
    }
  }

  var terminalIDs: Set<UUID> {
    switch self {
    case .terminal(let id): [id]
    case .markdown, .file, .empty: []
    case .split(_, let first, let second): first.terminalIDs.union(second.terminalIDs)
    }
  }

  var terminalIDsInDisplayOrder: [UUID] {
    switch self {
    case .terminal(let id): [id]
    case .markdown, .file, .empty: []
    case .split(_, let first, let second):
      first.terminalIDsInDisplayOrder + second.terminalIDsInDisplayOrder
    }
  }

  var emptyPaneIDs: Set<UUID> {
    switch self {
    case .terminal, .markdown, .file: return []
    case .empty(let id): return [id]
    case .split(_, let first, let second): return first.emptyPaneIDs.union(second.emptyPaneIDs)
    }
  }

  var paneIDs: Set<UUID> {
    switch self {
    case .terminal(let id), .markdown(let id, _, _), .file(let id, _, _), .empty(let id):
      return [id]
    case .split(_, let first, let second):
      return first.paneIDs.union(second.paneIDs)
    }
  }

  var contentPaneIDs: Set<UUID> {
    switch self {
    case .terminal(let id), .markdown(let id, _, _), .file(let id, _, _):
      return [id]
    case .empty:
      return []
    case .split(_, let first, let second):
      return first.contentPaneIDs.union(second.contentPaneIDs)
    }
  }

  var panesInDisplayOrder: [TerminalLayout] {
    switch self {
    case .terminal, .markdown, .file, .empty:
      return [self]
    case .split(_, let first, let second):
      return first.panesInDisplayOrder + second.panesInDisplayOrder
    }
  }

  func pane(withID paneID: UUID) -> TerminalLayout? {
    switch self {
    case .terminal(let id), .markdown(let id, _, _), .file(let id, _, _), .empty(let id):
      return id == paneID ? self : nil
    case .split(_, let first, let second):
      return first.pane(withID: paneID) ?? second.pane(withID: paneID)
    }
  }

  func splitting(paneID: UUID, orientation: SplitOrientation, emptyPaneID: UUID)
    -> TerminalLayout?
  {
    switch self {
    case .terminal(let id):
      return id == paneID ? .split(orientation, self, .empty(emptyPaneID)) : nil
    case .markdown(let id, _, _), .file(let id, _, _):
      return id == paneID ? .split(orientation, self, .empty(emptyPaneID)) : nil
    case .empty(let id):
      return id == paneID ? .split(orientation, self, .empty(emptyPaneID)) : nil
    case .split(let currentOrientation, let first, let second):
      if let updated = first.splitting(
        paneID: paneID, orientation: orientation, emptyPaneID: emptyPaneID)
      {
        return .split(currentOrientation, updated, second)
      }
      if let updated = second.splitting(
        paneID: paneID, orientation: orientation, emptyPaneID: emptyPaneID)
      {
        return .split(currentOrientation, first, updated)
      }
      return nil
    }
  }

  func replacingPane(_ paneID: UUID, with replacement: TerminalLayout) -> TerminalLayout? {
    switch self {
    case .terminal(let id), .markdown(let id, _, _), .file(let id, _, _), .empty(let id):
      return id == paneID ? replacement : nil
    case .split(let orientation, let first, let second):
      if let updated = first.replacingPane(paneID, with: replacement) {
        return .split(orientation, updated, second)
      }
      if let updated = second.replacingPane(paneID, with: replacement) {
        return .split(orientation, first, updated)
      }
      return nil
    }
  }

  func markdownPane(forPath path: String) -> (id: UUID, workspaceDirectory: String)? {
    switch self {
    case .markdown(let id, let panePath, let directory):
      return panePath == path ? (id, directory) : nil
    case .split(_, let first, let second):
      return first.markdownPane(forPath: path) ?? second.markdownPane(forPath: path)
    case .terminal, .file, .empty:
      return nil
    }
  }

  var firstFilePane: (id: UUID, path: String, workspaceDirectory: String)? {
    switch self {
    case .file(let id, let path, let directory):
      return (id, path, directory)
    case .split(_, let first, let second):
      return first.firstFilePane ?? second.firstFilePane
    case .terminal, .markdown, .empty:
      return nil
    }
  }

  var firstMarkdownPane: (id: UUID, path: String, workspaceDirectory: String)? {
    switch self {
    case .markdown(let id, let path, let directory):
      return (id, path, directory)
    case .split(_, let first, let second):
      return first.firstMarkdownPane ?? second.firstMarkdownPane
    case .terminal, .file, .empty:
      return nil
    }
  }
}
