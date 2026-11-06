import AppKit
import SwiftUI

struct InlineTextField: View {
  @Binding var text: String
  let placeholder: String
  var strong = false

  var body: some View {
    TextField(placeholder, text: $text)
      .font(.system(size: 13, weight: strong ? .bold : .semibold))
      .textFieldStyle(.plain)
      .foregroundStyle(ink)
      .lineLimit(1)
      .padding(.horizontal, 9)
      .frame(height: 30)
      .background(
        AppVisualStyle.surface.opacity(0.001),
        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
      )
  }
}

struct AppChoiceMenuLabel: View {
  let choice: AppChoice
  let fallbackSystemImage: String

  private var appIcon: NSImage? {
    guard let source = shortcutGuideAppIcon(forAppTarget: choice.target) else {
      return nil
    }
    let icon = (source.copy() as? NSImage) ?? source
    icon.size = NSSize(width: 16, height: 16)
    icon.isTemplate = false
    return icon
  }

  var body: some View {
    if let appIcon {
      Label {
        Text(choice.name)
      } icon: {
        Image(nsImage: appIcon)
          .renderingMode(.original)
      }
    } else {
      Label(choice.name, systemImage: fallbackSystemImage)
    }
  }
}

struct ActionMenu: View {
  @EnvironmentObject private var model: AppModel
  let item: ShortcutItem
  var compact = false

  var body: some View {
    Menu {
      Menu("打开 App / 文件 / 文件夹") {
        Menu("运行中的程序") {
          ForEach(Array(model.runningAppChoices().prefix(14))) { choice in
            Button {
              model.setOpenTarget(itemID: item.id, choice: choice)
            } label: {
              AppChoiceMenuLabel(choice: choice, fallbackSystemImage: "app.badge")
            }
          }
        }
        Menu("应用程序目录") {
          ForEach(model.installedAppChoices(limit: 24)) { choice in
            Button {
              model.setOpenTarget(itemID: item.id, choice: choice)
            } label: {
              AppChoiceMenuLabel(choice: choice, fallbackSystemImage: "app")
            }
          }
        }
        Divider()
        Button {
          model.browseOpenTarget(itemID: item.id)
        } label: {
          Label("从访达选择…", systemImage: "folder.badge.plus")
        }
      }

      Button {
        model.applyActionPreset(
          itemID: item.id,
          action: .openURL,
          target: item.target.hasPrefix("http") ? item.target : "https://aixlg.com/",
          scope: "全部应用",
          note: "网页链接"
        )
      } label: {
        Label("打开网址", systemImage: "safari")
      }

      Divider()

      Menu("窗口管理") {
        ForEach(WindowPreset.allCases) { preset in
          Button {
            model.applyActionPreset(
              itemID: item.id,
              action: .windowPreset,
              target: preset.rawValue,
              name: preset.title,
              scope: "窗口",
              note: "窗口管理"
            )
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
            scope: "窗口",
            note: "进入或退出全屏"
          )
        } label: {
          Label("进入全屏", systemImage: "arrow.up.left.and.arrow.down.right")
        }
      }

      Button {
        model.beginShortcutActionCapture(itemID: item.id)
      } label: {
        Label("发送按键...", systemImage: "keyboard.badge.ellipsis")
      }

      Menu("应用中心") {
        Button {
          model.applyActionPreset(
            itemID: item.id,
            action: .showProcessViewer,
            target: "process-viewer",
            name: "打开进程查看器",
            scope: "常用脚本",
            note: "打开独立的进程查看器窗口。"
          )
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
            note: "一个球测下载和上传，一个球测 Codex 四轮连通与响应。"
          )
        } label: {
          Label("打开测试网速", systemImage: "gauge.with.dots.needle.67percent")
        }
        Button {
          model.applyActionPreset(
            itemID: item.id,
            action: .sendShortcut,
            target: "⌃ ⌘ Space",
            name: "打开 Emoji 与符号",
            scope: "常用脚本",
            note: "打开系统 Emoji 与符号面板。"
          )
        } label: {
          Label("打开 Emoji 与符号", systemImage: "face.smiling")
        }
        Button {
          model.applyActionPreset(
            itemID: item.id,
            action: .insertText,
            target: "#",
            name: "输入井号 #",
            scope: "常用脚本",
            note: "在当前光标处输入 #。"
          )
        } label: {
          Label("输入井号 #", systemImage: "number")
        }
        Button {
          model.applyActionPreset(
            itemID: item.id,
            action: .runShell,
            target: "plugin:mic-toggle.sh",
            name: "切换麦克风",
            scope: "常用脚本",
            note: "Studio Display / DJI 麦克风切换。"
          )
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
            note: "让 Mac 进入睡眠。"
          )
        } label: {
          Label("休眠", systemImage: "moon.zzz.fill")
        }
        Button {
          model.applyActionPreset(
            itemID: item.id,
            action: .showSleepPanel,
            target: "sleep-infinite-toggle",
            name: "切换无限期保持唤醒",
            scope: "常用脚本",
            note: "按一次无限期保持唤醒，再按一次恢复系统默认睡眠。"
          )
        } label: {
          Label("切换无限期保持唤醒", systemImage: "bolt.fill")
        }
      }
    } label: {
      if compact {
        Label("管理", systemImage: "gearshape.fill")
          .labelStyle(.iconOnly)
          .font(.system(size: 13, weight: .semibold))
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(ink.opacity(0.70))
          .frame(width: 34, height: 30)
          .background(
            AppVisualStyle.surface.opacity(0.78),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .stroke(line.opacity(0.55), lineWidth: 1)
          )
      } else {
        HStack(spacing: 6) {
          ShortcutActionVisual(item: item, size: 22, iconSize: 10)
          Text(actionMenuTitle(item))
            .font(.system(size: 12, weight: .bold))
            .lineLimit(1)
          Spacer(minLength: 0)
          Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(
          LinearGradient(
            colors: [AppVisualStyle.surface.opacity(0.92), softSurface.opacity(0.70)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          ),
          in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .shadow(color: Color.black.opacity(0.018), radius: 3, x: 0, y: 2)
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(
            line.opacity(0.65), lineWidth: 1))
      }
    }
    .menuStyle(.borderlessButton)
    .help(compact ? "管理" : actionMenuTitle(item))
    .accessibilityLabel(Text(compact ? "管理" : actionMenuTitle(item)))
    .padding(.horizontal, 5)
  }

  private func actionMenuTitle(_ item: ShortcutItem) -> String {
    item.action.shortTitle
  }
}

