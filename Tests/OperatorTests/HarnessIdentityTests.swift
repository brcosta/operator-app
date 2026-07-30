import Testing

@testable import Operator

struct HarnessIdentityTests {
  @Test func harnessesHaveDistinctStableIdentityMetadata() {
    #expect(HarnessKind.claudeCode.displayName == "Claude Code")
    #expect(HarnessKind.codex.displayName == "Codex")
    #expect(HarnessKind.generic.displayName == "Terminal")
    #expect(Set(HarnessKind.allCases.map(\.symbolName)).count == HarnessKind.allCases.count)
  }
}
