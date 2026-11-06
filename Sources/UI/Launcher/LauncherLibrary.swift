import AppKit
import SwiftUI

struct AppLauncherPanelView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    LauncherLibraryContent(
      workspace: model.launcherWorkspace, actions: LauncherFeatureActions(model: model))
  }
}

/// Cross-feature operations are supplied by the application composition boundary.
@MainActor
struct LauncherFeatureActions {
  let shortcutCount: Int
  let shortcut: (LauncherApp) -> LauncherAppShortcut?
  let isRecordingShortcut: (LauncherApp) -> Bool
  let editShortcut: (LauncherApp) -> Void
  let uninstall: (LauncherApp) -> Void
  let open: (LauncherApp) -> Void
  let runUtility: () -> Bool

  init(model: AppModel) {
    shortcutCount = model.launcherShortcutCount
    shortcut = model.launcherShortcut(for:)
    isRecordingShortcut = model.isRecordingLauncherShortcut(for:)
    editShortcut = model.openLauncherShortcutManager(for:)
    uninstall = model.requestUninstallLauncherApp
    open = model.openLauncherApp
    runUtility = model.runLauncherUtilityIfAvailable
  }
}

struct LauncherLibraryContent: View {
  @ObservedObject var workspace: LauncherWorkspace
  let actions: LauncherFeatureActions
  @FocusState private var searchFocused: Bool

  private var results: [LauncherApp] {
    Array(workspace.filteredLauncherApps.prefix(80))
  }

  private var utilityItem: LauncherUtilityItem? {
    workspace.launcherUtilityItem
  }

