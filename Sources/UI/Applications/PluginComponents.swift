import AppKit
import SwiftUI

struct PluginToolCard: View {
  @EnvironmentObject private var model: AppModel
  @Binding var item: ShortcutItem

  var body: some View {
    VStack(alignment: .leading, spacing: 11) {
      HStack(alignment: .center, spacing: 12) {
        IconBadge(systemImage: pluginIconName, tint: pluginTint, size: 44, iconSize: 18)

        VStack(alignment: .leading, spacing: 6) {
          InlineTextField(
            text: Binding(
              get: { item.name },
              set: { value in
                item.name = value.isEmpty ? "未命名插件" : value
                model.selectedID = item.id
                model.saveOnly()
              }
            ),
            placeholder: "插件名称",
            strong: true
          )
          .padding(.horizontal, -9)

        }

        Spacer()

        Button {
          model.runItem(item.id)
        } label: {
          Label("运行", systemImage: "play.fill")
            .labelStyle(.iconOnly)
        }
        .buttonStyle(GlassLabelButtonStyle(tint: teal, prominent: true))
        .help("运行")

        Toggle(
          "",
          isOn: Binding(
            get: { item.enabled },
            set: { value in
              item.enabled = value
              model.selectedID = item.id
              model.saveAndReload()
            }
          )
        )
        .toggleStyle(.switch)
      }

      HStack(spacing: 10) {
        HotkeyCell(
          text: item.displayHotkey,
          active: model.isRecording(item.id),
          recordingOwnerID: model.isRecording(item.id) ? model.shortcutRecordingSessionID : nil,
          onKeyDown: { event, ownerID in model.applyRecorded(event, ownerID: ownerID) }
        ) {
          model.selectedID = item.id
          model.startRecording(itemID: item.id)
        }
        .frame(width: 126)
        .padding(.leading, -8)

        TextField(
          "plugin:xxx.sh",
          text: Binding(
            get: { item.target },
            set: { value in
              item.target = value
              model.selectedID = item.id
              model.saveAndScheduleHotkeyReload()
            }
          )
        )
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .textFieldStyle(.plain)
        .foregroundStyle(ink)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(
          AppVisualStyle.surface.opacity(0.86),
          in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(line.opacity(0.72), lineWidth: 1))
      }

      TextField(
        "插件说明",
        text: Binding(
          get: { item.note },
          set: { value in
            item.note = value
            model.selectedID = item.id
            model.saveOnly()
          }
        )
      )
      .font(.system(size: 12, weight: .medium))
      .textFieldStyle(.plain)
      .foregroundStyle(muted)
      .padding(.horizontal, 10)
      .frame(height: 30)
      .background(
        AppVisualStyle.surface.opacity(0.62),
        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private var pluginIconName: String {
    if item.name.contains("麦克风") { return "mic.fill" }
    if item.name.contains("输入法") { return "character.cursor.ibeam" }
    return "puzzlepiece.extension.fill"
  }

  private var pluginTint: Color {
    if item.name.contains("麦克风") { return ruby }
    if item.name.contains("输入法") { return teal }
    return violet
  }
}

struct PluginChip: View {
  let text: String
  let color: Color

  var body: some View {
    Text(text)
      .font(.system(size: 10, weight: .medium, design: .rounded))
      .foregroundStyle(color)
      .padding(.horizontal, 8)
      .frame(height: 22)
      .background(color.opacity(0.09), in: Capsule())
  }
}

struct PluginPermissionNotice: View {
  let message: String
  let action: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Label(message, systemImage: "figure.stand")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(ink)
        .lineLimit(1)

      Spacer(minLength: 8)

      Button(action: action) {
        Label("立即授权", systemImage: "lock.open.fill")
          .font(.system(size: 12, weight: .semibold))
      }
      .buttonStyle(GlassLabelButtonStyle(tint: amber))
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(
      amber.opacity(0.10),
      in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(amber.opacity(0.22), lineWidth: 1)
    )
  }
}

struct EmptyPluginView: View {
  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "shippingbox")
        .font(.system(size: 34, weight: .semibold))
        .foregroundStyle(accent)
      Text("暂无脚本插件")
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(ink)
      Text("普通使用不需要新建插件。")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(muted)
    }
    .frame(maxWidth: .infinity, minHeight: 260)
  }
}

struct SystemPreferredStrip: View {
  let items: [ShortcutItem]

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "arrow.triangle.branch")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(teal)
        .frame(width: 30, height: 30)
        .background(teal.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))

      VStack(alignment: .leading, spacing: 6) {
        Text("已改为系统级调用")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(ink)
        Text(items.map(\.name).joined(separator: "、"))
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(muted)
          .lineLimit(2)
      }

      Spacer()
    }
    .padding(13)
    .background(
      AppVisualStyle.surface.opacity(0.72),
      in: RoundedRectangle(cornerRadius: 15, style: .continuous)
    )
    .overlay(RoundedRectangle(cornerRadius: 15).stroke(AppVisualStyle.separator, lineWidth: 1))
  }
}
