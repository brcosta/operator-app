import AppKit
import CoreText
import Foundation
import Testing

@testable import Operator

struct TerminalPreferencesTests {
  @Test func defaultsPreserveTypographyAndBoundScrollbackForResponsiveness() {
    let preferences = TerminalPreferences.default

    #expect(preferences.fontFamily == nil)
    #expect(preferences.fontSize == 13)
    #expect(!preferences.ligaturesEnabled)
    #expect(preferences.scrollbackLines == 20_000)
  }

  @Test func malformedAndExtremePreferencesNormalizeSafely() throws {
    let data = Data(
      """
      {
        "fontFamily": "   ",
        "fontSize": 9999,
        "ligaturesEnabled": true,
        "scrollbackLines": 4
      }
      """.utf8)
    let preferences = try JSONDecoder().decode(TerminalPreferences.self, from: data)

    #expect(preferences.fontFamily == nil)
    #expect(preferences.fontSize == TerminalPreferences.fontSizeRange.upperBound)
    #expect(preferences.ligaturesEnabled)
    #expect(preferences.scrollbackLines == TerminalPreferences.scrollbackRange.lowerBound)

    let nonfinite = TerminalPreferences(fontSize: .infinity, scrollbackLines: Int.max)
    #expect(nonfinite.fontSize == TerminalPreferences.defaultFontSize)
    #expect(nonfinite.scrollbackLines == TerminalPreferences.scrollbackRange.upperBound)
  }

  @Test func missingOrProportionalFontsFallBackToSystemMonospaced() {
    let missing = TerminalFontResolver.font(
      for: TerminalPreferences(fontFamily: "Definitely Missing Operator Font", fontSize: 17))
    let proportional = TerminalFontResolver.font(
      for: TerminalPreferences(fontFamily: "Helvetica", fontSize: 16))

    #expect(missing.pointSize == 17)
    #expect(missing.fontDescriptor.symbolicTraits.contains(.monoSpace))
    #expect(proportional.pointSize == 16)
    #expect(proportional.fontDescriptor.symbolicTraits.contains(.monoSpace))
  }

  @Test func ligaturePreferenceChangesCoreTextShaping() throws {
    _ = try #require(TerminalFontCatalog.availableFamilies.contains("Menlo"))
    let enabled = TerminalFontResolver.font(
      for: TerminalPreferences(fontFamily: "Menlo", ligaturesEnabled: true))
    let disabled = TerminalFontResolver.font(
      for: TerminalPreferences(fontFamily: "Menlo", ligaturesEnabled: false))
    let enabledGlyphs = glyphs(in: "fi ->", font: enabled)
    let disabledGlyphs = glyphs(in: "fi ->", font: disabled)

    #expect(enabledGlyphs != disabledGlyphs)
    #expect(enabledGlyphs.count < disabledGlyphs.count)
  }

  @MainActor
  @Test func terminalAppliesTypographyAndOptimizedRedrawPreferencesLive() {
    let terminal = OperatorTerminalView(frame: .init(x: 0, y: 0, width: 640, height: 480))
    let preferences = TerminalPreferences(
      fontSize: 15, ligaturesEnabled: true, scrollbackLines: 10_000)

    terminal.apply(preferences)

    #expect(terminal.appliedPreferences == preferences)
    #expect(terminal.font.pointSize == 15)
    #expect(terminal.disableFullRedrawOnAnyChanges)
  }

