import Combine
import Foundation

/// UI identity is independent from visible titles and legacy persisted module names.
enum WorkspaceDestination: String, CaseIterable, Identifiable {
  case shortcuts, applications, phrases, settings

  var id: String { rawValue }
  var title: String {
    switch self {
    case .shortcuts: return "快捷键"
    case .applications: return "应用中心"
    case .phrases: return "快捷短语"
    case .settings: return "设置"
    }
  }
  var symbol: String {
    switch self {
    case .shortcuts: return "command"
    case .applications: return "square.grid.2x2"
    case .phrases: return "text.quote"
    case .settings: return "gearshape"
    }
  }
  var module: String {
    switch self {
    case .shortcuts: return "功能快捷键"
    case .applications: return "插件中心"
    case .phrases: return "快捷短语"
    case .settings: return "关于"
    }
  }
  init(module: String) {
    switch module {
    case "功能快捷键", "系统状态": self = .shortcuts
    case "快捷短语": self = .phrases
    case "关于": self = .settings
    default: self = .applications
    }
  }
}

struct SoftwareShortcutRequest: Identifiable {
  let id = UUID()
  let itemID: String?
  let draft: ShortcutItem
}

/// Main-window navigation and presentation requests have one lifetime independent of features.
/// Idempotent UI presentation stays separate from AppDelegate's hotkey toggle state machine.
@MainActor
final class MainWorkspace: ObservableObject {
  // Presentation survives leaving the page; background status updates do not navigate it.
  @Published var shortcutSearchText = ""
  @Published var shortcutCategory = "全部"
  let shortcutTableViewports = ShortcutTableViewportStore()
  @Published var applicationSearchText = ""
  @Published var applicationCategory = "全部"
  @Published var selectedPluginID: String?
  @Published var pluginCenterScrollAnchorID: String?
  @Published private var module = "插件中心"
  var selectedModuleName: String {
    get { module }
    set {
      let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
      if value == "启动器" || value == "App 启动器" || value == "快捷短语" {
        selectPlugin(id: value == "快捷短语" ? "phrases" : "launcher")
        module = WorkspaceDestination.applications.module
      } else {
        module = newValue
      }
    }
  }
  var destination: WorkspaceDestination {
    get { WorkspaceDestination(module: module) }
    set { selectedModuleName = newValue.module }
  }
  @Published var selectedAboutSection = SettingsNavigationPolicy.general
  @Published var shortcutGuideFocusRequest = 0
  @Published var shortcutGuideRequestedCategory = "全部"
  @Published var shortcutGuideRequestedSearchText = ""
  @Published var softwareShortcutRequest: SoftwareShortcutRequest?
  @Published var shortcutCreateRequestID = 0
  @Published var shortcutEditRequestID = 0
  @Published var sleepPanelRequestID = 0
  @Published var isMenuBarCustomizationPresented = false
  @Published var isCommunityQRCodePresented = false

  func selectPlugin(id: String?) {
    selectedPluginID = id
    if let id { pluginCenterScrollAnchorID = id }
  }

  func showSettings(section: String? = nil) {
    selectedAboutSection = SettingsNavigationPolicy.normalized(section ?? selectedAboutSection)
    destination = .settings
  }

  func requestCreateShortcut() {
    destination = .shortcuts
    shortcutCreateRequestID &+= 1
  }

  func showShortcutGuide(category: String = "全部") {
    shortcutCategory = category
    shortcutSearchText = ""
    destination = .shortcuts
    shortcutGuideRequestedCategory = category
    shortcutGuideRequestedSearchText = ""
    shortcutGuideFocusRequest &+= 1
  }

  func presentSoftwareShortcut(itemID: String?, draft: ShortcutItem) {
    showShortcutGuide(category: "软件类")
    softwareShortcutRequest = SoftwareShortcutRequest(itemID: itemID, draft: draft)
  }
}
