import AppKit
import SwiftUI

struct GridHeaderView: View {
  @EnvironmentObject private var model: AppModel
  let selectedModule: String

  var body: some View {
    HStack(spacing: 14) {
      VStack(alignment: .leading, spacing: 8) {
        Text(moduleTitle(selectedModule))
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(ink)

        HStack(spacing: 8) {
          Text(headerStatusText)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(muted.opacity(0.86))

          if let warningText {
            HeaderWarningChip(text: warningText)
          }
        }
      }

      Spacer()

      HStack(spacing: 6) {
        if selectedModule == moduleHotkeys || selectedModule == modulePhrases {
          HeaderToolIconButton(systemImage: "plus", title: "新增", tint: accent) {
            if selectedModule == modulePhrases {
              model.addPhrase()
            } else {
              model.addShortcut(module: selectedModule)
            }
          }

          HeaderToolIconButton(systemImage: "trash", title: "删除", tint: ruby, isDestructive: true) {
            if selectedModule == modulePhrases {
              model.deleteSelectedPhrase()
            } else {
              model.deleteSelected()
            }
          }
          .disabled(
            selectedModule == modulePhrases
              ? model.selectedPhraseID == nil
              : model.selectedID.map { model.canDeleteShortcut(id: $0) } != true)
        }

        HeaderToolIconButton(
          systemImage: model.isPaused ? "play.fill" : "pause.fill",
          title: model.isPaused ? "启用后台快捷键" : "暂停后台快捷键",
          tint: model.isPaused ? amber : teal
        ) { model.togglePaused() }

        HeaderToolIconButton(systemImage: "lock.shield", title: "权限", tint: indigo) {
          model.presentAuthorizationCenter()
        }

        HeaderToolIconButton(systemImage: "arrow.clockwise", title: "刷新快捷键", tint: muted) {
          model.reloadHotkeys()
        }

        HeaderToolIconButton(systemImage: "gearshape.fill", title: "设置", tint: accent) {
          model.showSettings()
        }
      }
      .padding(3)
      .background(
        AppVisualStyle.surface.opacity(0.24),
        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(AppVisualStyle.separator, lineWidth: 1)
      )
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .overlay(Rectangle().fill(hairline).frame(height: 1), alignment: .bottom)
  }

  private var headerStatusText: String {
    let runningText = model.isPaused ? "暂停" : "运行"
    let permissionText =
      model.authorizationPermissionsComplete
      ? "权限完整"
      : model.accessibilityAuthorizationStatusText
    return "\(runningText) · \(currentCount) 项 · \(permissionText)"
  }

  private var warningText: String? {
    if model.isPaused {
      return "已暂停"
    }
    if !model.advancedListeningAuthorized {
      return model.authorizationNeedsTargetedRepair ? "需定向修复" : "待授权"
    }
    if !model.hotkeyFailures.isEmpty {
      if model.hotkeyFailures.contains(where: {
        $0.localizedCaseInsensitiveContains("karabiner") || $0.contains("外部") || $0.contains("接管")
      }) {
        return "外部接管"
      }
      return "系统占用"
    }
    return nil
  }

  private var currentCount: Int {
    if isApplicationCenterModule(selectedModule) { return applicationCenterItemCount }
    if selectedModule == moduleScroll { return 1 }
    if selectedModule == moduleLauncher { return model.filteredLauncherApps.count }
    if selectedModule == modulePhrases { return model.phrases.count }
    if selectedModule == moduleScripts { return model.pluginItems.count }
    if selectedModule == moduleSystemStatus { return 2 }
    return model.items.filter { belongsToModule($0, selectedModule) }.count
  }
}
