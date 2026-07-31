import CoreGraphics
import SwiftTerm
import Testing

@Suite
struct TerminalSmoothScrollingTests {
  @Test
  func preciseDeltasRemainVisibleAndCrossRowsWithoutSnapping() {
    var position = TerminalSmoothScrollPosition(row: 10)

    position.consume(deltaPoints: 5, cellHeight: 20, maximumRow: 20)
    #expect(position == TerminalSmoothScrollPosition(row: 10, offset: 5))

    position.consume(deltaPoints: 20, cellHeight: 20, maximumRow: 20)
    #expect(position == TerminalSmoothScrollPosition(row: 9, offset: 5))
  }

  @Test
  func reversingDirectionPreservesTheContinuousViewport() {
    var position = TerminalSmoothScrollPosition(row: 10, offset: 5)

    position.consume(deltaPoints: -8, cellHeight: 20, maximumRow: 20)

    #expect(position == TerminalSmoothScrollPosition(row: 10, offset: -3))
  }

  @Test
  func scrollingClampsWithoutOverscrollAtBothBufferEdges() {
    var top = TerminalSmoothScrollPosition(row: 0)
    top.consume(deltaPoints: 10_000, cellHeight: 20, maximumRow: 20)
    #expect(top == TerminalSmoothScrollPosition(row: 0))

    var bottom = TerminalSmoothScrollPosition(row: 20)
    bottom.consume(deltaPoints: -10_000, cellHeight: 20, maximumRow: 20)
    #expect(bottom == TerminalSmoothScrollPosition(row: 20))
  }

  @Test
  func malformedGeometryAndDeltasCannotCorruptTheViewport() {
    let original = TerminalSmoothScrollPosition(row: 7, offset: 3)
    var position = original

    position.consume(deltaPoints: .nan, cellHeight: 20, maximumRow: 20)
    position.consume(deltaPoints: 5, cellHeight: 0, maximumRow: 20)
    position.consume(deltaPoints: .infinity, cellHeight: 20, maximumRow: 20)

    #expect(position == original)
  }

  @Test
  func hitTestingIncludesThePartiallyVisibleRows() {
    let revealingPreviousRow = TerminalSmoothScrollPosition(row: 10, offset: 5)
    #expect(
      revealingPreviousRow.bufferRow(forViewY: 99, viewHeight: 100, cellHeight: 20)
        == 9
    )
    #expect(
      revealingPreviousRow.bufferRow(forViewY: 80, viewHeight: 100, cellHeight: 20)
        == 10
    )

    let revealingFollowingRow = TerminalSmoothScrollPosition(row: 10, offset: -5)
    #expect(
      revealingFollowingRow.bufferRow(forViewY: 1, viewHeight: 100, cellHeight: 20)
        == 15
    )
  }

  @Test
  func exactCellBoundariesHaveNoResidualOffset() {
    var position = TerminalSmoothScrollPosition(row: 10)

    position.consume(deltaPoints: 40, cellHeight: 20, maximumRow: 20)

    #expect(position == TerminalSmoothScrollPosition(row: 8))
  }
}
