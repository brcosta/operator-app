import Foundation

indirect enum TerminalLayout: Hashable, Codable {
  case terminal(UUID)
  case empty(UUID)
  case split(SplitOrientation, TerminalLayout, TerminalLayout)

  var isSplit: Bool {
    if case .split = self { return true }
    return false
  }

  func removing(_ id: UUID) -> TerminalLayout? {
    switch self {
    case .terminal(let sessionID): return sessionID == id ? nil : self
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
    case .empty: false
    case .split(_, let first, let second): first.contains(id) || second.contains(id)
    }
  }

  func replacingEmptyPane(_ paneID: UUID, with sessionID: UUID) -> TerminalLayout? {
    switch self {
    case .empty(let id): return id == paneID ? .terminal(sessionID) : nil
    case .terminal: return nil
    case .split(let orientation, let first, let second):
      if let replacement = first.replacingEmptyPane(paneID, with: sessionID) {
        return .split(orientation, replacement, second)
      }
      if let replacement = second.replacingEmptyPane(paneID, with: sessionID) {
        return .split(orientation, first, replacement)
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
    case .empty: return nil
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
    case .terminal: return nil
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
    case .terminal: return nil
    case .empty(let id): return id == paneID ? path : nil
    case .split(_, let first, let second):
      return first.path(toEmptyPane: paneID, from: "\(path).0")
        ?? second.path(toEmptyPane: paneID, from: "\(path).1")
    }
  }

  func path(to sessionID: UUID, from path: String = "root") -> String? {
    switch self {
    case .terminal(let id): return id == sessionID ? path : nil
    case .empty: return nil
    case .split(_, let first, let second):
      return first.path(to: sessionID, from: "\(path).0")
        ?? second.path(to: sessionID, from: "\(path).1")
    }
  }

  func removingEmptyPane(_ paneID: UUID) -> TerminalLayout? {
    switch self {
    case .empty(let id): return id == paneID ? nil : self
    case .terminal: return self
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
    case .empty: return nil
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
    case .empty:
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
    case .empty: return nil
    case .split(_, let first, let second): return first.firstTerminalID ?? second.firstTerminalID
    }
  }

  var terminalIDs: Set<UUID> {
    switch self {
    case .terminal(let id): [id]
    case .empty: []
    case .split(_, let first, let second): first.terminalIDs.union(second.terminalIDs)
    }
  }

  var terminalIDsInDisplayOrder: [UUID] {
    switch self {
    case .terminal(let id): [id]
    case .empty: []
    case .split(_, let first, let second):
      first.terminalIDsInDisplayOrder + second.terminalIDsInDisplayOrder
    }
  }

  var emptyPaneIDs: Set<UUID> {
    switch self {
    case .terminal: return []
    case .empty(let id): return [id]
    case .split(_, let first, let second): return first.emptyPaneIDs.union(second.emptyPaneIDs)
    }
  }
}
