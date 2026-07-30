import SwiftUI

struct ActivityTimelineView: View {
  @ObservedObject var controller: WorkspaceController
  let setNotificationsEnabled: (Bool) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var selectedProjectID: UUID?
  @State private var section = 0
  private var store: StateStore { controller.store }

  private var events: [ActivityEvent] {
    guard let selectedProjectID else { return store.state.activity }
    return store.state.activity.filter { $0.projectID == selectedProjectID }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        VStack(alignment: .leading) {
          Text("Agent Activity").font(.title2.bold())
            .accessibilityIdentifier("operator.activity.title")
          Text("Launches, task updates, file changes, and session outcomes.").foregroundStyle(
            .secondary)
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 2) {
          Toggle(
            "Failure alerts for this run",
            isOn: Binding(get: { store.state.notificationsEnabled }, set: setNotificationsEnabled)
          )
          .toggleStyle(.switch)
          Text("Always off when Operator starts")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      Picker("Scope", selection: $selectedProjectID) {
        Text("All projects").tag(Optional<UUID>.none)
        ForEach(store.state.projects) { project in
          Text(project.displayName).tag(Optional(project.id))
        }
      }
      .pickerStyle(.menu)
      Picker("View", selection: $section) {
        Text("Activity").tag(0)
        Text("Harness Events").tag(1)
      }.pickerStyle(.segmented)
      if section == 0 {
        activityList
      } else {
        interactionList
      }
      HStack {
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("operator.activity.done")
      }
    }
    .padding(24).frame(width: 680, height: 540)
  }

  private var activityList: some View {
    List(events) { event in
      HStack(alignment: .top, spacing: 12) {
        let project = project(for: event.projectID)
        RoundedRectangle(cornerRadius: 2)
          .fill(project?.accent.color ?? color(for: event.kind))
          .frame(width: 3)
        HarnessIdentityMark(kind: controller.harnessKind(for: event.sessionID))
          .frame(width: 18)
        Image(systemName: event.kind.symbolName)
          .foregroundStyle(project?.accent.color ?? color(for: event.kind))
          .frame(width: 18)
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            Text(event.title).fontWeight(.medium)
            if let project {
              Text(project.displayName).font(.caption).foregroundStyle(project.accent.color)
            }
          }
          Text(event.detail).foregroundStyle(.secondary)
        }
        Spacer()
        Text(event.date, style: .relative).font(.caption).foregroundStyle(.secondary)
      }.padding(.vertical, 3)
    }
  }

  private var interactionList: some View {
    List(
      controller.interactions.filter {
        selectedProjectID == nil || $0.projectID == selectedProjectID
      }
    ) { event in
      HStack(alignment: .top, spacing: 12) {
        let project = project(for: event.projectID)
        RoundedRectangle(cornerRadius: 2)
          .fill(project?.accent.color ?? .secondary)
          .frame(width: 3)
        HarnessIdentityMark(kind: controller.harnessKind(for: event.sessionID))
          .frame(width: 18)
        Image(systemName: symbol(for: event.kind))
          .foregroundStyle(project?.accent.color ?? .secondary)
          .frame(width: 18)
        HStack(alignment: .top, spacing: 12) {
          VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
              Text(event.kind.rawValue).fontWeight(.medium)
              if let project {
                Text(project.displayName).font(.caption).foregroundStyle(project.accent.color)
              }
            }
            Text(event.message).foregroundStyle(.secondary)
          }
          Spacer()
          Text(event.date, style: .relative).font(.caption).foregroundStyle(.secondary)
        }
      }.padding(.vertical, 3)
    }
  }

  private func symbol(for kind: HarnessEventKind) -> String {
    switch kind {
    case .progress: "chart.bar.fill"
    case .question: "questionmark.bubble.fill"
    case .childStarted: "person.badge.plus"
    case .childFinished: "person.badge.minus"
    case .taskFinished: "checkmark.circle.fill"
    case .artifact: "shippingbox.fill"
    }
  }

  private func color(for kind: ActivityKind) -> Color {
    switch kind {
    case .failed: .red
    case .filesChanged: .orange
    case .launched: .green
    default: .secondary
    }
  }

  private func project(for id: UUID?) -> Project? {
    guard let id else { return nil }
    return store.state.projects.first { $0.id == id }
  }
}

