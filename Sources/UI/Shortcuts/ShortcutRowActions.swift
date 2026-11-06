import AppKit
import SwiftUI

struct ShortcutFeatureCell: View {
  // Native Table hosts cells separately; their model must cross that boundary explicitly.
  @ObservedObject var model: AppModel
  let item: ShortcutItem
  let edit: (() -> Void)?
  let delete: () -> Void
  @State private var showingIssueDetail = false

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        HStack(spacing: 9) {
          ShortcutActionVisual(item: item, size: 30, iconSize: 13)

          VStack(alignment: .leading, spacing: 3) {
            Text(item.name)
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(ink)
              .lineLimit(2)
              .fixedSize(horizontal: false, vertical: true)

            if let subtitle = shortcutActionSubtitle(item) {
              Text(subtitle)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(muted)
                .lineLimit(1)
            }
          }

          Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)

        Menu {
          shortcutRowMenuContent(model: model, item: item, edit: edit, delete: delete)
        } label: {
          Image(systemName: "ellipsis.circle")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(muted)
            .frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 24)
        .accessibilityIdentifier("shortcut.feature.\(item.id)")
        .accessibilityLabel(featureAccessibilityLabel)
        .accessibilityHint("按 Return 或空格打开菜单")
        .help("\(item.name)：打开操作菜单")

      }

      if let issue = model.shortcutIssue(for: item) {
        Button {
          showingIssueDetail = true
        } label: {
          ShortcutIssueChip(issue: issue)
        }
        .buttonStyle(.plain)
        .help("查看详情")
        .accessibilityLabel("\(issue.kind.label)，查看详情")
        .popover(isPresented: $showingIssueDetail, arrowEdge: .trailing) {
          ShortcutIssueDetailView(issue: issue)
        }
        .padding(.leading, 39)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.trailing, 8)
  }

  private var featureAccessibilityLabel: String {
    let category = shortcutGuideCategoryDisplayName(shortcutGuideCategory(for: item))
    return "\(item.name)，\(category)，操作菜单"
  }
}

