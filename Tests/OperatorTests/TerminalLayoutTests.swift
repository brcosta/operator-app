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

  @Test func mixedContentLeavesSplitRemoveAndRoundTripWithoutLosingIdentity() throws {
    let terminalID = UUID()
    let markdownID = UUID()
    let fileID = UUID()
    let emptyID = UUID()
    let layout: TerminalLayout = .split(
      .vertical,
      .split(
        .horizontal, .terminal(terminalID),
        .markdown(markdownID, path: "/tmp/README.md", workspaceDirectory: "/tmp")),
      .split(
        .horizontal, .file(fileID, path: "/tmp/App.swift", workspaceDirectory: "/tmp"),
        .empty(emptyID)))

    #expect(layout.terminalIDs == [terminalID])
    #expect(layout.contentPaneIDs == [terminalID, markdownID, fileID])
    #expect(layout.paneIDs == [terminalID, markdownID, fileID, emptyID])
    #expect(layout.markdownPane(forPath: "/tmp/README.md")?.id == markdownID)
    #expect(layout.firstFilePane?.id == fileID)
    #expect(layout.panesInDisplayOrder.count == 4)

    let data = try JSONEncoder().encode(layout)
    #expect(try JSONDecoder().decode(TerminalLayout.self, from: data) == layout)
    #expect(layout.removing(markdownID)?.contentPaneIDs == [terminalID, fileID])
    #expect(layout.removing(fileID)?.contentPaneIDs == [terminalID, markdownID])
  }

  @Test func unavailableRepairPreservesDocumentAndSourceViewerPanes() {
    let terminalID = UUID()
    let markdownID = UUID()
    let fileID = UUID()
    let layout: TerminalLayout = .split(
      .vertical,
      .markdown(markdownID, path: "/tmp/README.md", workspaceDirectory: "/tmp"),
      .split(
        .horizontal, .terminal(terminalID),
        .file(fileID, path: "/tmp/App.swift", workspaceDirectory: "/tmp")))

    let repaired = layout.replacingUnavailableTerminals(availableSessionIDs: [])

    #expect(repaired.emptyPaneIDs == [terminalID])
    #expect(repaired.contentPaneIDs == [markdownID, fileID])
    #expect(repaired.markdownPane(forPath: "/tmp/README.md")?.id == markdownID)
    #expect(repaired.firstFilePane?.id == fileID)
  }
}
