import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
  case newSession, closePane, splitPane, missionControl, changes, activity, taskBrief,
    newProject, previousPane, nextPane, previousProject, nextProject
  var id: String { rawValue }
  var title: String {
    switch self {
    case .newSession: "New Session"
    case .closePane: "Close Pane"
    case .splitPane: "Split Pane"
    case .missionControl: "Mission Control"
    case .changes: "Open Changes"
    case .activity: "Activity"
    case .taskBrief: "Task Brief"
    case .newProject: "New Project"
    case .previousPane: "Previous Pane"
    case .nextPane: "Next Pane"
    case .previousProject: "Previous Project"
    case .nextProject: "Next Project"
    }
  }
}

struct ShortcutBinding: Codable, Hashable, Identifiable {
  var action: ShortcutAction
  var key: String
  var command = true
  var shift = false
  var option = false
  var control = false
  var id: ShortcutAction { action }

  var modifiers: EventModifiers {
    var result: EventModifiers = []
    if command { result.insert(.command) }
    if shift { result.insert(.shift) }
    if option { result.insert(.option) }
    if control { result.insert(.control) }
    return result
  }

  static let defaults: [ShortcutBinding] = [
    .init(action: .newSession, key: "k"), .init(action: .closePane, key: "w"),
    .init(action: .splitPane, key: "\\"),
    .init(action: .missionControl, key: "m", shift: true),
    .init(action: .changes, key: "g", shift: true),
    .init(action: .activity, key: "a", shift: true),
    .init(action: .taskBrief, key: "b", shift: true),
    .init(action: .newProject, key: "n", shift: true),
    .init(action: .previousPane, key: ",", option: true),
    .init(action: .nextPane, key: ".", option: true),
    .init(action: .previousProject, key: "[", option: true),
    .init(action: .nextProject, key: "]", option: true),
  ]
}

extension View {
  func operatorShortcut(_ binding: ShortcutBinding) -> some View {
    keyboardShortcut(
      KeyEquivalent(binding.key.lowercased().first ?? "?"), modifiers: binding.modifiers)
  }
}