@ViewBuilder
@MainActor
func shortcutRowMenuContent(
  model: AppModel,
  item: ShortcutItem,
  edit: (() -> Void)? = nil,
  delete: @escaping () -> Void
) -> some View {
  if let edit {
    Button(action: edit) {
      Label("编辑快捷键…", systemImage: "slider.horizontal.3")
    }
    Divider()
  }

  Button {
    model.presentSoftwareShortcutEditor(item: item)
  } label: {
    Label("选择 / 更换软件…", systemImage: "app.badge")
  }
  .disabled(!model.canChangeShortcutAction(id: item.id))
  .help(model.shortcutActionChangeHelp(id: item.id))

  Button {
    model.selectedID = item.id
    model.startRecording(itemID: item.id)
  } label: {
    Label("重新录制快捷键…", systemImage: "keyboard")
  }
  Divider()

  Menu("更多动作") {
    Menu("窗口管理") {
      ForEach(WindowPreset.allCases) { preset in
        Button {
          model.applyActionPreset(
            itemID: item.id,
            action: .windowPreset,
            target: preset.rawValue,
            name: preset.title,
            note: "窗口管理")
        } label: {
          Label(preset.title, systemImage: windowPresetIcon(preset))
        }
      }
      Button {
        model.applyActionPreset(
          itemID: item.id,
          action: .nativeFullScreen,
          target: "entireScreen",
          name: "全屏",
          note: "进入或退出全屏")
      } label: {
        Label("进入全屏", systemImage: "arrow.up.left.and.arrow.down.right")
      }
    }
    .disabled(!model.canChangeShortcutAction(id: item.id))
    .help(model.shortcutActionChangeHelp(id: item.id))

    Button {
      model.beginShortcutActionCapture(itemID: item.id)
    } label: {
      Label("发送按键...", systemImage: "keyboard.badge.ellipsis")
    }
    .disabled(!model.canChangeShortcutAction(id: item.id))
    .help(model.shortcutActionChangeHelp(id: item.id))

    Menu("应用中心") {
      Button {
        model.applyActionPreset(
          itemID: item.id,
          action: .showProcessViewer,
          target: "process-viewer",
          name: "打开进程查看器",
          scope: "常用脚本",
          note: "打开独立的进程查看器窗口。")
      } label: {
        Label("打开进程查看器", systemImage: "cpu")
      }
      Button {
        model.applyActionPreset(
          itemID: item.id,
          action: .showCodexNetworkProbe,
          target: "codex-network-probe",
          name: "打开测试网速",
          scope: "常用脚本",
          note: "一个球测下载和上传，一个球测 Codex 四轮连通与响应。")
      } label: {
        Label("打开测试网速", systemImage: "gauge.with.dots.needle.67percent")
      }
      Button {
        model.applyActionPreset(
          itemID: item.id,
          action: .openURL,
          target: item.target.hasPrefix("http") ? item.target : "https://aixlg.com/",
          note: "网页链接")
      } label: {
        Label("打开网址", systemImage: "safari")
      }
      Button {
        model.applyActionPreset(
          itemID: item.id,
          action: .insertText,
          target: item.target.isEmpty ? "小龙哥Mac哲学" : item.target,
          name: item.name.isEmpty ? "输入文本" : item.name,
          note: "把目标文本输入到前台光标位置")
      } label: {
        Label("输入文本", systemImage: "text.cursor")
      }
      Button {
        model.applyActionPreset(
          itemID: item.id,
          action: .sendShortcut,
          target: "⌃ ⌘ Space",
          name: "打开 Emoji 与符号",
          scope: "常用脚本",
          note: "打开系统 Emoji 与符号面板。")
      } label: {
        Label("打开 Emoji 与符号", systemImage: "face.smiling")
      }
      Button {
        model.applyActionPreset(
          itemID: item.id,
          action: .runShell,
          target: "plugin:mic-toggle.sh",
          name: "切换麦克风",
          scope: "常用脚本",
          note: "Studio Display / DJI 麦克风切换。")
      } label: {
        Label("切换麦克风", systemImage: "mic.fill")
      }
      Button {
        model.applyActionPreset(
          itemID: item.id,
          action: .runShell,
          target: "osascript -e 'tell application \"System Events\" to sleep'",
          name: "休眠",
          scope: "常用脚本",
          note: "让 Mac 进入睡眠。")
      } label: {
        Label("休眠", systemImage: "moon.zzz.fill")
      }
      Button {
        model.applyActionPreset(
          itemID: item.id,
          action: .runShell,
          target: "pmset displaysleepnow",
          name: "息屏",
          scope: "常用脚本",
          note: "立即关闭屏幕，不退出 App。")
      } label: {
        Label("息屏", systemImage: "display")
      }
      Button {
        model.applyActionPreset(
          itemID: item.id,
          action: .showSleepPanel,
          target: "sleep-panel",
          name: "保持唤醒",
          scope: "常用脚本",
          note: "打开睡眠管理，选择不睡机时长。")
      } label: {
        Label("保持唤醒", systemImage: "bolt.fill")
      }
    }
    .disabled(!model.canChangeShortcutAction(id: item.id))
    .help(model.shortcutActionChangeHelp(id: item.id))

  }

  Divider()

  Button {
    model.undoActionPreset(itemID: item.id)
  } label: {
    Label("撤销上一次调整", systemImage: "arrow.uturn.backward")
  }
  .disabled(!model.canUndoActionPreset(itemID: item.id))

  Button(role: .destructive) {
    delete()
  } label: {
    Label("删除快捷键...", systemImage: "trash")
  }
  .disabled(!model.canDeleteShortcut(id: item.id))
  .help(model.shortcutDeletionHelp(id: item.id))
}

func shortcutRowAppChoiceLabel(_ choice: AppChoice) -> some View {
  Label {
    Text(choice.name)
  } icon: {
    if let icon = shortcutGuideAppIcon(forAppTarget: choice.target) {
      Image(nsImage: icon)
        .resizable()
        .interpolation(.high)
    } else {
      Image(systemName: "app")
    }
  }
}
