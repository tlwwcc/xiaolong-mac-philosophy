import AppKit
import SwiftUI

struct ShortcutIssueChip: View {
  let issue: ShortcutIssue

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: issueIcon)
        .font(.system(size: 8, weight: .bold))
      Text(issue.kind.label)
        .font(.system(size: 10, weight: .semibold))
      Text("详情")
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(issueTint.opacity(0.78))
    }
    .foregroundStyle(issueTint)
    .padding(.horizontal, 7)
    .frame(height: 18)
    .background(issueTint.opacity(0.09), in: Capsule())
    .overlay(Capsule().stroke(issueTint.opacity(0.18), lineWidth: 1))
  }

  private var issueTint: Color {
    switch issue.kind {
    case .shortcutDuplicate: return ruby
    case .systemOccupied: return amber
    case .externalManaged: return indigo
    case .possibleCollision: return amber.opacity(0.88)
    case .needsCompletion: return muted
    }
  }

  private var issueIcon: String {
    switch issue.kind {
    case .shortcutDuplicate: return "exclamationmark.triangle.fill"
    case .systemOccupied: return "lock.trianglebadge.exclamationmark"
    case .externalManaged: return "arrow.triangle.branch"
    case .possibleCollision: return "exclamationmark.circle"
    case .needsCompletion: return "ellipsis.circle"
    }
  }
}

struct ShortcutIssueDetailView: View {
  let issue: ShortcutIssue

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Text(issue.kind.label)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(ink)
        StatusPill(
          text: issue.kind.isBlocking ? "需要处理" : "仅提醒",
          color: issue.kind.isBlocking ? ruby : amber)
      }

      ShortcutIssueDetailLine(title: "当前快捷键", value: issue.hotkey)
      ShortcutIssueDetailLine(title: "对象", value: issue.object)
      ShortcutIssueDetailLine(title: "影响", value: issue.impact)
      ShortcutIssueDetailLine(title: "建议", value: issue.suggestion)
    }
    .padding(14)
    .frame(width: 320, alignment: .leading)
  }
}

struct ShortcutIssueDetailLine: View {
  let title: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(muted)
      Text(value)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(ink.opacity(0.88))
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct ShortcutDescriptionCell: View {
  let item: ShortcutItem

  var body: some View {
    Text(shortcutHumanDescription(item))
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(ink.opacity(0.82))
      .lineLimit(2)
      .help(shortcutHumanDescription(item))
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 10)
  }
}

func shortcutCategoryTag(_ item: ShortcutItem) -> String? {
  shortcutGuideCategory(for: item)
}

func shortcutActionSubtitle(_ item: ShortcutItem) -> String? {
  if item.commandID != nil { return "截图操作" }
  let category = shortcutGuideCategoryDisplayName(shortcutGuideCategory(for: item))
  let action = shortcutActionDisplayText(item)
  guard !category.isEmpty else { return action }
  return "\(category) · \(action)"
}

func shortcutActionDisplayText(_ item: ShortcutItem) -> String {
  if item.commandID != nil {
    return "截图操作"
  }
  if item.scope == "常用脚本" {
    return "应用中心"
  }
  switch item.action {
  case .openApp: return "打开 App"
  case .openURL: return "打开网址"
  case .runShell: return "脚本"
  case .showPanel: return "功能快捷键"
  case .showLauncher: return "启动器"
  case .showProcessViewer: return "进程查看器"
  case .showClipboardHistory: return "剪贴板历史"
  case .showCodexNetworkProbe: return "测试网速"
  case .showSleepPanel: return "保持唤醒开关"
  case .windowPreset: return "排列窗口"
  case .nativeFullScreen: return "全屏"
  case .sendShortcut: return "发送按键"
  case .closeWindowSmart: return "关闭窗口"
  case .insertText: return "输入文字"
  }
}