  var body: some View {
    VStack(spacing: 16) {
      VStack(spacing: 12) {
        HStack(spacing: 10) {
          Image(systemName: "magnifyingglass")
            .font(.system(size: 15, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(accent)
            .frame(width: 28, height: 28)
            .background(
              accent.opacity(0.08),
              in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )

          Text("搜索 App、计算和网页")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(ink)

          Spacer(minLength: 12)

          LauncherHeaderMetric(
            value: "\(workspace.launcherApps.count)",
            title: "应用",
            systemImage: "app"
          )
          LauncherHeaderMetric(
            value: "\(actions.shortcutCount)",
            title: "快捷键",
            systemImage: "keyboard"
          )

          ToolbarIconButton(systemImage: "arrow.clockwise", title: "重新扫描 App", tint: muted) {
            workspace.refreshLauncherApps()
          }
        }

        HStack(spacing: 12) {
          Image(systemName: "magnifyingglass")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(searchFocused ? accent : muted)

          TextField("输入 App 名称、算式或网址", text: $workspace.launcherQuery)
            .textFieldStyle(.plain)
            .font(.system(size: 21, weight: .semibold))
            .focused($searchFocused)
            .onSubmit { openFirstResult() }

          if !workspace.launcherQuery.isEmpty {
            Button {
              workspace.launcherQuery = ""
            } label: {
              Image(systemName: "xmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(muted.opacity(0.72))
            }
            .buttonStyle(.plain)
            .help("清空")
          }
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
        .background(
          LinearGradient(
            colors: [
              AppVisualStyle.surface.opacity(0.98),
              AppVisualStyle.surface.opacity(0.86),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          ),
          in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(
              searchFocused ? accent.opacity(0.36) : AppVisualStyle.surface.opacity(0.82),
              lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.030), radius: 9, x: 0, y: 4)
      }
      .padding(14)
      .background(
        LinearGradient(
          colors: [
            AppVisualStyle.surface.opacity(0.70),
            AppVisualStyle.background.opacity(0.52),
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        ),
        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .stroke(AppVisualStyle.separator, lineWidth: 1)
      )

      if workspace.isLauncherScanning {
        VStack(spacing: 10) {
          ProgressView()
            .controlSize(.small)
          Text("正在扫描本机 App")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .premiumPanel(radius: 18)
      } else if results.isEmpty && utilityItem == nil {
        VStack(spacing: 12) {
          Image(systemName: "app.dashed")
            .font(.system(size: 36, weight: .bold))
            .foregroundStyle(muted.opacity(0.62))
          Text(workspace.launcherQuery.isEmpty ? "没有扫描到 App" : "没有匹配的 App")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(ink)
          Button {
            workspace.refreshLauncherApps()
          } label: {
            Label("重新扫描", systemImage: "arrow.clockwise")
          }
          .buttonStyle(GlassLabelButtonStyle(tint: accent, prominent: true))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .premiumPanel(radius: 18)
      } else {
        ScrollView {
          VStack(spacing: 14) {
            if let utilityItem {
              LauncherUtilityCard(item: utilityItem) {
                _ = actions.runUtility()
              }
            }

            if !results.isEmpty {
              LazyVGrid(
                columns: [
                  GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 14, alignment: .top)
                ],
                spacing: 14
              ) {
                ForEach(results) { app in
                  AppLauncherCard(actions: actions, app: app) {
                    actions.open(app)
                  }
                }
              }
            }
          }
          .padding(16)
        }
        .background(
          LinearGradient(
            colors: [
              AppVisualStyle.surface.opacity(0.68),
              AppVisualStyle.background.opacity(0.76),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          ),
          in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 24, style: .continuous)
            .stroke(AppVisualStyle.separator, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.035), radius: 14, x: 0, y: 7)
      }
    }
    .onAppear {
      workspace.launcherQuery = ""
      workspace.ensureLauncherAppsReady()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
        searchFocused = true
      }
    }
  }

  private func openFirstResult() {
    if actions.runUtility() { return }
    guard let first = results.first else { return }
    actions.open(first)
  }
}

struct LauncherHeaderMetric: View {
  let value: String
  let title: String
  let systemImage: String

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: systemImage)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(accent)
      Text(value)
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(ink)
      Text(title)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(muted)
    }
    .padding(.horizontal, 9)
    .frame(height: 28)
    .background(AppVisualStyle.surface.opacity(0.68), in: Capsule())
    .overlay(Capsule().stroke(line.opacity(0.42), lineWidth: 1))
  }
}

struct AppLauncherCard: View {
  let actions: LauncherFeatureActions
  @State private var isHovering = false
  let app: LauncherApp
  let action: () -> Void

  private var shortcut: LauncherAppShortcut? {
    actions.shortcut(app)
  }

  private var isRecordingShortcut: Bool {
    actions.isRecordingShortcut(app)
  }

  private var hasShortcutBadge: Bool {
    shortcut != nil || isRecordingShortcut
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 13) {
        VStack(spacing: 4) {
          AppLauncherIcon(app: app)
            .frame(width: hasShortcutBadge ? 44 : 48, height: hasShortcutBadge ? 44 : 48)

          if isRecordingShortcut {
            LauncherShortcutPill(text: "按下组合键", compact: true, active: true)
          } else if let shortcut {
            LauncherShortcutPill(text: shortcut.hotkey, compact: true)
          }
        }
        .frame(width: 58)

        VStack(alignment: .leading, spacing: 5) {
          Text(app.name)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(ink)
            .lineLimit(1)

          Text(subtitle)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(isRecordingShortcut ? accent : (shortcut == nil ? muted : teal))
            .lineLimit(1)
        }

        Spacer(minLength: 6)

        if isRecordingShortcut {
          LauncherRecordingBadge()
        } else {
          LauncherKeyPill(systemImage: "return")
        }
      }
      .padding(.horizontal, 13)
      .frame(height: hasShortcutBadge ? 88 : 78)
      .background(
        LinearGradient(
          colors: cardColors,
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        ),
        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .stroke(cardStrokeColor, lineWidth: 1)
      )
      .shadow(
        color: Color.black.opacity(isHovering ? 0.07 : 0.032), radius: isHovering ? 16 : 9, x: 0,
        y: isHovering ? 8 : 4
      )
      .scaleEffect(isHovering ? 1.012 : 1)
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .animation(.easeOut(duration: 0.14), value: isHovering)
    .contextMenu {
      Button {
        actions.editShortcut(app)
      } label: {
        Label(
          actions.shortcut(app) == nil ? "设置快捷键…" : "修改快捷键…", systemImage: "keyboard")
      }

      Divider()

      Button(role: .destructive) {
        actions.uninstall(app)
      } label: {
        Label {
          Text("卸载 App…")
            .foregroundColor(ruby)
        } icon: {
          Image(systemName: "trash")
            .foregroundColor(ruby)
        }
      }
    }
  }

  private var subtitle: String {
    if isRecordingShortcut {
      return "正在设置快捷键 · 直接按组合键"
    }
    if shortcut != nil {
      return "已设快捷键 · \(displayPath(app.path))"
    }
    if !app.initials.isEmpty {
      return "\(app.initials) · \(displayPath(app.path))"
    }
    return displayPath(app.path)
  }

  private func displayPath(_ path: String) -> String {
    path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
  }

  private var cardColors: [Color] {
    if isHovering {
      return [AppVisualStyle.surface.opacity(1), accent.opacity(0.075)]
    }
    if isRecordingShortcut {
      return [AppVisualStyle.surface.opacity(1), accent.opacity(0.14)]
    }
    if shortcut != nil {
      return [AppVisualStyle.surface.opacity(0.98), teal.opacity(0.075)]
    }
    return [AppVisualStyle.surface.opacity(0.96), softSurface.opacity(0.82)]
  }

  private var cardStrokeColor: Color {
    if isHovering { return accent.opacity(0.24) }
    if isRecordingShortcut { return accent.opacity(0.44) }
    if shortcut != nil { return teal.opacity(0.26) }
    return AppVisualStyle.surface.opacity(0.88)
  }
}

struct AppLauncherIcon: View {
  @ObservedObject private var iconCache = LauncherIconCache.shared
  let app: LauncherApp
  var plain = false

  var body: some View {
    Group {
      if let icon = iconCache.icon(for: app) {
        Image(nsImage: icon)
          .resizable()
          .interpolation(.high)
          .scaledToFit()
      } else {
        Image(systemName: "app")
          .resizable()
          .scaledToFit()
          .foregroundStyle(muted.opacity(0.68))
      }
    }
    .padding(plain ? 1 : 5)
    .background {
      if !plain {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color(nsColor: .controlBackgroundColor))
      }
    }
    .onAppear { iconCache.load(app) }
  }
}

struct PlainLauncherAppIcon: View {
  let app: LauncherApp
  let size: CGFloat

  var body: some View {
    AppLauncherIcon(app: app, plain: true)
      .frame(width: size, height: size)
  }
}
