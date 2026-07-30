import AppKit
import SwiftTerm

struct TerminalRGB: Equatable, Sendable {
  let red: UInt8
  let green: UInt8
  let blue: UInt8

  init(hex: UInt32) {
    red = UInt8((hex >> 16) & 0xFF)
    green = UInt8((hex >> 8) & 0xFF)
    blue = UInt8(hex & 0xFF)
  }

  var hex: UInt32 {
    (UInt32(red) << 16) | (UInt32(green) << 8) | UInt32(blue)
  }

  var appKitColor: NSColor {
    NSColor(
      srgbRed: CGFloat(red) / 255,
      green: CGFloat(green) / 255,
      blue: CGFloat(blue) / 255,
      alpha: 1)
  }

  var swiftTermColor: SwiftTerm.Color {
    SwiftTerm.Color(
      red: UInt16(red) * 257,
      green: UInt16(green) * 257,
      blue: UInt16(blue) * 257)
  }
}

struct TerminalColorPalette: Equatable, Sendable {
  let background: TerminalRGB
  let foreground: TerminalRGB
  let cursor: TerminalRGB
  let cursorText: TerminalRGB
  let selectionBackground: TerminalRGB
  let ansiColors: [TerminalRGB]

  /// The stock iTerm2 "Default" profile. Keeping the terminal profile independent from
  /// Operator's window appearance also prevents app theme changes from recoloring live sessions.
  static let iTermDefault = TerminalColorPalette(
    background: TerminalRGB(hex: 0x000000),
    foreground: TerminalRGB(hex: 0xBBBBBB),
    cursor: TerminalRGB(hex: 0xBBBBBB),
    cursorText: TerminalRGB(hex: 0xFFFFFF),
    selectionBackground: TerminalRGB(hex: 0xB5D5FF),
    ansiColors: [
      TerminalRGB(hex: 0x000000),
      TerminalRGB(hex: 0xBB0000),
      TerminalRGB(hex: 0x00BB00),
      TerminalRGB(hex: 0xBBBB00),
      TerminalRGB(hex: 0x0000BB),
      TerminalRGB(hex: 0xBB00BB),
      TerminalRGB(hex: 0x00BBBB),
      TerminalRGB(hex: 0xBBBBBB),
      TerminalRGB(hex: 0x555555),
      TerminalRGB(hex: 0xFF5555),
      TerminalRGB(hex: 0x55FF55),
      TerminalRGB(hex: 0xFFFF55),
      TerminalRGB(hex: 0x5555FF),
      TerminalRGB(hex: 0xFF55FF),
      TerminalRGB(hex: 0x55FFFF),
      TerminalRGB(hex: 0xFFFFFF),
    ])

  @MainActor
  func apply(to terminal: LocalProcessTerminalView) {
    terminal.nativeBackgroundColor = background.appKitColor
    terminal.layer?.backgroundColor = background.appKitColor.cgColor
    terminal.nativeForegroundColor = foreground.appKitColor
    terminal.caretColor = cursor.appKitColor
    terminal.caretTextColor = cursorText.appKitColor
    terminal.selectedTextBackgroundColor = selectionBackground.appKitColor
    terminal.useBrightColors = true
    terminal.installColors(ansiColors.map(\.swiftTermColor))
  }
}
