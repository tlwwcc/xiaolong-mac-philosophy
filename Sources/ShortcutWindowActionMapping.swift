import Foundation

extension ShortcutAction {
  /// Exhaustive on purpose: adding a new shortcut action forces an explicit product decision
  /// about whether it owns a persistent presentation that must follow the family toggle language.
  var windowToggleTarget: ShortcutWindowTarget? {
    switch self {
    case .showPanel:
      return .shortcutGuide
    case .showLauncher:
      return .launcher
    case .showProcessViewer:
      return .processViewer
    case .showClipboardHistory:
      return .clipboardHistory
    case .showCodexNetworkProbe:
      return .networkProbe
    case .openApp, .openURL, .runShell, .showSleepPanel, .windowPreset, .nativeFullScreen,
      .sendShortcut, .closeWindowSmart, .insertText:
      return nil
    }
  }
}
