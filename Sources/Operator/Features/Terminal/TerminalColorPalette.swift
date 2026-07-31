import AppKit
import SwiftTerm
import SwiftUI

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

  /// The iTerm2 Tango profile used as Operator's dark terminal default.
  static let iTermDark = TerminalColorPalette(
    background: TerminalRGB(hex: 0x000000),
    foreground: TerminalRGB(hex: 0xDEDEDE),
    cursor: TerminalRGB(hex: 0xFFFFFF),
    cursorText: TerminalRGB(hex: 0x000000),
    selectionBackground: TerminalRGB(hex: 0xB5D5FF),
    ansiColors: [
      TerminalRGB(hex: 0x000000), TerminalRGB(hex: 0xCC0000),
      TerminalRGB(hex: 0x4E9A06), TerminalRGB(hex: 0xC4A000),
      TerminalRGB(hex: 0x3465A4), TerminalRGB(hex: 0x75507B),
      TerminalRGB(hex: 0x06989A), TerminalRGB(hex: 0xD3D7CF),
      TerminalRGB(hex: 0x555753), TerminalRGB(hex: 0xEF2929),
      TerminalRGB(hex: 0x8AE234), TerminalRGB(hex: 0xFCE94F),
      TerminalRGB(hex: 0x729FCF), TerminalRGB(hex: 0xAD7FA8),
      TerminalRGB(hex: 0x34E2E2), TerminalRGB(hex: 0xEEEEEC),
    ])

  /// A light, high-contrast companion palette. Every colored ANSI value has sufficient
  /// contrast against the warm paper background for command output and diagnostics.
  static let paperLight = TerminalColorPalette(
    background: TerminalRGB(hex: 0xFFFDF8),
    foreground: TerminalRGB(hex: 0x24292F),
    cursor: TerminalRGB(hex: 0x0969DA),
    cursorText: TerminalRGB(hex: 0xFFFFFF),
    selectionBackground: TerminalRGB(hex: 0xB6D7FF),
    ansiColors: [
      TerminalRGB(hex: 0x24292F), TerminalRGB(hex: 0xCF222E),
      TerminalRGB(hex: 0x1A7F37), TerminalRGB(hex: 0x9A6700),
      TerminalRGB(hex: 0x0969DA), TerminalRGB(hex: 0x8250DF),
      TerminalRGB(hex: 0x1B7C83), TerminalRGB(hex: 0x57606A),
      TerminalRGB(hex: 0x6E7781), TerminalRGB(hex: 0xA40E26),
      TerminalRGB(hex: 0x116329), TerminalRGB(hex: 0x7D4E00),
      TerminalRGB(hex: 0x0550AE), TerminalRGB(hex: 0x6639BA),
      TerminalRGB(hex: 0x0A6A75), TerminalRGB(hex: 0xFFFFFF),
    ])

  static func `default`(for colorScheme: ColorScheme) -> TerminalColorPalette {
    colorScheme == .dark ? iTermDark : paperLight
  }

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
