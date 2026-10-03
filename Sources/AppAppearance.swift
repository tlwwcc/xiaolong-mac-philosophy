import AppKit
import SwiftUI

/// Local UI preference. Never writes AppleInterfaceStyle or changes another app's appearance.
enum AppAppearanceMode: String, CaseIterable, Identifiable {
  case system, light, dark

  var id: String { rawValue }
  var title: String {
    switch self {
    case .system: return "跟随系统"
    case .light: return "浅色"
    case .dark: return "深色"
    }
  }

  var appearance: NSAppearance? {
    switch self {
    case .system: return nil
    case .light: return NSAppearance(named: .aqua)
    case .dark: return NSAppearance(named: .darkAqua)
    }
  }
}

@MainActor
final class AppAppearanceController: ObservableObject {
  static let preferenceKey = "appAppearanceModeV1"
  static let shared = AppAppearanceController()
  private let defaults: UserDefaults
  private var restoreObserver: NSObjectProtocol?

  @Published var mode: AppAppearanceMode {
    didSet {
      defaults.set(mode.rawValue, forKey: Self.preferenceKey)
      apply()
    }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    mode = AppAppearanceMode(rawValue: defaults.string(forKey: Self.preferenceKey) ?? "") ?? .system
    restoreObserver = NotificationCenter.default.addObserver(
      forName: Notification.Name("AIXLGManagedConfigurationDidRestore"), object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.reload()
      }
    }
  }

  deinit {
    if let restoreObserver { NotificationCenter.default.removeObserver(restoreObserver) }
  }

  func reload() {
    mode = AppAppearanceMode(rawValue: defaults.string(forKey: Self.preferenceKey) ?? "") ?? .system
  }

  func apply() {
    // Nil restores native live system tracking. Existing NSHostingViews receive the effective
    // appearance change without reconstructing windows or losing editing/session state.
    NSApplication.shared.appearance = mode.appearance
  }
}

@MainActor
struct AppAppearanceSetting: View {
  @ObservedObject private var appearance: AppAppearanceController

  init(controller: AppAppearanceController? = nil) {
    appearance = controller ?? .shared
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Picker("外观", selection: $appearance.mode) {
        ForEach(AppAppearanceMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .accessibilityLabel("外观")
      Text("立即应用到所有窗口；跟随系统会随 Mac 自动切换。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}
