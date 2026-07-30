import AppKit
import Testing

@testable import Operator

struct NativeMacIntegrationTests {
  @Test func appearancePreferencesMapToNativeMacAppearances() {
    #expect(AppAppearanceResolver.name(for: .system) == nil)
    #expect(AppAppearanceResolver.name(for: .light) == .aqua)
    #expect(AppAppearanceResolver.name(for: .dark) == .darkAqua)
  }

  @Test func dockPrioritizesQuestionsThenFailuresAndAveragesProgress() {
    let questions = NativeSurfaceState(
      runningHarnessCount: 3, pendingQuestionCount: 2, failedHarnessCount: 1,
      progressValues: [0.2, 0.8, 1.5])
    #expect(questions.dockBadgeLabel == "2")
    #expect(questions.progress == 2.0 / 3.0)
    #expect(questions.statusItemSymbolName == "questionmark.bubble.fill")

    let failure = NativeSurfaceState(
      runningHarnessCount: 0, pendingQuestionCount: 0, failedHarnessCount: 1, progressValues: [])
    #expect(failure.dockBadgeLabel == "!")
    #expect(failure.statusItemSymbolName == "exclamationmark.triangle.fill")
    #expect(failure.menuSummary == "0 harnesses running · 1 needs attention")
  }

  @Test func dockClampsInvalidProgressAndClearsWhenUnavailable() {
    let state = NativeSurfaceState(
      runningHarnessCount: 1, pendingQuestionCount: 0, failedHarnessCount: 0,
      progressValues: [-1, .infinity, 0.5])
    #expect(state.progress == 0.25)
    #expect(state.dockBadgeLabel == nil)
    #expect(state.statusItemSymbolName == "terminal.fill")
  }
}
