import SwiftUI

struct WorkspaceSidebar: View {
  @EnvironmentObject private var model: AppModel
  @Binding var selection: WorkspaceDestination?

  var body: some View {
    List(selection: $selection) {
      Section("工作区") {
        ForEach([WorkspaceDestination.shortcuts, .applications]) { destination in
          sidebarRow(destination)
        }
      }
      Section {
        sidebarRow(.settings)
      }
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(alignment: .leading, spacing: 7) {
        Label("小龙哥 Mac 哲学", systemImage: "capslock")
          .font(.subheadline.weight(.semibold))
        Text("左手，掌控 Mac 一切。")
          .font(.caption)
          .foregroundStyle(.secondary)
        if model.isPaused {
          Label("快捷键已暂停", systemImage: "pause.circle")
            .font(.caption)
            .foregroundStyle(AppVisualStyle.warning)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(AppVisualStyle.Spacing.large)
    }
    .accessibilityIdentifier("workspace.sidebar")
  }

  private func sidebarRow(_ destination: WorkspaceDestination) -> some View {
    Label(destination.title, systemImage: destination.symbol)
      .tag(destination)
      .accessibilityIdentifier("workspace.destination.\(destination.rawValue)")
  }
}
