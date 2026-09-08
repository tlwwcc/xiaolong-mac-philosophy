import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CommandWProtectionSettingsView: View {
  @EnvironmentObject private var model: AppModel
  @State private var selected = CommandWProtectionPolicy.load().bundleIDs
  @State private var selectionError: String?

  private var displayedIDs: [String] {
    Array(selected.union(["com.microsoft.edgemac", "com.apple.Safari"])).sorted()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("屏蔽所选软件中的 ⌘W，避免误关标签页或窗口。")
        .font(.callout)
      ForEach(displayedIDs, id: \.self) { bundleID in
        Toggle(
          isOn: Binding(
            get: { selected.contains(bundleID) },
            set: { enabled in
              if enabled { selected.insert(bundleID) } else { selected.remove(bundleID) }
              save()
            }
          )
        ) {
          HStack(spacing: 8) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
              Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: 22, height: 22)
              Text(FileManager.default.displayName(atPath: url.path))
            } else {
              Text(
                bundleID == "com.apple.Safari"
                  ? "Safari" : bundleID == "com.microsoft.edgemac" ? "Microsoft Edge" : bundleID)
            }
          }
        }
        .toggleStyle(.switch)
      }
      Button("添加软件…", action: addApplication)
      Text("只屏蔽 ⌘W；菜单和关闭按钮仍可用。取消勾选即可恢复。")
        .font(.caption).foregroundStyle(.secondary)
      if !selected.isEmpty {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
          Text(model.commandWProtectionStatus)
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      if let selectionError {
        Text(selectionError).font(.caption).foregroundStyle(.red)
      }
    }
  }

  private func save() {
    UserDefaults.standard.set(selected.sorted(), forKey: CommandWProtectionPolicy.defaultsKey)
    model.reloadHotkeys()
  }

  private func addApplication() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.application]
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.prompt = "添加"
    guard panel.runModal() == .OK else { return }
    selectionError = nil
    for url in panel.urls {
      guard let id = Bundle(url: url)?.bundleIdentifier, !id.isEmpty else {
        selectionError = "无法识别所选软件，请选择有效的 App。"
        continue
      }
      selected.insert(id)
    }
    save()
  }
}
