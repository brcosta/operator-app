import SwiftUI

struct ProjectManagerView: View {
  @ObservedObject var store: StateStore
  let controller: WorkspaceController
  let revealWorkspace: () -> Void
  @State private var deleteTarget: Project?

  private var managedProjects: [Project] {
    store.state.projects.sorted {
      ($0.lastOpenedAt ?? $0.createdAt) > ($1.lastOpenedAt ?? $1.createdAt)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("Project Manager").font(.title2.bold())
          Text("Open saved projects, control sidebar visibility, or delete saved metadata.")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("New Project") {
          revealWorkspace()
          NotificationCenter.default.post(name: .operatorNewProject, object: nil)
        }
      }
      .padding(20)

      if managedProjects.isEmpty {
        ContentUnavailableView(
          "No Saved Projects", systemImage: "folder",
          description: Text("Create a project to manage it here."))
      } else {
        List {
          ForEach(managedProjects, id: \Project.id) { project in projectRow(project) }
        }
      }
    }
    .frame(minWidth: 720, minHeight: 460)
    .alert(
      "Delete Saved Project Metadata?",
      isPresented: Binding(
        get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    ) {
      Button("Delete Metadata", role: OperatorAlertActionStyle.destructiveRole) {
        if let project = deleteTarget { controller.deleteProjectMetadata(project.id) }
        deleteTarget = nil
      }
      Button("Cancel", role: .cancel) { deleteTarget = nil }
    } message: {
      Text(
        "This removes saved project settings, layouts, task briefs, activity, and session recipes for \(deleteTarget?.name ?? "this project"). Running terminal processes are not terminated."
      )
    }
  }

  private func projectRow(_ project: Project) -> some View {
    HStack(spacing: 12) {
      ProjectIdentityMark(project: project, size: 26)
      VStack(alignment: .leading, spacing: 3) {
        Text(project.name).font(.headline)
        Text(project.workspaces.map(\.displayName).joined(separator: " · "))
          .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        Text(project.isShownInSidebar ? "Shown in sidebar" : "Hidden from sidebar")
          .font(.caption2)
          .foregroundStyle(project.isShownInSidebar ? Color.secondary : Color.orange)
      }
      Spacer(minLength: 12)
      Button("Open") {
        controller.openManagedProject(project.id)
        revealWorkspace()
      }
      if project.isShownInSidebar {
        Button("Remove from Sidebar") { controller.hideProjectFromSidebar(project.id) }
      } else {
        Button("Show in Sidebar") { store.showProjectInSidebar(project.id) }
      }
      Button("Delete Metadata…", role: .destructive) { deleteTarget = project }
    }
    .padding(.vertical, 5)
  }
}
