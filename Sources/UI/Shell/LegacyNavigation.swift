import AppKit
import SwiftUI

struct AppTopNavigationView: View {
  @EnvironmentObject private var model: AppModel
  @Binding var selectedModule: String

  var body: some View {
    HStack(spacing: 24) {
      HStack(spacing: 10) {
        Image(nsImage: brandIcon())
          .resizable()
          .interpolation(.high)
          .frame(width: 32, height: 32)
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 2) {
          Text("小龙哥 Mac 哲学")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
          HStack(spacing: 8) {
            Text(model.appVersionText)
            if model.isPaused {
              Label("快捷键已暂停", systemImage: "pause.circle")
                .foregroundStyle(AppVisualStyle.warning)
            }
          }
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("小龙哥 Mac 哲学，\(model.appVersionAccessibilityText)\(model.isPaused ? "，快捷键已暂停" : "")")
      }
      .fixedSize(horizontal: true, vertical: false)

      Spacer(minLength: 0)

      HStack(spacing: 4) {
        ForEach(moduleOrder, id: \.self) { module in
          TopModuleButton(
            title: moduleTitle(module),
            systemImage: moduleIcon(module),
            selectedTint: accent,
            selected: module == moduleOptimize
              ? isApplicationCenterModule(selectedModule)
              : selectedModule == module
          ) {
            selectedModule = module
          }
          .accessibilityIdentifier("workspace.module.\(module)")
        }
      }
      .padding(4)
      .frame(minWidth: 368, idealWidth: 420, maxWidth: 468)
      .background(
        AppVisualStyle.background,
        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(hairline, lineWidth: 1)
      )
      .accessibilityElement(children: .contain)
      .accessibilityLabel("主导航")
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 12)
    .background(.bar)
    .accessibilityIdentifier("workspace.top-navigation")
  }
}

struct TopModuleButton: View {
  @State private var hovering = false

  let title: String
  let systemImage: String
  let selectedTint: Color
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: systemImage)
          .font(.system(size: 13, weight: .medium))
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(selected ? selectedTint : Color.secondary.opacity(0.82))
          .frame(width: 18, height: 18)
          .accessibilityHidden(true)

        Text(title)
          .font(.system(size: 12, weight: selected ? .semibold : .medium))
          .foregroundStyle(selected ? ink : Color.secondary)
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
      }
      .padding(.horizontal, 8)
      .frame(maxWidth: .infinity)
      .frame(height: 32)
      .background(buttonBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(selected ? AppVisualStyle.separator : Color.clear, lineWidth: 1)
      )
      .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityValue(selected ? "已选" : "未选")
    .accessibilityAddTraits(selected ? .isSelected : [])
    .onHover { hovering = $0 }
  }

  private var buttonBackground: Color {
    selected ? AppVisualStyle.surface : (hovering ? AppVisualStyle.hover : Color.clear)
  }
}

struct ScopeSidebarView: View {
  @EnvironmentObject private var model: AppModel
  @Binding var selectedModule: String

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 12) {
        ZStack {
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(
              LinearGradient(
                colors: [indigo, accent],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              )
            )
            .shadow(color: accent.opacity(0.18), radius: 14, x: 0, y: 7)
          Image(nsImage: brandIcon())
            .resizable()
            .interpolation(.high)
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .frame(width: 54, height: 54)

        VStack(alignment: .leading, spacing: 5) {
          Text("小龙哥")
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(ink)
          Text("Mac哲学")
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(ink)
          StatusPill(
            text: model.authorizationPermissionsComplete
              ? "后台监听正常" : model.accessibilityAuthorizationStatusText,
            color: model.authorizationPermissionsComplete ? teal : amber)
        }
      }
      .padding(13)
      .premiumPanel(radius: 18)
      .padding(.top, 20)
      .padding(.horizontal, 10)

      VStack(spacing: 7) {
        ForEach(moduleOrder, id: \.self) { module in
          ScopeButton(
            title: moduleTitle(module),
            systemImage: moduleIcon(module),
            selected: module == moduleOptimize
              ? isApplicationCenterModule(selectedModule)
              : selectedModule == module,
            count: count(for: module)
          ) {
            if module == moduleOptimize && !isApplicationCenterModule(selectedModule) {
              model.selectPlugin(id: nil)
            }
            selectedModule = module
          }
        }
      }
      .padding(.horizontal, 10)

      Spacer()

      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Label("已启用", systemImage: "bolt.fill")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(teal)
          Spacer()
          Text("\(model.enabledCount)")
            .font(.system(size: 18, weight: .semibold, design: .rounded))
            .foregroundStyle(ink)
        }
        ProgressView(
          value: Double(model.enabledCount),
          total: max(Double(model.items.count + model.phrases.count), 1)
        )
        .tint(teal)
        .controlSize(.small)
      }
      .padding(14)
      .premiumPanel(radius: 16)
      .padding(.horizontal, 12)

      HStack(spacing: 10) {
        if selectedModule == moduleHotkeys || selectedModule == modulePhrases {
          SidebarActionButton(systemImage: "plus", title: "新增", tint: accent) {
            if selectedModule == modulePhrases {
              model.addPhrase()
            } else {
              model.addShortcut(module: selectedModule)
            }
          }

          SidebarActionButton(systemImage: "trash", title: "删除", tint: ruby) {
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
      }
      .padding(.horizontal, 18)
      .padding(.bottom, 18)
    }
    .background(
      LinearGradient(
        colors: [sidebarBackground, sidebarTint],
        startPoint: .top,
        endPoint: .bottom
      )
    )
  }

  private func count(for module: String) -> Int {
    if module == moduleOptimize { return applicationCenterItemCount }
    if module == moduleScroll { return model.scrollEngineRunning ? 1 : 0 }
    if module == moduleLauncher { return model.launcherApps.count }
    if module == modulePhrases { return model.phrases.count }
    if module == moduleScripts { return model.pluginItems.count }
    if module == moduleSystemStatus { return 2 }
    return model.items.filter { belongsToModule($0, module) }.count
  }
}

struct ScopeButton: View {
  let title: String
  let systemImage: String
  let selected: Bool
  let count: Int
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: systemImage)
          .font(.system(size: 14, weight: .bold))
          .frame(width: 29, height: 29)
          .foregroundStyle(selected ? AppVisualStyle.onAccent : accent)
          .background(
            selected ? AppVisualStyle.surface.opacity(0.18) : glowBlue.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
          )
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.system(size: 14, weight: .semibold))
            .lineLimit(1)
        }
        Spacer()
        Text("\(count)")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(selected ? AppVisualStyle.onAccent.opacity(0.82) : muted)
      }
      .foregroundStyle(selected ? AppVisualStyle.onAccent : ink)
      .padding(.horizontal, 12)
      .frame(height: 54)
      .background(
        selected
          ? LinearGradient(
            colors: [accent, indigo],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
          : LinearGradient(
            colors: [surface.opacity(0.74), AppVisualStyle.surface.opacity(0.48)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          ),
        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(selected ? AppVisualStyle.surface.opacity(0.18) : glassLine, lineWidth: 1)
      )
      .shadow(
        color: selected ? accent.opacity(0.20) : Color.black.opacity(0.018),
        radius: selected ? 10 : 5,
        x: 0,
        y: selected ? 6 : 2
      )
    }
    .buttonStyle(.plain)
    .animation(.easeOut(duration: 0.16), value: selected)
  }
}