func shortcutHumanDescription(_ item: ShortcutItem) -> String {
  if item.commandID != nil {
    let note = item.note.trimmingCharacters(in: .whitespacesAndNewlines)
    return note.isEmpty ? "执行截图操作。" : note
  }
  switch item.action {
  case .openApp:
    return shortcutOpenTargetDescription(item)
  case .openURL:
    return shortcutURLDescription(item.target)
  case .runShell:
    return "按下后运行这条常用脚本，完成对应系统动作。"
  case .showPanel:
    return "打开功能快捷键页面，查看和管理当前快捷键。"
  case .showLauncher:
    return "弹出应用启动器，可以搜索应用、计算或打开网页。"
  case .showProcessViewer:
    return "打开独立的进程查看器窗口。"
  case .showClipboardHistory:
    return "打开剪贴板历史，并直接搜索或恢复之前复制的内容。"
  case .showCodexNetworkProbe:
    return "一个球测下载和上传，一个球测 Codex 四轮连通与响应。"
  case .showSleepPanel:
    return "按一次无限期保持唤醒，再按一次恢复系统默认睡眠。"
  case .windowPreset:
    return shortcutWindowDescription(item.target)
  case .nativeFullScreen:
    return "让当前窗口进入或退出 Mac 全屏。"
  case .sendShortcut:
    if isEmojiShortcut(item) {
      return "弹出 Emoji 与符号面板。"
    }
    return "把 \(shortcutSendShortcutText(item.target)) 作为真实组合键发给当前正在使用的 App，不输入文字。"
  case .closeWindowSmart:
    return "按下后关闭当前标签页或当前窗口。"
  case .insertText:
    return "把这段常用文字填到当前光标位置。"
  }
}

func isSystemSettingsShortcut(_ item: ShortcutItem) -> Bool {
  let target = item.target.lowercased()
  return target == "bundle:com.apple.systempreferences"
    || target == "bundle:com.apple.systemsettings"
    || item.name.contains("系统设置")
}

func isEmojiShortcut(_ item: ShortcutItem) -> Bool {
  let normalizedTarget = item.target.replacingOccurrences(of: " ", with: "")
  return item.name.localizedCaseInsensitiveContains("emoji")
    || normalizedTarget == "⌃⌘Space"
    || normalizedTarget == "ControlCommandSpace"
}

func shortcutOpenTargetDescription(_ item: ShortcutItem) -> String {
  if isSystemSettingsShortcut(item) {
    return "打开系统设置，继续调整 Mac 的权限或偏好。"
  }
  let appName = shortcutDisplayName(item)
  let expandedTarget = (item.target.trimmingCharacters(in: .whitespacesAndNewlines) as NSString)
    .expandingTildeInPath
  if expandedTarget.hasPrefix("/") {
    let url = URL(fileURLWithPath: expandedTarget)
    if url.pathExtension != "app" {
      return "打开 \(appName)，直接到指定文件或文件夹。"
    }
  }
  return "按下后打开 \(appName)；已在后台时带到眼前，已在前台时隐藏。"
}

func shortcutDisplayName(_ item: ShortcutItem) -> String {
  var name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
  if name.hasPrefix("打开 ") {
    name.removeFirst(3)
  } else if name.hasPrefix("打开") {
    name.removeFirst(2)
  }
  return name.isEmpty ? "这个 App" : name
}

func shortcutURLDescription(_ target: String) -> String {
  guard let url = URL(string: target), let host = url.host, !host.isEmpty else {
    return "打开指定网页。"
  }
  return "打开 \(host) 网页，直接到常用页面。"
}

func shortcutWindowDescription(_ target: String) -> String {
  guard let preset = WindowPreset(rawValue: target) else {
    return "调整当前窗口位置。"
  }

  switch preset {
  case .leftHalf:
    return "把当前窗口贴到屏幕左半边，方便并排查看。"
  case .rightHalf:
    return "把当前窗口贴到屏幕右半边，方便并排查看。"
  case .leftProportional:
    return "按设置中的分屏比例，把当前窗口贴到屏幕左边。"
  case .rightProportional:
    return "按设置中的分屏比例，把当前窗口贴到屏幕右边。"
  case .topHalf:
    return "把当前窗口贴到屏幕上半边。"
  case .bottomHalf:
    return "把当前窗口贴到屏幕下半边。"
  case .topLeft:
    return "把当前窗口收进左上角，留出其他工作区。"
  case .topRight:
    return "把当前窗口收进右上角，留出其他工作区。"
  case .bottomLeft:
    return "把当前窗口收进左下角，留出其他工作区。"
  case .bottomRight:
    return "把当前窗口收进右下角，留出其他工作区。"
  case .maximize:
    return "把当前窗口铺满可用区域，同时保留 Dock 和菜单栏。"
  case .center:
    return "把当前窗口移到屏幕中间，方便继续处理。"
  case .minimize:
    return "把当前窗口收进 Dock，先腾出桌面。"
  }
}

func shortcutSendShortcutText(_ target: String) -> String {
  let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
  return trimmed.isEmpty ? "预设按键" : trimmed
}
