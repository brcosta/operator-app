import Testing

@testable import Operator

struct HarnessIdentityTests {
  @Test func harnessesHaveDistinctStableIdentityMetadata() {
    #expect(HarnessKind.claudeCode.displayName == "Claude Code")
    #expect(HarnessKind.codex.displayName == "Codex")
    #expect(HarnessKind.generic.displayName == "Terminal")
    #expect(Set(HarnessKind.allCases.map(\.symbolName)).count == HarnessKind.allCases.count)
  }

  @Test func codingHarnessesShipWithTransparentBrandAssets() {
    #expect(HarnessBrandAssets.resourceURL(for: .claudeCode) != nil)
    #expect(HarnessBrandAssets.resourceURL(for: .codex) != nil)
    #expect(HarnessBrandAssets.resourceURL(for: .generic) == nil)
    #expect(HarnessBrandAssets.image(for: .claudeCode)?.size.width ?? 0 > 0)
    #expect(HarnessBrandAssets.image(for: .codex)?.size.height ?? 0 > 0)
  }
}
