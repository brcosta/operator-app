import AppKit
import CoreText
import Foundation

struct TerminalPreferences: Codable, Hashable {
  static let defaultFontSize = 13.0
  static let fontSizeRange = 9.0...32.0
  static let scrollbackRange = 1_000...100_000
  static let scrollbackOptions = [5_000, 10_000, 20_000, 50_000, 100_000]
  static let `default` = TerminalPreferences()

  var fontFamily: String?
  var fontSize: Double
  var ligaturesEnabled: Bool
  var scrollbackLines: Int

  init(
    fontFamily: String? = nil, fontSize: Double = defaultFontSize,
    ligaturesEnabled: Bool = false, scrollbackLines: Int = 20_000
  ) {
    self.fontFamily = Self.normalizedFontFamily(fontFamily)
    self.fontSize = Self.normalizedFontSize(fontSize)
    self.ligaturesEnabled = ligaturesEnabled
    self.scrollbackLines = Self.normalizedScrollback(scrollbackLines)
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      fontFamily: try? container.decodeIfPresent(String.self, forKey: .fontFamily),
      fontSize: (try? container.decodeIfPresent(Double.self, forKey: .fontSize))
        ?? Self.defaultFontSize,
      ligaturesEnabled: (try? container.decodeIfPresent(Bool.self, forKey: .ligaturesEnabled))
        ?? false,
      scrollbackLines: (try? container.decodeIfPresent(Int.self, forKey: .scrollbackLines))
        ?? 20_000)
  }

  var normalized: TerminalPreferences {
    TerminalPreferences(
      fontFamily: fontFamily, fontSize: fontSize, ligaturesEnabled: ligaturesEnabled,
      scrollbackLines: scrollbackLines)
  }

  private static func normalizedFontFamily(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 120 else { return nil }
    return trimmed
  }

  private static func normalizedFontSize(_ value: Double) -> Double {
    guard value.isFinite else { return defaultFontSize }
    return min(fontSizeRange.upperBound, max(fontSizeRange.lowerBound, value))
  }

  private static func normalizedScrollback(_ value: Int) -> Int {
    min(scrollbackRange.upperBound, max(scrollbackRange.lowerBound, value))
  }
}

enum TerminalFontCatalog {
  static let systemMonospacedTitle = "System Monospaced"

  static let availableFamilies: [String] = {
    let manager = NSFontManager.shared
    return manager.availableFontFamilies.filter { family in
      guard
        let font = manager.font(
          withFamily: family, traits: [], weight: 5,
          size: TerminalPreferences.defaultFontSize)
      else { return false }
      return font.fontDescriptor.symbolicTraits.contains(.monoSpace)
    }
    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }()
}

enum TerminalFontResolver {
  static func font(for rawPreferences: TerminalPreferences) -> NSFont {
    let preferences = rawPreferences.normalized
    let size = CGFloat(preferences.fontSize)
    let selected =
      preferences.fontFamily.flatMap { family in
        NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
          ?? NSFont(name: family, size: size)
      }
    let base: NSFont
    if let selected, selected.fontDescriptor.symbolicTraits.contains(.monoSpace) {
      base = selected
    } else {
      base = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    let featureSettings: [[NSFontDescriptor.FeatureKey: Int]] = [
      [
        .typeIdentifier: kLigaturesType,
        .selectorIdentifier:
          preferences.ligaturesEnabled
          ? kCommonLigaturesOnSelector : kCommonLigaturesOffSelector,
      ],
      [
        .typeIdentifier: kContextualAlternatesType,
        .selectorIdentifier:
          preferences.ligaturesEnabled
          ? kContextualAlternatesOnSelector : kContextualAlternatesOffSelector,
      ],
    ]
    let descriptor = base.fontDescriptor.addingAttributes([.featureSettings: featureSettings])
    return NSFont(descriptor: descriptor, size: size) ?? base
  }
}

struct TerminalFocusIntent: Equatable {
  private(set) var isPending = false

  mutating func request() {
    isPending = true
  }

  mutating func recordDelivery(succeeded: Bool) {
    if succeeded { isPending = false }
  }
}
