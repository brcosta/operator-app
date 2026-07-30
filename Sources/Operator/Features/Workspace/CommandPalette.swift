import SwiftUI

struct CommandPalette: View {
  @ObservedObject var store: StateStore
  @ObservedObject var controller: WorkspaceController
  let targetPaneID: UUID?
  let onDismiss: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var command = ""
  @State private var title = ""

  private var project: Project? {
    store.state.projects.first { $0.id == store.state.selectedProjectID }
  }
  private var workspace: Workspace? { project?.workspaces.first }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "terminal.fill")
          .font(.title2)
          .foregroundStyle(.tint)
          .frame(width: 34, height: 34)
          .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        VStack(alignment: .leading, spacing: 4) {
          Text("Run a custom command").font(.title2.bold())
            .accessibilityIdentifier("operator.commandPalette.title")
          Text("It will start in the active project’s workspace.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      VStack(alignment: .leading, spacing: 7) {
        Label("Command", systemImage: "chevron.left.forwardslash.chevron.right")
          .font(.subheadline.weight(.medium))
        TextField("e.g. codex, claude, or npm test", text: $command, axis: .vertical)
          .textFieldStyle(.roundedBorder).lineLimit(2...4)
      }
      .accessibilityIdentifier("operator.commandPalette.command")
      VStack(alignment: .leading, spacing: 7) {
        Label("Session name", systemImage: "tag")
          .font(.subheadline.weight(.medium))
        TextField("Optional — defaults to the command name", text: $title)
          .textFieldStyle(.roundedBorder)
      }
      .accessibilityIdentifier("operator.commandPalette.sessionTitle")
      HStack {
        Spacer()
        Button {
          dismiss()
          onDismiss()
        } label: {
          Label("Cancel", systemImage: "xmark")
        }
        .accessibilityIdentifier("operator.commandPalette.cancel")
        Button {
          run()
        } label: {
          Label("Run", systemImage: "play.fill")
        }
        .keyboardShortcut(.defaultAction)
        .disabled(
          command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || workspace == nil
        )
        .accessibilityIdentifier("operator.commandPalette.run")
      }
    }
    .padding(28).frame(width: 500)
  }

  private func run() {
    guard let project, let workspace else { return }
    let cleanCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedTitle =
      cleanTitle.isEmpty
      ? cleanCommand.components(separatedBy: .whitespaces).first ?? "Session" : cleanTitle
    controller.launch(
      LaunchRequest(
        title: resolvedTitle, command: cleanCommand, directory: workspace.directory,
        projectID: project.id, workspaceID: workspace.id), intoPane: targetPaneID)
    dismiss()
    onDismiss()
  }
}
