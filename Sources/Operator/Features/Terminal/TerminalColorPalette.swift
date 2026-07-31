import AppKit
import Foundation
import SwiftTerm
import SwiftUI

struct TerminalRGB: Codable, Equatable, Hashable, Sendable {
  let red: UInt8
  let green: UInt8
  let blue: UInt8

  init(hex: UInt32) {
    red = UInt8((hex >> 16) & 0xFF)
    green = UInt8((hex >> 8) & 0xFF)
    blue = UInt8(hex & 0xFF)
  }

  init(red: UInt8, green: UInt8, blue: UInt8) {
    self.red = red
    self.green = green
    self.blue = blue
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

  var swiftUIColor: SwiftUI.Color { SwiftUI.Color(nsColor: appKitColor) }

  init(color: SwiftUI.Color) {
    let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .black
    red = UInt8((resolved.redComponent * 255).rounded().clamped(to: 0...255))
    green = UInt8((resolved.greenComponent * 255).rounded().clamped(to: 0...255))
    blue = UInt8((resolved.blueComponent * 255).rounded().clamped(to: 0...255))
  }
}

struct TerminalColorPalette: Codable, Equatable, Hashable, Sendable {
  var background: TerminalRGB
  var foreground: TerminalRGB
  var cursor: TerminalRGB
  var cursorText: TerminalRGB
  var selectionBackground: TerminalRGB
  var ansiColors: [TerminalRGB]

  /// The user's iTerm2 profile used as Operator's dark terminal default.
  static let iTermDark = TerminalColorPalette(
    background: TerminalRGB(hex: 0x14181D),
    // Keep the default prompt/output text slightly softer than pure white.
    // This matches the requested iTerm profile foreground: RGB(198, 198, 198).
    foreground: TerminalRGB(hex: 0xC6C6C6),
    cursor: TerminalRGB(hex: 0xFFFFFF),
    cursorText: TerminalRGB(hex: 0x000000),
    selectionBackground: TerminalRGB(hex: 0xBAD6FC),
    ansiColors: [
      TerminalRGB(hex: 0x14191D), TerminalRGB(hex: 0xA74532),
      TerminalRGB(hex: 0x57BF38), TerminalRGB(hex: 0xC7C43F),
      TerminalRGB(hex: 0x2E43C0), TerminalRGB(hex: 0xB249B8),
      TerminalRGB(hex: 0x59C2C5), TerminalRGB(hex: 0xC7C7C7),
      TerminalRGB(hex: 0x686868), TerminalRGB(hex: 0xD07F78),
      TerminalRGB(hex: 0x81E398), TerminalRGB(hex: 0xEAE14A),
      TerminalRGB(hex: 0xA7AAED), TerminalRGB(hex: 0xD482DC),
      TerminalRGB(hex: 0x8EFAFD), TerminalRGB(hex: 0xFFFFFF),
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

  static func resolved(for colorScheme: ColorScheme, preferences: TerminalPreferences)
    -> TerminalColorPalette
  {
    colorScheme == .dark ? (preferences.darkColorPalette ?? iTermDark) : paperLight
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

private extension Double {
  func clamped(to range: ClosedRange<Double>) -> Double {
    min(range.upperBound, max(range.lowerBound, self))
  }
}

enum ITermProfileImportError: LocalizedError {
  case unavailable
  case preferencesUnavailable
  case selectedProfileUnavailable
  case colorUnavailable(String)

  var errorDescription: String? {
    switch self {
    case .unavailable: "iTerm2 is not installed."
    case .preferencesUnavailable: "Could not read iTerm2 preferences."
    case .selectedProfileUnavailable: "iTerm2 has no readable selected color profile."
    case .colorUnavailable(let name): "The iTerm2 profile is missing its \(name) color."
    }
  }
}

enum ITermProfileImporter {
  static var availability: Result<String, ITermProfileImportError> {
    guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil
    else { return .failure(.unavailable) }
    do {
      let profile = try selectedProfile()
      return .success((profile["Name"] as? String) ?? "selected profile")
    } catch let error as ITermProfileImportError {
      return .failure(error)
    } catch {
      return .failure(.preferencesUnavailable)
    }
  }

  static func selectedPalette() throws -> TerminalColorPalette {
    let profile = try selectedProfile()
    var palette = TerminalColorPalette.iTermDark
    palette.background = try rgb(named: "Background", in: profile)
    palette.foreground = try rgb(named: "Foreground", in: profile)
    palette.cursor = try optionalRGB(named: "Cursor", in: profile) ?? palette.cursor
    palette.cursorText = try optionalRGB(named: "Cursor Text", in: profile) ?? palette.cursorText
    palette.selectionBackground = try optionalRGB(named: "Selection", in: profile)
      ?? palette.selectionBackground
    palette.ansiColors = try (0..<16).map { index in
      try rgb(named: "Ansi \(index)", in: profile)
    }
    return palette
  }

  private static func selectedProfile() throws -> [String: Any] {
    guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil
    else { throw ITermProfileImportError.unavailable }
    let preferencesURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Preferences/com.googlecode.iterm2.plist")
    guard let data = try? Data(contentsOf: preferencesURL),
      let root = try? PropertyListSerialization.propertyList(from: data, format: nil),
      let preferences = root as? [String: Any],
      let profiles = preferences["New Bookmarks"] as? [[String: Any]], !profiles.isEmpty
    else { throw ITermProfileImportError.preferencesUnavailable }
    if let guid = preferences["Default Bookmark Guid"] as? String,
      let profile = profiles.first(where: { ($0["Guid"] as? String) == guid })
    { return profile }
    if profiles.count == 1, let profile = profiles.first { return profile }
    throw ITermProfileImportError.selectedProfileUnavailable
  }

  private static func rgb(named name: String, in profile: [String: Any]) throws -> TerminalRGB {
    guard let color = try optionalRGB(named: name, in: profile) else {
      throw ITermProfileImportError.colorUnavailable(name)
    }
    return color
  }

  private static func optionalRGB(named name: String, in profile: [String: Any]) throws -> TerminalRGB? {
    guard let components = profile["\(name) Color"] as? [String: Any] else { return nil }
    func component(_ key: String) -> Double? {
      if let value = components[key] as? NSNumber { return value.doubleValue }
      if let value = components[key] as? String { return Double(value) }
      return nil
    }
    guard let red = component("Red Component"), let green = component("Green Component"),
      let blue = component("Blue Component")
    else { throw ITermProfileImportError.colorUnavailable(name) }
    func byte(_ value: Double) -> UInt8 {
      let normalized = value > 1 ? value / 255 : value
      return UInt8((normalized * 255).rounded().clamped(to: 0...255))
    }
    return TerminalRGB(red: byte(red), green: byte(green), blue: byte(blue))
  }
}
