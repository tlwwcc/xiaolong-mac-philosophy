import AppKit
import SwiftUI

/// The same signed app owns the GUI and CLI. This page never launches shell commands.
struct AutomationSettingsView: View {
  @State private var copied = false

  @State private var copyFailed = false

  private var helpCommand: String {
    "'\(AutomationDiscovery.installedExecutablePath)' --cli --help"
  }

  private var assistantInstructions: String { AutomationDiscovery.aiSetupPrompt }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AppVisualStyle.Spacing.section) {
        VStack(alignment: .leading, spacing: 8) {
          Label("CLI", systemImage: "terminal")
            .font(.title2.weight(.semibold))
          Text("把想做的事告诉 Codex 或其他能运行本机命令的 AI。")
            .foregroundStyle(.secondary)
        }
        SettingsGroup(title: "只需说出你的想法") {
          Text("“给 Safari 加一个快捷键”")
          Text("“把截图快捷键改一下”")
          Text("“看看有哪些功能，怎么用”")
          Divider()
          Button {
            NSPasteboard.general.clearContents()
            copied = NSPasteboard.general.setString(assistantInstructions, forType: .string)
            copyFailed = !copied
          } label: {
            Label(
              copied ? "已复制，发给你的 AI" : "复制给 AI 的说明",
              systemImage: copied ? "checkmark" : "doc.on.doc")
          }
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("automation.copyInstructions")
          if copyFailed {
            Text("复制失败，可展开下方说明手动复制。")
              .font(.caption)
              .foregroundStyle(AppVisualStyle.warning)
          }
        }
        SettingsGroup(title: "由同一个 App 管理") {
          Text("界面和命令行使用同一份本机配置。具体能力以当前版本的命令帮助为准。")
            .font(.callout)
            .foregroundStyle(.secondary)
          DisclosureGroup("命令入口与完整说明") {
            Text(assistantInstructions + "\n\n命令帮助：\n" + helpCommand)
              .font(.system(.caption, design: .monospaced))
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
              .padding(.top, 8)
          }
        }
      }
      .frame(maxWidth: AppVisualStyle.Layout.readableWidth, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .top)
      .padding(AppVisualStyle.Spacing.page)
    }
    .accessibilityIdentifier("settings.automation")
  }
}
