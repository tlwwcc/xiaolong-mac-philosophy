import AppKit
import MacFeatureCatalog
import SwiftUI

let moduleHotkeys = "功能快捷键"
let moduleOptimize = "插件中心"
let moduleLauncher = "启动器"
let modulePhrases = "快捷短语"
let moduleAbout = "关于"
let moduleScripts = "内置插件"
let moduleScroll = "滚动手感"
let moduleSystemStatus = "系统状态"

let moduleOrder = [
  moduleHotkeys, moduleOptimize, moduleAbout,
]

let applicationYoumuID = "youmu"
let applicationPijuanPDFID = "pijuan-pdf"
let applicationPhrasesID = AppModel.phrasesPluginID
let applicationClipboardHistoryID = "clipboard-history"
let applicationCenterItemCount = ProductFeatureCatalog.all.count

func isApplicationCenterModule(_ module: String) -> Bool {
  switch module {
  case moduleOptimize, moduleLauncher, modulePhrases, moduleScripts, moduleScroll:
    return true
  default:
    return false
  }
}

func legacyApplicationSelectionID(for module: String) -> String? {
  switch module {
  case moduleLauncher: return AppModel.launcherPluginID
  case modulePhrases: return applicationPhrasesID
  case moduleScroll: return "mouse-scroll"
  default: return nil
  }
}

func moduleTitle(_ module: String) -> String {
  switch module {
  case moduleOptimize: return "应用中心"
  case moduleHotkeys: return "功能快捷键"
  case moduleLauncher: return "启动器"
  case modulePhrases: return "快捷短语"
  case moduleAbout: return "设置"
  case moduleScripts: return "脚本插件"
  case moduleScroll: return "滚动手感"
  case moduleSystemStatus: return "系统状态"
  default: return module
  }
}

func moduleSubtitle(_ module: String) -> String {
  switch module {
  case moduleOptimize: return "应用"
  case moduleHotkeys: return "快捷键"
  case moduleLauncher: return "启动器"
  case modulePhrases: return "短语"
  case moduleAbout: return "设置与关于"
  case moduleScripts: return "脚本"
  case moduleScroll: return "滚轮"
  case moduleSystemStatus: return "状态"
  default: return ""
  }
}

func moduleIcon(_ module: String) -> String {
  switch module {
  case moduleOptimize: return "square.grid.2x2.fill"
  case moduleHotkeys: return "command"
  case moduleLauncher: return "magnifyingglass"
  case modulePhrases: return "quote.bubble"
  case moduleAbout: return "gearshape"
  case moduleScripts: return "puzzlepiece.extension"
  case moduleScroll: return "scroll"
  case moduleSystemStatus: return "speedometer"
  default: return "square.grid.2x2"
  }
}

func module(for item: ShortcutItem) -> String {
  if item.scope == "常用脚本" {
    return moduleHotkeys
  }
  if item.action == .showSleepPanel { return moduleHotkeys }
  if item.action == .insertText {
    return modulePhrases
  }
  if isLauncherManagedAppShortcut(item) {
    return moduleLauncher
  }
  return moduleHotkeys
}

func isLauncherManagedAppShortcut(_ item: ShortcutItem) -> Bool {
  guard item.action == .openApp else { return false }
  if item.scope.localizedCaseInsensitiveContains("系统") { return false }
  let target = item.target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  if target.contains("com.apple.systempreferences") { return false }
  if target.contains("/system/applications/apps.app") { return false }
  return true
}

func belongsToModule(_ item: ShortcutItem, _ selectedModule: String) -> Bool {
  module(for: item) == selectedModule
}

func brandIcon() -> NSImage {
  NSImage(named: "AppIcon")
    ?? NSImage(systemSymbolName: "command.square.fill", accessibilityDescription: nil)
    ?? NSImage()
}
