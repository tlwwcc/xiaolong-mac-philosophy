import Foundation

/// Stable, user-facing entries that may appear in the primary status item's shortcut menu.
///
/// Management commands such as Application Center, Settings, Update, Pause, and Quit are
/// intentionally absent: they are structural escape hatches and must always remain available.
enum MenuBarCatalogItemID: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
  case youmu = "youmu"
  case phrases = "host.phrases"
  case inputMethod = "host.inputMethod"
  case networkProbe = "host.networkProbe"
  case keepAwake = "host.keepAwake"
  case launcher = "host.launcher"
  case shortcuts = "host.shortcuts"
  case processViewer = "host.processViewer"
  case pijuanPDF = "host.pijuanPDF"
  case aiPlayer = "host.aiPlayer"
  case clipboardHistory = "host.clipboardHistory"

  var id: String { rawValue }
}

struct MenuBarCatalogItemDescriptor: Identifiable, Hashable, Sendable {
  let id: MenuBarCatalogItemID
  let title: String
  let detail: String
  let systemImage: String
  let isVisibleByDefault: Bool
}

enum MenuBarCatalog {
  static let configurationVersion = 1
  static let visibleIDsDefaultsKey = "menuBarVisibleCatalogItemIDsV1"
  static let configurationVersionDefaultsKey = "menuBarCatalogConfigurationVersionV1"

  /// The order here is both the settings-sheet order and the canonical persistence order.
  static let items: [MenuBarCatalogItemDescriptor] = [
    MenuBarCatalogItemDescriptor(
      id: .youmu,
      title: "游目",
      detail: "截图、OCR、翻译与选区朗读",
      systemImage: "viewfinder",
      isVisibleByDefault: true),
    MenuBarCatalogItemDescriptor(
      id: .phrases,
      title: "快捷短语",
      detail: "打开短语与文本扩展",
      systemImage: "text.bubble",
      isVisibleByDefault: true),
    MenuBarCatalogItemDescriptor(
      id: .inputMethod,
      title: "输入法管理",
      detail: "管理按 App 切换输入法",
      systemImage: "character.cursor.ibeam",
      isVisibleByDefault: true),
    MenuBarCatalogItemDescriptor(
      id: .networkProbe,
      title: "测试网速",
      detail: "查看国内、国际与 Codex 链路",
      systemImage: "gauge.with.dots.needle.67percent",
      isVisibleByDefault: true),
    MenuBarCatalogItemDescriptor(
      id: .keepAwake,
      title: "永不睡眠",
      detail: "打开保持唤醒面板",
      systemImage: "moon.zzz.fill",
      isVisibleByDefault: true),
    MenuBarCatalogItemDescriptor(
      id: .launcher,
      title: "启动器",
      detail: "搜索并打开 App",
      systemImage: "magnifyingglass",
      isVisibleByDefault: true),
    MenuBarCatalogItemDescriptor(
      id: .shortcuts,
      title: "查看快捷键",
      detail: "打开快捷键总览",
      systemImage: "command",
      isVisibleByDefault: true),
    MenuBarCatalogItemDescriptor(
      id: .processViewer,
      title: "进程查看器",
      detail: "查看当前进程与资源占用",
      systemImage: "cpu",
      isVisibleByDefault: true),
    MenuBarCatalogItemDescriptor(
      id: .pijuanPDF,
      title: "披卷",
      detail: "打开 PDF 阅读器",
      systemImage: "doc.richtext",
      isVisibleByDefault: false),
    MenuBarCatalogItemDescriptor(
      id: .aiPlayer,
      title: "听澜播放器",
      detail: "打开音频播放器",
      systemImage: "headphones",
      isVisibleByDefault: false),
    MenuBarCatalogItemDescriptor(
      id: .clipboardHistory,
      title: "剪贴板历史",
      detail: "打开最近复制记录",
      systemImage: "doc.on.clipboard",
      isVisibleByDefault: false),
  ]

  static let defaultVisibleItemIDs: Set<MenuBarCatalogItemID> = Set(
    items.lazy.filter(\.isVisibleByDefault).map(\.id))

  static let defaultVisibleRawValues: Set<String> = Set(
    defaultVisibleItemIDs.map(\.rawValue))

  static func loadVisibleItemIDs(
    from defaults: UserDefaults = .standard
  ) -> Set<MenuBarCatalogItemID> {
    guard defaults.object(forKey: visibleIDsDefaultsKey) != nil else {
      saveVisibleItemIDs(defaultVisibleItemIDs, to: defaults)
      return defaultVisibleItemIDs
    }
    guard let storedRawValues = defaults.stringArray(forKey: visibleIDsDefaultsKey) else {
      saveVisibleItemIDs(defaultVisibleItemIDs, to: defaults)
      return defaultVisibleItemIDs
    }

    let normalized = normalizedVisibleItemIDs(storedRawValues)
    if storedRawValues != orderedRawValues(for: normalized)
      || defaults.integer(forKey: configurationVersionDefaultsKey) != configurationVersion
    {
      saveVisibleItemIDs(normalized, to: defaults)
    }
    return normalized
  }

  static func saveVisibleItemIDs(
    _ itemIDs: Set<MenuBarCatalogItemID>,
    to defaults: UserDefaults = .standard
  ) {
    defaults.set(orderedRawValues(for: itemIDs), forKey: visibleIDsDefaultsKey)
    defaults.set(configurationVersion, forKey: configurationVersionDefaultsKey)
  }

  static func normalizedVisibleItemIDs<S: Sequence>(
    _ rawValues: S
  ) -> Set<MenuBarCatalogItemID> where S.Element == String {
    Set(rawValues.compactMap(MenuBarCatalogItemID.init(rawValue:)))
  }

  static func normalizedVisibleRawValues<S: Sequence>(
    _ rawValues: S
  ) -> Set<String> where S.Element == String {
    Set(normalizedVisibleItemIDs(rawValues).map(\.rawValue))
  }

  static func orderedRawValues(for itemIDs: Set<MenuBarCatalogItemID>) -> [String] {
    items.compactMap { itemIDs.contains($0.id) ? $0.id.rawValue : nil }
  }

  static func catalogItemID(forStatusMenuCommandID commandID: String) -> MenuBarCatalogItemID? {
    if commandID.hasPrefix("youmu.") {
      return .youmu
    }
    return MenuBarCatalogItemID(rawValue: commandID)
  }

  /// Unknown commands are structural by default. Callers should only make a command customizable
  /// after adding it to this catalog; this keeps Settings, Update, Pause, and Quit unhideable.
  static func isStatusMenuCommandVisible(
    _ commandID: String,
    visibleItemIDs: Set<MenuBarCatalogItemID>
  ) -> Bool {
    guard let itemID = catalogItemID(forStatusMenuCommandID: commandID) else { return true }
    return visibleItemIDs.contains(itemID)
  }

  static func isStatusMenuCommandVisible(
    _ commandID: String,
    visibleRawValues: Set<String>
  ) -> Bool {
    isStatusMenuCommandVisible(
      commandID,
      visibleItemIDs: normalizedVisibleItemIDs(visibleRawValues))
  }
}
