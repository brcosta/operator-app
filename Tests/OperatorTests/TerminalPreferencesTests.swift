import AppKit
import CoreText
import Foundation
import SwiftUI
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

  @Test func darkTerminalPaletteMatchesItermTangoProfile() {
    let palette = TerminalColorPalette.iTermDark

    #expect(palette.background.hex == 0x000000)
    #expect(palette.foreground.hex == 0xDEDEDE)
    #expect(palette.cursor.hex == 0xFFFFFF)
    #expect(palette.cursorText.hex == 0x000000)
    #expect(palette.selectionBackground.hex == 0xB5D5FF)
    #expect(
      palette.ansiColors.map(\.hex) == [
        0x000000, 0xCC0000, 0x4E9A06, 0xC4A000,
        0x3465A4, 0x75507B, 0x06989A, 0xD3D7CF,
        0x555753, 0xEF2929, 0x8AE234, 0xFCE94F,
        0x729FCF, 0xAD7FA8, 0x34E2E2, 0xEEEEEC,
      ])
  }

  @Test func lightTerminalPaletteKeepsColoredOutputReadable() {
    let palette = TerminalColorPalette.paperLight

    #expect(palette.background.hex == 0xFFFDF8)
    #expect(palette.foreground.hex == 0x24292F)
    #expect(palette.cursor.hex == 0x0969DA)
    #expect(palette.cursorText.hex == 0xFFFFFF)
    #expect(palette.selectionBackground.hex == 0xB6D7FF)
    #expect(
      palette.ansiColors.map(\.hex) == [
        0x24292F, 0xCF222E, 0x1A7F37, 0x9A6700,
        0x0969DA, 0x8250DF, 0x1B7C83, 0x57606A,
        0x6E7781, 0xA40E26, 0x116329, 0x7D4E00,
        0x0550AE, 0x6639BA, 0x0A6A75, 0xFFFFFF,
      ])
  }

  @Test func terminalPaletteFollowsTheInterfaceColorScheme() {
    #expect(TerminalColorPalette.default(for: .dark) == .iTermDark)
    #expect(TerminalColorPalette.default(for: .light) == .paperLight)
  }

  @MainActor
  @Test func terminalAppliesPaletteWithoutReapplyingItOnPreferenceChanges() throws {
    let terminal = OperatorTerminalView(frame: .init(x: 0, y: 0, width: 640, height: 480))

    terminal.apply(.default, palette: .iTermDark)
    let palette = try #require(terminal.appliedColorPalette)
    terminal.nativeBackgroundColor = TerminalRGB(hex: 0x123456).appKitColor
    terminal.apply(TerminalPreferences(fontSize: 15), palette: .iTermDark)

    #expect(palette == .iTermDark)
    #expect(rgbHex(of: terminal.nativeForegroundColor) == palette.foreground.hex)
    #expect(rgbHex(of: terminal.caretColor) == palette.cursor.hex)
    #expect(rgbHex(of: terminal.caretTextColor) == palette.cursorText.hex)
    #expect(rgbHex(of: terminal.selectedTextBackgroundColor) == palette.selectionBackground.hex)
    #expect(rgbHex(of: terminal.nativeBackgroundColor) == 0x123456)
  }

  @MainActor
  @Test func terminalRecolorsAnExistingSessionWhenAppearanceChanges() throws {
    let terminal = OperatorTerminalView(frame: .init(x: 0, y: 0, width: 640, height: 480))

    terminal.apply(.default, palette: .iTermDark)
    terminal.apply(.default, palette: .paperLight)

    #expect(terminal.appliedColorPalette == .paperLight)
    #expect(rgbHex(of: terminal.nativeBackgroundColor) == 0xFFFDF8)
    #expect(rgbHex(of: terminal.nativeForegroundColor) == 0x24292F)
    #expect(rgbHex(of: terminal.caretColor) == 0x0969DA)
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
