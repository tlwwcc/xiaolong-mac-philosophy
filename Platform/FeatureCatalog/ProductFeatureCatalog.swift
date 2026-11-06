/// Stable product discovery data shared by native UI and automation adapters.
/// Permissions, enabled state, shortcut bindings and execution remain host responsibilities.
public enum ProductFeatureMode: String, Codable, CaseIterable, Sendable {
  case background
  case primaryEntry
  case launch
  case action
  case configuration

  public var title: String {
    switch self {
    case .background: return "后台开关"
    case .primaryEntry: return "菜单栏主入口"
    case .launch: return "按需打开"
    case .action: return "单次操作"
    case .configuration: return "配置能力"
    }
  }
}

public enum ProductFeatureCategory: String, Codable, CaseIterable, Sendable {
  case coreApplications
  case inputEfficiency
  case mouse
  case systemAndNetwork

  public var title: String {
    switch self {
    case .coreApplications: return "核心应用"
    case .inputEfficiency: return "输入效率"
    case .mouse: return "鼠标"
    case .systemAndNetwork: return "系统与网络"
    }
  }
}

public struct ProductFeatureDescriptor: Identifiable, Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let purpose: String
  public let valueDescription: String
  public let usage: String
  public let systemImage: String
  public let assetName: String?
  public let category: ProductFeatureCategory
  public let mode: ProductFeatureMode
  public let isFeatured: Bool
  /// Legacy ShortcutAction raw values; these are associations, not permission to execute.
  public let shortcutActions: [String]
  /// Only commands actually routed by the current host are listed.
  public let shortcutCommandIDs: [String]

  private enum CodingKeys: String, CodingKey {
    case id, name, purpose, valueDescription, usage, systemImage, assetName, category, mode
    case isFeatured, shortcutActions
    case shortcutCommandIDs = "shortcutCommandIds"
  }

  init(
    id: String, name: String, purpose: String, valueDescription: String, usage: String,
    systemImage: String, assetName: String? = nil,
    category: ProductFeatureCategory, mode: ProductFeatureMode, isFeatured: Bool = false,
    shortcutActions: [String] = [], shortcutCommandIDs: [String] = []
  ) {
    self.id = id
    self.name = name
    self.purpose = purpose
    self.valueDescription = valueDescription
    self.usage = usage
    self.systemImage = systemImage
    self.assetName = assetName
    self.category = category
    self.mode = mode
    self.isFeatured = isFeatured
    self.shortcutActions = shortcutActions
    self.shortcutCommandIDs = shortcutCommandIDs
  }

  /// Mirrors host dispatch precedence: a command-bound row must not be classified by its
  /// compatibility action (for example screenshot commands retain the old runShell action).
  public func matchesShortcut(action: String, commandID: String?) -> Bool {
    if let commandID {
      return shortcutCommandIDs.contains(commandID)
    }
    return shortcutActions.contains(action)
  }
}