struct ShortcutSettingsView: View {
  @ObservedObject var store: StateStore
  @Environment(\.dismiss) private var dismiss
  @State private var operationMessage: String?
  @State private var operationFailed = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Settings").font(.title2.bold())
            .accessibilityIdentifier("operator.shortcuts.title")
          Text("Appearance, layout preferences, shortcuts, backups, and diagnostics")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Import…") { importConfiguration() }
        Button("Export…") { exportConfiguration() }
        Button("Diagnostics…") { exportDiagnostics() }
        Button("Restore Shortcut Defaults") { store.restoreDefaultShortcuts() }
      }
      if let operationMessage {
        Label(
          operationMessage,
          systemImage: operationFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
        )
        .font(.callout)
        .foregroundStyle(operationFailed ? .red : .green)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          (operationFailed ? Color.red : Color.green).opacity(0.08),
          in: RoundedRectangle(cornerRadius: 9))
      }
      GroupBox("Interface") {
        VStack(alignment: .leading, spacing: 14) {
          HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Appearance").font(.callout.weight(.medium))
              Text("Follow macOS or keep Operator consistently light or dark.")
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker(
              "Appearance",
              selection: Binding(
                get: { store.state.appearance },
                set: { store.setAppearance($0) }
              )
            ) {
              ForEach(AppAppearancePreference.allCases) { appearance in
                Label(appearance.title, systemImage: appearance.systemImage)
                  .tag(appearance)
              }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 250)
            .accessibilityIdentifier("operator.settings.appearance")
          }
          Divider()
          HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Pane status bar").font(.callout.weight(.medium))
              Text("Show each terminal’s status above or below its pane.")
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker(
              "Pane status bar position",
              selection: Binding(
                get: { store.state.paneStatusBarPosition ?? .top },
                set: { store.setPaneStatusBarPosition($0) }
              )
            ) {
              ForEach(PaneStatusBarPosition.allCases) { position in
                Text(position.title).tag(position)
              }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 250)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
      }
      GroupBox("Terminal") {
        VStack(alignment: .leading, spacing: 12) {
          HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Font").font(.callout.weight(.medium))
              Text("Use any installed monospaced font.")
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Terminal font", selection: terminalFontFamily) {
              Text(TerminalFontCatalog.systemMonospacedTitle).tag("")
              if let selected = store.state.terminalPreferences.fontFamily,
                !TerminalFontCatalog.availableFamilies.contains(selected)
              {
                Text("\(selected) — unavailable").tag(selected)
              }
              ForEach(TerminalFontCatalog.availableFamilies, id: \.self) { family in
                Text(family).tag(family)
              }
            }
            .labelsHidden()
            .frame(width: 250)
            .accessibilityIdentifier("operator.settings.terminalFont")
          }
          Divider()
          HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Font size").font(.callout.weight(.medium))
              Text("Applied immediately to every open terminal.")
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Stepper(
              value: terminalFontSize,
              in: TerminalPreferences.fontSizeRange,
              step: 1
            ) {
              Text("\(Int(store.state.terminalPreferences.fontSize)) pt")
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
            }
            .accessibilityIdentifier("operator.settings.terminalFontSize")
          }
          Divider()
          Toggle("Enable programming ligatures", isOn: terminalLigatures)
            .help("Uses ligatures and contextual alternates supported by the selected font.")
            .accessibilityIdentifier("operator.settings.terminalLigatures")
          Divider()
          HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Scrollback").font(.callout.weight(.medium))
              Text("Lower limits use less memory and keep long sessions responsive.")
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Scrollback lines", selection: terminalScrollback) {
              ForEach(TerminalPreferences.scrollbackOptions, id: \.self) { count in
                Text(count.formatted()).tag(count)
              }
            }
            .labelsHidden()
            .frame(width: 120)
            .accessibilityIdentifier("operator.settings.terminalScrollback")
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
      }
      GroupBox("Daily-driver data") {
        VStack(alignment: .leading, spacing: 7) {
          LabeledContent("State") {
            Text(store.stateFileURL.path).font(.caption.monospaced()).lineLimit(1)
              .truncationMode(.middle)
          }
          LabeledContent("Last-known-good backup") {
            Text(
              FileManager.default.fileExists(atPath: store.backupFileURL.path)
                ? "Available" : "Created after the first save"
            )
            .font(.caption).foregroundStyle(.secondary)
          }
          LabeledContent("Structured debug log") {
            Button("Reveal") {
              NSWorkspace.shared.activateFileViewerSelecting([OperatorDebugLog.logFileURL])
            }
            .buttonStyle(.link)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      Divider()
      Text("Keyboard Shortcuts").font(.headline)
      List(ShortcutAction.allCases) { action in
        ShortcutRow(binding: store.shortcut(for: action)) { store.setShortcut($0) }
      }
      HStack {
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("operator.shortcuts.done")
      }
    }
    .padding(24).frame(width: 620, height: 780)
  }

  private var terminalFontFamily: Binding<String> {
    Binding(
      get: { store.state.terminalPreferences.fontFamily ?? "" },
      set: { value in
        updateTerminalPreferences { preferences in
          preferences.fontFamily = value.isEmpty ? nil : value
        }
      })
  }

  private var terminalFontSize: Binding<Double> {
    Binding(
      get: { store.state.terminalPreferences.fontSize },
      set: { value in updateTerminalPreferences { $0.fontSize = value } })
  }

  private var terminalLigatures: Binding<Bool> {
    Binding(
      get: { store.state.terminalPreferences.ligaturesEnabled },
      set: { value in updateTerminalPreferences { $0.ligaturesEnabled = value } })
  }

  private var terminalScrollback: Binding<Int> {
    Binding(
      get: { store.state.terminalPreferences.scrollbackLines },
      set: { value in updateTerminalPreferences { $0.scrollbackLines = value } })
  }

  private func updateTerminalPreferences(_ update: (inout TerminalPreferences) -> Void) {
    var preferences = store.state.terminalPreferences
    update(&preferences)
    store.setTerminalPreferences(preferences)
  }

  private func exportConfiguration() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "operator-configuration.json"
    panel.allowedContentTypes = [.json]
    if panel.runModal() == .OK, let url = panel.url {
      perform("Configuration exported.") { try store.exportConfiguration(to: url) }
    }
  }

  private func importConfiguration() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url {
      perform("Configuration imported and merged.") { try store.importConfiguration(from: url) }
    }
  }

  private func exportDiagnostics() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "operator-diagnostics.json"
    panel.allowedContentTypes = [.json]
    if panel.runModal() == .OK, let url = panel.url {
      perform("Diagnostics exported.") { try OperatorDiagnostics.write(to: url, store: store) }
    }
  }

  private func perform(_ success: String, operation: () throws -> Void) {
    do {
      try operation()
      operationFailed = false
      operationMessage = success
    } catch {
      operationFailed = true
      operationMessage = error.localizedDescription
      OperatorDebugLog.record(
        "settings.operation.failed", error.localizedDescription, level: .error)
    }
  }
}

private struct ShortcutRow: View {
  @State var binding: ShortcutBinding
  let save: (ShortcutBinding) -> Void

  var body: some View {
    HStack {
      Text(binding.action.title).frame(width: 140, alignment: .leading)
      TextField(
        "Key",
        text: Binding(
          get: { binding.key },
          set: {
            binding.key = String($0.prefix(1)).lowercased()
            save(binding)
          })
      )
      .frame(width: 38).textFieldStyle(.roundedBorder)
      Toggle(
        "⌘",
        isOn: Binding(
          get: { binding.command },
          set: {
            binding.command = $0
            save(binding)
          })
      ).labelsHidden()
      Toggle(
        "⇧",
        isOn: Binding(
          get: { binding.shift },
          set: {
            binding.shift = $0
            save(binding)
          })
      ).labelsHidden()
      Toggle(
        "⌥",
        isOn: Binding(
          get: { binding.option },
          set: {
            binding.option = $0
            save(binding)
          })
      ).labelsHidden()
      Toggle(
        "⌃",
        isOn: Binding(
          get: { binding.control },
          set: {
            binding.control = $0
            save(binding)
          })
      ).labelsHidden()
    }
  }
}
