import AppKit
import Foundation

/// A compact, testable representation of the state shown outside the main window.
struct NativeSurfaceState: Equatable {
  let runningHarnessCount: Int
  let pendingQuestionCount: Int
  let failedHarnessCount: Int
  let progress: Double?

  init(
    runningHarnessCount: Int, pendingQuestionCount: Int, failedHarnessCount: Int,
    progressValues: [Double]
  ) {
    self.runningHarnessCount = runningHarnessCount
    self.pendingQuestionCount = pendingQuestionCount
    self.failedHarnessCount = failedHarnessCount
    let valid = progressValues.filter { $0.isFinite }.map { min(1, max(0, $0)) }
    progress = valid.isEmpty ? nil : valid.reduce(0, +) / Double(valid.count)
  }

  var dockBadgeLabel: String? {
    if pendingQuestionCount > 0 { return "\(pendingQuestionCount)" }
    if failedHarnessCount > 0 { return "!" }
    return nil
  }

  var menuSummary: String {
    var parts: [String] = []
    parts.append(
      runningHarnessCount == 1 ? "1 harness running" : "\(runningHarnessCount) harnesses running")
    if pendingQuestionCount > 0 {
      parts.append(pendingQuestionCount == 1 ? "1 question" : "\(pendingQuestionCount) questions")
    }
    if failedHarnessCount > 0 {
      parts.append(
        failedHarnessCount == 1 ? "1 needs attention" : "\(failedHarnessCount) need attention")
    }
    return parts.joined(separator: " · ")
  }

  var statusItemSymbolName: String {
    if pendingQuestionCount > 0 { return "questionmark.bubble.fill" }
    if failedHarnessCount > 0 { return "exclamationmark.triangle.fill" }
    return runningHarnessCount > 0 ? "terminal.fill" : "terminal"
  }
}

@MainActor
final class OperatorSystemSurfaces: NSObject {
  private weak var appDelegate: OperatorAppDelegate?
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

  init(appDelegate: OperatorAppDelegate) {
    self.appDelegate = appDelegate
    super.init()
    statusItem.button?.imagePosition = .imageOnly
    statusItem.button?.setAccessibilityLabel("Operator control center")
  }

  deinit { NSStatusBar.system.removeStatusItem(statusItem) }

  func update(state: NativeSurfaceState, questions: [HarnessQuestion], sessions: [TerminalSession])
  {
    let symbol = NSImage(
      systemSymbolName: state.statusItemSymbolName, accessibilityDescription: "Operator")
    symbol?.isTemplate = true
    statusItem.button?.image = symbol
    statusItem.button?.toolTip = state.menuSummary
    statusItem.menu = makeMenu(state: state, questions: questions, sessions: sessions)

    NSApp.dockTile.badgeLabel = state.dockBadgeLabel
    if let progress = state.progress, state.runningHarnessCount > 0 {
      NSApp.dockTile.contentView = DockProgressView(
        icon: NSApp.applicationIconImage, progress: progress)
    } else {
      NSApp.dockTile.contentView = nil
    }
    NSApp.dockTile.display()
  }

  private func makeMenu(
    state: NativeSurfaceState, questions: [HarnessQuestion], sessions: [TerminalSession]
  ) -> NSMenu {
    let menu = NSMenu()
    let summary = NSMenuItem(title: state.menuSummary, action: nil, keyEquivalent: "")
    summary.isEnabled = false
    menu.addItem(summary)
    menu.addItem(.separator())
    menu.addItem(withTitle: "Open Operator", action: #selector(openOperator), keyEquivalent: "")
    menu.addItem(withTitle: "New Session", action: #selector(newSession), keyEquivalent: "n")

    let sessionTitles = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.title) })
    let pending = questions.prefix(5)
    if !pending.isEmpty {
      menu.addItem(.separator())
      for question in pending {
        let title = sessionTitles[question.sessionID] ?? "Harness"
        let item = NSMenuItem(
          title: "Focus \(title): \(question.message)", action: #selector(focusQuestion(_:)),
          keyEquivalent: "")
        item.representedObject = question.id.uuidString
        item.toolTip = question.message
        menu.addItem(item)
      }
    }

    menu.addItem(.separator())
    menu.addItem(
      withTitle: "Quit Operator", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
    )
    return menu
  }

  @objc private func openOperator() { appDelegate?.showWorkspace() }

  @objc private func newSession() {
    appDelegate?.showWorkspace()
    NotificationCenter.default.post(name: .operatorNewSession, object: nil)
  }

  @objc private func focusQuestion(_ item: NSMenuItem) {
    guard let rawID = item.representedObject as? String, let id = UUID(uuidString: rawID) else {
      return
    }
    appDelegate?.focusQuestion(id: id)
  }
}

private final class DockProgressView: NSView {
  private let icon: NSImage?
  private let progress: Double

  init(icon: NSImage?, progress: Double) {
    self.icon = icon
    self.progress = progress
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) { nil }

  override func draw(_ dirtyRect: NSRect) {
    icon?.draw(in: bounds)
    let diameter = min(bounds.width, bounds.height) * 0.38
    let ring = NSRect(x: bounds.maxX - diameter - 5, y: 5, width: diameter, height: diameter)
    NSColor.windowBackgroundColor.withAlphaComponent(0.88).setFill()
    NSBezierPath(ovalIn: ring).fill()
    let path = NSBezierPath()
    path.appendArc(
      withCenter: NSPoint(x: ring.midX, y: ring.midY), radius: ring.width / 2 - 3, startAngle: 90,
      endAngle: 90 - CGFloat(progress) * 360, clockwise: true)
    path.lineWidth = 4
    NSColor.controlAccentColor.setStroke()
    path.stroke()
  }
}
