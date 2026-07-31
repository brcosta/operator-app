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

  var keyEquivalent: KeyEquivalent {
    switch key {
    case ShortcutKey.leftArrow: .leftArrow
    case ShortcutKey.rightArrow: .rightArrow
    case ShortcutKey.upArrow: .upArrow
    case ShortcutKey.downArrow: .downArrow
    default: KeyEquivalent(key.lowercased().first ?? "?")
    }
  }

  var keyDisplayName: String { ShortcutKey.displayName(for: key) }

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

enum ShortcutKey {
  static let leftArrow = "leftArrow"
  static let rightArrow = "rightArrow"
  static let upArrow = "upArrow"
  static let downArrow = "downArrow"
  static let arrowKeys = [leftArrow, rightArrow, upArrow, downArrow]

  static func normalized(_ rawValue: String) -> String? {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return switch value.lowercased() {
    case "←", "left", "leftarrow": leftArrow
    case "→", "right", "rightarrow": rightArrow
    case "↑", "up", "uparrow": upArrow
    case "↓", "down", "downarrow": downArrow
    default: value.first.map { String($0).lowercased() }
    }
  }

  static func displayName(for key: String) -> String {
    switch key {
    case leftArrow: "←"
    case rightArrow: "→"
    case upArrow: "↑"
    case downArrow: "↓"
    default: key.uppercased()
    }
  }
}

extension View {
  func operatorShortcut(_ binding: ShortcutBinding) -> some View {
    keyboardShortcut(binding.keyEquivalent, modifiers: binding.modifiers)
  }
}

enum OperatorSettingsSection: String, CaseIterable, Identifiable {
  case general
  case terminal
  case colors
  case integrations
  case shortcuts
  case data

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: "General"
    case .terminal: "Terminal"
    case .colors: "Terminal Colors"
    case .integrations: "Privacy & Integrations"
    case .shortcuts: "Shortcuts"
    case .data: "Data & Diagnostics"
    }
  }

  var subtitle: String {
    switch self {
    case .general: "Appearance and workspace layout"
    case .terminal: "Typography, ligatures, and history"
    case .colors: "Dark palette and iTerm2 import"
    case .integrations: "Control optional harness and file integrations"
    case .shortcuts: "Keyboard commands for daily actions"
    case .data: "Configuration, backups, and support"
    }
  }

  var systemImage: String {
    switch self {
    case .general: "slider.horizontal.3"
    case .terminal: "terminal"
    case .colors: "paintpalette"
    case .integrations: "hand.raised"
    case .shortcuts: "keyboard"
    case .data: "externaldrive"
    }
  }
}

struct ShortcutSettingsView: View {
  @ObservedObject var store: StateStore
  let applyIntegrationPreferences: (OperatorIntegrationPreferences) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var selectedSection = OperatorSettingsSection.general
  @State private var operationMessage: String?
  @State private var operationFailed = false

  init(
    store: StateStore,
    applyIntegrationPreferences: @escaping (OperatorIntegrationPreferences) -> Void = { _ in }
  ) {
    self.store = store
    self.applyIntegrationPreferences = applyIntegrationPreferences
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("Settings").font(.title2.bold())
            .accessibilityIdentifier("operator.shortcuts.title")
          Text("Personalize Operator for your daily workflow.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(.horizontal, 22)
      .padding(.vertical, 18)

      Divider()

      HStack(spacing: 0) {
        settingsSidebar
        Divider()
        ZStack(alignment: .top) {
          ScrollView {
            selectedPage
              .frame(maxWidth: .infinity, alignment: .topLeading)
              .padding(24)
          }
          if let operationMessage {
            operationToast(operationMessage)
              .padding(.horizontal, 24)
              .padding(.top, 14)
              .transition(.move(edge: .top).combined(with: .opacity))
              .zIndex(2)
          }
        }
        .animation(.easeOut(duration: 0.18), value: operationMessage)
      }

      Divider()

      HStack {
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("operator.shortcuts.done")
      }
      .padding(.horizontal, 22)
      .padding(.vertical, 14)
    }
    .frame(width: 820, height: 620)
  }

