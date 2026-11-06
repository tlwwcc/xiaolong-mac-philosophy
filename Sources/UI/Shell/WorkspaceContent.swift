import AppKit
import SwiftUI

struct ShortcutGridView: View {
  @EnvironmentObject private var model: AppModel
  let selectedModule: String

  var body: some View {
    VStack(spacing: 14) {
      if selectedModule != moduleHotkeys && !isApplicationCenterModule(selectedModule)
        && selectedModule != moduleAbout && selectedModule != moduleSystemStatus
      {
        GridHeaderView(selectedModule: selectedModule)
          .fixedSize(horizontal: false, vertical: true)
          .layoutPriority(2)
      }

      if selectedModule == moduleHotkeys {
        ShortcutUnifiedPanelView()
      } else if isApplicationCenterModule(selectedModule) {
        PluginCenterView(
          requestedSelectionID: legacyApplicationSelectionID(for: selectedModule)
        )
      } else if selectedModule == moduleSystemStatus {
        SystemStatusPanelView()
      } else if selectedModule == moduleAbout {
        AboutPanelView()
      } else {
        ShortcutTableView(selectedModule: selectedModule)
      }

      if selectedModule != moduleHotkeys && !isApplicationCenterModule(selectedModule)
        && selectedModule != moduleAbout && selectedModule != moduleSystemStatus
      {
        StatusFooterView()
          .fixedSize(horizontal: false, vertical: true)
          .layoutPriority(2)
      }
    }
    .padding(.horizontal, usesSplitWorkspace ? 0 : 20)
    .padding(.vertical, usesSplitWorkspace ? 0 : 16)
  }

  private var usesSplitWorkspace: Bool {
    isApplicationCenterModule(selectedModule) || selectedModule == moduleAbout
  }
}