struct ShortcutActionVisual: View {
  let item: ShortcutItem
  var size: CGFloat = 28
  var iconSize: CGFloat = 12

  private var appIcon: NSImage? {
    shortcutGuideAppIcon(for: item)
  }

  var body: some View {
    Group {
      if let appIcon {
        Image(nsImage: appIcon)
          .resizable()
          .interpolation(.high)
          .scaledToFit()
          .padding(size * 0.13)
      } else {
        Image(
          systemName: item.commandID == nil
            ? actionIconName(item.action) : "viewfinder.circle.fill"
        )
        .font(.system(size: iconSize, weight: .bold))
        .foregroundStyle(accent)
      }
    }
    .frame(width: size, height: size)
    .background(
      appIcon == nil ? accent.opacity(0.08) : AppVisualStyle.surface.opacity(0.92),
      in: RoundedRectangle(cornerRadius: max(6, size * 0.30), style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: max(6, size * 0.30), style: .continuous)
        .stroke(
          appIcon == nil ? accent.opacity(0.12) : AppVisualStyle.surface.opacity(0.80), lineWidth: 1
        )
    )
  }
}

func windowPresetIcon(_ preset: WindowPreset) -> String {
  switch preset {
  case .leftHalf, .leftProportional: return "rectangle.lefthalf.filled"
  case .rightHalf, .rightProportional: return "rectangle.righthalf.filled"
  case .topHalf: return "rectangle.tophalf.filled"
  case .bottomHalf: return "rectangle.bottomhalf.filled"
  case .topLeft: return "square.grid.2x2.fill"
  case .topRight: return "square.grid.2x2.fill"
  case .bottomLeft: return "square.grid.2x2.fill"
  case .bottomRight: return "square.grid.2x2.fill"
  case .maximize: return "arrow.up.left.and.arrow.down.right"
  case .center: return "scope"
  case .minimize: return "minus.rectangle"
  }
}

func actionIconName(_ action: ShortcutAction) -> String {
  switch action {
  case .openApp: return "app.badge"
  case .openURL: return "safari"
  case .runShell: return "terminal"
  case .showPanel: return "doc.text.magnifyingglass"
  case .showLauncher: return "magnifyingglass.circle"
  case .showProcessViewer: return "cpu"
  case .showClipboardHistory: return "doc.on.clipboard.fill"
  case .showCodexNetworkProbe: return "gauge.with.dots.needle.67percent"
  case .showSleepPanel: return "moon.zzz.fill"
  case .windowPreset: return "rectangle.on.rectangle"
  case .nativeFullScreen: return "arrow.up.left.and.arrow.down.right"
  case .sendShortcut: return "keyboard"
  case .closeWindowSmart: return "xmark.square"
  case .insertText: return "text.cursor"
  }
}