  @Test func defaultTerminalPaletteMatchesItermDefaultProfile() {
    let palette = TerminalColorPalette.iTermDefault

    #expect(palette.background.hex == 0x000000)
    #expect(palette.foreground.hex == 0xBBBBBB)
    #expect(palette.cursor.hex == 0xBBBBBB)
    #expect(palette.cursorText.hex == 0xFFFFFF)
    #expect(palette.selectionBackground.hex == 0xB5D5FF)
    #expect(
      palette.ansiColors.map(\.hex) == [
        0x000000, 0xBB0000, 0x00BB00, 0xBBBB00,
        0x0000BB, 0xBB00BB, 0x00BBBB, 0xBBBBBB,
        0x555555, 0xFF5555, 0x55FF55, 0xFFFF55,
        0x5555FF, 0xFF55FF, 0x55FFFF, 0xFFFFFF,
      ])
  }

  @MainActor
  @Test func terminalAppliesDefaultPaletteWithoutReapplyingItOnPreferenceChanges() throws {
    let terminal = OperatorTerminalView(frame: .init(x: 0, y: 0, width: 640, height: 480))

    terminal.apply(.default)
    let palette = try #require(terminal.appliedColorPalette)
    terminal.nativeBackgroundColor = TerminalRGB(hex: 0x123456).appKitColor
    terminal.apply(TerminalPreferences(fontSize: 15))

    #expect(palette == .iTermDefault)
    #expect(rgbHex(of: terminal.nativeForegroundColor) == palette.foreground.hex)
    #expect(rgbHex(of: terminal.caretColor) == palette.cursor.hex)
    #expect(rgbHex(of: terminal.caretTextColor) == palette.cursorText.hex)
    #expect(rgbHex(of: terminal.selectedTextBackgroundColor) == palette.selectionBackground.hex)
    #expect(rgbHex(of: terminal.nativeBackgroundColor) == 0x123456)
  }

  @Test func focusIntentSurvivesMountingUntilFirstResponderDeliverySucceeds() {
    var intent = TerminalFocusIntent()

    intent.request()
    #expect(intent.isPending)
    intent.recordDelivery(succeeded: false)
    #expect(intent.isPending)
    intent.recordDelivery(succeeded: true)
    #expect(!intent.isPending)
  }

  @MainActor
  @Test func launchingATerminalQueuesFocusBeforeItsNativeViewMounts() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
    let controller = WorkspaceController(store: store)

    controller.launch(
      LaunchRequest(title: "Focused shell", command: "fish", directory: directory.path))

    let session = try #require(controller.sessions.first)
    #expect(controller.selectedSessionID == session.id)
    #expect(session.keyboardFocusIntent.isPending)
  }

  @MainActor
  @Test func terminalPreferencesPersistAndLegacyStateUsesResponsiveDefaults() throws {
    let directory = try TestSupport.temporaryDirectory()
    defer { TestSupport.remove(directory) }
    let stateURL = directory.appendingPathComponent("state.json")
    let store = StateStore(fileURL: stateURL)
    let preferences = TerminalPreferences(
      fontFamily: TerminalFontCatalog.availableFamilies.first, fontSize: 18,
      ligaturesEnabled: true, scrollbackLines: 50_000)

    store.setTerminalPreferences(preferences)
    #expect(StateStore(fileURL: stateURL).state.terminalPreferences == preferences.normalized)

    let legacyData = Data(
      """
      {
        "schemaVersion": 9,
        "projects": [],
        "profiles": [],
        "recentSessions": [],
        "shortcuts": []
      }
      """.utf8)
    try legacyData.write(to: stateURL, options: .atomic)
    let legacy = StateStore(fileURL: stateURL)
    #expect(legacy.state.terminalPreferences == .default)
  }

  private func glyphs(in text: String, font: NSFont) -> [CGGlyph] {
    let attributed = NSAttributedString(string: text, attributes: [.font: font])
    let line = CTLineCreateWithAttributedString(attributed)
    let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
    return runs.flatMap { run in
      let count = CTRunGetGlyphCount(run)
      var glyphs = [CGGlyph](repeating: 0, count: count)
      CTRunGetGlyphs(run, CFRange(), &glyphs)
      return glyphs
    }
  }

  private func rgbHex(of color: NSColor?) -> UInt32? {
    guard let color = color?.usingColorSpace(.sRGB) else { return nil }
    let red = UInt32((color.redComponent * 255).rounded())
    let green = UInt32((color.greenComponent * 255).rounded())
    let blue = UInt32((color.blueComponent * 255).rounded())
    return (red << 16) | (green << 8) | blue
  }
}