  private var settingsSidebar: some View {
    VStack(alignment: .leading, spacing: 5) {
      ForEach(OperatorSettingsSection.allCases) { section in
        Button {
          selectedSection = section
        } label: {
          HStack(spacing: 11) {
            Image(systemName: section.systemImage)
              .font(.system(size: 15, weight: .medium))
              .frame(width: 20)
            Text(section.title)
              .font(.callout.weight(.medium))
            Spacer(minLength: 0)
          }
          .foregroundStyle(selectedSection == section ? Color.accentColor : Color.primary)
          .padding(.horizontal, 11)
          .padding(.vertical, 9)
          .background(
            selectedSection == section ? Color.accentColor.opacity(0.14) : .clear,
            in: RoundedRectangle(cornerRadius: 8)
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("operator.settings.section.\(section.rawValue)")
      }
      Spacer()
    }
    .padding(12)
    .frame(width: 210)
    .background(Color.primary.opacity(0.025))
  }

  @ViewBuilder private var selectedPage: some View {
    switch selectedSection {
    case .general:
      generalPage
    case .terminal:
      terminalPage
    case .colors:
      colorsPage
    case .integrations:
      integrationsPage
    case .shortcuts:
      shortcutsPage
    case .data:
      dataPage
    }
  }

  private var generalPage: some View {
    SettingsPage(
      title: OperatorSettingsSection.general.title,
      subtitle: OperatorSettingsSection.general.subtitle
    ) {
      GroupBox {
        VStack(spacing: 0) {
          SettingsControlRow(
            title: "Appearance",
            detail: "Follow macOS or keep Operator consistently light or dark."
          ) {
            Picker(
              "Appearance",
              selection: Binding(
                get: { store.state.appearance },
                set: { store.setAppearance($0) }
              )
            ) {
              ForEach(AppAppearancePreference.allCases) { appearance in
                Text(appearance.title).tag(appearance)
              }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 230)
            .accessibilityIdentifier("operator.settings.appearance")
          }
          Divider()
          SettingsControlRow(
            title: "Pane status bar",
            detail: "Show each terminal’s status above or below its pane."
          ) {
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
            .frame(width: 230)
          }
        }
      }
    }
  }

  private var terminalPage: some View {
    SettingsPage(
      title: OperatorSettingsSection.terminal.title,
      subtitle: OperatorSettingsSection.terminal.subtitle
    ) {
      GroupBox {
        VStack(spacing: 0) {
          SettingsControlRow(title: "Font", detail: "Use any installed monospaced font.") {
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
            .frame(width: 260)
            .accessibilityIdentifier("operator.settings.terminalFont")
          }
          Divider()
          SettingsControlRow(
            title: "Font size", detail: "Applied immediately to every open terminal."
          ) {
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
          SettingsControlRow(
            title: "Programming ligatures",
            detail: "Use ligatures and contextual alternates supported by the font."
          ) {
            Toggle("Programming ligatures", isOn: terminalLigatures)
              .labelsHidden()
              .toggleStyle(.switch)
              .accessibilityIdentifier("operator.settings.terminalLigatures")
          }
          Divider()
          SettingsControlRow(
            title: "Scrollback",
            detail: "Lower limits use less memory and keep long sessions responsive."
          ) {
            Picker("Scrollback lines", selection: terminalScrollback) {
              ForEach(TerminalPreferences.scrollbackOptions, id: \.self) { count in
                Text(count.formatted()).tag(count)
              }
            }
            .labelsHidden()
            .frame(width: 130)
            .accessibilityIdentifier("operator.settings.terminalScrollback")
          }
        }
      }
    }
  }

  private var colorsPage: some View {
    SettingsPage(
      title: OperatorSettingsSection.colors.title,
      subtitle: "Customize the dark terminal palette. Changes apply to every open dark-mode terminal."
    ) {
      GroupBox("Core colors") {
        VStack(spacing: 0) {
          SettingsControlRow(title: "Background", detail: "Terminal canvas behind command output.") {
            ColorPicker("Background", selection: terminalColorBinding(\.background))
              .labelsHidden()
          }
          Divider()
          SettingsControlRow(title: "Foreground", detail: "Default prompt and output text.") {
            ColorPicker("Foreground", selection: terminalColorBinding(\.foreground))
              .labelsHidden()
          }
          Divider()
          SettingsControlRow(title: "Cursor", detail: "Caret and selected text contrast.") {
            ColorPicker("Cursor", selection: terminalColorBinding(\.cursor))
              .labelsHidden()
          }
          Divider()
          SettingsControlRow(title: "Selection", detail: "Background used for selected terminal text.") {
            ColorPicker("Selection", selection: terminalColorBinding(\.selectionBackground))
              .labelsHidden()
          }
        }
      }
      GroupBox("ANSI colors") {
        Grid(horizontalSpacing: 18, verticalSpacing: 10) {
          GridRow {
            Text("Color").foregroundStyle(.secondary)
            Text("Normal").foregroundStyle(.secondary)
            Text("Bright").foregroundStyle(.secondary)
          }
          .font(.caption.weight(.semibold))
          ForEach(Array(ansiColorNames.enumerated()), id: \.offset) { index, name in
            GridRow {
              Text(name).font(.callout)
              ColorPicker("\(name) normal", selection: ansiColorBinding(index))
                .labelsHidden()
              ColorPicker("\(name) bright", selection: ansiColorBinding(index + 8))
                .labelsHidden()
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
      }
      GroupBox("iTerm2") {
        VStack(alignment: .leading, spacing: 10) {
          Text(iTermImportDescription)
            .font(.callout)
            .foregroundStyle(.secondary)
          HStack {
            Button("Import selected iTerm2 profile") { importITermColors() }
              .disabled(!canImportITermColors)
              .help(iTermImportDescription)
              .accessibilityIdentifier("operator.settings.importITermColors")
            Button("Restore Operator default") { restoreDefaultTerminalColors() }
              .accessibilityIdentifier("operator.settings.restoreTerminalColors")
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
      }
    }
  }

  private var integrationsPage: some View {
    SettingsPage(
      title: OperatorSettingsSection.integrations.title,
      subtitle:
        "Each integration is optional. Turning one off never modifies your global harness configuration."
    ) {
      GroupBox("Harness sessions") {
        VStack(spacing: 0) {
          SettingsControlRow(
            title: "Operator skill",
            detail:
              "Do not add Operator’s session-scoped guidance to new Claude Code or Codex sessions."
          ) {
            Toggle("Operator skill", isOn: integrationBinding(\.skillsEnabled))
              .labelsHidden().toggleStyle(.switch)
              .accessibilityIdentifier("operator.settings.skillsEnabled")
          }
          Divider()
          SettingsControlRow(
            title: "Harness hooks",
            detail:
              "Do not inject session-scoped lifecycle hooks into new Claude Code or Codex sessions."
          ) {
            Toggle("Harness hooks", isOn: integrationBinding(\.hooksEnabled))
              .labelsHidden().toggleStyle(.switch)
              .accessibilityIdentifier("operator.settings.hooksEnabled")
          }
        }
      }
      GroupBox("Local monitoring") {
        VStack(spacing: 0) {
          SettingsControlRow(
            title: "Native notifications",
            detail:
              "Suppress permission prompts and all Operator notifications until you turn this back on."
          ) {
            Toggle("Native notifications", isOn: integrationBinding(\.notificationsPermitted))
              .labelsHidden().toggleStyle(.switch)
              .accessibilityIdentifier("operator.settings.notificationsPermitted")
          }
          Divider()
          SettingsControlRow(
            title: "File watching",
            detail:
              "Stop live Git, source, Markdown, and terminal working-tree updates. You can still refresh manually."
          ) {
            Toggle("File watching", isOn: integrationBinding(\.fileWatchingEnabled))
              .labelsHidden().toggleStyle(.switch)
              .accessibilityIdentifier("operator.settings.fileWatchingEnabled")
          }
        }
      }
      Text(
        "Changes apply immediately. Skill and hook changes affect newly launched harnesses; existing sessions continue with the options they started with."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private var shortcutsPage: some View {
    SettingsPage(
      title: OperatorSettingsSection.shortcuts.title,
      subtitle: OperatorSettingsSection.shortcuts.subtitle
    ) {
      HStack {
        Text("Choose a key and the modifiers that should trigger each action.")
          .font(.callout)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Restore Defaults") { store.restoreDefaultShortcuts() }
      }
      GroupBox {
        VStack(spacing: 0) {
          HStack {
            Text("Action").frame(maxWidth: .infinity, alignment: .leading)
            Text("Key").frame(width: 82)
            Text("⌘").frame(width: 30)
            Text("⇧").frame(width: 30)
            Text("⌥").frame(width: 30)
            Text("⌃").frame(width: 30)
          }
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 12)
          .padding(.vertical, 9)
          Divider()
          ForEach(Array(ShortcutAction.allCases.enumerated()), id: \.element.id) {
            index, action in
            ShortcutRow(binding: store.shortcut(for: action)) { store.setShortcut($0) }
              .padding(.horizontal, 12)
              .padding(.vertical, 7)
            if index < ShortcutAction.allCases.count - 1 { Divider() }
          }
        }
      }
    }
  }

  private var dataPage: some View {
    SettingsPage(
      title: OperatorSettingsSection.data.title,
      subtitle: OperatorSettingsSection.data.subtitle
    ) {
      GroupBox("Storage") {
        VStack(alignment: .leading, spacing: 11) {
          LabeledContent("State") {
            Text(store.stateFileURL.path)
              .font(.caption.monospaced())
              .lineLimit(1)
              .truncationMode(.middle)
          }
          LabeledContent("Last-known-good backup") {
            Text(
              FileManager.default.fileExists(atPath: store.backupFileURL.path)
                ? "Available" : "Created after the first save"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          LabeledContent("Structured debug log") {
            Button("Reveal") {
              NSWorkspace.shared.activateFileViewerSelecting([OperatorDebugLog.logFileURL])
            }
            .buttonStyle(.link)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
      }
      GroupBox("Configuration") {
        VStack(alignment: .leading, spacing: 0) {
          SettingsActionRow(
            title: "Import configuration",
            detail: "Merge projects, preferences, launch profiles, and shortcuts from JSON.",
            buttonTitle: "Import…",
            action: importConfiguration)
          Divider()
          SettingsActionRow(
            title: "Export configuration",
            detail: "Create a portable JSON backup of your Operator configuration.",
            buttonTitle: "Export…",
            action: exportConfiguration)
          Divider()
          SettingsActionRow(
            title: "Export diagnostics",
            detail: "Create a support bundle without terminal output or secret environment values.",
            buttonTitle: "Export…",
            action: exportDiagnostics)
        }
      }
    }
  }

  private func operationToast(_ message: String) -> some View {
    Label(
      message,
      systemImage: operationFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    )
    .font(.callout.weight(.medium))
    .foregroundStyle(operationFailed ? Color.red : Color.green)
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder((operationFailed ? Color.red : Color.green).opacity(0.22))
    }
    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
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

  private var ansiColorNames: [String] {
    ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]
  }

  private var effectiveDarkPalette: TerminalColorPalette {
    store.state.terminalPreferences.darkColorPalette ?? .iTermDark
  }

  private var canImportITermColors: Bool {
    if case .success = ITermProfileImporter.availability { return true }
    return false
  }

  private var iTermImportDescription: String {
    switch ITermProfileImporter.availability {
    case .success(let name): "Import colors from iTerm2’s selected profile: \(name)."
    case .failure(let error): error.localizedDescription
    }
  }

  private func terminalColorBinding(
    _ keyPath: WritableKeyPath<TerminalColorPalette, TerminalRGB>
  ) -> Binding<Color> {
    Binding(
      get: { effectiveDarkPalette[keyPath: keyPath].swiftUIColor },
      set: { color in
        updateDarkTerminalPalette { $0[keyPath: keyPath] = TerminalRGB(color: color) }
      })
  }

  private func ansiColorBinding(_ index: Int) -> Binding<Color> {
    Binding(
      get: { effectiveDarkPalette.ansiColors[index].swiftUIColor },
      set: { color in
        updateDarkTerminalPalette { palette in
          guard palette.ansiColors.indices.contains(index) else { return }
          palette.ansiColors[index] = TerminalRGB(color: color)
        }
      })
  }

  private func updateDarkTerminalPalette(_ update: (inout TerminalColorPalette) -> Void) {
    var palette = effectiveDarkPalette
    update(&palette)
    updateTerminalPreferences { $0.darkColorPalette = palette }
  }

  private func importITermColors() {
    perform("Imported the selected iTerm2 color profile.") {
      let palette = try ITermProfileImporter.selectedPalette()
      updateTerminalPreferences { $0.darkColorPalette = palette }
    }
  }

  private func restoreDefaultTerminalColors() {
    updateTerminalPreferences { $0.darkColorPalette = nil }
    operationFailed = false
    operationMessage = "Restored Operator’s dark terminal palette."
  }

  private func updateTerminalPreferences(_ update: (inout TerminalPreferences) -> Void) {
    var preferences = store.state.terminalPreferences
    update(&preferences)
    store.setTerminalPreferences(preferences)
  }

  private func integrationBinding(
    _ keyPath: WritableKeyPath<OperatorIntegrationPreferences, Bool>
  ) -> Binding<Bool> {
    Binding(
      get: { store.state.integrationPreferences[keyPath: keyPath] },
      set: { value in
        var preferences = store.state.integrationPreferences
        preferences[keyPath: keyPath] = value
        applyIntegrationPreferences(preferences)
      })
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

private struct SettingsPage<Content: View>: View {
  let title: String
  let subtitle: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.title2.bold())
        Text(subtitle)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      content
    }
  }
}

private struct SettingsControlRow<Control: View>: View {
  let title: String
  let detail: String
  @ViewBuilder let control: Control

  var body: some View {
    HStack(spacing: 20) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.callout.weight(.medium))
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 16)
      control
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 13)
  }
}

private struct SettingsActionRow: View {
  let title: String
  let detail: String
  let buttonTitle: String
  let action: () -> Void

  var body: some View {
    HStack(spacing: 20) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.callout.weight(.medium))
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 16)
      Button(buttonTitle, action: action)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 13)
  }
}

private struct ShortcutRow: View {
  @State var binding: ShortcutBinding
  let save: (ShortcutBinding) -> Void

  var body: some View {
    HStack {
      Text(binding.action.title)
        .frame(maxWidth: .infinity, alignment: .leading)
      TextField(
        "Key",
        text: Binding(
          get: { binding.keyDisplayName },
          set: {
            if let key = ShortcutKey.normalized($0) {
              binding.key = key
              save(binding)
            }
          })
      )
      .frame(width: 44)
      .textFieldStyle(.roundedBorder)
      Menu {
        Section("Arrow keys") {
          shortcutKeyButton("Left Arrow", key: ShortcutKey.leftArrow)
          shortcutKeyButton("Right Arrow", key: ShortcutKey.rightArrow)
          shortcutKeyButton("Up Arrow", key: ShortcutKey.upArrow)
          shortcutKeyButton("Down Arrow", key: ShortcutKey.downArrow)
        }
      } label: {
        Image(systemName: "chevron.up.chevron.down")
          .frame(width: 18)
      }
      .menuStyle(.borderlessButton)
      .frame(width: 30)
      .help("Choose a special key")
      modifierToggle("Command", symbol: "⌘", isOn: $binding.command)
      modifierToggle("Shift", symbol: "⇧", isOn: $binding.shift)
      modifierToggle("Option", symbol: "⌥", isOn: $binding.option)
      modifierToggle("Control", symbol: "⌃", isOn: $binding.control)
    }
  }

  private func shortcutKeyButton(_ title: String, key: String) -> some View {
    Button(title) {
      binding.key = key
      save(binding)
    }
  }

  private func modifierToggle(_ name: String, symbol: String, isOn: Binding<Bool>) -> some View {
    Toggle(
      name,
      isOn: Binding(
        get: { isOn.wrappedValue },
        set: {
          isOn.wrappedValue = $0
          save(binding)
        })
    )
    .labelsHidden()
    .frame(width: 30)
    .help("\(name) (\(symbol))")
    .accessibilityLabel(name)
  }
}
