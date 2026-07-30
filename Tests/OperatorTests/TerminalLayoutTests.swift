import Foundation
import Testing

@testable import Operator

struct TerminalLayoutTests {
  @Test func removingCollapsesNestedBranchesAndPreservesOrientation() {
    let first = UUID()
    let second = UUID()
    let third = UUID()
    let layout: TerminalLayout = .split(
      .vertical, .terminal(first), .split(.horizontal, .terminal(second), .terminal(third)))

    guard let afterSecond = layout.removing(second) else {
      Issue.record("Expected a remaining layout")
      return
    }
    #expect(afterSecond == TerminalLayout.split(.vertical, .terminal(first), .terminal(third)))
    #expect(afterSecond.contains(first))
    #expect(!afterSecond.contains(second))
    #expect(afterSecond.contains(third))
    #expect(afterSecond.removing(first) == .terminal(third))
    #expect(TerminalLayout.terminal(third).removing(third) == nil)
  }

  @Test func removingUnknownTerminalLeavesLayoutUnchanged() {
    let id = UUID()
    let layout = TerminalLayout.terminal(id)
    #expect(layout.removing(UUID()) == layout)
    #expect(!layout.contains(UUID()))
  }

  @Test func unavailableRestoredTerminalsBecomeExplicitEmptyPanes() {
    let available = UUID()
    let unavailable = UUID()
    let existingEmpty = UUID()
    let layout: TerminalLayout = .split(
      .horizontal, .terminal(available),
      .split(.vertical, .terminal(unavailable), .empty(existingEmpty)))

    let repaired = layout.replacingUnavailableTerminals(availableSessionIDs: [available])

    #expect(repaired.contains(available))
    #expect(!repaired.contains(unavailable))
    #expect(repaired.isSplit)
    #expect(repaired.emptyPaneIDs.contains(unavailable))
    #expect(repaired.emptyPaneIDs.contains(existingEmpty))
  }
}
