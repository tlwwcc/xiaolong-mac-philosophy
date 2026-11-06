import AppKit
import SwiftUI

struct MainWindowUpdateToolbarView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    if showsUpdateEntry {
      HeaderUpdateButton(
        title: "更新",
        isBusy: updateIsBusy,
        busyTitle: updateBusyTitle,
        helpText: updateHelpText,
        accessibilityLabel: updateAccessibilityLabel
      ) {
        model.showAvailableUpdate()
      }
      .accessibilityIdentifier("main.toolbar.update")
    }
  }

  private var showsUpdateEntry: Bool {
    model.hasAvailableUpdate || qaUpdateState != nil
  }

  private var updateIsBusy: Bool {
    model.isUpdateBusy || qaUpdateState == "busy"
  }

  private var updateBusyTitle: String {
    model.updateStatusText.hasPrefix("正在检查更新") ? "检查中" : "正在更新"
  }

  private var updateHelpText: String {
    guard let displayVersion = model.availableUpdateVersion else {
      return "有可用更新，点击查看新版并更新"
    }
    return "发现 \(displayVersion)，点击查看新版并更新"
  }

  private var updateAccessibilityLabel: String {
    guard let displayVersion = model.availableUpdateVersion else {
      return "有可用更新，查看新版并更新"
    }
    return "发现新版本 \(displayVersion)，查看新版并更新"
  }

  private var qaUpdateState: String? {
    #if DEBUG
      let value = ProcessInfo.processInfo.environment["AIXLG_QA_TITLEBAR_UPDATE_STATE"]
      return value == "available" || value == "busy" ? value : nil
    #else
      return nil
    #endif
  }
}
