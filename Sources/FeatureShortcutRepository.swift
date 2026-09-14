import Foundation

struct FeatureShortcutCommandDescriptor: Identifiable, Equatable {
  let id: String
  let displayName: String
  let scope: String
  let key: String
  let modifiers: [String]
  let note: String
  let requiresPro: Bool

  var target: String { "feature-command:\(id)" }

  func makeShortcutItem(enabled: Bool = true) -> ShortcutItem {
    ShortcutItem(
      id: "feature-shortcut-\(id)",
      commandID: id,
      name: displayName,
      scope: scope,
      key: key,
      modifiers: modifiers,
      // The legacy action remains decodable by older builds. New builds dispatch commandID first.
      action: .runShell,
      target: target,
      enabled: enabled,
      note: note)
  }
}

enum YoumuFeatureShortcutCatalog {
  /// Feature and command identities describe product capabilities, not a build channel.
  /// Stable and development builds keep separate storage/runtime namespaces while sharing these
  /// IDs so one manifest can safely own and dispatch every Youmu command.
  static let featureID = "cn.tlww.aixlg.hotkeys.feature.youmu"

  // Since build 135 every distributable App is built through SwiftPM and must link YoumuFeature.
  // Keeping the old optional-module branch would make an integrated build silently skip defaults.
  static let runtimeAvailable = true

  static let quickSnapshot = command(
    "quick-snapshot",
    name: "游目 · 截图到剪贴板",
    key: "1",
    modifiers: ["control", "option"],
    note: "Caps + 1：框选截图并复制到剪贴板。",
    requiresPro: false)

  static let annotatedScreenshot = command(
    "annotated-screenshot",
    name: "游目 · 截图加标注",
    key: "1",
    modifiers: ["control", "option", "command"],
    note: "Caps + ⌘ + 1：框选截图并进入标注。",
    requiresPro: false)

  static let longScreenshot = command(
    "long-screenshot",
    name: "游目 · 长截图",
    key: "2",
    modifiers: ["control", "option"],
    note: "Caps + 2：开始滚动长截图。",
    requiresPro: false)

  static let pinScreenshot = command(
    "pin-screenshot",
    name: "游目 · 钉截图",
    key: "T",
    modifiers: ["control", "option", "command"],
    note: "Caps + ⌘ + T：把最近一次截图钉在桌面上。",
    requiresPro: false)

  static let selectionReader = command(
    "selection-reader",
    name: "游目 · 选哪读哪",
    key: "R",
    modifiers: ["control", "option"],
    note: "Caps + R：框选文字区域并朗读。",
    requiresPro: false)

  static let imageTranslate = command(
    "image-translate",
    name: "游目 · 原图翻译",
    key: "S",
    modifiers: ["control", "option", "command"],
    note: "Caps + ⌘ + S：框选图片，在原图位置显示译文。",
    requiresPro: false)

  static let ocrTranslate = command(
    "ocr-translate",
    name: "游目 · OCR 翻译",
    key: "Y",
    modifiers: ["control", "option", "command"],
    note: "Caps + ⌘ + Y：框选识别文字并翻译。",
    requiresPro: false)

  static let ocrCopy = command(
    "ocr-copy",
    name: "游目 · OCR 复制",
    key: "A",
    modifiers: ["control", "option", "command"],
    note: "Caps + ⌘ + A：框选识别文字并复制。",
    requiresPro: false)

  static let all: [FeatureShortcutCommandDescriptor] = [
    quickSnapshot,
    annotatedScreenshot,
    longScreenshot,
    pinScreenshot,
    selectionReader,
    imageTranslate,
    ocrTranslate,
    ocrCopy,
  ]

  static let ids = Set(all.map(\.id))

  static func descriptor(for commandID: String) -> FeatureShortcutCommandDescriptor? {
    all.first(where: { $0.id == commandID })
  }

  static func missingDefaultDescriptors(
    in items: [ShortcutItem],
    deletedNames: Set<String> = [],
    deletedRecoveryIDs: Set<String> = []
  ) -> [FeatureShortcutCommandDescriptor] {
    all.filter { descriptor in
      // Fixed Youmu capabilities remain discoverable even after deletion by older builds.
      // The host backs up and restores missing rows without taking a conflicting hotkey.
      !items.contains { item in
        item.commandID == descriptor.id
          || (item.isBuiltIn != false && item.target == descriptor.target)
      }
    }
  }

  private static func command(
    _ localID: String,
    name: String,
    key: String,
    modifiers: [String],
    note: String,
    requiresPro: Bool
  ) -> FeatureShortcutCommandDescriptor {
    FeatureShortcutCommandDescriptor(
      id: "\(featureID).command.\(localID)",
      displayName: name,
      scope: "游目",
      key: key,
      modifiers: modifiers,
      note: note,
      requiresPro: requiresPro)
  }
}