public enum ProductFeatureCatalog {
  /// Ordered exactly as the current application center. Stable IDs survive display-name changes.
  public static let all: [ProductFeatureDescriptor] = [
    ProductFeatureDescriptor(
      id: "youmu",
      name: "截图",
      purpose: "截图、标注、识别文字",
      valueDescription: "截取画面、钉在桌面，或识别、翻译其中的文字。",
      usage: "在应用中心打开截图设置，选择截图、标注或文字识别；也可使用功能快捷键中对应的当前按键。",
      systemImage: "viewfinder.circle.fill",
      assetName: "YoumuAppIcon",
      category: .coreApplications,
      mode: .launch,
      isFeatured: true,
      shortcutCommandIDs: [
        "cn.tlww.aixlg.hotkeys.feature.youmu.command.quick-snapshot",
        "cn.tlww.aixlg.hotkeys.feature.youmu.command.annotated-screenshot",
        "cn.tlww.aixlg.hotkeys.feature.youmu.command.long-screenshot",
        "cn.tlww.aixlg.hotkeys.feature.youmu.command.pin-screenshot",
        "cn.tlww.aixlg.hotkeys.feature.youmu.command.selection-reader",
        "cn.tlww.aixlg.hotkeys.feature.youmu.command.image-translate",
        "cn.tlww.aixlg.hotkeys.feature.youmu.command.ocr-translate",
        "cn.tlww.aixlg.hotkeys.feature.youmu.command.ocr-copy",
      ]),
    ProductFeatureDescriptor(
      id: "pijuan-pdf",
      name: "PDF 浏览器",
      purpose: "打开和阅读 PDF",
      valueDescription: "查找文字、旋转页面，继续上次阅读。",
      usage: "在应用中心打开 PDF 浏览器并选择文件；阅读按键可在软件内的管理快捷键入口查看和修改。",
      systemImage: "doc.richtext.fill",
      assetName: "PijuanAppIcon",
      category: .coreApplications,
      mode: .launch,
      isFeatured: true),
    ProductFeatureDescriptor(
      id: "caps-core",
      name: "Caps 核心键",
      purpose: "把 Caps Lock 变成左手控制台",
      valueDescription: "一只左手完成启动、切换、窗口和常用动作。",
      usage: "在应用中心启用 Caps 核心键并完成所需授权，再用 Caps 搭配已设置的功能键操作。",
      systemImage: "capslock.fill",
      category: .inputEfficiency,
      mode: .background),
    ProductFeatureDescriptor(
      id: "launcher",
      name: "启动器",
      purpose: "快速打开 App、计算和网页",
      valueDescription: "Caps + Space 呼出，搜索之后直接抵达。",
      usage: "启用后使用当前设置的启动器快捷键，输入应用名称、算式或网址，再选择结果。",
      systemImage: "magnifyingglass",
      category: .inputEfficiency,
      mode: .background,
      shortcutActions: ["showLauncher"]),
    ProductFeatureDescriptor(
      id: "phrases",
      name: "快捷短语",
      purpose: "一个缩写输入一整段常用文字",
      valueDescription: "地址、回复和固定文案只写一次，到处复用。",
      usage: "在应用中心添加短语与缩写并启用；在文字输入处键入缩写，即可自动展开文本。",
      systemImage: "quote.bubble.fill",
      category: .inputEfficiency,
      mode: .configuration),
    ProductFeatureDescriptor(
      id: "clipboard-history",
      name: "剪贴板历史",
      purpose: "每次复制自动保存，需要时再找回",
      valueDescription: "文字、图片和多个文件都可搜索；重复内容只保留一条。",
      usage: "启用记录后正常复制内容；打开剪贴板历史窗口，搜索并选择要再次使用的内容。",
      systemImage: "doc.on.clipboard.fill",
      category: .inputEfficiency,
      mode: .background,
      shortcutActions: ["showClipboardHistory"]),
    ProductFeatureDescriptor(
      id: "mouse-scroll",
      name: "鼠标滚动",
      purpose: "让外接鼠标滚动稳定、顺手",
      valueDescription: "按自己的习惯调速度、步进和自然方向。",
      usage: "在应用中心启用鼠标滚动，按需要调整速度、步进和滚动方向。",
      systemImage: "scroll.fill",
      category: .mouse,
      mode: .background),
    ProductFeatureDescriptor(
      id: "mouse-volume",
      name: "鼠标音量",
      purpose: "在屏幕右上角用滚轮调音量",
      valueDescription: "不找菜单、不按键，鼠标顺手一滚就够。",
      usage: "在应用中心启用鼠标音量；将指针移到屏幕右上角，再滚动鼠标滚轮调节音量。",
      systemImage: "speaker.wave.2.fill",
      category: .mouse,
      mode: .background),
    ProductFeatureDescriptor(
      id: "process-viewer",
      name: "进程查看器",
      purpose: "看清进程、资源占用和交换空间",
      valueDescription: "需要时打开窗口查看，关闭后不持续刷新。",
      usage: "从应用中心或当前快捷键打开进程查看器，查看运行状态；关闭窗口后停止刷新。",
      systemImage: "cpu",
      category: .systemAndNetwork,
      mode: .launch,
      shortcutActions: ["showProcessViewer"]),
    ProductFeatureDescriptor(
      id: "codex-network-probe",
      name: "测试网速",
      purpose: "测试网络速度与 Codex 连通响应",
      valueDescription: "只在打开测速窗口时运行，不在后台偷偷测速。",
      usage: "打开测试网速窗口，选择网络测速或 Codex 连通检测，并按窗口提示开始。",
      systemImage: "gauge.with.dots.needle.67percent",
      category: .systemAndNetwork,
      mode: .launch,
      shortcutActions: ["showCodexNetworkProbe"]),
    ProductFeatureDescriptor(
      id: "sleep",
      name: "保持唤醒",
      purpose: "临时保持 Mac 唤醒",
      valueDescription: "开会、下载、投屏时按时长开启，到点自动恢复。",
      usage: "在应用中心选择保持唤醒的时长并开启；使用对应快捷键可开始或停止持续唤醒。",
      systemImage: "moon.zzz.fill",
      category: .systemAndNetwork,
      mode: .action,
      shortcutActions: ["showSleepPanel"]),
  ]

  public static let currentIDs: Set<String> = Set(all.map(\.id))
  public static let categories: [ProductFeatureCategory] = [
    .coreApplications, .inputEfficiency, .mouse, .systemAndNetwork,
  ]

  public static func feature(id: String) -> ProductFeatureDescriptor? {
    all.first { $0.id == id }
  }
}
