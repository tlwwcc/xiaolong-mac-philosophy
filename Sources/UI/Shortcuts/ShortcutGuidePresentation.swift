import AppKit
import SwiftUI

struct ShortcutGuideEmptyState: View {
  let searchText: String
  let selectedCategory: String

  var body: some View {
    WorkspaceEmptyState(
      systemImage: "keyboard",
      title: searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "这一类还没有快捷键" : "没有匹配结果",
      detail: "可从上方添加快捷键，或切换分类查看已有配置。")
  }
}

struct ShortcutGuideReservedListState: View {
  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: "rectangle.stack.badge.plus")
        .font(.system(size: 24, weight: .semibold))
        .foregroundStyle(amber)
      Text("外部软件分类已预留")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(ink)
      Text("第一版不会自动扫描第三方软件快捷键。")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(muted)
    }
    .frame(maxWidth: .infinity, minHeight: 220)
  }
}

struct ShortcutGuideExternalReservedView: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      IconBadge(systemImage: "rectangle.stack.badge.plus", tint: amber, size: 46, iconSize: 19)
      Text("外部软件快捷键")
        .font(.system(size: 22, weight: .semibold))
        .foregroundStyle(ink)
      Text("这里先作为结构入口保留。当前版本只展示小龙哥 Mac 哲学内部真实配置，不读取、不扫描、不判断第三方软件的快捷键。")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(muted)
        .lineSpacing(4)
      Spacer()
    }
  }
}

struct ShortcutGuideNoSelectionView: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      IconBadge(systemImage: "keyboard", tint: muted, size: 46, iconSize: 19)
      Text("选择一条快捷键查看说明")
        .font(.system(size: 19, weight: .semibold))
        .foregroundStyle(ink)
      Text("也可以直接搜索功能名、按键或说明。")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(muted)
      Spacer()
    }
  }
}

func shortcutGuideCategory(for item: ShortcutItem) -> String {
  if item.commandID != nil { return "截图类" }
  if isScreenshotShortcut(item) { return "截图类" }
  if item.action == .showPanel || item.action == .showLauncher
    || item.action == .showProcessViewer || item.action == .showClipboardHistory
    || item.action == .showCodexNetworkProbe
  {
    return "工具类"
  }
  if isSystemLevelShortcut(item) { return "系统级" }
  if item.action == .runShell || item.scope == "常用脚本" { return "脚本类" }
  if item.action == .windowPreset || item.action == .nativeFullScreen
    || item.action == .closeWindowSmart
  {
    return "窗口类"
  }
  if item.action == .openApp || isOpenFileOrFolderShortcut(item) {
    return "软件类"
  }
  return "其他类"
}

func shortcutGuideCategoryDisplayName(_ category: String) -> String {
  switch category {
  case "窗口类": return "窗口"
  case "软件类": return "软件"
  case "截图类": return "截图"
  case "PDF类": return "PDF 浏览器"
  case "工具类": return "工具"
  case "系统级": return "系统"
  case "脚本类": return "脚本"
  case "其他类": return "其他"
  default: return category
  }
}

func shortcutGuideSource(for item: ShortcutItem) -> String {
  if item.commandID != nil { return "截图" }
  if isScreenshotShortcut(item) { return "截图" }
  if isSystemSettingsShortcut(item) { return "系统设置" }
  if isSystemLevelShortcut(item) { return "系统级" }
  if item.scope == "常用脚本" { return "功能快捷键" }
  if item.action == .insertText { return "快捷短语" }
  return "功能快捷键"
}

func isOpenFileOrFolderShortcut(_ item: ShortcutItem) -> Bool {
  guard item.action == .openURL else { return false }
  let target = item.target.trimmingCharacters(in: .whitespacesAndNewlines)
  return target.hasPrefix("/") || target.hasPrefix("~/")
}

func isScreenshotShortcut(_ item: ShortcutItem) -> Bool {
  shortcutGuideTextLooksLikeScreenshot(
    [
      item.name,
      item.scope,
      item.target,
      item.note,
      item.action.title,
    ].joined(separator: " ")
  )
}

func shortcutGuideTextLooksLikeScreenshot(_ text: String) -> Bool {
  let normalized = text.folding(
    options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
  return [
    "截图",
    "截屏",
    "cleanshot",
    "screenshot",
    "screen shot",
    "screencapture",
    "capture",
    "pin last screenshot",
    "滚动截图",
    "图片标注",
    "⇧⌘5",
    "⇧ ⌘ 5",
    "shift command 5",
  ].contains { normalized.localizedCaseInsensitiveContains($0) }
}

func isSystemLevelShortcut(_ item: ShortcutItem) -> Bool {
  if item.action == .showSleepPanel || isSystemSettingsShortcut(item) {
    return true
  }
  let normalized = [
    item.name,
    item.scope,
    item.target,
    item.note,
  ].joined(separator: " ")
    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
  return [
    "休眠",
    "睡眠",
    "保持唤醒",
    "无限保持",
    "系统设置",
    "系统偏好",
    "系统面板",
    "系统辅助",
    "system events",
    "systempreferences",
    "systemsettings",
    "shortcuts run",
  ].contains { normalized.localizedCaseInsensitiveContains($0) }
}

func shortcutGuideAppIcon(for item: ShortcutItem) -> NSImage? {
  guard item.action == .openApp else { return nil }
  guard let appURL = shortcutGuideAppURL(for: item.target) else { return nil }
  return NSWorkspace.shared.icon(forFile: appURL.path)
}

func shortcutGuideAppIcon(forAppTarget target: String) -> NSImage? {
  guard let appURL = shortcutGuideAppURL(for: target) else { return nil }
  return NSWorkspace.shared.icon(forFile: appURL.path)
}

func shortcutGuideAppURL(for target: String) -> URL? {
  let trimmedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmedTarget.isEmpty else { return nil }
  if trimmedTarget.hasPrefix("bundle:") {
    let bundleID = String(trimmedTarget.dropFirst("bundle:".count))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !bundleID.isEmpty else { return nil }
    return shortcutGuideApplicationURL(forBundleIdentifier: bundleID)
  }

  let expandedPath: String
  if trimmedTarget == "~" {
    expandedPath = NSHomeDirectory()
  } else if trimmedTarget.hasPrefix("~/") {
    expandedPath = NSHomeDirectory() + String(trimmedTarget.dropFirst())
  } else {
    expandedPath = trimmedTarget
  }
  guard expandedPath.hasSuffix(".app"),
    FileManager.default.fileExists(atPath: expandedPath)
  else { return nil }
  return URL(fileURLWithPath: expandedPath, isDirectory: true)
}

func shortcutGuideApplicationURL(forBundleIdentifier bundleID: String) -> URL? {
  if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
    return url
  }
  let searchRoots = [
    URL(fileURLWithPath: "/Applications", isDirectory: true),
    URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
      "Applications", isDirectory: true),
  ]
  for root in searchRoots {
    guard
      let children = try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles])
    else { continue }
    for child in children where child.pathExtension == "app" {
      if Bundle(url: child)?.bundleIdentifier == bundleID {
        return child
      }
    }
  }
  return nil
}