struct TaskBriefEditor: View {
  @ObservedObject var controller: WorkspaceController
  let session: TerminalSession
  @Environment(\.dismiss) private var dismiss
  @State private var objective = ""
  @State private var constraints = ""
  @State private var acceptanceCriteria = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Task Brief").font(.title2.bold())
      Text(session.title).foregroundStyle(.secondary)
      TextField("Objective", text: $objective, axis: .vertical).lineLimit(3...6)
      TextField("Constraints and context", text: $constraints, axis: .vertical).lineLimit(3...6)
      TextField("Acceptance criteria", text: $acceptanceCriteria, axis: .vertical).lineLimit(3...6)
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
        Button("Save Brief") {
          controller.saveTaskBrief(
            for: session, objective: objective, constraints: constraints,
            acceptanceCriteria: acceptanceCriteria)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24).frame(width: 560)
    .onAppear {
      guard let brief = controller.taskBrief(for: session) else { return }
      objective = brief.objective
      constraints = brief.constraints
      acceptanceCriteria = brief.acceptanceCriteria
    }
  }
}

struct SessionRadarButton: View {
  let files: [GitChangedFile]
  @State private var isPresented = false

  private var presentation: SessionFileRadarPresentation {
    SessionFileRadarPresentation(files: files)
  }

  var body: some View {
    if !presentation.isEmpty {
      Button {
        isPresented.toggle()
      } label: {
        Label("\(files.count)", systemImage: "doc.badge.gearshape")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.orange)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(Color.orange.opacity(isPresented ? 0.18 : 0.1), in: Capsule())
      }
      .buttonStyle(.plain)
      .contentShape(Capsule())
      .help("\(presentation.summary). Show details.")
      .accessibilityLabel(presentation.accessibilityLabel)
      .accessibilityIdentifier("operator.sessionFileRadar")
      .popover(isPresented: $isPresented, arrowEdge: .bottom) {
        SessionRadarPopover(presentation: presentation)
      }
      .onChange(of: presentation.isEmpty) { _, isEmpty in
        if isEmpty { isPresented = false }
      }
    }
  }
}

private struct SessionRadarPopover: View {
  let presentation: SessionFileRadarPresentation

  private var listHeight: CGFloat {
    let sectionHeaders = CGFloat(presentation.sections.count) * 26
    let fileRows = CGFloat(presentation.visibleFiles.count) * 27
    let overflowRow: CGFloat = presentation.overflowCount > 0 ? 24 : 0
    return min(max(sectionHeaders + fileRows + overflowRow, 72), 340)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        Image(systemName: "doc.badge.gearshape")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(.orange)
          .frame(width: 28, height: 28)
          .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        VStack(alignment: .leading, spacing: 2) {
          Text(presentation.summary).font(.headline)
          Text("Live changes in this terminal’s Git worktree")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Divider()

      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          ForEach(presentation.sections) { section in
            VStack(alignment: .leading, spacing: 6) {
              Text(section.kind.rawValue.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
              ForEach(section.files) { file in
                HStack(spacing: 9) {
                  Text(file.status.trimmingCharacters(in: .whitespaces))
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(.orange)
                    .frame(minWidth: 20, alignment: .leading)
                  Text(file.path)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(file.path)
                }
              }
            }
          }
          if presentation.overflowCount > 0 {
            Text("+ \(presentation.overflowCount) more files")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(height: listHeight)

      HStack(spacing: 5) {
        Image(systemName: "eye")
        Text("Read-only · updates automatically")
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
    }
    .padding(16)
    .frame(width: 430)
  }
}
