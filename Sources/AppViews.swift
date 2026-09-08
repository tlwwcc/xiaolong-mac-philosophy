import AppKit
import SwiftUI

private let accent = Color(red: 0.02, green: 0.36, blue: 0.95)
private let teal = Color(red: 0.00, green: 0.49, blue: 0.42)
private let amber = Color(red: 0.86, green: 0.52, blue: 0.10)
private let ruby = Color(red: 0.86, green: 0.18, blue: 0.24)
private let violet = Color(red: 0.42, green: 0.23, blue: 0.82)
private let ink = Color(red: 0.07, green: 0.08, blue: 0.09)
private let muted = Color(red: 0.40, green: 0.45, blue: 0.47)
private let appBackground = Color(red: 0.94, green: 0.965, blue: 0.975)
private let sidebarBackground = Color(red: 0.90, green: 0.95, blue: 0.965)
private let surface = Color.white
private let softSurface = Color(red: 0.97, green: 0.98, blue: 0.985)
private let line = Color(red: 0.84, green: 0.87, blue: 0.88)
private let indigo = Color(red: 0.12, green: 0.20, blue: 0.46)
private let glowBlue = Color(red: 0.12, green: 0.46, blue: 1.00)
private let glassLine = Color.white.opacity(0.72)
private let chrome = Color(red: 0.925, green: 0.948, blue: 0.958)
private let sidebarTint = Color(red: 0.885, green: 0.935, blue: 0.955)
private let elevatedSurface = Color.white.opacity(0.88)
private let hairline = Color.black.opacity(0.07)
private let softShadow = Color.black.opacity(0.055)
private let aixlgPurple = Color(red: 107 / 255, green: 35 / 255, blue: 142 / 255)
private let aixlgMist = Color(red: 244 / 255, green: 240 / 255, blue: 248 / 255)
private let aixlgPaper = Color(red: 252 / 255, green: 251 / 255, blue: 253 / 255)

private func symbolForPrimaryAction(_ title: String) -> String {
  if title.contains("新增") { return "plus" }
  if title.contains("删除") || title.contains("卸载") { return "trash" }
  if title.contains("扫描") || title.contains("检测") || title.contains("恢复") {
    return "arrow.clockwise"
  }
  if title.contains("辅助") || title.contains("权限") { return "figure.stand" }
  if title.contains("配置") || title.contains("说明") { return "doc.text.magnifyingglass" }
  if title.contains("官网") || title.contains("网址") { return "safari" }
  if title.contains("应用") || title.contains("目录") || title.contains("文件") { return "folder" }
  if title.contains("运行") { return "play.fill" }
  if title.contains("确定") { return "checkmark" }
  if title.contains("取消") || title.contains("关闭") { return "xmark" }
  return "circle"
}

struct AppBackdrop: View {
  var body: some View {
    ZStack {
      LinearGradient(
        colors: [
          Color(red: 0.968, green: 0.976, blue: 0.980),
          Color(red: 0.936, green: 0.950, blue: 0.958),
          Color(red: 0.958, green: 0.962, blue: 0.958),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )

      VStack(spacing: 0) {
        Rectangle()
          .fill(
            LinearGradient(
              colors: [glowBlue.opacity(0.055), teal.opacity(0.040), Color.clear],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
          .frame(height: 96)
        Spacer()
      }
    }
    .ignoresSafeArea()
  }
}

private struct PremiumPanel: ViewModifier {
  let radius: CGFloat
  let shadowRadius: CGFloat
  let shadowY: CGFloat

  func body(content: Content) -> some View {
    content
      .background(
        LinearGradient(
          colors: [elevatedSurface, Color.white.opacity(0.66)],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        ),
        in: RoundedRectangle(cornerRadius: radius, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .stroke(Color.white.opacity(0.78), lineWidth: 1)
      )
      .shadow(color: softShadow, radius: shadowRadius, x: 0, y: shadowY)
  }
}

extension View {
  fileprivate func premiumPanel(
    radius: CGFloat = 16, shadowRadius: CGFloat = 14, shadowY: CGFloat = 8
  )
    -> some View
  {
    modifier(PremiumPanel(radius: radius, shadowRadius: shadowRadius, shadowY: shadowY))
  }
}

struct IconBadge: View {
  let systemImage: String
  let tint: Color
  var size: CGFloat = 44
  var iconSize: CGFloat = 18
  var filled = true

  var body: some View {
    Image(systemName: systemImage)
      .font(.system(size: iconSize, weight: .semibold))
      .symbolRenderingMode(.hierarchical)
      .foregroundStyle(filled ? .white : tint)
      .frame(width: size, height: size)
      .background(backgroundShape)
      .overlay(
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
          .stroke(Color.white.opacity(filled ? 0.28 : 0.78), lineWidth: 1)
      )
      .shadow(
        color: filled ? tint.opacity(0.20) : Color.black.opacity(0.025), radius: 9, x: 0, y: 5
      )
      .accessibilityHidden(true)
  }

  private var backgroundShape: some ShapeStyle {
    if filled {
      return LinearGradient(
        colors: [tint.opacity(0.96), indigo.opacity(0.94)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    }
    return LinearGradient(
      colors: [Color.white.opacity(0.94), tint.opacity(0.09)],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }
}

struct GlassLabelButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  let tint: Color
  var prominent = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(prominent ? Color.white : (isEnabled ? tint : muted.opacity(0.55)))
      .padding(.horizontal, 12)
      .frame(height: 34)
      .background(
        LinearGradient(
          colors: backgroundColors(isPressed: configuration.isPressed),
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        ),
        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(prominent ? Color.white.opacity(0.26) : Color.white.opacity(0.74), lineWidth: 1)
      )
      .shadow(
        color: isEnabled ? tint.opacity(prominent ? 0.18 : 0.07) : Color.clear,
        radius: configuration.isPressed ? 3 : 8,
        x: 0,
        y: configuration.isPressed ? 1 : 4
      )
      .scaleEffect(configuration.isPressed ? 0.985 : 1)
      .opacity(isEnabled ? 1 : 0.52)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }

  private func backgroundColors(isPressed: Bool) -> [Color] {
    if !isEnabled {
      return [Color.white.opacity(0.50), chrome.opacity(0.52)]
    }
    if prominent {
      return isPressed ? [indigo.opacity(0.98), tint.opacity(0.90)] : [tint, indigo]
    }
    return isPressed
      ? [tint.opacity(0.14), Color.white.opacity(0.78)]
      : [Color.white.opacity(0.96), tint.opacity(0.075)]
  }
}

struct IconOnlyButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  let tint: Color
  var isDestructive = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(isEnabled ? tint : muted.opacity(0.52))
      .frame(width: 30, height: 30)
      .background(
        (isDestructive ? ruby : tint).opacity(configuration.isPressed ? 0.16 : 0.08),
        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .stroke((isDestructive ? ruby : tint).opacity(0.16), lineWidth: 1)
      )
      .opacity(isEnabled ? 1 : 0.48)
      .scaleEffect(configuration.isPressed ? 0.96 : 1)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

struct SidebarActionButton: View {
  @Environment(\.isEnabled) private var isEnabled

  let systemImage: String
  let title: String
  let tint: Color
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: systemImage)
          .font(.system(size: 13, weight: .semibold))
        Text(title)
          .font(.system(size: 12, weight: .medium))
      }
      .frame(maxWidth: .infinity, minHeight: 36)
    }
    .buttonStyle(GlassLabelButtonStyle(tint: tint, prominent: false))
    .help(title)
    .accessibilityLabel(title)
    .opacity(isEnabled ? 1 : 0.52)
  }
}

struct MainWindowTitlebarView: View {
  @EnvironmentObject private var model: AppModel

  let title: String

  var body: some View {
    HStack(spacing: 10) {
      Text(title)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.primary)
        .lineLimit(1)
        .accessibilityIdentifier("main.titlebar.title")

      if showsUpdateEntry {
        HeaderUpdateButton(
          title: "更新到新版本",
          isBusy: updateIsBusy,
          busyTitle: updateBusyTitle,
          helpText: updateHelpText,
          accessibilityLabel: updateAccessibilityLabel
        ) {
          model.runPrimaryUpdateAction()
        }
      }
    }
    .frame(width: 320, height: 28, alignment: .leading)
    .accessibilityIdentifier("main.titlebar")
  }

  private var showsUpdateEntry: Bool {
    model.latestUpdate != nil || qaUpdateState != nil
  }

  private var updateIsBusy: Bool {
    model.isUpdateBusy || qaUpdateState == "busy"
  }

  private var updateBusyTitle: String {
    model.updateStatusText.hasPrefix("正在检查更新") ? "检查中" : "正在更新"
  }

  private var updateHelpText: String {
    guard let displayVersion = model.latestUpdate?.displayVersion else {
      return "发现新版本，点击开始安全更新"
    }
    return "发现 \(displayVersion)，点击开始安全更新"
  }

  private var updateAccessibilityLabel: String {
    guard let displayVersion = model.latestUpdate?.displayVersion else {
      return "发现新版本，更新到新版本"
    }
    return "发现新版本 \(displayVersion)，更新到新版本"
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

struct RootView: View {
  @EnvironmentObject private var model: AppModel
  @State private var isKeepAwakePresented = false

  var body: some View {
    VStack(spacing: 0) {
      AppTopNavigationView(
        selectedModule: Binding(
          get: { model.selectedModuleName },
          set: { model.selectedModuleName = $0 }
        )
      )
      .fixedSize(horizontal: false, vertical: true)
      .layoutPriority(3)
      .zIndex(2)

      Rectangle()
        .fill(Color.white.opacity(0.78))
        .frame(height: 1)
        .zIndex(2)

      ShortcutGridView(selectedModule: model.selectedModuleName)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
    }
    .frame(minWidth: 820, minHeight: 600)
    .background(AppBackdrop())
    .sheet(
      isPresented: Binding(
        get: { model.isCapturingShortcutAction },
        set: { if !$0 { model.cancelShortcutActionCapture() } })
    ) {
      ShortcutActionCaptureSheet()
        .environmentObject(model)
    }
    .sheet(
      isPresented: Binding(
        get: { model.isMenuBarCustomizationPresented },
        set: { model.isMenuBarCustomizationPresented = $0 })
    ) {
      MenuBarCustomizationSheet()
        .environmentObject(model)
    }
    .sheet(
      isPresented: Binding(
        get: { model.isAccessibilityAuthorizationPresented },
        set: { model.isAccessibilityAuthorizationPresented = $0 })
    ) {
      AccessibilityAuthorizationSheetView()
        .environmentObject(model)
    }
    .sheet(isPresented: $isKeepAwakePresented) {
      KeepAwakeSheetView()
        .environmentObject(model)
    }
    .onChange(of: model.sleepPanelRequestID) { _ in
      isKeepAwakePresented = true
    }
    .sheet(
      isPresented: Binding(
        get: { model.isReleaseNotePresented },
        set: { if !$0 { model.markReleaseNoteSeen() } })
    ) {
      if let note = model.pendingReleaseNote {
        ReleaseAnnouncementSheetView(note: note)
          .environmentObject(model)
      }
    }
    .onAppear {
      if model.selectedModuleName == moduleScripts {
        model.selectedModuleName = moduleOptimize
      }
      if model.selectedModuleName == "一键部署" {
        model.selectedModuleName = moduleOptimize
      }
      if model.selectedModuleName == moduleScroll {
        model.selectedModuleName = moduleOptimize
      }
      if model.selectedModuleName == moduleSystemStatus {
        model.selectedModuleName = moduleHotkeys
      }
      model.checkForUpdatesIfNeeded()
      model.showReleaseNoteIfNeeded()
    }

  }
}

struct ReleaseAnnouncementSheetView: View {
  @EnvironmentObject private var model: AppModel
  let note: ReleaseNoteEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 12) {
        IconBadge(systemImage: "sparkles", tint: accent, size: 42, iconSize: 17)

        VStack(alignment: .leading, spacing: 4) {
          Text("已更新到 \(note.displayVersion)")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(ink)
          Text(note.dateText)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(muted)
        }

        Spacer()
      }

      Text(note.title)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(ink)

      Text(note.summary)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(muted)
        .lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)

      VStack(alignment: .leading, spacing: 10) {
        Text("这次更顺手的地方")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(ink)
        ForEach(note.highlights, id: \.self) { item in
          ReleaseNoteBullet(text: item)
        }
      }

      if !note.previousHighlights.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          Text("你已经拥有")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(ink)
          ForEach(note.previousHighlights, id: \.self) { item in
            ReleaseNoteBullet(text: item)
          }
        }
      }

      HStack(spacing: 10) {
        Button {
          model.openReleaseNotesChangelog()
        } label: {
          Label("查看更新记录", systemImage: "safari")
        }
        .buttonStyle(GlassLabelButtonStyle(tint: muted))

        Spacer()

        Button {
          model.markReleaseNoteSeen()
        } label: {
          Label("知道了", systemImage: "checkmark")
        }
        .buttonStyle(GlassLabelButtonStyle(tint: accent, prominent: true))
      }
    }
    .padding(24)
    .frame(width: 520)
    .background(AppBackdrop())
    .allowsApplicationTerminationWhenModal()
  }
}

private struct ReleaseNoteBullet: View {
  let text: String

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(teal)
        .padding(.top, 1)
      Text(text)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(ink)
        .lineSpacing(2)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

private let shortcutGuideCategories = [
  "全部", "截图类", "PDF类", "工具类", "窗口类", "软件类", "系统级", "脚本类", "其他类",
]

struct ShortcutGuideEntry: Identifiable, Equatable {
  enum SourceKind: Equatable {
    case current(index: Int, item: ShortcutItem)
  }

  let kind: SourceKind

  var id: String {
    switch kind {
    case .current(_, let item): return item.id
    }
  }

  var index: Int {
    switch kind {
    case .current(let index, _): return index
    }
  }

  var shortcutItem: ShortcutItem? {
    if case .current(_, let item) = kind { return item }
    return nil
  }

  var title: String {
    switch kind {
    case .current(_, let item): return item.name
    }
  }

  var hotkeyText: String {
    switch kind {
    case .current(_, let item): return item.displayHotkey
    }
  }

  var category: String {
    switch kind {
    case .current(_, let item): return shortcutGuideCategory(for: item)
    }
  }

  var source: String {
    switch kind {
    case .current(_, let item): return shortcutGuideSource(for: item)
    }
  }

  var statusText: String {
    switch kind {
    case .current(_, let item): return item.enabled ? "启用" : "停用"
    }
  }

  var description: String {
    switch kind {
    case .current(_, let item):
      let note = item.note.trimmingCharacters(in: .whitespacesAndNewlines)
      return note.isEmpty ? shortcutHumanDescription(item) : note
    }
  }

  var actionTitle: String {
    switch kind {
    case .current(_, let item): return item.action.title
    }
  }

  var scopeText: String {
    switch kind {
    case .current(_, let item): return item.scope.isEmpty ? "未设置" : item.scope
    }
  }

  var targetText: String {
    switch kind {
    case .current(_, let item): return item.target
    }
  }

  func matches(_ query: String) -> Bool {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedQuery.isEmpty else { return true }
    return [
      title,
      scopeText,
      hotkeyText,
      actionTitle,
      targetText,
      description,
      category,
      source,
      statusText,
    ].contains { $0.localizedCaseInsensitiveContains(normalizedQuery) }
  }
}

private func shortcutGuideCategoryIcon(_ category: String) -> String {
  switch category {
  case "全部": return "square.grid.2x2"
  case "软件类": return "app.badge"
  case "窗口类": return "rectangle.on.rectangle"
  case "截图类": return "camera.viewfinder"
  case "PDF类": return "doc.richtext"
  case "系统级": return "gearshape.2"
  case "其他类": return "command"
  default: return "command"
  }
}

private func shortcutGuideCategoryTint(_ category: String) -> Color {
  switch category {
  case "全部": return accent
  case "软件类": return Color(red: 0.16, green: 0.42, blue: 0.76)
  case "窗口类": return Color(red: 0.08, green: 0.50, blue: 0.45)
  case "截图类": return amber
  case "PDF类": return accent
  case "系统级": return indigo
  case "其他类": return muted
  default: return muted
  }
}

private func shortcutGuideCategoryPreview(_ category: String) -> String {
  switch category {
  case "全部": return "Caps / ⌘"
  case "软件类": return "Caps E"
  case "窗口类": return "Caps ◀"
  case "截图类": return "Caps + 1"
  case "PDF类": return "⌥ [ / ]"
  case "系统级": return "Caps ⌘ X"
  case "其他类": return "Caps B"
  default: return "Caps"
  }
}

struct AccessibilityAuthorizationSheetView: View {
  @EnvironmentObject private var model: AppModel
  @State private var isClearPermissionConfirmationPresented = false
  @State private var isPermissionRecoveryExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .center, spacing: 12) {
        IconBadge(systemImage: "lock.shield.fill", tint: indigo, size: 40, iconSize: 17)

        VStack(alignment: .leading, spacing: 5) {
          HStack(spacing: 8) {
            Text(
              model.allRequiredPermissionsComplete
                ? (model.authorizationRelaunchCompleted ? "权限已生效" : "权限已开启")
                : "权限设置向导"
            )
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(ink)
            StatusPill(
              text: model.allRequiredPermissionsComplete ? "已开启" : "待授权",
              color: model.allRequiredPermissionsComplete ? teal : amber)
          }
          Text(
            model.allRequiredPermissionsComplete
              ? "两项基础权限均已生效。"
              : "从这里开始，按提示完成快捷键所需的两项权限。"
          )
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(muted)
          .lineLimit(2)
        }

        Spacer()

        Button {
          model.dismissAuthorizationCenter()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(muted)
            .frame(width: 30, height: 30)
            .background(Color.white.opacity(0.45), in: Circle())
            .overlay(Circle().stroke(line.opacity(0.54), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("收起窗口；当前授权步骤会继续")
      }

      Label(
        model.allRequiredPermissionsComplete
          ? "所需权限均已生效。"
          : "系统设置前会出现授权卡；完成一项后会自动进入下一项。",
        systemImage: model.allRequiredPermissionsComplete
          ? "checkmark.circle.fill" : "hand.draw.fill"
      )
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(model.allRequiredPermissionsComplete ? teal : indigo)
      .fixedSize(horizontal: false, vertical: true)
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(softSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 14).stroke(line.opacity(0.68), lineWidth: 1))

      VStack(spacing: 8) {
        AuthorizationPermissionStepRow(
          step: 1,
          title: "辅助功能",
          isGranted: model.advancedListeningAuthorized,
          isCurrent: !model.advancedListeningAuthorized)
        AuthorizationPermissionStepRow(
          step: 2,
          title: "输入监控",
          isGranted: model.inputMonitoringAuthorized,
          isCurrent: model.advancedListeningAuthorized && !model.inputMonitoringAuthorized)
      }

      Button {
        model.performAuthorizationPrimaryAction()
      } label: {
        Label(
          model.authorizationPrimaryButtonTitle,
          systemImage: model.authorizationManualRelaunchRequired
            ? "power.circle.fill"
            : (model.authorizationAutomaticRelaunchInProgress
              ? "arrow.clockwise.circle.fill"
              : (model.allRequiredPermissionsComplete
                ? (model.authorizationRelaunchCompleted
                  ? "checkmark.circle.fill" : "arrow.clockwise.circle.fill")
                : "lock.open.fill"))
        )
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(
        GlassLabelButtonStyle(
          tint: model.allRequiredPermissionsComplete ? teal : indigo,
          prominent: true)
      )
      .disabled(model.authorizationPrimaryButtonDisabled)

      Text(model.authorizationPrimarySafetyText)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(muted)
        .fixedSize(horizontal: false, vertical: true)

      DisclosureGroup("权限已经打开，但功能仍不生效？", isExpanded: $isPermissionRecoveryExpanded) {
        HStack(spacing: 8) {
          Text("仅在系统权限记录失效时使用：")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(muted)

          Button {
            isClearPermissionConfirmationPresented = true
          } label: {
            Label(
              model.isRepairingAuthorization ? "正在修复权限…" : "修复失效权限…",
              systemImage: "arrow.counterclockwise.circle")
          }
          .buttonStyle(.plain)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(model.isRepairingAuthorization ? muted : amber)
          .disabled(model.isRepairingAuthorization)
          .accessibilityLabel("修复本软件失效的系统权限")
          .help("清理本 App 的旧权限记录，随后自动重启并重新引导授权")
        }
        .padding(.top, 6)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if !model.authorizationRepairResultText.isEmpty {
        Text(model.authorizationRepairResultText)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(ink)
          .fixedSize(horizontal: false, vertical: true)
          .padding(10)
          .background(
            Color.white.opacity(0.62),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      }
    }
    .padding(20)
    .frame(width: 560)
    .background(AppBackdrop())
    .allowsApplicationTerminationWhenModal()
    .explicitPermissionClearConfirmation(
      isPresented: $isClearPermissionConfirmationPresented,
      model: model)
  }
}

private struct AuthorizationPermissionStepRow: View {
  let step: Int
  let title: String
  let isGranted: Bool
  let isCurrent: Bool

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: isGranted ? "checkmark.circle.fill" : "\(step).circle.fill")
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(isGranted ? teal : (isCurrent ? indigo : muted.opacity(0.72)))
        .frame(width: 22)

      Text(title)
        .font(.system(size: 12, weight: isCurrent ? .semibold : .medium))
        .foregroundStyle(isCurrent || isGranted ? ink : muted)

      Spacer()

      Text(isGranted ? "已完成" : (isCurrent ? "正在设置" : "稍后设置"))
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(isGranted ? teal : (isCurrent ? indigo : muted))
    }
    .padding(.horizontal, 11)
    .frame(height: 38)
    .background(
      (isCurrent ? indigo.opacity(0.09) : softSurface),
      in: RoundedRectangle(cornerRadius: 12, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(isCurrent ? indigo.opacity(0.34) : line.opacity(0.58), lineWidth: 1)
    )
  }
}

private struct ExplicitPermissionClearConfirmationModifier: ViewModifier {
  @Binding var isPresented: Bool
  let model: AppModel

  func body(content: Content) -> some View {
    content.alert(
      "修复本 App 的权限？",
      isPresented: $isPresented
    ) {
      Button("取消", role: .cancel) {}
      Button("清除旧记录并修复", role: .destructive) {
        model.clearAuthorizationPermissionsAndRestart(userConfirmed: true)
      }
    } message: {
      Text("会清理“小龙哥 Mac 哲学”的辅助功能、屏幕录制和输入监控旧记录，不影响其他 App。软件随后会自动重启，并重新引导你打开系统开关。")
    }
  }
}

extension View {
  fileprivate func explicitPermissionClearConfirmation(
    isPresented: Binding<Bool>,
    model: AppModel
  ) -> some View {
    modifier(
      ExplicitPermissionClearConfirmationModifier(
        isPresented: isPresented,
        model: model))
  }
}

struct ShortcutGuideCategoryButton: View {
  let title: String
  let count: Int
  let selected: Bool
  let action: () -> Void

  var body: some View {
    let tint = shortcutGuideCategoryTint(title)

    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: shortcutGuideCategoryIcon(title))
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(selected ? .white : tint)
          .frame(width: 16)

        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 5) {
            Text(title)
              .font(.system(size: 12, weight: selected ? .semibold : .medium))
              .lineLimit(1)

            Text("\(count)")
              .font(.system(size: 10, weight: .bold, design: .rounded))
              .foregroundStyle(selected ? .white.opacity(0.84) : tint.opacity(0.82))
              .padding(.horizontal, 5)
              .frame(height: 16)
              .background(
                selected ? Color.white.opacity(0.16) : tint.opacity(0.10),
                in: Capsule()
              )
          }

          Text(shortcutGuideCategoryPreview(title))
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(selected ? .white.opacity(0.72) : muted.opacity(0.82))
            .lineLimit(1)
        }
      }
      .foregroundStyle(selected ? .white : ink)
      .padding(.horizontal, 11)
      .frame(height: 42)
      .background(
        selected ? tint : Color.white.opacity(0.92),
        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
      )
      .background(
        tint.opacity(selected ? 0 : 0.08),
        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(selected ? Color.white.opacity(0.22) : tint.opacity(0.18), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
  }
}

struct ShortcutFormTextField: View {
  let title: String
  let placeholder: String
  @Binding var text: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(muted)
      TextField(placeholder, text: $text)
        .textFieldStyle(.plain)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(ink)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .background(
          Color.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(glassLine, lineWidth: 1))
    }
  }
}

struct ShortcutGuideRow: View {
  let entry: ShortcutGuideEntry
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        ShortcutGuideActionBadge(entry: entry, category: entry.category)

        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 7) {
            Text(entry.title)
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(ink)
              .lineLimit(1)
            StatusPill(
              text: entry.statusText, color: entry.shortcutItem?.enabled == false ? muted : teal)
          }
          ShortcutGuideKeycaps(text: entry.hotkeyText)
        }

        Spacer(minLength: 8)
      }
      .padding(.horizontal, 12)
      .frame(height: 70)
      .background(
        selected
          ? LinearGradient(
            colors: [accent.opacity(0.12), teal.opacity(0.055)], startPoint: .leading,
            endPoint: .trailing)
          : LinearGradient(
            colors: [Color.white.opacity(0.96), Color.white.opacity(0.82)], startPoint: .leading,
            endPoint: .trailing)
      )
      .overlay(Rectangle().fill(line.opacity(0.72)).frame(height: 1), alignment: .bottom)
    }
    .buttonStyle(.plain)
  }
}

struct ShortcutGuideActionBadge: View {
  let entry: ShortcutGuideEntry
  let category: String

  var body: some View {
    Group {
      if let appIcon {
        Image(nsImage: appIcon)
          .resizable()
          .interpolation(.high)
          .scaledToFit()
          .padding(5)
      } else {
        Image(systemName: iconName)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(tint)
      }
    }
    .frame(width: 34, height: 34)
    .background(
      appIcon == nil ? tint.opacity(0.10) : Color.white.opacity(0.92),
      in: RoundedRectangle(cornerRadius: 10, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(appIcon == nil ? tint.opacity(0.12) : Color.white.opacity(0.88), lineWidth: 1)
    )
  }

  private var appIcon: NSImage? {
    if let item = entry.shortcutItem {
      return shortcutGuideAppIcon(for: item)
    }
    return nil
  }

  private var iconName: String {
    shortcutGuideCategoryIcon(category)
  }

  private var tint: Color {
    shortcutGuideCategoryTint(category)
  }
}

struct ShortcutGuideKeycaps: View {
  let text: String

  var body: some View {
    HStack(spacing: 4) {
      ForEach(text.components(separatedBy: " + "), id: \.self) { key in
        Text(shortcutKeycapLabel(key))
          .font(.system(size: 11, weight: .semibold, design: .rounded))
          .foregroundStyle(accent.opacity(0.82))
          .padding(.horizontal, 7)
          .frame(height: 21)
          .background(
            softSurface.opacity(0.92), in: RoundedRectangle(cornerRadius: 6, style: .continuous)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .stroke(line.opacity(0.62), lineWidth: 1)
          )
      }
    }
  }
}

private func shortcutKeycapLabel(_ key: String) -> String {
  switch key {
  case "Left": return "◀"
  case "Right": return "▶"
  case "Up": return "▲"
  case "Down": return "▼"
  default: return key
  }
}

struct ShortcutGuideDetailPane: View {
  let selectedCategory: String
  let entry: ShortcutGuideEntry?
  let totalCount: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if let entry {
        ShortcutGuideEntryDetail(
          entry: entry,
          totalCount: totalCount
        )
      } else {
        ShortcutGuideNoSelectionView()
      }
    }
    .padding(20)
  }
}

struct ShortcutGuideEntryDetail: View {
  let entry: ShortcutGuideEntry
  let totalCount: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 12) {
        ShortcutGuideActionBadge(entry: entry, category: entry.category)
        VStack(alignment: .leading, spacing: 4) {
          Text(entry.title)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(ink)
            .lineLimit(2)
          Text("第 \(entry.index + 1) 条，共 \(totalCount) 条")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(muted)
        }
        Spacer()
      }

      ShortcutGuideKeycaps(text: entry.hotkeyText)

      HStack(spacing: 8) {
        PluginChip(text: entry.category, color: accent)
        PluginChip(
          text: entry.statusText, color: entry.shortcutItem?.enabled == false ? muted : teal)
        PluginChip(text: entry.source, color: violet)
      }

      ShortcutGuideDetailBlock(title: "说明", value: entry.description)
      ShortcutGuideDetailBlock(title: "执行动作", value: entry.actionTitle)
      ShortcutGuideDetailBlock(title: "作用范围", value: entry.scopeText)

      if !entry.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        ShortcutGuideDetailBlock(title: "执行内容", value: entry.targetText)
      }

      Spacer()
    }
  }
}

struct ShortcutGuideDetailBlock: View {
  let title: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(muted)
      Text(value)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(ink)
        .lineSpacing(3)
        .textSelection(.enabled)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Color.white.opacity(0.70), in: RoundedRectangle(cornerRadius: 12, style: .continuous)
    )
    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(glassLine, lineWidth: 1))
  }
}

struct ShortcutGuideEmptyState: View {
  let searchText: String
  let selectedCategory: String

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 24, weight: .semibold))
        .foregroundStyle(muted.opacity(0.70))
      Text(
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "这一类还没有快捷键" : "没有匹配结果"
      )
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(ink)
      Text("列表读取当前 App 配置。")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(muted)
    }
    .frame(maxWidth: .infinity, minHeight: 220)
  }
}

struct ShortcutGuideReservedListState: View {
  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: "rectangle.stack.badge.plus")
        .font(.system(size: 24, weight: .semibold))
        .foregroundStyle(amber)
      Text("外部软件分类已预留")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(ink)
      Text("第一版不会自动扫描第三方软件快捷键。")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(muted)
    }
    .frame(maxWidth: .infinity, minHeight: 220)
  }
}

struct ShortcutGuideExternalReservedView: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      IconBadge(systemImage: "rectangle.stack.badge.plus", tint: amber, size: 46, iconSize: 19)
      Text("外部软件快捷键")
        .font(.system(size: 22, weight: .semibold))
        .foregroundStyle(ink)
      Text("这里先作为结构入口保留。当前版本只展示小龙哥 Mac 哲学内部真实配置，不读取、不扫描、不判断第三方软件的快捷键。")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(muted)
        .lineSpacing(4)
      Spacer()
    }
  }
}

struct ShortcutGuideNoSelectionView: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      IconBadge(systemImage: "keyboard", tint: muted, size: 46, iconSize: 19)
      Text("选择一条快捷键查看说明")
        .font(.system(size: 19, weight: .semibold))
        .foregroundStyle(ink)
      Text("也可以直接搜索功能名、按键或说明。")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(muted)
      Spacer()
    }
  }
}

private func shortcutGuideCategory(for item: ShortcutItem) -> String {
  if item.commandID != nil { return "截图类" }
  if isScreenshotShortcut(item) { return "截图类" }
  if item.action == .showPanel || item.action == .showLauncher
    || item.action == .showProcessViewer || item.action == .showClipboardHistory
    || item.action == .showCodexNetworkProbe
  {
    return "工具类"
  }
  if isSystemLevelShortcut(item) { return "系统级" }
  if item.action == .runShell || item.scope == "常用脚本" { return "脚本类" }
  if item.action == .windowPreset || item.action == .nativeFullScreen
    || item.action == .closeWindowSmart
  {
    return "窗口类"
  }
  if item.action == .openApp || isOpenFileOrFolderShortcut(item) {
    return "软件类"
  }
  return "其他类"
}

private func shortcutGuideCategoryDisplayName(_ category: String) -> String {
  switch category {
  case "窗口类": return "窗口"
  case "软件类": return "软件"
  case "截图类": return "游目"
  case "PDF类": return "披卷"
  case "工具类": return "工具"
  case "系统级": return "系统"
  case "脚本类": return "脚本"
  case "其他类": return "其他"
  default: return category
  }
}

private func shortcutGuideSource(for item: ShortcutItem) -> String {
  if item.commandID != nil { return "游目" }
  if isScreenshotShortcut(item) { return "游目" }
  if isSystemSettingsShortcut(item) { return "系统设置" }
  if isSystemLevelShortcut(item) { return "系统级" }
  if item.scope == "常用脚本" { return "功能快捷键" }
  if item.action == .insertText { return "快捷短语" }
  return "功能快捷键"
}

private func isOpenFileOrFolderShortcut(_ item: ShortcutItem) -> Bool {
  guard item.action == .openURL else { return false }
  let target = item.target.trimmingCharacters(in: .whitespacesAndNewlines)
  return target.hasPrefix("/") || target.hasPrefix("~/")
}

private func isScreenshotShortcut(_ item: ShortcutItem) -> Bool {
  shortcutGuideTextLooksLikeScreenshot(
    [
      item.name,
      item.scope,
      item.target,
      item.note,
      item.action.title,
    ].joined(separator: " ")
  )
}

private func shortcutGuideTextLooksLikeScreenshot(_ text: String) -> Bool {
  let normalized = text.folding(
    options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
  return [
    "截图",
    "截屏",
    "cleanshot",
    "screenshot",
    "screen shot",
    "screencapture",
    "capture",
    "pin last screenshot",
    "滚动截图",
    "图片标注",
    "⇧⌘5",
    "⇧ ⌘ 5",
    "shift command 5",
  ].contains { normalized.localizedCaseInsensitiveContains($0) }
}

private func isSystemLevelShortcut(_ item: ShortcutItem) -> Bool {
  if item.action == .showSleepPanel || isSystemSettingsShortcut(item) {
    return true
  }
  let normalized = [
    item.name,
    item.scope,
    item.target,
    item.note,
  ].joined(separator: " ")
    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
  return [
    "休眠",
    "睡眠",
    "保持唤醒",
    "无限保持",
    "系统设置",
    "系统偏好",
    "系统面板",
    "系统辅助",
    "system events",
    "systempreferences",
    "systemsettings",
    "shortcuts run",
  ].contains { normalized.localizedCaseInsensitiveContains($0) }
}

private func shortcutGuideAppIcon(for item: ShortcutItem) -> NSImage? {
  guard item.action == .openApp else { return nil }
  guard let appURL = shortcutGuideAppURL(for: item.target) else { return nil }
  return NSWorkspace.shared.icon(forFile: appURL.path)
}

private func shortcutGuideAppIcon(forAppTarget target: String) -> NSImage? {
  guard let appURL = shortcutGuideAppURL(for: target) else { return nil }
  return NSWorkspace.shared.icon(forFile: appURL.path)
}

private func shortcutGuideAppURL(for target: String) -> URL? {
  let trimmedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmedTarget.isEmpty else { return nil }
  if trimmedTarget.hasPrefix("bundle:") {
    let bundleID = String(trimmedTarget.dropFirst("bundle:".count))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !bundleID.isEmpty else { return nil }
    return shortcutGuideApplicationURL(forBundleIdentifier: bundleID)
  }

  let expandedPath: String
  if trimmedTarget == "~" {
    expandedPath = NSHomeDirectory()
  } else if trimmedTarget.hasPrefix("~/") {
    expandedPath = NSHomeDirectory() + String(trimmedTarget.dropFirst())
  } else {
    expandedPath = trimmedTarget
  }
  guard expandedPath.hasSuffix(".app"),
    FileManager.default.fileExists(atPath: expandedPath)
  else { return nil }
  return URL(fileURLWithPath: expandedPath, isDirectory: true)
}

private func shortcutGuideApplicationURL(forBundleIdentifier bundleID: String) -> URL? {
  if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
    return url
  }
  let searchRoots = [
    URL(fileURLWithPath: "/Applications", isDirectory: true),
    URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
      "Applications", isDirectory: true),
  ]
  for root in searchRoots {
    guard
      let children = try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles])
    else { continue }
    for child in children where child.pathExtension == "app" {
      if Bundle(url: child)?.bundleIdentifier == bundleID {
        return child
      }
    }
  }
  return nil
}

private let moduleHotkeys = "功能快捷键"
private let moduleOptimize = "插件中心"
private let moduleLauncher = "启动器"
private let modulePhrases = "快捷短语"
private let moduleAbout = "关于"
private let moduleScripts = "内置插件"
private let moduleScroll = "滚动手感"
private let moduleSystemStatus = "系统状态"

private let moduleOrder = [
  moduleHotkeys, moduleOptimize, moduleAbout,
]

private let applicationYoumuID = "youmu"
private let applicationPijuanPDFID = "pijuan-pdf"
private let applicationAIPlayerID = "ai-player"
private let applicationFeatureShortcutsID = "feature-shortcuts"
private let applicationPhrasesID = AppModel.phrasesPluginID
private let applicationClipboardHistoryID = "clipboard-history"
private let applicationPermanentUninstallID = "permanent-uninstall"
private let applicationCenterItemCount = 16

private func isApplicationCenterModule(_ module: String) -> Bool {
  switch module {
  case moduleOptimize, moduleLauncher, modulePhrases, moduleScripts, moduleScroll:
    return true
  default:
    return false
  }
}

private func legacyApplicationSelectionID(for module: String) -> String? {
  switch module {
  case moduleLauncher: return AppModel.launcherPluginID
  case modulePhrases: return applicationPhrasesID
  case moduleScroll: return "mouse-scroll"
  default: return nil
  }
}

private func moduleTitle(_ module: String) -> String {
  switch module {
  case moduleOptimize: return "应用中心"
  case moduleHotkeys: return "功能快捷键"
  case moduleLauncher: return "启动器"
  case modulePhrases: return "快捷短语"
  case moduleAbout: return "设置"
  case moduleScripts: return "脚本插件"
  case moduleScroll: return "滚动手感"
  case moduleSystemStatus: return "系统状态"
  default: return module
  }
}

private func moduleSubtitle(_ module: String) -> String {
  switch module {
  case moduleOptimize: return "应用"
  case moduleHotkeys: return "快捷键"
  case moduleLauncher: return "启动器"
  case modulePhrases: return "短语"
  case moduleAbout: return "设置与关于"
  case moduleScripts: return "脚本"
  case moduleScroll: return "滚轮"
  case moduleSystemStatus: return "状态"
  default: return ""
  }
}

private func moduleIcon(_ module: String) -> String {
  switch module {
  case moduleOptimize: return "square.grid.2x2.fill"
  case moduleHotkeys: return "command"
  case moduleLauncher: return "magnifyingglass"
  case modulePhrases: return "quote.bubble"
  case moduleAbout: return "gearshape"
  case moduleScripts: return "puzzlepiece.extension"
  case moduleScroll: return "scroll"
  case moduleSystemStatus: return "speedometer"
  default: return "square.grid.2x2"
  }
}

private func module(for item: ShortcutItem) -> String {
  if item.scope == "常用脚本" {
    return moduleHotkeys
  }
  if item.action == .showSleepPanel { return moduleHotkeys }
  if item.action == .insertText {
    return modulePhrases
  }
  if isLauncherManagedAppShortcut(item) {
    return moduleLauncher
  }
  return moduleHotkeys
}

private func isLauncherManagedAppShortcut(_ item: ShortcutItem) -> Bool {
  guard item.action == .openApp else { return false }
  if item.scope.localizedCaseInsensitiveContains("系统") { return false }
  let target = item.target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  if target.contains("com.apple.systempreferences") { return false }
  if target.contains("/system/applications/apps.app") { return false }
  return true
}

private func belongsToModule(_ item: ShortcutItem, _ selectedModule: String) -> Bool {
  module(for: item) == selectedModule
}

private func brandIcon() -> NSImage {
  NSImage(named: "AppIcon")
    ?? NSImage(systemSymbolName: "command.square.fill", accessibilityDescription: nil)
    ?? NSImage()
}

struct AppTopNavigationView: View {
  @EnvironmentObject private var model: AppModel
  @Binding var selectedModule: String

  var body: some View {
    VStack(spacing: 9) {
      HStack(spacing: 12) {
        Image(nsImage: brandIcon())
          .resizable()
          .interpolation(.high)
          .frame(width: 32, height: 32)
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
          .shadow(color: Color.black.opacity(0.055), radius: 4, x: 0, y: 2)

        VStack(alignment: .leading, spacing: 2) {
          Text("小龙哥 Mac 哲学")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
          Text(model.appVersionText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .layoutPriority(2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("小龙哥 Mac 哲学，\(model.appVersionAccessibilityText)")

        Spacer(minLength: 12)
      }
      .frame(minHeight: 32)

      HStack(alignment: .center, spacing: 6) {
        ForEach(moduleOrder, id: \.self) { module in
          TopModuleButton(
            title: moduleTitle(module),
            systemImage: moduleIcon(module),
            selectedTint: module == moduleOptimize ? aixlgPurple : accent,
            selected: module == moduleOptimize
              ? isApplicationCenterModule(selectedModule)
              : selectedModule == module
          ) {
            if module == moduleOptimize && !isApplicationCenterModule(selectedModule) {
              model.selectPlugin(id: nil)
            }
            if module == moduleAbout {
              model.showSettings()
            } else {
              selectedModule = module
            }
          }
        }
      }
      .padding(3)
      .frame(maxWidth: .infinity)
      .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .background(
        Color.white.opacity(0.35),
        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(hairline, lineWidth: 1)
      )
    }
    .padding(.horizontal, 24)
    .padding(.top, 9)
    .padding(.bottom, 9)
    .background(.bar)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(hairline)
        .frame(height: 1)
    }
  }
}

struct TopModuleButton: View {
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
          .minimumScaleFactor(0.86)
      }
      .padding(.horizontal, 8)
      .frame(maxWidth: .infinity)
      .frame(height: 34)
      .background(buttonBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(selected ? Color.white.opacity(0.82) : Color.clear, lineWidth: 1)
      )
      .shadow(color: selected ? Color.black.opacity(0.060) : Color.clear, radius: 7, x: 0, y: 3)
      .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityValue(selected ? "已选" : "未选")
    .animation(.easeOut(duration: 0.16), value: selected)
  }

  private var buttonBackground: some ShapeStyle {
    if selected {
      return LinearGradient(
        colors: [Color.white.opacity(0.97), Color.white.opacity(0.82)],
        startPoint: .top,
        endPoint: .bottom
      )
    }
    return LinearGradient(
      colors: [Color.white.opacity(0.01), Color.white.opacity(0.01)],
      startPoint: .top,
      endPoint: .bottom
    )
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
      .premiumPanel(radius: 18, shadowRadius: 11, shadowY: 6)
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
      .premiumPanel(radius: 16, shadowRadius: 10, shadowY: 5)
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
          .foregroundStyle(selected ? .white : accent)
          .background(
            selected ? Color.white.opacity(0.18) : glowBlue.opacity(0.08),
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
          .foregroundStyle(selected ? .white.opacity(0.82) : muted)
      }
      .foregroundStyle(selected ? .white : ink)
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
            colors: [surface.opacity(0.74), Color.white.opacity(0.48)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          ),
        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(selected ? Color.white.opacity(0.18) : glassLine, lineWidth: 1)
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
    .padding(.horizontal, 18)
    .padding(.vertical, 16)
  }
}

struct AppLauncherPanelView: View {
  @EnvironmentObject private var model: AppModel
  @FocusState private var searchFocused: Bool

  private var results: [LauncherApp] {
    Array(model.filteredLauncherApps.prefix(80))
  }

  private var utilityItem: LauncherUtilityItem? {
    model.launcherUtilityItem
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
            value: "\(model.launcherApps.count)",
            title: "应用",
            systemImage: "app"
          )
          LauncherHeaderMetric(
            value: "\(model.launcherShortcutCount)",
            title: "快捷键",
            systemImage: "keyboard"
          )

          ToolbarIconButton(systemImage: "arrow.clockwise", title: "重新扫描 App", tint: muted) {
            model.refreshLauncherApps()
          }
        }

        HStack(spacing: 12) {
          Image(systemName: "magnifyingglass")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(searchFocused ? accent : muted)

          TextField("输入 App 名称、算式或网址", text: $model.launcherQuery)
            .textFieldStyle(.plain)
            .font(.system(size: 21, weight: .semibold))
            .focused($searchFocused)
            .onSubmit { openFirstResult() }

          if !model.launcherQuery.isEmpty {
            Button {
              model.launcherQuery = ""
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
              Color.white.opacity(0.98),
              Color.white.opacity(0.86),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          ),
          in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(searchFocused ? accent.opacity(0.36) : Color.white.opacity(0.82), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.030), radius: 9, x: 0, y: 4)
      }
      .padding(14)
      .background(
        LinearGradient(
          colors: [
            Color.white.opacity(0.70),
            Color(red: 0.945, green: 0.972, blue: 0.984).opacity(0.52),
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        ),
        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .stroke(Color.white.opacity(0.72), lineWidth: 1)
      )

      if model.isLauncherScanning {
        VStack(spacing: 10) {
          ProgressView()
            .controlSize(.small)
          Text("正在扫描本机 App")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .premiumPanel(radius: 18, shadowRadius: 10, shadowY: 5)
      } else if results.isEmpty && utilityItem == nil {
        VStack(spacing: 12) {
          Image(systemName: "app.dashed")
            .font(.system(size: 36, weight: .bold))
            .foregroundStyle(muted.opacity(0.62))
          Text(model.launcherQuery.isEmpty ? "没有扫描到 App" : "没有匹配的 App")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(ink)
          Button {
            model.refreshLauncherApps()
          } label: {
            Label("重新扫描", systemImage: "arrow.clockwise")
          }
          .buttonStyle(GlassLabelButtonStyle(tint: accent, prominent: true))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .premiumPanel(radius: 18, shadowRadius: 10, shadowY: 5)
      } else {
        ScrollView {
          VStack(spacing: 14) {
            if let utilityItem {
              LauncherUtilityCard(item: utilityItem) {
                model.runLauncherUtilityIfAvailable()
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
                  AppLauncherCard(app: app) {
                    model.openLauncherApp(app)
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
              Color.white.opacity(0.68),
              Color(red: 0.965, green: 0.98, blue: 0.985).opacity(0.76),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          ),
          in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 24, style: .continuous)
            .stroke(Color.white.opacity(0.82), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.035), radius: 14, x: 0, y: 7)
      }
    }
    .onAppear {
      model.launcherQuery = ""
      model.ensureLauncherAppsReady()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
        searchFocused = true
      }
    }
  }

  private func openFirstResult() {
    if model.runLauncherUtilityIfAvailable() { return }
    guard let first = results.first else { return }
    model.openLauncherApp(first)
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
    .background(Color.white.opacity(0.68), in: Capsule())
    .overlay(Capsule().stroke(line.opacity(0.42), lineWidth: 1))
  }
}

struct AppLauncherCard: View {
  @EnvironmentObject private var model: AppModel
  @State private var isHovering = false
  let app: LauncherApp
  let action: () -> Void

  private var shortcut: LauncherAppShortcut? {
    model.launcherShortcut(for: app)
  }

  private var isRecordingShortcut: Bool {
    model.isRecordingLauncherShortcut(for: app)
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
        model.openLauncherShortcutManager(for: app)
      } label: {
        Label("前往功能快捷键", systemImage: "keyboard")
      }

      Divider()

      Button(role: .destructive) {
        model.requestUninstallLauncherApp(app)
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
      return [Color.white.opacity(1), accent.opacity(0.075)]
    }
    if isRecordingShortcut {
      return [Color.white.opacity(1), accent.opacity(0.14)]
    }
    if shortcut != nil {
      return [Color.white.opacity(0.98), teal.opacity(0.075)]
    }
    return [Color.white.opacity(0.96), softSurface.opacity(0.82)]
  }

  private var cardStrokeColor: Color {
    if isHovering { return accent.opacity(0.24) }
    if isRecordingShortcut { return accent.opacity(0.44) }
    if shortcut != nil { return teal.opacity(0.26) }
    return Color.white.opacity(0.88)
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

private struct PlainLauncherAppIcon: View {
  let app: LauncherApp
  let size: CGFloat

  var body: some View {
    AppLauncherIcon(app: app, plain: true)
      .frame(width: size, height: size)
  }
}

struct ClassicTabSwitcherHUDView: View {
  @EnvironmentObject private var model: AppModel

  private var state: ClassicTabSwitcherHUDState {
    model.classicTabSwitcherHUDState
  }

  var body: some View {
    VStack(spacing: 12) {
      HStack(alignment: .center) {
        HStack(spacing: 8) {
          Image(nsImage: hudLogo)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: 24, height: 24)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
          Text("窗口切换")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(ink.opacity(0.86))
        }

        Spacer()

        Text(candidateCountText)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(muted.opacity(0.86))
      }

      if let message = state.message {
        Spacer(minLength: 2)
        Text(message)
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(ink)
          .multilineTextAlignment(.center)
        Spacer(minLength: 2)
      } else {
        ScrollViewReader { proxy in
          ScrollView(.vertical, showsIndicators: state.apps.count > 12) {
            LazyVGrid(columns: gridColumns, alignment: .center, spacing: 10) {
              ForEach(allApps, id: \.index) { item in
                ClassicTabSwitcherAppItem(
                  app: item.app,
                  selected: item.index == state.selectedIndex
                )
                .id(item.index)
              }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
          }
          .frame(maxHeight: 326)
          .onAppear { scrollSelectedApp(in: proxy) }
          .onChange(of: state.selectedIndex) { _ in scrollSelectedApp(in: proxy) }
        }
      }
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 18)
    .frame(width: 780, height: 430)
    .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .stroke(Color.white.opacity(0.48), lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.22), radius: 42, x: 0, y: 22)
  }

  private var hudLogo: NSImage {
    NSImage(named: "AppIcon") ?? NSApp.applicationIconImage ?? NSImage()
  }

  private var allApps: [(index: Int, app: ClassicTabSwitcherAppSnapshot)] {
    state.apps.enumerated().map { ($0.offset, $0.element) }
  }

  private var gridColumns: [GridItem] {
    Array(
      repeating: GridItem(.flexible(minimum: 136, maximum: 160), spacing: 10, alignment: .top),
      count: 4)
  }

  private var candidateCountText: String {
    if state.apps.isEmpty {
      return "正在准备窗口"
    }
    let shortcut =
      model.classicTabSwitcherCommandTabTakeoverConfirmed ? "Command + Tab" : "Option + Tab"
    return "\(state.apps.count) 个窗口 · \(shortcut)"
  }

  private func scrollSelectedApp(in proxy: ScrollViewProxy) {
    guard state.apps.indices.contains(state.selectedIndex) else { return }
    DispatchQueue.main.async {
      withAnimation(.easeOut(duration: 0.12)) {
        proxy.scrollTo(state.selectedIndex, anchor: .center)
      }
    }
  }
}

struct ClassicTabSwitcherAppItem: View {
  let app: ClassicTabSwitcherAppSnapshot
  let selected: Bool

  var body: some View {
    VStack(spacing: 9) {
      HStack(alignment: .top, spacing: 9) {
        Image(nsImage: icon)
          .resizable()
          .interpolation(.high)
          .scaledToFit()
          .padding(5)
          .frame(width: 42, height: 42)
          .background(
            Color.white.opacity(selected ? 0.58 : 0.42),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
          )
          .opacity(selected ? 1 : 0.86)

        VStack(alignment: .leading, spacing: 3) {
          Text(app.name)
            .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
            .foregroundStyle(ink.opacity(selected ? 0.88 : 0.70))
            .lineLimit(1)
            .truncationMode(.tail)
          Text(title)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(muted.opacity(selected ? 0.86 : 0.68))
            .lineLimit(2)
            .truncationMode(.tail)
            .frame(minHeight: 25, alignment: .topLeading)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      HStack(spacing: 5) {
        ForEach(statusBadges, id: \.self) { badge in
          Text(badge)
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(selected ? teal : muted)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .frame(height: 16)
            .background((selected ? teal : muted).opacity(0.10), in: Capsule())
        }
        Spacer(minLength: 0)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 9)
    .frame(height: 108)
    .background(cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(
          selected ? teal.opacity(0.70) : Color.white.opacity(0.24),
          lineWidth: selected ? 1.4 : 1)
    )
    .shadow(color: selected ? Color.black.opacity(0.08) : Color.clear, radius: 8, x: 0, y: 4)
  }

  private var icon: NSImage {
    if let icon = app.icon { return icon }
    return NSImage(named: NSImage.applicationIconName) ?? NSImage()
  }

  private var title: String {
    let title = app.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    if title.isEmpty || genericWindowTitles.contains(title.lowercased()) {
      return app.name
    }
    return title
  }

  private var genericWindowTitles: Set<String> {
    ["window", "untitled", "未命名窗口", "无标题"]
  }

  private var statusBadges: [String] {
    var badges: [String] = []
    if selected {
      badges.append("选中")
    }
    if app.isCurrentWindow {
      badges.append("当前")
    }
    if app.isMinimized {
      badges.append("最小化")
    }
    if app.isHidden {
      badges.append("隐藏")
    }
    if app.isFullscreen {
      badges.append("全屏")
    }
    return badges.isEmpty ? ["可切换"] : Array(badges.prefix(3))
  }

  private var cardBackground: some ShapeStyle {
    selected ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color.white.opacity(0.14))
  }
}

struct LauncherKeyPill: View {
  let systemImage: String

  var body: some View {
    Image(systemName: systemImage)
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(accent.opacity(0.78))
      .frame(width: 30, height: 28)
      .background(accent.opacity(0.085), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .stroke(Color.white.opacity(0.78), lineWidth: 1)
      )
  }
}

struct LauncherShortcutPill: View {
  let text: String
  var compact = false
  var active = false

  var body: some View {
    Text(text)
      .font(.system(size: compact ? 8 : 10, weight: .bold, design: .rounded))
      .foregroundStyle(active ? accent : teal)
      .lineLimit(1)
      .minimumScaleFactor(0.72)
      .padding(.horizontal, compact ? 5 : 7)
      .frame(height: compact ? 17 : 22)
      .background((active ? accent : teal).opacity(active ? 0.14 : 0.10), in: Capsule())
      .overlay(Capsule().stroke(Color.white.opacity(0.82), lineWidth: 1))
  }
}

struct LauncherRecordingBadge: View {
  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: "record.circle.fill")
        .font(.system(size: 10, weight: .semibold))
      Text("录入中")
        .font(.system(size: 10, weight: .bold))
    }
    .foregroundStyle(accent)
    .padding(.horizontal, 8)
    .frame(height: 28)
    .background(accent.opacity(0.12), in: Capsule())
    .overlay(Capsule().stroke(accent.opacity(0.25), lineWidth: 1))
  }
}

struct LauncherUtilityCard: View {
  @State private var isHovering = false
  let item: LauncherUtilityItem
  var compact = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      if compact {
        HStack(spacing: 12) {
          Image(systemName: iconName)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .accessibilityHidden(true)

          Text(primaryText)
            .font(.system(size: 18, weight: .medium, design: .rounded))
            .foregroundStyle(ink)
            .lineLimit(1)

          Spacer(minLength: 8)

          Image(systemName: item.kind == .calculator ? "doc.on.doc" : "arrow.up.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(muted)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
        .background(
          isHovering ? Color.primary.opacity(0.05) : Color.clear,
          in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      } else {
        HStack(spacing: 15) {
          Image(systemName: iconName)
            .font(.system(size: 23, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 50, height: 50)
            .accessibilityHidden(true)

          VStack(alignment: .leading, spacing: 5) {
            Text(headerText)
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(tint)

            Text(primaryText)
              .font(.system(size: 26, weight: .semibold, design: .rounded))
              .foregroundStyle(ink)
              .lineLimit(1)

            Text(item.subtitle)
              .font(.system(size: 11, weight: .bold))
              .foregroundStyle(muted)
              .lineLimit(1)
          }

          Spacer(minLength: 8)

          Text(item.actionTitle)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint)
        }
        .padding(.horizontal, 16)
        .frame(height: 92)
        .background(isHovering ? Color.accentColor.opacity(0.07) : Color.clear)
        .overlay(alignment: .bottom) { Divider() }
      }
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .animation(.easeOut(duration: 0.14), value: isHovering)
    .help(accessibilityText)
    .accessibilityLabel(accessibilityText)
  }

  private var tint: Color {
    item.kind == .calculator ? amber : accent
  }

  private var iconName: String {
    item.kind == .calculator ? "function" : "safari.fill"
  }

  private var headerText: String {
    item.kind == .calculator ? "计算器" : item.title
  }

  private var primaryText: String {
    item.value
  }

  private var accessibilityText: String {
    "\(headerText)，\(primaryText)，\(item.actionTitle)"
  }
}

struct LauncherOverlayView: View {
  @EnvironmentObject private var model: AppModel
  @FocusState private var searchFocused: Bool
  @FocusState private var pinnedFocusID: String?
  @FocusState private var resultFocusID: String?
  @State private var launcherWidth: CGFloat = 720

  let onClose: () -> Void
  let onOpen: (LauncherApp) -> Void

  private var results: [LauncherApp] {
    Array(model.launcherResultApps.prefix(40))
  }

  private var utilityItem: LauncherUtilityItem? {
    model.launcherUtilityItem
  }

  private var pinnedItems: [ResolvedLauncherPinnedItem] {
    model.launcherPinnedItems
  }

  private var showsPinnedItems: Bool {
    LauncherPinnedPresentation.shouldShowPinnedItems(
      query: model.launcherQuery,
      itemCount: pinnedItems.count
    )
  }

  private var pinnedLayout: LauncherPinnedLayout {
    LauncherPinnedLayout(width: launcherWidth)
  }

  var body: some View {
    ZStack {
      Color(nsColor: .windowBackgroundColor)

      VStack(spacing: 0) {
        VStack(spacing: 8) {
          HStack(spacing: 11) {
            Menu {
              ForEach(LauncherSearchEngine.allCases) { engine in
                Button {
                  model.setLauncherSearchEngine(engine)
                  searchFocused = true
                } label: {
                  Label(engine.title, systemImage: engine.systemImage)
                }
              }
            } label: {
              Image(systemName: model.launcherSearchEngine.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(searchFocused ? accent : muted)
                .frame(width: 26, height: 30)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("搜索引擎：\(model.launcherSearchEngine.title)")
            .accessibilityLabel("选择搜索引擎，当前是 \(model.launcherSearchEngine.title)")

            TextField(
              "搜索 App 或计算", text: $model.launcherQuery
            )
            .textFieldStyle(.plain)
            .font(.system(size: 22, weight: .medium))
            .focused($searchFocused)
            .onSubmit { openFirstResult() }
            .onMoveCommand { direction in
              guard direction == .down, showsPinnedItems, let first = pinnedItems.first else {
                return
              }
              searchFocused = false
              pinnedFocusID = first.id
            }

            if !model.launcherQuery.isEmpty {
              Button {
                model.launcherQuery = ""
              } label: {
                Image(systemName: "xmark.circle.fill")
                  .font(.system(size: 16, weight: .semibold))
                  .foregroundStyle(muted.opacity(0.72))
              }
              .buttonStyle(.plain)
              .help("清空")
            }
          }
          .padding(.horizontal, 14)
          .frame(height: LauncherPinnedPresentation.searchFieldHeight(for: launcherWidth))
          .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.92),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
              .stroke(
                searchFocused ? accent.opacity(0.48) : Color.primary.opacity(0.055),
                lineWidth: searchFocused ? 1.5 : 1)
          )
          .shadow(
            color: searchFocused ? accent.opacity(0.08) : Color.black.opacity(0.025),
            radius: searchFocused ? 14 : 8, x: 0, y: 4)

        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 12)

        if showsPinnedItems {
          LauncherPinnedSection(
            items: pinnedItems,
            layout: pinnedLayout,
            focusedID: $pinnedFocusID,
            focusSearch: {
              pinnedFocusID = nil
              searchFocused = true
            },
            focusNextControl: {
              pinnedFocusID = nil
              DispatchQueue.main.async {
                NSApp.keyWindow?.selectNextKeyView(nil)
              }
            },
            onOpen: { item in
              if item.isAIPlayer {
                model.showAIPlayer()
                onClose()
              } else if let app = item.app {
                onOpen(app)
              } else {
                model.reportUnavailableLauncherPinnedItem(item)
              }
            }
          )
        }

        VStack(spacing: 0) {
          if model.isLauncherScanning {
            VStack(spacing: 12) {
              ProgressView()
                .controlSize(.small)
              Text("正在扫描本机 App")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else if results.isEmpty && utilityItem == nil {
            VStack(spacing: 12) {
              Image(systemName: "app.dashed")
                .font(.system(size: 38, weight: .bold))
                .foregroundStyle(muted.opacity(0.54))
              Text(model.launcherQuery.isEmpty ? "输入一个字母开始搜索" : "没有匹配的 App")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ink)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            ScrollView {
              VStack(spacing: 10) {
                if let utilityItem {
                  LauncherUtilityCard(item: utilityItem, compact: true) {
                    let shouldStayOpen = model.launcherCalculatorItem != nil
                    if model.runLauncherUtilityIfAvailable(), !shouldStayOpen {
                      onClose()
                    }
                  }
                }

                if model.launcherDisplayMode == .list {
                  LazyVStack(spacing: 4) {
                    ForEach(results) { app in
                      LauncherResultRow(app: app) {
                        model.launcherSelectedResultID = app.id
                        onOpen(app)
                      }
                      .focused($resultFocusID, equals: app.id)
                    }
                  }
                } else {
                  LazyVGrid(
                    columns: [
                      GridItem(.adaptive(minimum: 96, maximum: 132), spacing: 12)
                    ],
                    spacing: 12
                  ) {
                    ForEach(results) { app in
                      LauncherResultGridItem(app: app) {
                        model.launcherSelectedResultID = app.id
                        onOpen(app)
                      }
                      .focused($resultFocusID, equals: app.id)
                    }
                  }
                }
              }
              .padding(.horizontal, 18)
              .padding(.vertical, 10)
            }
            .scrollIndicators(.automatic)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          }
        }
        .background(Color.clear)
      }
    }
    .overlay(alignment: .bottom) {
      if !model.launcherPinnedStatusText.isEmpty {
        Label(model.launcherPinnedStatusText, systemImage: "checkmark")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(ink)
          .lineLimit(1)
          .padding(.horizontal, 13)
          .frame(height: 32)
          .background(.regularMaterial, in: Capsule())
          .overlay(Capsule().stroke(Color.white.opacity(0.58), lineWidth: 1))
          .shadow(color: Color.black.opacity(0.10), radius: 12, x: 0, y: 5)
          .padding(.bottom, 14)
          .transition(.move(edge: .bottom).combined(with: .opacity))
          .accessibilityLabel("启动器状态，\(model.launcherPinnedStatusText)")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background {
      GeometryReader { proxy in
        Color.clear
          .onAppear { launcherWidth = proxy.size.width }
          .onChange(of: proxy.size.width) { launcherWidth = $0 }
      }
    }
    .onAppear {
      model.ensureLauncherAppsReady()
      model.markLauncherInteractive()
      model.markLauncherFirstResultsIfAvailable(source: "cache")
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        searchFocused = true
      }
    }
    .onExitCommand {
      onClose()
    }
    .onChange(of: model.launcherQuery) { _ in
      if !model.launcherHasEmptyQuery {
        pinnedFocusID = nil
      }
      model.launcherSelectedResultID = nil
      model.markLauncherFirstResultsIfAvailable(source: "query")
    }
    .onChange(of: model.launcherDisplayMode) { _ in
      guard let selectedID = model.launcherSelectedResultID else { return }
      DispatchQueue.main.async { resultFocusID = selectedID }
    }
    .onChange(of: resultFocusID) { focusedID in
      if let focusedID {
        model.launcherSelectedResultID = focusedID
      }
    }
    .onChange(of: results.map(\.id)) { _ in
      model.markLauncherFirstResultsIfAvailable(source: "results")
    }
    .onChange(of: model.launcherFocusRequestID) { _ in
      DispatchQueue.main.async {
        pinnedFocusID = nil
        resultFocusID = nil
        searchFocused = true
      }
    }
    .onChange(of: model.launcherPinnedStatusText) { message in
      guard !message.isEmpty else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
        if model.launcherPinnedStatusText == message {
          model.launcherPinnedStatusText = ""
        }
      }
    }
    .animation(.easeOut(duration: 0.18), value: model.launcherPinnedStatusText)
  }

  private func openFirstResult() {
    let shouldStayOpen = model.launcherCalculatorItem != nil
    if model.runLauncherUtilityIfAvailable() {
      if !shouldStayOpen {
        onClose()
      }
      return
    }
    if let selectedID = model.launcherSelectedResultID,
      let selected = results.first(where: { $0.id == selectedID })
    {
      onOpen(selected)
      return
    }
    guard let first = results.first else { return }
    onOpen(first)
  }
}

private struct LauncherPinnedLayout {
  let width: CGFloat

  var isNarrow: Bool { width < 600 }
  var columnCount: Int { LauncherPinnedPresentation.columnCount(for: width) }
  var horizontalPadding: CGFloat { width < 420 ? 14 : (isNarrow ? 16 : (width >= 800 ? 20 : 18)) }
  var columnSpacing: CGFloat { width < 420 ? 6 : (isNarrow ? 8 : (width >= 800 ? 8 : 6)) }
  var rowSpacing: CGFloat { isNarrow ? columnSpacing : 0 }
  var iconSize: CGFloat { width < 420 ? 38 : (isNarrow ? 42 : (width >= 800 ? 50 : 46)) }
  var tileHeight: CGFloat { width < 420 ? 68 : (isNarrow ? 72 : (width >= 800 ? 76 : 72)) }
  var labelSize: CGFloat { isNarrow ? 11 : 12 }
  var sectionHeight: CGFloat { width < 420 ? 154 : (isNarrow ? 160 : (width >= 800 ? 92 : 88)) }
}

private struct LauncherPinnedSection: View {
  @EnvironmentObject private var model: AppModel

  let items: [ResolvedLauncherPinnedItem]
  let layout: LauncherPinnedLayout
  let focusedID: FocusState<String?>.Binding
  let focusSearch: () -> Void
  let focusNextControl: () -> Void
  let onOpen: (ResolvedLauncherPinnedItem) -> Void

  var body: some View {
    Group {
      if layout.isNarrow {
        LazyVGrid(
          columns: Array(
            repeating: GridItem(.flexible(), spacing: layout.columnSpacing),
            count: layout.columnCount),
          spacing: layout.rowSpacing
        ) {
          pinnedTiles
        }
      } else {
        HStack(spacing: layout.width >= 800 ? 18 : 14) {
          pinnedTiles
        }
        .frame(maxWidth: .infinity)
      }
    }
    .padding(.horizontal, layout.horizontalPadding)
    .padding(.bottom, 4)
    .frame(height: layout.sectionHeight, alignment: .center)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("已固定，\(items.count) 项")
  }

  @ViewBuilder
  private var pinnedTiles: some View {
    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
      LauncherPinnedTile(
        item: item,
        index: index,
        itemCount: items.count,
        layout: layout,
        focusedID: focusedID,
        focusSearch: focusSearch,
        focusNextControl: focusNextControl,
        onOpen: onOpen
      )
      .frame(width: layout.isNarrow ? nil : (layout.width >= 800 ? 82 : 76))
    }
  }
}

private struct LauncherPinnedTile: View {
  @EnvironmentObject private var model: AppModel
  @State private var isHovering = false

  let item: ResolvedLauncherPinnedItem
  let index: Int
  let itemCount: Int
  let layout: LauncherPinnedLayout
  let focusedID: FocusState<String?>.Binding
  let focusSearch: () -> Void
  let focusNextControl: () -> Void
  let onOpen: (ResolvedLauncherPinnedItem) -> Void

  private var isFocused: Bool { focusedID.wrappedValue == item.id }
  private var canMoveBackward: Bool { model.canMoveLauncherPinnedItem(id: item.id, offset: -1) }
  private var canMoveForward: Bool { model.canMoveLauncherPinnedItem(id: item.id, offset: 1) }

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Button {
        onOpen(item)
      } label: {
        VStack(spacing: 5) {
          Group {
            if let app = item.app {
              PlainLauncherAppIcon(app: app, size: layout.iconSize)
            } else if let systemImageName = item.systemImageName {
              Image(systemName: systemImageName)
                .font(.system(size: layout.iconSize * 0.64, weight: .medium))
                .foregroundStyle(violet)
            } else {
              Image(systemName: "questionmark.app.dashed")
                .font(.system(size: layout.iconSize * 0.70, weight: .medium))
                .foregroundStyle(muted)
            }
          }
          .frame(width: layout.iconSize, height: layout.iconSize)
          .saturation(item.isAvailable ? 1 : 0)
          .opacity(item.isAvailable ? 1 : 0.45)

          if model.launcherShowsPinnedNames || !item.isAvailable {
            Text(item.isAvailable ? item.name : "\(item.name) · 已不可用")
              .foregroundStyle(item.isAvailable ? ink : ruby)
              .font(.system(size: layout.labelSize, weight: .medium))
              .lineLimit(1)
              .truncationMode(.tail)
          }
        }
        .padding(.horizontal, 3)
        .frame(maxWidth: .infinity, minHeight: layout.tileHeight, maxHeight: layout.tileHeight)
        .background(
          (isHovering || isFocused) ? Color.primary.opacity(0.050) : Color.clear,
          in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(isFocused ? Color.accentColor.opacity(0.72) : Color.clear, lineWidth: 1.5)
        )
        .scaleEffect(isHovering ? 1.04 : 1)
      }
      .buttonStyle(LauncherPinnedButtonStyle())
      .focused(focusedID, equals: item.id)
      .help(item.name)
      .accessibilityLabel(accessibilityLabel)
      .accessibilityHint(accessibilityHint)
      .accessibilityActions {
        Button("取消固定") { model.unpinLauncherItem(id: item.id) }
        if canMoveBackward {
          Button("向前移动") { model.moveLauncherPinnedItem(id: item.id, offset: -1) }
        }
        if canMoveForward {
          Button("向后移动") { model.moveLauncherPinnedItem(id: item.id, offset: 1) }
        }
      }
      .onMoveCommand(perform: moveFocus)
      .onHover { isHovering = $0 }
      .animation(.easeOut(duration: 0.14), value: isHovering)
      .draggable(item.id)
      .dropDestination(for: String.self) { values, _ in
        guard let sourceID = values.first else { return false }
        model.moveLauncherPinnedItem(id: sourceID, before: item.id)
        return true
      }
      .contextMenu { pinnedMenuContent }

      Menu {
        pinnedMenuContent
      } label: {
        Image(systemName: "ellipsis.circle")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(muted)
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .opacity(isHovering || isFocused ? 0.92 : 0.001)
      .help("\(item.name) 更多操作")
      .accessibilityLabel("\(item.name) 更多操作")
    }
  }

  @ViewBuilder
  private var pinnedMenuContent: some View {
    Button {
      model.unpinLauncherItem(id: item.id)
    } label: {
      Label(item.isAvailable ? "取消固定" : "移除固定", systemImage: "pin.slash")
    }

    if item.isAvailable {
      Divider()
      Button {
        model.moveLauncherPinnedItem(id: item.id, offset: -1)
      } label: {
        Label("向前移动", systemImage: "arrow.left")
      }
      .disabled(!canMoveBackward)

      Button {
        model.moveLauncherPinnedItem(id: item.id, offset: 1)
      } label: {
        Label("向后移动", systemImage: "arrow.right")
      }
      .disabled(!canMoveForward)
    }
  }

  private var accessibilityLabel: String {
    if item.isAvailable {
      return "\(item.name)，\(item.kindLabel)，已固定，第 \(index + 1) 项，共 \(itemCount) 项"
    }
    return "\(item.name)，已不可用，已固定，第 \(index + 1) 项，共 \(itemCount) 项"
  }

  private var accessibilityHint: String {
    item.isAvailable
      ? "按下以打开；使用操作菜单取消固定或调整顺序。"
      : "已不可用，可使用操作菜单移除固定。"
  }

  private func moveFocus(_ direction: MoveCommandDirection) {
    let columns = layout.columnCount
    let target: Int?
    switch direction {
    case .left:
      target = index % columns == 0 ? nil : index - 1
    case .right:
      target = (index + 1) % columns == 0 ? nil : index + 1
    case .up:
      if index >= columns {
        target = index - columns
      } else {
        focusSearch()
        return
      }
    case .down:
      let candidate = index + columns
      if candidate < itemCount {
        target = candidate
      } else {
        focusNextControl()
        return
      }
    default:
      target = nil
    }
    guard let target, itemsIndexContains(target) else { return }
    focusedID.wrappedValue = model.launcherPinnedItems[target].id
  }

  private func itemsIndexContains(_ candidate: Int) -> Bool {
    candidate >= 0 && candidate < itemCount
  }
}

private struct LauncherPinnedButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.82 : 1)
  }
}

struct LauncherResultRow: View {
  @EnvironmentObject private var model: AppModel
  @State private var isHovering = false
  let app: LauncherApp
  let action: () -> Void

  private var shortcut: LauncherAppShortcut? {
    model.launcherShortcut(for: app)
  }

  private var isRecordingShortcut: Bool {
    model.isRecordingLauncherShortcut(for: app)
  }

  private var isPinned: Bool {
    model.isLauncherAppPinned(app)
  }

  private var helpText: String {
    guard let shortcut else { return app.name }
    return "\(app.name) · \(shortcut.hotkey)"
  }

  private var accessibilityText: String {
    guard let shortcut else { return "\(app.name)，App" }
    return "\(app.name)，App，快捷键 \(shortcut.hotkey)"
  }

  private var pinnedActionTitle: String {
    isPinned ? "取消固定" : "固定到启动器"
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        PlainLauncherAppIcon(app: app, size: 38)

        VStack(alignment: .leading, spacing: 3) {
          Text(app.name)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(ink)
            .lineLimit(1)

          if isRecordingShortcut {
            Text("按下组合键")
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(accent)
              .lineLimit(1)
          }
        }

        Spacer(minLength: 8)

        if isRecordingShortcut {
          LauncherRecordingBadge()
        }
      }
      .padding(.horizontal, 12)
      .frame(height: 52)
      .background(
        isHovering ? Color.primary.opacity(0.05) : Color.clear,
        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .animation(.easeOut(duration: 0.14), value: isHovering)
    .help(helpText)
    .accessibilityLabel(accessibilityText)
    .accessibilityAction(named: pinnedActionTitle) {
      if isPinned {
        model.unpinLauncherApp(app)
      } else {
        model.pinLauncherApp(app)
      }
    }
    .contextMenu {
      Button {
        if isPinned {
          model.unpinLauncherApp(app)
        } else {
          model.pinLauncherApp(app)
        }
      } label: {
        Label(isPinned ? "取消固定" : "固定到启动器", systemImage: isPinned ? "pin.slash" : "pin")
      }

      Divider()

      Button {
        model.openLauncherShortcutManager(for: app)
      } label: {
        Label("前往功能快捷键", systemImage: "keyboard")
      }

      Divider()

      Button(role: .destructive) {
        model.requestUninstallLauncherApp(app)
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

}

private struct LauncherResultGridItem: View {
  @EnvironmentObject private var model: AppModel
  @State private var isHovering = false

  let app: LauncherApp
  let action: () -> Void

  private var shortcut: LauncherAppShortcut? {
    model.launcherShortcut(for: app)
  }

  private var isRecordingShortcut: Bool {
    model.isRecordingLauncherShortcut(for: app)
  }

  private var isPinned: Bool {
    model.isLauncherAppPinned(app)
  }

  private var helpText: String {
    guard let shortcut else { return app.name }
    return "\(app.name) · \(shortcut.hotkey)"
  }

  private var accessibilityText: String {
    guard let shortcut else { return "\(app.name)，App" }
    return "\(app.name)，App，快捷键 \(shortcut.hotkey)"
  }

  private var pinnedActionTitle: String {
    isPinned ? "取消固定" : "固定到启动器"
  }

  var body: some View {
    Button(action: action) {
      VStack(spacing: 8) {
        PlainLauncherAppIcon(app: app, size: 56)

        Text(app.name)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(ink)
          .lineLimit(1)
          .truncationMode(.tail)

        if isRecordingShortcut {
          Text("按下组合键")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(accent)
            .lineLimit(1)
        }
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 7)
      .frame(
        maxWidth: .infinity,
        minHeight: isRecordingShortcut ? 108 : 92,
        maxHeight: isRecordingShortcut ? 108 : 92
      )
      .background(
        isHovering ? Color.primary.opacity(0.055) : Color.clear,
        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(
            isRecordingShortcut ? accent.opacity(0.58) : Color.clear,
            lineWidth: isRecordingShortcut ? 1.5 : 0)
      )
      .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      .scaleEffect(isHovering ? 1.035 : 1)
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .animation(.easeOut(duration: 0.14), value: isHovering)
    .help(helpText)
    .accessibilityLabel(accessibilityText)
    .accessibilityAction(named: pinnedActionTitle) {
      if isPinned {
        model.unpinLauncherApp(app)
      } else {
        model.pinLauncherApp(app)
      }
    }
    .contextMenu {
      Button {
        if isPinned {
          model.unpinLauncherApp(app)
        } else {
          model.pinLauncherApp(app)
        }
      } label: {
        Label(isPinned ? "取消固定" : "固定到启动器", systemImage: isPinned ? "pin.slash" : "pin")
      }

      Divider()

      Button {
        model.openLauncherShortcutManager(for: app)
      } label: {
        Label("前往功能快捷键", systemImage: "keyboard")
      }

      Divider()

      Button(role: .destructive) {
        model.requestUninstallLauncherApp(app)
      } label: {
        Label("卸载 App…", systemImage: "trash.slash")
      }
    }
  }
}

struct OneClickOptimizePanelView: View {
  var body: some View {
    PluginCenterView()
  }
}

struct AIPlayerPluginCard: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    HStack(spacing: 14) {
      IconBadge(systemImage: "play.square.stack.fill", tint: violet, size: 48, iconSize: 20)

      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 7) {
          Text("听澜播放器")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(ink)
          StatusPill(
            text: model.aiPlayerExtendedMediaAvailable ? "音频与视频可播放" : "常用音频可播放",
            color: teal)
        }
        Text("播放音频和视频，管理历史、收藏与自定义媒体库。")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(muted)
          .lineLimit(2)
      }

      Spacer(minLength: 12)

      Button {
        model.showAIPlayer()
      } label: {
        Label("打开播放器", systemImage: "play.fill")
      }
      .buttonStyle(GlassLabelButtonStyle(tint: violet, prominent: true))
      .help("打开听澜播放器")
      .accessibilityLabel("打开听澜播放器")
    }
    .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
  }
}

struct CapsCorePluginCard: View {
  @EnvironmentObject private var model: AppModel

  private var needsPermission: Bool {
    model.capsCorePluginEnabled && !model.authorizationPermissionsComplete
  }


  private var displayedStatusText: String {
    needsPermission ? "待授权" : model.capsCorePluginStatus.displayText
  }

  private var displayedDetailText: String {
    needsPermission
      ? "Caps 核心键需要辅助功能和输入监控；点下方按钮即可重新检测并补齐。"
      : model.capsCorePluginStatus.detailText
  }

  private var statusColor: Color {
    if needsPermission { return amber }
    switch model.capsCorePluginStatus {
    case .running: return teal
    case .conflict, .failed: return ruby
    case .waitingForPermission: return amber
    case .stopped, .paused: return muted
    }
  }

  private var statusIcon: String {
    if needsPermission { return "lock.trianglebadge.exclamationmark" }
    switch model.capsCorePluginStatus {
    case .running: return "checkmark.circle.fill"
    case .conflict, .failed: return "exclamationmark.triangle.fill"
    case .waitingForPermission: return "lock.trianglebadge.exclamationmark"
    case .paused: return "pause.circle.fill"
    case .stopped: return "circle"
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .center, spacing: 12) {
        IconBadge(
          systemImage: "capslock.fill",
          tint: model.capsCorePluginEnabled ? accent : muted,
          size: 48,
          iconSize: 20,
          filled: false)

        VStack(alignment: .leading, spacing: 5) {
          HStack(spacing: 8) {
            Text("Caps 核心键")
              .font(.system(size: 17, weight: .semibold))
              .foregroundStyle(ink)
            StatusPill(text: displayedStatusText, color: statusColor)
          }
          Text("按住 Caps Lock 等于左 Control + 左 Option；松开立即释放。")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(muted)
            .lineLimit(2)
        }

        Spacer(minLength: 12)

        Toggle(
          "",
          isOn: Binding(
            get: { model.capsCorePluginEnabled },
            set: { model.setCapsCorePluginEnabled($0) }
          )
        )
        .labelsHidden()
        .toggleStyle(.switch)
        .accessibilityLabel("Caps 核心键")
        .accessibilityValue(displayedStatusText)
      }

      if model.capsCorePluginEnabled {
        HStack(alignment: .top, spacing: 9) {
          Image(systemName: statusIcon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(statusColor)
            .frame(width: 18, height: 18)

          VStack(alignment: .leading, spacing: 3) {
            if case .conflict(let conflict) = model.capsCorePluginStatus {
              Text(conflict.displayText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ink)
            }
            Text(displayedDetailText)
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(muted)
              .fixedSize(horizontal: false, vertical: true)
          }

          Spacer(minLength: 8)

          if needsPermission {
            EmptyView()
          } else {
            ToolbarIconButton(systemImage: "arrow.clockwise", title: "重试", tint: muted) {
              model.reloadCapsCorePlugin(requestPermission: false)
            }
          }
        }
        .padding(10)
        .background(
          Color.white.opacity(0.30),
          in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(statusColor.opacity(0.16), lineWidth: 1))


        Button {
          model.presentAuthorizationCenter()
        } label: {
          Label(
            needsPermission ? "检测并开启权限" : "检测 / 管理权限",
            systemImage: needsPermission ? "lock.open.fill" : "checkmark.shield")
        }
        .buttonStyle(
          GlassLabelButtonStyle(tint: needsPermission ? indigo : muted, prominent: needsPermission)
        )
        .help("检测 Caps 核心键所需的辅助功能和输入监控；异常时可一键清除本 App 权限后重加")
        .accessibilityLabel(
          needsPermission ? "检测并开启 Caps 核心键权限" : "检测或管理 Caps 核心键权限")
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }
}

struct MouseScrollPluginCard: View {
  @EnvironmentObject private var model: AppModel

  private var settings: ScrollEngineSettings {
    model.scrollSettings
  }

  private var needsAccessibility: Bool {
    settings.enabled && !model.scrollEngineRunning && !model.advancedListeningAuthorized
  }

  private var listenerStatusText: String {
    guard settings.enabled else { return "未监听" }
    if model.scrollEngineRunning { return "监听中" }
    if !model.advancedListeningAuthorized { return model.accessibilityAuthorizationStatusText }
    return "未监听"
  }

  private var listenerStatusColor: Color {
    if settings.enabled && model.scrollEngineRunning { return accent }
    return amber
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .center, spacing: 12) {
        IconBadge(systemImage: "scroll.fill", tint: accent, size: 48, iconSize: 20)

        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            Text("鼠标滚动")
              .font(.system(size: 17, weight: .semibold))
              .foregroundStyle(ink)
            StatusPill(
              text: settings.enabled ? "已开启" : "默认关闭",
              color: settings.enabled ? teal : muted)
            StatusPill(
              text: listenerStatusText,
              color: listenerStatusColor)
          }
          Text("外接鼠标按 Windows 滚轮习惯滚动；关闭时不接管普通滚动，触控板始终保持系统原样。")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(muted)
            .lineLimit(2)
        }

        Spacer()

        Toggle(
          "",
          isOn: Binding(
            get: { settings.enabled },
            set: { model.setScrollEngineEnabled($0) }
          )
        )
        .toggleStyle(.switch)
      }

      if needsAccessibility {
        PluginPermissionNotice(
          message: "需要完成系统授权，软件会自动判断下一步。"
        ) {
          model.presentAuthorizationCenter()
        }
      }

      HStack(spacing: 8) {
        ForEach(MouseScrollPreset.allCases) { preset in
          Button {
            model.applyMouseScrollPreset(preset)
          } label: {
            VStack(alignment: .leading, spacing: 3) {
              Text(preset.title)
                .font(.system(size: 13, weight: .semibold))
              Text(preset.detail)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .frame(height: 50)
          }
          .buttonStyle(
            GlassLabelButtonStyle(
              tint: model.mouseScrollPreset == preset ? accent : muted,
              prominent: model.mouseScrollPreset == preset))
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }
}

struct BuiltInWindowSwitchingPluginCard: View {
  @EnvironmentObject private var model: AppModel

  private var enabled: Bool {
    model.classicTabSwitcherEnabled
  }

  private var healthy: Bool {
    enabled && model.classicTabSwitcherRunning
  }

  private var secondaryColor: Color {
    if healthy { return accent }
    if enabled { return amber }
    return muted
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .center, spacing: 12) {
        IconBadge(
          systemImage: "rectangle.stack.badge.play.fill",
          tint: enabled ? accent : amber,
          size: 48,
          iconSize: 20
        )

        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            Text("窗口切换")
              .font(.system(size: 17, weight: .semibold))
              .foregroundStyle(ink)
            StatusPill(
              text: model.classicTabSwitcherPrimaryStatusText,
              color: enabled ? teal : muted)
            StatusPill(text: model.classicTabSwitcherSecondaryStatusText, color: secondaryColor)
            StatusPill(text: model.classicTabSwitcherShortcutText, color: indigo)
          }
          Text("内置窗口级切换，不需要再安装 AltTab；确认后用 Command + Tab 替代系统切换，Option + Tab 保留回退。")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(muted)
            .lineLimit(2)
        }

        Spacer(minLength: 12)

        VStack(spacing: 8) {
          Button {
            model.previewClassicTabSwitcherHUD()
          } label: {
            Label("预览 HUD", systemImage: "rectangle.stack.fill")
          }
          .buttonStyle(GlassLabelButtonStyle(tint: accent))

          Button {
            model.reloadClassicTabSwitcher()
          } label: {
            Label("重启监听", systemImage: "arrow.clockwise")
          }
          .buttonStyle(GlassLabelButtonStyle(tint: muted))

          if model.classicTabSwitcherCommandTabTakeoverConfirmed {
            Button {
              model.restoreSystemCommandTabForClassicTabSwitcher()
            } label: {
              Label("恢复系统", systemImage: "command")
            }
            .buttonStyle(GlassLabelButtonStyle(tint: amber))
          } else {
            Button {
              model.confirmClassicTabSwitcherCommandTabTakeover()
            } label: {
              Label("接管 ⌘Tab", systemImage: "command")
            }
            .buttonStyle(GlassLabelButtonStyle(tint: accent, prominent: true))
          }
        }
      }

      HStack(spacing: 10) {
        PluginChip(text: "内置", color: accent)
        PluginChip(text: "窗口级", color: teal)
        PluginChip(text: "MVP", color: indigo)
        PluginChip(text: "不复制源码", color: amber)
        PluginChip(text: "不依赖 AltTab", color: muted)
        Spacer()
      }

      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          Text("内置窗口切换")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(ink)
          StatusPill(text: "自研", color: accent)
          StatusPill(
            text: model.classicTabSwitcherCommandTabTakeoverConfirmed
              ? "已接管 Command + Tab"
              : "待确认接管",
            color: model.classicTabSwitcherCommandTabTakeoverConfirmed ? teal : amber)

          Spacer(minLength: 10)

          Toggle(
            "",
            isOn: Binding(
              get: { model.classicTabSwitcherEnabled },
              set: { model.setClassicTabSwitcherEnabled($0) }
            )
          )
          .toggleStyle(.switch)
        }

        HStack(alignment: .center, spacing: 10) {
          Text(model.classicTabSwitcherTakeoverSummaryText)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(muted)
            .lineLimit(2)

          Spacer(minLength: 10)

          if model.classicTabSwitcherNeedsPermission {
            Button {
              model.presentAuthorizationCenter()
            } label: {
              Label("立即授权", systemImage: "lock.open.fill")
            }
            .buttonStyle(GlassLabelButtonStyle(tint: amber, prominent: true))
          }
        }
      }
      .padding(12)
      .background(
        Color.white.opacity(0.50),
        in: RoundedRectangle(
          cornerRadius: 14,
          style: .continuous
        )
      )
      .overlay(
        RoundedRectangle(cornerRadius: 14)
          .stroke(Color.white.opacity(0.72), lineWidth: 1))
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }
}

struct MouseVolumePluginCard: View {
  @EnvironmentObject private var model: AppModel

  private var settings: ScrollEngineSettings {
    model.scrollSettings
  }

  private var needsAccessibility: Bool {
    settings.volumeHotCornerEnabled && !model.scrollEngineRunning
      && !model.advancedListeningAuthorized
  }

  private var listenerStatusText: String {
    guard settings.volumeHotCornerEnabled else { return "未监听" }
    if model.scrollEngineRunning { return "右上角可用" }
    if !model.advancedListeningAuthorized { return model.accessibilityAuthorizationStatusText }
    return "未监听"
  }

  private var listenerStatusColor: Color {
    if settings.volumeHotCornerEnabled && model.scrollEngineRunning { return accent }
    return amber
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .center, spacing: 12) {
        IconBadge(systemImage: "speaker.wave.2.fill", tint: teal, size: 48, iconSize: 20)

        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            Text("鼠标音量")
              .font(.system(size: 17, weight: .semibold))
              .foregroundStyle(ink)
            StatusPill(
              text: settings.volumeHotCornerEnabled ? "已开启" : "默认关闭",
              color: settings.volumeHotCornerEnabled ? teal : muted)
            StatusPill(
              text: listenerStatusText,
              color: listenerStatusColor)
          }
          Text("鼠标移到屏幕右上角热区，滚轮调节系统音量。")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(muted)
            .lineLimit(2)
        }

        Spacer()

        Toggle(
          "",
          isOn: Binding(
            get: { settings.volumeHotCornerEnabled },
            set: { model.setMouseVolumePluginEnabled($0) }
          )
        )
        .toggleStyle(.switch)
      }

      if needsAccessibility {
        PluginPermissionNotice(
          message: "需要完成系统授权，软件会自动判断下一步。"
        ) {
          model.presentAuthorizationCenter()
        }
      }

      MosSliderRow(
        title: "音量步进",
        value: settings.volumeStep,
        range: 0.5...6.0,
        help: "每格滚动调节音量；滚轮过密或惯性会被节流。"
      ) { nextValue in
        model.updateMouseVolumePluginSettings { settings in settings.volumeStep = nextValue }
      }
      .disabled(!settings.volumeHotCornerEnabled)
      .opacity(settings.volumeHotCornerEnabled ? 1 : 0.52)
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }
}

struct NetworkSpeedPluginCard: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .center, spacing: 12) {
        IconBadge(
          systemImage: "arrow.up.arrow.down.circle.fill",
          tint: indigo,
          size: 48,
          iconSize: 20
        )

        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            Text("自定义菜单栏")
              .font(.system(size: 17, weight: .semibold))
              .foregroundStyle(ink)
            StatusPill(text: "菜单栏主入口", color: teal)
            StatusPill(text: "点击菜单", color: accent)
          }
          Text("菜单栏图标、系统健康、资源指标和快捷入口都在这里设置。")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(muted)
            .lineLimit(2)
        }

        Spacer()
      }

      Label("所有菜单栏设置共用同一个页面，改完立即生效。", systemImage: "checkmark.circle.fill")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(teal)

      HStack {
        Button {
          model.presentMenuBarCustomization()
        } label: {
          Label("打开自定义菜单栏…", systemImage: "menubar.rectangle")
        }
        .buttonStyle(GlassLabelButtonStyle(tint: accent))
        .help("选择哪些插件入口显示在菜单栏快捷菜单中")

        Text("不再需要去其他卡片寻找菜单栏开关。")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(muted)
        Spacer()
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }
}

private struct MenuBarCustomizationSheet: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        IconBadge(systemImage: "menubar.rectangle", tint: accent, size: 44, iconSize: 18)
        VStack(alignment: .leading, spacing: 4) {
          Text("自定义菜单栏")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(ink)
          Text("图标、状态内容和快捷入口集中在这一处。")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(muted)
        }
        Spacer()
      }
      .padding(.horizontal, 22)
      .padding(.vertical, 18)
      .background(.bar)
      .overlay(Rectangle().fill(hairline).frame(height: 1), alignment: .bottom)

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          menuSectionTitle("菜单栏图标")

          menuBarIconRow(
            title: "网速与快捷菜单",
            detail: "主入口 · 始终显示",
            systemImage: "arrow.up.arrow.down.circle.fill",
            isOn: .constant(true),
            locked: true)

          menuBarIconRow(
            title: "醒 / 眠",
            detail: "点一下直接切换保持唤醒",
            systemImage: "moon.zzz.fill",
            isOn: Binding(
              get: { model.sleepStatusItemVisible },
              set: { model.setSleepStatusItemVisible($0) }),
            locked: false)

          Divider()

          menuSectionTitle("状态内容")

          VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 18) {
              NetworkMetricOptionToggle(
                title: "系统健康卡片",
                isOn: Binding(
                  get: { model.systemHealthMonitoringEnabled },
                  set: { model.setSystemHealthMonitoringEnabled($0) }))
              NetworkMetricOptionToggle(
                title: "内存占用",
                isOn: Binding(
                  get: { model.networkSpeedShowMemory },
                  set: { model.setNetworkSpeedShowMemory($0) }))
              Spacer(minLength: 0)
            }
            HStack(spacing: 18) {
              NetworkMetricOptionToggle(
                title: "CPU 占用",
                isOn: Binding(
                  get: { model.networkSpeedShowCPU },
                  set: { model.setNetworkSpeedShowCPU($0) }))
              NetworkMetricOptionToggle(
                title: "GPU 占用",
                isOn: Binding(
                  get: { model.networkSpeedShowGPU },
                  set: { model.setNetworkSpeedShowGPU($0) }))
              Spacer(minLength: 0)
            }
          }
          .padding(12)
          .background(Color.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 10))

          Text("系统健康卡片关闭后不常驻采样；网速主入口仍会保留。")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(muted)

          Divider()

          menuSectionTitle("程序坞")

          menuBarIconRow(
            title: "在程序坞中显示图标",
            detail: "关闭后只保留顶部菜单栏；可随时打开窗口或完全退出",
            systemImage: "dock.rectangle",
            isOn: Binding(
              get: { model.dockIconVisible },
              set: { model.setDockIconVisible($0) }),
            locked: false)

          Divider()

          menuSectionTitle("快捷菜单")

          VStack(spacing: 6) {
            ForEach(MenuBarCatalog.items) { descriptor in
              Toggle(
                isOn: Binding(
                  get: { model.isMenuBarCatalogItemVisible(descriptor.id) },
                  set: { model.setMenuBarCatalogItemVisible(descriptor.id, $0) })
              ) {
                menuBarCatalogLabel(descriptor)
              }
              .toggleStyle(.checkbox)
              .padding(.horizontal, 12)
              .frame(minHeight: 44)
              .background(Color.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 10))
              .accessibilityHint("勾选后立即出现在菜单栏的快捷菜单中")
            }
          }

          Text("应用中心、自定义菜单栏、设置、检查更新、暂停后台和退出始终保留。")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(muted)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
      }

      HStack {
        Button("恢复默认") {
          model.resetMenuBarCatalogVisibility()
        }
        .buttonStyle(GlassLabelButtonStyle(tint: muted))
        Spacer()
        Button("完成") {
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(GlassLabelButtonStyle(tint: accent, prominent: true))
      }
      .padding(.horizontal, 22)
      .padding(.vertical, 14)
      .background(.bar)
      .overlay(Rectangle().fill(hairline).frame(height: 1), alignment: .top)
    }
    .frame(width: 520, height: 680)
    .background(AppBackdrop())
  }

  private func menuSectionTitle(_ title: String) -> some View {
    Text(title)
      .font(.system(size: 12, weight: .bold))
      .foregroundStyle(ink.opacity(0.72))
  }

  private func menuBarIconRow(
    title: String,
    detail: String,
    systemImage: String,
    isOn: Binding<Bool>,
    locked: Bool
  ) -> some View {
    Toggle(isOn: isOn) {
      HStack(spacing: 10) {
        Image(systemName: systemImage)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(locked ? muted : accent)
          .frame(width: 28, height: 28)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(title)
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(ink)
            if locked {
              Image(systemName: "lock.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(muted)
            }
          }
          Text(detail)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(muted)
        }
      }
    }
    .toggleStyle(.checkbox)
    .disabled(locked)
    .padding(.horizontal, 12)
    .frame(minHeight: 48)
    .background(Color.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 10))
  }

  private func menuBarCatalogLabel(
    _ descriptor: MenuBarCatalogItemDescriptor
  ) -> some View {
    HStack(spacing: 10) {
      Image(systemName: descriptor.systemImage)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(accent)
        .frame(width: 26, height: 26)
      VStack(alignment: .leading, spacing: 2) {
        Text(descriptor.title)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(ink)
        Text(descriptor.detail)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(muted)
      }
      Spacer()
    }
  }
}

struct SleepPluginCard: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .center, spacing: 12) {
        IconBadge(
          systemImage: model.keepAwakeEnabled ? "moon.zzz.fill" : "moon.fill",
          tint: model.keepAwakeEnabled ? teal : violet,
          size: 48,
          iconSize: 20
        )

        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            Text("睡眠")
              .font(.system(size: 17, weight: .semibold))
              .foregroundStyle(ink)
            StatusPill(
              text: model.keepAwakeEnabled ? "保持唤醒" : "未开启",
              color: model.keepAwakeEnabled ? teal : muted)
            StatusPill(
              text: model.keepAwakeStatusText, color: model.keepAwakeEnabled ? accent : amber)
          }
          Text("防止 Mac 空闲睡眠；支持无限期、倒计时、自定义小时，以及不锁屏 / 不进屏保。")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(muted)
            .lineLimit(2)
        }

        Spacer()
      }

      Toggle(
        isOn: Binding(
          get: { model.sleepStatusItemVisible },
          set: { model.setSleepStatusItemVisible($0) }
        )
      ) {
        VStack(alignment: .leading, spacing: 3) {
          Text("状态栏显示")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(ink)
          Text("菜单栏显示醒 / 眠状态；点一下直接切换，倒计时和高级选项仍在这里设置。")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(muted)
        }
      }
      .toggleStyle(.switch)

      KeepAwakeSettingsPanel()
        .padding(.top, 2)
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }
}

struct NetworkMetricOptionToggle: View {
  let title: String
  @Binding var isOn: Bool

  var body: some View {
    Toggle(title, isOn: $isOn)
      .toggleStyle(.checkbox)
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(ink)
  }
}

struct OptimizePrincipleCard: View {
  let icon: String
  let title: String
  let detail: String
  let color: Color

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: icon)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(color)
        .frame(width: 30, height: 30)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(ink)
        Text(detail)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(muted)
          .lineLimit(3)
      }
      Spacer(minLength: 0)
    }
    .padding(13)
    .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
    .background(
      Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 15, style: .continuous)
    )
    .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.white.opacity(0.78), lineWidth: 1))
  }
}

private enum ApplicationCenterMode {
  case background
  case primaryEntry
  case launch
  case action
  case configuration

  var title: String {
    switch self {
    case .background: return "后台开关"
    case .primaryEntry: return "菜单栏主入口"
    case .launch: return "按需打开"
    case .action: return "单次操作"
    case .configuration: return "配置能力"
    }
  }

}

private struct ApplicationCenterItem: Identifiable {
  let id: String
  let name: String
  let purpose: String
  let valueDescription: String
  var assetName: String? = nil
  let systemImage: String
  let tint: Color
  let category: String
  let mode: ApplicationCenterMode
  let statusText: String?
  let statusImage: String
  let statusColor: Color
  let isEnabled: Binding<Bool>?
  var isFeatured = false
}

private struct ApplicationCenterIcon: View {
  let item: ApplicationCenterItem
  let size: CGFloat

  private var bundledImage: NSImage? {
    guard let assetName = item.assetName,
      let url = Bundle.main.url(forResource: assetName, withExtension: "png")
    else { return nil }
    return NSImage(contentsOf: url)
  }

  var body: some View {
    Group {
      if let bundledImage {
        Image(nsImage: bundledImage)
          .resizable()
          .interpolation(.high)
          .renderingMode(.original)
          .scaledToFit()
          .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
          .shadow(color: Color.black.opacity(0.10), radius: size * 0.08, x: 0, y: size * 0.04)
      } else {
        Image(systemName: item.systemImage)
          .font(.system(size: size * 0.50, weight: .semibold))
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(item.tint)
          .frame(width: size, height: size)
          .background(
            item.tint.opacity(0.09),
            in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
          )
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

struct PluginCenterView: View {
  @EnvironmentObject private var model: AppModel
  @AppStorage("processViewerPluginEnabledV1") private var processViewerPluginEnabled = true
  @AppStorage("codexNetworkProbePluginEnabledV1") private var codexNetworkProbePluginEnabled = true
  @State private var searchText = ""
  @State private var category = "全部"

  var requestedSelectionID: String? = nil

  private var allItems: [ApplicationCenterItem] {
    [
      ApplicationCenterItem(
        id: applicationYoumuID,
        name: "游目",
        purpose: "看懂屏幕上的文字与画面",
        valueDescription: "截图、钉图、OCR 与翻译，一步完成看见与理解。",
        assetName: "YoumuAppIcon",
        systemImage: "viewfinder.circle.fill",
        tint: aixlgPurple,
        category: "核心应用",
        mode: .launch,
        statusText: nil,
        statusImage: "arrow.up.right.square.fill",
        statusColor: accent,
        isEnabled: nil,
        isFeatured: true),
      ApplicationCenterItem(
        id: applicationPijuanPDFID,
        name: "披卷",
        purpose: "把 PDF 阅读变成顺手的资料工作流",
        valueDescription: "阅读、检索和整理长文档，不必再装一堆零散工具。",
        assetName: "PijuanAppIcon",
        systemImage: "doc.richtext.fill",
        tint: aixlgPurple,
        category: "核心应用",
        mode: .launch,
        statusText: nil,
        statusImage: "arrow.up.right.square.fill",
        statusColor: accent,
        isEnabled: nil,
        isFeatured: true),
      ApplicationCenterItem(
        id: applicationAIPlayerID,
        name: "听澜",
        purpose: "专注播放、收藏与复盘本地音视频",
        valueDescription: "让课程、播客和视频在一处安静播放、继续收听。",
        assetName: "TinglanAppIcon",
        systemImage: "play.square.stack.fill",
        tint: accent,
        category: "核心应用",
        mode: .launch,
        statusText: nil,
        statusImage: "arrow.up.right.square.fill",
        statusColor: accent,
        isEnabled: nil,
        isFeatured: true),
      ApplicationCenterItem(
        id: applicationFeatureShortcutsID,
        name: "功能快捷键",
        purpose: "把重复动作固定成顺手的一键",
        valueDescription: "先用默认配置；熟悉后再按自己的习惯增删和改键。",
        systemImage: "keyboard.badge.ellipsis",
        tint: indigo,
        category: "输入效率",
        mode: .configuration,
        statusText: "\(model.enabledCount) 项已启用",
        statusImage: "bolt.fill",
        statusColor: teal,
        isEnabled: nil),
      ApplicationCenterItem(
        id: "caps-core",
        name: "Caps 核心键",
        purpose: "把 Caps Lock 变成左手控制台",
        valueDescription: "一只左手完成启动、切换、窗口和常用动作。",
        systemImage: "capslock.fill",
        tint: accent,
        category: "输入效率",
        mode: .background,
        statusText: capsStatusText,
        statusImage: capsStatusImage,
        statusColor: capsStatusColor,
        isEnabled: Binding(
          get: { model.capsCorePluginEnabled },
          set: { model.setCapsCorePluginEnabled($0) })),
      ApplicationCenterItem(
        id: AppModel.launcherPluginID,
        name: "启动器",
        purpose: "快速打开 App、计算和网页",
        valueDescription: "Caps + Space 呼出，搜索之后直接抵达。",
        systemImage: "magnifyingglass",
        tint: indigo,
        category: "输入效率",
        mode: .background,
        statusText: launcherStatusText,
        statusImage: "exclamationmark.triangle.fill",
        statusColor: amber,
        isEnabled: Binding(
          get: { model.launcherPluginEnabled },
          set: { model.setLauncherPluginEnabled($0) })),
      ApplicationCenterItem(
        id: applicationPhrasesID,
        name: "快捷短语",
        purpose: "一个缩写输入一整段常用文字",
        valueDescription: "地址、回复和固定文案只写一次，到处复用。",
        systemImage: "quote.bubble.fill",
        tint: violet,
        category: "输入效率",
        mode: .configuration,
        statusText: "\(model.phrases.count) 条短语",
        statusImage: "text.badge.checkmark",
        statusColor: muted,
        isEnabled: nil),
      ApplicationCenterItem(
        id: applicationClipboardHistoryID,
        name: "剪贴板历史",
        purpose: "每次复制自动保存，需要时再找回",
        valueDescription: "文字、图片和多个文件都可搜索；重复内容只保留一条。",
        systemImage: "doc.on.clipboard.fill",
        tint: accent,
        category: "输入效率",
        mode: .background,
        statusText: clipboardHistoryStatusText,
        statusImage: clipboardHistoryStatusImage,
        statusColor: clipboardHistoryStatusColor,
        isEnabled: Binding(
          get: { model.clipboardHistory.isEnabled },
          set: { model.clipboardHistory.setEnabled($0) })),
      ApplicationCenterItem(
        id: AppModel.inputMethodPluginID,
        name: "输入法管家",
        purpose: "让指定 App 自动用对输入法",
        valueDescription: "只按你明确设置的 App 规则切换；Shift 完全交给当前输入法。",
        systemImage: "character.cursor.ibeam",
        tint: teal,
        category: "输入效率",
        mode: .background,
        statusText: inputMethodStatusText,
        statusImage: "exclamationmark.triangle.fill",
        statusColor: inputMethodStatusColor,
        isEnabled: Binding(
          get: { model.inputMethodPluginEnabled },
          set: { model.setInputMethodPluginEnabled($0) })),
      ApplicationCenterItem(
        id: "mouse-scroll",
        name: "鼠标滚动",
        purpose: "让外接鼠标滚动稳定、顺手",
        valueDescription: "按自己的习惯调速度、步进和自然方向。",
        systemImage: "scroll.fill",
        tint: indigo,
        category: "鼠标",
        mode: .background,
        statusText: mouseScrollStatusText,
        statusImage: "lock.trianglebadge.exclamationmark",
        statusColor: amber,
        isEnabled: Binding(
          get: { model.scrollSettings.enabled },
          set: { model.setScrollEngineEnabled($0) })),
      ApplicationCenterItem(
        id: "mouse-volume",
        name: "鼠标音量",
        purpose: "在屏幕右上角用滚轮调音量",
        valueDescription: "不找菜单、不按键，鼠标顺手一滚就够。",
        systemImage: "speaker.wave.2.fill",
        tint: violet,
        category: "鼠标",
        mode: .background,
        statusText: mouseVolumeStatusText,
        statusImage: "lock.trianglebadge.exclamationmark",
        statusColor: amber,
        isEnabled: Binding(
          get: { model.mouseVolumePluginEnabled },
          set: { model.setMouseVolumePluginEnabled($0) })),
      ApplicationCenterItem(
        id: "process-viewer",
        name: "进程查看器",
        purpose: "看清进程、资源占用和交换空间",
        valueDescription: "需要时打开窗口查看，关闭后不持续刷新。",
        systemImage: "cpu",
        tint: teal,
        category: "系统与网络",
        mode: .launch,
        statusText: nil,
        statusImage: "arrow.up.right.square.fill",
        statusColor: accent,
        isEnabled: nil),
      ApplicationCenterItem(
        id: "network-speed",
        name: "自定义菜单栏",
        purpose: "在一处管理图标、系统健康与快捷入口",
        valueDescription: "所有菜单栏选项集中在同一页，改完立即生效。",
        systemImage: "speedometer",
        tint: accent,
        category: "系统与网络",
        mode: .primaryEntry,
        statusText: "主入口",
        statusImage: "menubar.rectangle",
        statusColor: teal,
        isEnabled: nil),
      ApplicationCenterItem(
        id: "codex-network-probe",
        name: "测试网速",
        purpose: "测试网络速度与 Codex 连通响应",
        valueDescription: "只在打开测速窗口时运行，不在后台偷偷测速。",
        systemImage: "gauge.with.dots.needle.67percent",
        tint: indigo,
        category: "系统与网络",
        mode: .launch,
        statusText: nil,
        statusImage: "arrow.up.right.square.fill",
        statusColor: accent,
        isEnabled: nil),
      ApplicationCenterItem(
        id: "sleep",
        name: "保持唤醒",
        purpose: "临时保持 Mac 唤醒",
        valueDescription: "开会、下载、投屏时按时长开启，到点自动恢复。",
        systemImage: "moon.zzz.fill",
        tint: violet,
        category: "系统与网络",
        mode: .action,
        statusText: model.keepAwakeEnabled ? model.keepAwakeStatusText : nil,
        statusImage: "moon.zzz.fill",
        statusColor: teal,
        isEnabled: nil),
      ApplicationCenterItem(
        id: applicationPermanentUninstallID,
        name: "彻底卸载",
        purpose: "清理 App 和确认过的关联残留",
        valueDescription: "先扫描可安全识别的范围，再由你确认是否永久删除。",
        systemImage: "trash.slash.fill",
        tint: ruby,
        category: "维护",
        mode: .action,
        statusText: "扫描后确认",
        statusImage: "checkmark.shield.fill",
        statusColor: muted,
        isEnabled: nil),
    ]
  }

  private var visibleItems: [ApplicationCenterItem] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    return allItems.filter { item in
      let categoryMatches = category == "全部" || item.category == category
      return categoryMatches
        && (query.isEmpty
          || item.name.localizedCaseInsensitiveContains(query)
          || item.purpose.localizedCaseInsensitiveContains(query)
          || item.valueDescription.localizedCaseInsensitiveContains(query)
          || item.mode.title.localizedCaseInsensitiveContains(query))
    }
  }

  private var categories: [String] {
    ["全部", "核心应用", "输入效率", "鼠标", "系统与网络", "维护"]
  }

  private var selectedItem: ApplicationCenterItem? {
    guard let selectedID = model.selectedPluginID else { return nil }
    return allItems.first(where: { $0.id == selectedID })
  }

  var body: some View {
    HStack(spacing: 0) {
      overviewList
        .frame(minWidth: 260, idealWidth: 282, maxWidth: 300)
      Divider()
      if let selectedItem {
        applicationDetail(item: selectedItem)
      } else {
        ApplicationCenterOverviewView(
          featuredItems: allItems.filter(\.isFeatured),
          selectFeatureShortcuts: {
            model.selectedModuleName = moduleHotkeys
          },
          select: { model.selectPlugin(id: $0) }
        )
      }
    }
    .background(Color(nsColor: .controlBackgroundColor))
    .onAppear {
      applyRequestedSelection()
      if model.selectedPluginID != nil && selectedItem == nil {
        model.selectPlugin(id: nil)
      }
    }
    .onChange(of: requestedSelectionID) { _ in
      applyRequestedSelection()
    }
    .onReceive(model.clipboardHistory.objectWillChange) { _ in
      model.objectWillChange.send()
    }
  }

  private var overviewList: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        TextField("搜索应用或功能", text: $searchText)
          .textFieldStyle(.roundedBorder)
          .controlSize(.small)
          .accessibilityLabel("搜索应用中心")

        Picker("应用分类", selection: $category) {
          ForEach(categories, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
        .controlSize(.small)
        .frame(width: 96)
        .accessibilityLabel("应用分类")
      }
      .padding(8)

      Divider()

      ScrollViewReader { reader in
        ScrollView {
          if visibleItems.isEmpty {
            VStack(spacing: 8) {
              Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundStyle(.secondary)
              Text("没有找到匹配的应用")
                .font(.callout.weight(.medium))
              Text("换个关键词或分类试试。")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
            .accessibilityElement(children: .combine)
          } else {
            LazyVStack(spacing: 2) {
              ForEach(visibleItems) { item in
                ApplicationCenterOverviewRow(
                  item: item,
                  selected: model.selectedPluginID == item.id
                ) {
                  model.selectPlugin(id: item.id)
                }
                .id(item.id)
              }
            }
            .padding(6)
          }
        }
        .onAppear {
          guard let anchor = model.pluginCenterScrollAnchorID else { return }
          DispatchQueue.main.async { reader.scrollTo(anchor, anchor: .center) }
        }
      }
    }
    .background(Color(nsColor: .windowBackgroundColor).opacity(0.72))
  }

  @ViewBuilder
  private func applicationDetail(item: ApplicationCenterItem) -> some View {
    VStack(spacing: 0) {
      ApplicationCenterDetailHeader(item: item) {
        model.selectPlugin(id: nil)
      }
      Divider()

      switch item.id {
      case applicationYoumuID:
        YoumuApplicationDetailView()
      case applicationPijuanPDFID:
        PijuanApplicationDetailView()
      case applicationAIPlayerID:
        AIPlayerApplicationDetailView()
      case applicationFeatureShortcutsID:
        OnDemandApplicationDetailView(
          productName: item.name,
          headline: "先用默认配置完成一次",
          description: "从打开 App、窗口左右分屏或复制粘贴开始。默认动作可以直接用，熟悉后再调整按键。"
        ) {
          model.selectedModuleName = moduleHotkeys
        }
      case applicationPhrasesID:
        PhrasePanelView()
      case applicationClipboardHistoryID:
        ClipboardHistoryApplicationDetailView(
          controller: model.clipboardHistory,
          openHistory: { model.showClipboardHistory() },
          openShortcutSettings: {
            model.openShortcutManager(action: .showClipboardHistory)
          })
      case AppModel.launcherPluginID:
        LauncherPluginDetailView()
      case AppModel.inputMethodPluginID:
        InputMethodPluginDetailView()
      case "process-viewer":
        OnDemandApplicationDetailView(
          productName: item.name,
          headline: "查看运行状态",
          description: "查看 CPU、内存和交换空间；关闭窗口后停止刷新。"
        ) {
          processViewerPluginEnabled = true
          model.showProcessViewer()
        }
      case "codex-network-probe":
        NetworkProbeApplicationDetailView {
          codexNetworkProbePluginEnabled = true
          model.showCodexNetworkProbe()
        }
      case applicationPermanentUninstallID:
        PermanentUninstallApplicationDetailView()
      default:
        ScrollView {
          Group {
            switch item.id {
            case "caps-core": CapsCorePluginCard()
            case "mouse-scroll": MouseScrollPluginCard()
            case "mouse-volume": MouseVolumePluginCard()
            case "network-speed": NetworkSpeedPluginCard()
            case "sleep": SleepPluginCard()
            default:
              Text("这个应用入口暂时不可用。")
                .foregroundStyle(muted)
            }
          }
          .padding(16)
          .frame(maxWidth: .infinity, alignment: .topLeading)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func applyRequestedSelection() {
    guard let requestedSelectionID else { return }
    guard allItems.contains(where: { $0.id == requestedSelectionID }) else { return }
    model.selectPlugin(id: requestedSelectionID)
  }

  private var launcherStatusText: String? {
    guard model.launcherPluginEnabled else { return nil }
    return model.launcherHotkeySummary == "Caps + Space" ? nil : "需要处理"
  }

  private var capsStatusText: String? {
    guard model.capsCorePluginEnabled else { return nil }
    if !model.authorizationPermissionsComplete { return "需要授权" }
    switch model.capsCorePluginStatus {
    case .running: return nil
    case .stopped, .paused: return "需要处理"
    case .waitingForPermission: return "需要授权"
    case .conflict(let conflict): return conflict.displayText
    case .failed: return "失败，可重试"
    }
  }

  private var capsStatusImage: String {
    if !model.authorizationPermissionsComplete { return "lock.trianglebadge.exclamationmark" }
    if case .waitingForPermission = model.capsCorePluginStatus {
      return "lock.trianglebadge.exclamationmark"
    }
    return "exclamationmark.triangle.fill"
  }

  private var capsStatusColor: Color {
    switch model.capsCorePluginStatus {
    case .conflict, .failed: return ruby
    default: return amber
    }
  }

  private var inputMethodStatusText: String? {
    guard model.inputMethodPluginEnabled else { return nil }
    switch model.inputMethodPluginStatus {
    case .ready, .switched: return nil
    case .stopped: return "需要处理"
    case .noRules: return "未设置规则"
    case .conflict: return "检测到同类工具"
    case .failed: return "切换失败"
    }
  }

  private var inputMethodStatusColor: Color {
    switch model.inputMethodPluginStatus {
    case .conflict, .failed: return ruby
    default: return amber
    }
  }

  private var mouseScrollStatusText: String? {
    guard model.scrollSettings.enabled, !model.scrollEngineRunning else { return nil }
    return model.advancedListeningAuthorized ? "需要处理" : "需要授权"
  }

  private var mouseVolumeStatusText: String? {
    guard model.mouseVolumePluginEnabled, !model.scrollEngineRunning else { return nil }
    return model.advancedListeningAuthorized ? "需要处理" : "需要授权"
  }

  private var clipboardHistoryStatusText: String? {
    if !model.clipboardHistory.isEnabled { return "已暂停" }
    if model.clipboardHistory.quotaBlocked { return "空间已满" }
    if model.clipboardHistory.statusMessage?.hasPrefix("保存失败") == true {
      return "保存失败"
    }
    if model.clipboardHistory.pendingDeletionBytes > 0 { return "正在清理" }
    return nil
  }

  private var clipboardHistoryStatusImage: String {
    if model.clipboardHistory.quotaBlocked {
      return "externaldrive.badge.exclamationmark"
    }
    if model.clipboardHistory.statusMessage?.hasPrefix("保存失败") == true {
      return "exclamationmark.triangle.fill"
    }
    if model.clipboardHistory.pendingDeletionBytes > 0 {
      return "arrow.triangle.2.circlepath"
    }
    return "pause.circle.fill"
  }

  private var clipboardHistoryStatusColor: Color {
    if model.clipboardHistory.quotaBlocked
      || model.clipboardHistory.statusMessage?.hasPrefix("保存失败") == true
    {
      return ruby
    }
    if model.clipboardHistory.pendingDeletionBytes > 0 { return amber }
    return amber
  }
}

private struct InputMethodPluginDetailView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    Form {
      Section {
        Toggle(
          "按 App 自动切换",
          isOn: Binding(
            get: { model.inputMethodPluginEnabled },
            set: { model.setInputMethodPluginEnabled($0) })
        )
        .toggleStyle(.switch)

        LabeledContent("状态", value: model.inputMethodPluginStatus.displayText)
        Text(model.inputMethodPluginStatus.detailText)
          .font(.caption)
          .foregroundStyle(statusColor)
      } header: {
        Label("输入法管家", systemImage: "character.cursor.ibeam")
      } footer: {
        Text("默认关闭。只在前台 App 真正发生切换时执行；未设置的 App 保持当前输入法。")
      }

      Section {
        if model.inputMethodRules.isEmpty {
          VStack(spacing: 8) {
            Image(systemName: "keyboard")
              .font(.system(size: 26))
              .foregroundStyle(.secondary)
            Text("还没有 App 规则")
              .font(.headline)
            Text("先添加一个 App，再选择它应使用的输入法。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, minHeight: 120)
        } else {
          ForEach(model.inputMethodRules) { rule in
            inputMethodRuleRow(rule)
          }
        }

        HStack {
          Menu {
            ForEach(model.inputMethodCandidateApps) { app in
              Button {
                model.addInputMethodRule(app)
              } label: {
                InputMethodCandidateMenuLabel(candidate: app)
              }
            }
            if !model.inputMethodCandidateApps.isEmpty {
              Divider()
            }
            Button("从应用程序选择…") {
              model.chooseInputMethodRuleApp()
            }
          } label: {
            Label("添加 App", systemImage: "plus")
          }

          Spacer()

          Button("刷新输入法") {
            model.refreshInputMethodSources()
          }
        }
      } header: {
        Text("App 规则")
      } footer: {
        Text("每个 App 只保留一条规则；启动器等内置窗口也可单独设置。")
      }

      if !model.inputMethodRuleDiagnostics.isEmpty {
        Section("规则健康") {
          ForEach(model.inputMethodRuleDiagnostics) { diagnostic in
            Label {
              VStack(alignment: .leading, spacing: 2) {
                Text(diagnostic.appName)
                  .font(.body.weight(.medium))
                Text(diagnostic.detailText)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            } icon: {
              Image(systemName: diagnosticIcon(diagnostic.kind))
                .foregroundStyle(diagnosticColor(diagnostic.kind))
            }
          }

          if model.inputMethodRuleDiagnostics.contains(where: \.isRepairable) {
            Button("清理重复或空规则") {
              model.repairInputMethodRules()
            }
          }
        }
      }

      Section("备份与恢复") {
        HStack {
          Button("导出规则…") {
            model.exportInputMethodRules()
          }
          Button("导入规则…") {
            model.importInputMethodRules()
          }
          Spacer()
          Button("打开备份文件夹") {
            model.openInputMethodRulesBackupFolder()
          }
        }
        Text("导入前会校验格式和版本，并请你确认；替换前自动保存当前规则，旧版规则也可直接导入。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("立即测试") {
        Menu {
          ForEach(model.inputMethodSources) { source in
            Button(source.name) {
              model.testInputMethodSource(selectionID: source.selectionID)
            }
          }
        } label: {
          Label("切换到指定输入法", systemImage: "arrow.left.arrow.right")
        }
        .disabled(model.inputMethodSources.isEmpty)

        LabeledContent("系统当前输入法", value: InputMethodSourceController.currentSourceName())
      }

      Section("稳定性保护") {
        Label("只监听 App 激活，不轮询、不监听每次点击。", systemImage: "checkmark.shield")
        Label("目标已是当前输入法时不重复切换。", systemImage: "checkmark.shield")
        Label("切换后会确认结果；未生效时最多重试一次。", systemImage: "checkmark.shield")
        Label("启动器收起时恢复之前的输入法。", systemImage: "checkmark.shield")
        Label("发现同类自动切换工具运行时，自动让位。", systemImage: "checkmark.shield")
        Label("规则只存本机；不读取输入内容，也不记录按键或网站。", systemImage: "hand.raised")
        Text("为避免打断中文组词，本功能不会根据输入框或网站频繁切换输入法。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private func inputMethodRuleRow(_ rule: InputMethodAppRule) -> some View {
    HStack(spacing: 10) {
      Toggle(
        "",
        isOn: Binding(
          get: {
            model.inputMethodRules.first(where: { $0.id == rule.id })?.enabled ?? false
          },
          set: { model.setInputMethodRuleEnabled(id: rule.id, enabled: $0) })
      )
      .labelsHidden()
      .toggleStyle(.switch)
      .accessibilityLabel("启用 \(rule.appName) 输入法规则")

      Image(nsImage: model.inputMethodAppIcon(rule: rule))
        .resizable()
        .scaledToFit()
        .frame(width: 30, height: 30)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(rule.appName)
          .font(.body.weight(.medium))
          .lineLimit(1)
        Text(rule.bundleIdentifier)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer(minLength: 8)

      Picker(
        "输入法",
        selection: Binding(
          get: {
            model.inputMethodRules.first(where: { $0.id == rule.id })?.sourceSelectionID
              ?? rule.sourceSelectionID
          },
          set: { model.setInputMethodRuleSource(id: rule.id, selectionID: $0) })
      ) {
        if !model.inputMethodSources.contains(where: {
          $0.selectionID == rule.sourceSelectionID
        }) {
          Text("输入法不可用").tag(rule.sourceSelectionID)
        }
        ForEach(model.inputMethodSources) { source in
          Text(source.name).tag(source.selectionID)
        }
      }
      .labelsHidden()
      .frame(width: 170)
      .accessibilityLabel("\(rule.appName) 使用的输入法")

      Button(role: .destructive) {
        model.removeInputMethodRule(id: rule.id)
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
      .help("删除规则")
      .accessibilityLabel("删除 \(rule.appName) 输入法规则")
    }
  }

  private var statusColor: Color {
    switch model.inputMethodPluginStatus {
    case .conflict, .failed: return ruby
    default: return .secondary
    }
  }

  private func diagnosticIcon(_ kind: InputMethodRuleDiagnosticKind) -> String {
    switch kind {
    case .emptyRule: return "exclamationmark.triangle"
    case .duplicateApplication: return "square.on.square"
    case .unavailableInputSource: return "keyboard.badge.ellipsis"
    }
  }

  private func diagnosticColor(_ kind: InputMethodRuleDiagnosticKind) -> Color {
    switch kind {
    case .unavailableInputSource: return .orange
    case .emptyRule, .duplicateApplication: return .red
    }
  }
}

private struct InputMethodCandidateMenuLabel: View {
  let candidate: InputMethodAppCandidate

  private var appIcon: NSImage {
    let source =
      FileManager.default.fileExists(atPath: candidate.path)
      ? NSWorkspace.shared.icon(forFile: candidate.path)
      : (NSImage(named: NSImage.applicationIconName) ?? NSImage())
    let icon = (source.copy() as? NSImage) ?? source
    icon.size = NSSize(width: 16, height: 16)
    icon.isTemplate = false
    return icon
  }

  var body: some View {
    if candidate.bundleIdentifier == InputMethodBuiltInTarget.launcherIdentifier {
      Label(candidate.name, systemImage: "magnifyingglass")
    } else {
      Label {
        Text(candidate.name)
      } icon: {
        Image(nsImage: appIcon)
          .renderingMode(.original)
      }
    }
  }
}

private struct SystemManagedPluginDetailView: View {
  @EnvironmentObject private var model: AppModel
  @Binding var item: ShortcutItem

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      PluginToolCard(item: $item)

      Divider()

      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("恢复设置")
            .font(.system(size: 13, weight: .semibold))
          Text("调错后可恢复为 App 内置默认值。")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(muted)
        }
        Spacer()
        Button("恢复默认设置") {
          model.restorePluginShortcut(id: item.id)
        }
        .buttonStyle(.bordered)
        .disabled(!model.canRestorePluginShortcut(id: item.id))
      }
    }
  }
}

private struct ApplicationCenterOverviewRow: View {
  let item: ApplicationCenterItem
  let selected: Bool
  let action: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Button(action: action) {
        HStack(spacing: 9) {
          ApplicationCenterIcon(item: item, size: 30)

          VStack(alignment: .leading, spacing: 2) {
            Text(item.name)
              .font(.callout.weight(.semibold))
              .foregroundStyle(.primary)
              .lineLimit(1)
            Text(item.purpose)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(2)
              .help(item.purpose)
          }

          Spacer(minLength: 4)
          if let statusText = item.statusText {
            Label(statusText, systemImage: item.statusImage)
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(item.statusColor)
              .lineLimit(1)
              .labelStyle(.titleAndIcon)
          }
          Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(accessibilityLabel)
      .accessibilityValue(selected ? "已选" : "未选")
      .accessibilityHint("查看详情")

      if let isEnabled = item.isEnabled {
        Toggle("", isOn: isEnabled)
          .labelsHidden()
          .toggleStyle(.switch)
          .controlSize(.small)
          .accessibilityLabel("\(item.name)后台开关")
          .accessibilityValue(isEnabled.wrappedValue ? "已打开" : "已关闭")
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, minHeight: 56)
    .background(
      selected ? aixlgMist : Color.clear,
      in: RoundedRectangle(cornerRadius: 9, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .stroke(selected ? aixlgPurple.opacity(0.12) : Color.clear, lineWidth: 1)
    )
    .overlay(alignment: .leading) {
      if selected {
        Capsule()
          .fill(aixlgPurple)
          .frame(width: 3, height: 24)
          .padding(.leading, 2)
          .accessibilityHidden(true)
      }
    }
  }

  private var accessibilityLabel: String {
    [item.name, item.mode.title, item.valueDescription, item.statusText]
      .compactMap { $0 }
      .joined(separator: "。")
  }
}

private struct ApplicationCenterOverviewView: View {
  let featuredItems: [ApplicationCenterItem]
  let selectFeatureShortcuts: () -> Void
  let select: (String) -> Void

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [aixlgPaper, aixlgMist.opacity(0.78), aixlgPaper],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
              Circle()
                .fill(aixlgPurple)
                .frame(width: 6, height: 6)
              Text("应用中心")
                .font(.caption.weight(.semibold))
                .foregroundStyle(aixlgPurple)
            }

            Text("先试一个最有感的功能")
              .font(.title2.weight(.semibold))
              .foregroundStyle(.primary)

            Text("选一件，马上得到结果；细节可以之后再慢慢设置。")
              .font(.callout)
              .foregroundStyle(.secondary)
          }

          ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { firstWinActions }
            VStack(spacing: 8) { firstWinActions }
          }

          Text("核心应用")
            .font(.headline)
            .foregroundStyle(.primary)

          VStack(spacing: 0) {
            ForEach(Array(featuredItems.enumerated()), id: \.element.id) { index, item in
              Button {
                select(item.id)
              } label: {
                HStack(spacing: 10) {
                  ApplicationCenterIcon(item: item, size: 34)

                  VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                      .font(.callout.weight(.semibold))
                      .foregroundStyle(.primary)
                    Text(item.purpose)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .lineLimit(1)
                  }

                  Spacer(minLength: 8)
                  Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                }
                .padding(.horizontal, 11)
                .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityElement(children: .ignore)
              .accessibilityLabel("\(item.name)。\(item.purpose)")
              .accessibilityHint("查看详情")

              if index < featuredItems.count - 1 {
                Divider()
                  .padding(.leading, 56)
              }
            }
          }
          .background(
            aixlgPaper.opacity(0.92),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
              .stroke(aixlgPurple.opacity(0.09), lineWidth: 1)
          )
        }
        .padding(24)
        .frame(maxWidth: 640, alignment: .topLeading)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private var firstWinActions: some View {
    ApplicationCenterFirstWinButton(
      systemImage: "viewfinder.circle.fill",
      assetName: "YoumuAppIcon",
      tint: aixlgPurple,
      title: "看懂屏幕外文",
      hint: "打开游目"
    ) {
      select(applicationYoumuID)
    }
    ApplicationCenterFirstWinButton(
      systemImage: "magnifyingglass",
      tint: accent,
      title: "快速找到 App",
      hint: "试试 Caps + Space"
    ) {
      select(AppModel.launcherPluginID)
    }
    ApplicationCenterFirstWinButton(
      systemImage: "keyboard.badge.ellipsis",
      tint: teal,
      title: "少做重复动作",
      hint: "使用默认快捷键"
    ) {
      selectFeatureShortcuts()
    }
  }
}

private struct ApplicationCenterFirstWinButton: View {
  let systemImage: String
  var assetName: String? = nil
  let tint: Color
  let title: String
  let hint: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 7) {
        firstWinIcon
        Text(title)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
        Text(hint)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(11)
      .frame(minWidth: 150, maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
      .background(
        aixlgPaper.opacity(0.88),
        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .stroke(tint.opacity(0.10), lineWidth: 1)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(title)。\(hint)")
  }

  @ViewBuilder
  private var firstWinIcon: some View {
    if let assetName, let appIcon = NSImage(named: NSImage.Name(assetName)) {
      Image(nsImage: appIcon)
        .resizable()
        .renderingMode(.original)
        .scaledToFit()
        .frame(width: 24, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .shadow(color: Color.black.opacity(0.10), radius: 2, x: 0, y: 1)
    } else {
      Image(systemName: systemImage)
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(tint)
    }
  }
}

private struct ApplicationCenterDetailHeader: View {
  let item: ApplicationCenterItem
  let showOverview: () -> Void

  var body: some View {
    HStack(spacing: 11) {
      Button(action: showOverview) {
        Image(systemName: "chevron.left")
          .font(.system(size: 12, weight: .bold))
          .frame(width: 28, height: 28)
          .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
      }
      .buttonStyle(.plain)
      .help("返回应用中心总览")
      .accessibilityLabel("返回应用中心总览")

      ApplicationCenterIcon(item: item, size: 30)

      VStack(alignment: .leading, spacing: 2) {
        Text(item.name)
          .font(.headline)
          .foregroundStyle(ink)
        Text(item.purpose)
          .font(.caption)
          .foregroundStyle(muted)
          .lineLimit(1)
      }

      Spacer(minLength: 4)
      Text("永久免费")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 14)
    .frame(minHeight: 52)
    .accessibilityElement(children: .contain)
  }
}

private struct OnDemandApplicationDetailView: View {
  let productName: String
  let headline: String
  let description: String
  let action: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 7) {
          Text(headline)
            .font(.title3.weight(.semibold))
            .foregroundStyle(ink)
          Text(description)
            .font(.body)
            .foregroundStyle(muted)
            .fixedSize(horizontal: false, vertical: true)
        }

        ApplicationWindowOpenButton(productName: productName, action: action)
      }
      .padding(22)
      .frame(maxWidth: 680, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct ApplicationWindowOpenButton: View {
  let productName: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label("打开窗口", systemImage: "arrow.up.right.square")
    }
    .buttonStyle(.borderedProminent)
    .tint(accent)
    .controlSize(.large)
    .help("打开 \(productName) 窗口")
    .accessibilityLabel("打开 \(productName) 窗口")
  }
}

private struct YoumuApplicationDetailView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 7) {
          Text("看懂屏幕内容")
            .font(.title3.weight(.semibold))
            .foregroundStyle(ink)
          Text("调整截图、朗读与翻译。")
            .font(.body)
            .foregroundStyle(muted)
        }

        ApplicationWindowOpenButton(productName: "游目") {
          model.openYoumuControlCenter()
        }

        HStack(spacing: 10) {
          Image(systemName: "menubar.rectangle")
            .foregroundStyle(accent)
            .accessibilityHidden(true)
          Text("快捷操作可从菜单栏调用，快捷键在“功能快捷键”统一管理。")
            .font(.callout)
            .foregroundStyle(muted)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 8)
          Button {
            model.openFeatureShortcutManager(
              commandID: YoumuFeatureShortcutCatalog.quickSnapshot.id)
          } label: {
            Label("管理快捷键", systemImage: "keyboard")
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .accessibilityLabel("在功能快捷键中管理游目快捷键")
        }
        .padding(.top, 2)
      }
      .padding(22)
      .frame(maxWidth: 680, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct AIPlayerApplicationDetailView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 7) {
          Text("播放本地音视频")
            .font(.title3.weight(.semibold))
            .foregroundStyle(ink)
          Text("课程、播客和视频集中播放，自动保留进度。")
            .font(.body)
            .foregroundStyle(muted)
            .fixedSize(horizontal: false, vertical: true)
        }

        Label(
          "MP3、M4A、WAV 使用 macOS 原生引擎，无需安装播放插件",
          systemImage: "checkmark.circle.fill"
        )
        .font(.callout.weight(.medium))
        .foregroundStyle(teal)

        ApplicationWindowOpenButton(productName: "听澜播放器") {
          model.showAIPlayer()
        }

        FileAssociationControlCard(
          kind: .audio,
          title: "双击音频直接进入听澜",
          detail: "主动设置后，MP3、M4A、WAV 可从访达直接进入听澜播放；这些格式无需额外插件。",
          systemImage: "waveform.circle.fill",
          tint: accent)

        if model.aiPlayerCanUndoTrash {
          Divider()
          VStack(alignment: .leading, spacing: 8) {
            Text("刚才删除错了？")
              .font(.headline)
              .foregroundStyle(ink)
            Button {
              model.undoAIPlayerTrash()
            } label: {
              Label("撤销播放器刚才的删除", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
            .tint(teal)
            .accessibilityLabel("撤销播放器刚才移到废纸篓的文件")
          }
        }
      }
      .padding(22)
      .frame(maxWidth: 680, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct PijuanApplicationDetailView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 7) {
          Text("阅读 PDF")
            .font(.title3.weight(.semibold))
            .foregroundStyle(ink)
          Text("阅读、检索和整理长文档。")
            .font(.body)
            .foregroundStyle(muted)
        }

        ApplicationWindowOpenButton(productName: "披卷") {
          model.showPijuanPDFFeature()
        }

        FileAssociationControlCard(
          kind: .pdf,
          title: "双击 PDF 直接进入披卷",
          detail: "不会默认抢走现有设置；只有你点击按钮后才会关联，之后也能一键恢复原应用。",
          systemImage: "doc.richtext.fill",
          tint: violet)
      }
      .padding(22)
      .frame(maxWidth: 680, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct FileAssociationControlCard: View {
  @EnvironmentObject private var model: AppModel

  let kind: AssociatedFileKind
  let title: String
  let detail: String
  let systemImage: String
  let tint: Color

  private var coverage: FileAssociationStatus.Coverage {
    kind == .pdf ? model.pdfFileAssociationCoverage : model.audioFileAssociationCoverage
  }

  private var canRestore: Bool {
    kind == .pdf ? model.pdfFileAssociationCanRestore : model.audioFileAssociationCanRestore
  }

  private var status: (String, Color) {
    guard model.fileAssociationChangesAllowed else { return ("仅正式安装版可设置", muted) }
    switch coverage {
    case .all: return ("已设为默认打开", teal)
    case .partial: return ("部分已关联", amber)
    case .none: return ("未设为默认", muted)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      HStack(alignment: .top, spacing: 12) {
        IconBadge(systemImage: systemImage, tint: tint, size: 42, iconSize: 18)
        VStack(alignment: .leading, spacing: 5) {
          HStack(spacing: 8) {
            Text(title)
              .font(.headline)
              .foregroundStyle(ink)
            StatusPill(text: status.0, color: status.1)
          }
          Text(detail)
            .font(.callout)
            .foregroundStyle(muted)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 4)
      }

      HStack(spacing: 10) {
        Button {
          model.setAsDefaultApplication(for: kind)
        } label: {
          if model.fileAssociationBusyKind == kind {
            ProgressView().controlSize(.small)
          } else {
            Label(coverage == .all ? "已设为默认" : "设为默认打开", systemImage: "checkmark.circle")
          }
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .disabled(
          !model.fileAssociationChangesAllowed || coverage == .all
            || model.fileAssociationBusyKind != nil)

        if canRestore {
          Button("恢复原打开方式") {
            model.restorePreviousDefaultApplication(for: kind)
          }
          .buttonStyle(.bordered)
          .disabled(model.fileAssociationBusyKind != nil)
        }

        Spacer()
      }

      if model.fileAssociationFeedbackKind == kind,
        !model.fileAssociationFeedbackText.isEmpty
      {
        Text(model.fileAssociationFeedbackText)
          .font(.caption)
          .foregroundStyle(muted)
          .fixedSize(horizontal: false, vertical: true)
      } else if !model.fileAssociationChangesAllowed {
        Text("请从正式安装的应用中更改访达文件打开方式。")
          .font(.caption)
          .foregroundStyle(muted)
      } else {
        Text("macOS 如果询问，确认一次即可；安装本身不会自动更改默认应用。")
          .font(.caption)
          .foregroundStyle(muted)
      }
    }
    .padding(15)
    .background(
      Color(nsColor: .controlBackgroundColor).opacity(0.66),
      in: RoundedRectangle(cornerRadius: 16, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
    )
    .onAppear { model.refreshFileAssociationStatus() }
  }
}

private struct NetworkProbeApplicationDetailView: View {
  @EnvironmentObject private var model: AppModel
  let openWindow: () -> Void

  var body: some View {
    Form {
      Section {
        Text("一个球测下载、上传、延迟和抖动，一个球测 Codex 四轮连通与响应。")
          .font(.body)
          .foregroundStyle(.secondary)

        ApplicationWindowOpenButton(productName: "测试网速", action: openWindow)
      } header: {
        Text("测速")
      }

      Section("快捷键") {
        LabeledContent("当前快捷键", value: model.codexNetworkProbeHotkeySummary)
        Button {
          model.openShortcutManager(action: .showCodexNetworkProbe)
        } label: {
          Label("修改快捷键", systemImage: "keyboard")
        }
      }
    }
    .formStyle(.grouped)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct PermanentUninstallApplicationDetailView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        VStack(alignment: .leading, spacing: 7) {
          Text("卸载前，先看清删除范围")
            .font(.title3.weight(.semibold))
            .foregroundStyle(ink)
          Text("先选择 App，再扫描可识别的关联文件；确认界面会列出具体路径，只有最终确认后才会执行。")
            .font(.body)
            .foregroundStyle(muted)
            .fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: 10) {
          Label("不会因为点了入口就立即删除", systemImage: "checkmark.shield.fill")
          Label("系统 App 和受保护目标会被拦截", systemImage: "checkmark.shield.fill")
          Label("这是本机维护功能，不依赖 Pro 或联网状态", systemImage: "checkmark.shield.fill")
        }
        .font(.callout)
        .foregroundStyle(ink.opacity(0.86))
        .symbolRenderingMode(.hierarchical)

        Button(role: .destructive) {
          model.chooseAppForPermanentUninstall()
        } label: {
          Label("选择要卸载的 App…", systemImage: "trash.slash")
        }
        .buttonStyle(.bordered)
        .tint(ruby)
        .controlSize(.large)
        .help("先扫描可安全识别的范围，再确认是否永久删除")
        .accessibilityLabel("选择要彻底卸载的 App")

        Text("建议先确认重要数据已有备份。确认界面会列出主程序和专属数据的具体路径。")
          .font(.caption)
          .foregroundStyle(muted)
      }
      .padding(22)
      .frame(maxWidth: 680, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct LauncherPluginDetailView: View {
  @EnvironmentObject private var model: AppModel

  private var needsAttention: Bool {
    model.launcherPluginEnabled && model.launcherHotkeySummary != "Caps + Space"
  }

  var body: some View {
    Form {
      Section {
        Toggle(
          "启动器",
          isOn: Binding(
            get: { model.launcherPluginEnabled },
            set: { model.setLauncherPluginEnabled($0) })
        )
        .toggleStyle(.switch)
      } header: {
        Label("启动器", systemImage: "magnifyingglass")
      } footer: {
        Text("快速打开 App、计算和网页。关闭后固定项目、顺序、显示偏好和索引仍保留。")
      }

      Section("显示偏好") {
        Picker(
          "显示方式",
          selection: Binding(
            get: { model.launcherDisplayMode },
            set: { model.setLauncherDisplayMode($0) })
        ) {
          ForEach(LauncherDisplayMode.allCases) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .pickerStyle(.segmented)

        Toggle(
          "显示名称",
          isOn: Binding(
            get: { model.launcherShowsPinnedNames },
            set: { model.setLauncherShowsPinnedNames($0) })
        )
        .accessibilityLabel("显示固定图标名称")
        .accessibilityHint("只影响固定区视觉；工具提示和 VoiceOver 始终保留名称。")
      }

      Section("固定项目") {
        LabeledContent("已固定", value: "\(model.launcherPinnedRecords.count)/8")
        HStack {
          Label("听澜播放器", systemImage: "play.square.stack.fill")
          Spacer()
          Button(model.isAIPlayerPinnedInLauncher ? "取消固定" : "添加到快捷栏") {
            model.setAIPlayerPinnedInLauncher(!model.isAIPlayerPinnedInLauncher)
          }
          .accessibilityLabel(
            model.isAIPlayerPinnedInLauncher
              ? "从启动器快捷栏移除听澜播放器"
              : "将听澜播放器添加到启动器快捷栏")
        }
        Text("固定、排序和移除仍在启动器对象菜单中完成。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if needsAttention {
        Section("需要处理") {
          Label("Caps + Space 当前有受保护的占用。", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(amber)
          HStack {
            Button("保留原设置") { model.keepCurrentCapsSpaceBehavior() }
            Spacer()
            Button("改为启动器") { model.adoptCapsSpaceForLauncher() }
              .buttonStyle(.borderedProminent)
          }
        }
      }

      Section {
        Button {
          model.showLauncher()
        } label: {
          Label(
            model.launcherPluginEnabled ? "打开启动器" : "预览启动器", systemImage: "arrow.up.right.square")
        }
      }
    }
    .formStyle(.grouped)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct PluginToolCard: View {
  @EnvironmentObject private var model: AppModel
  @Binding var item: ShortcutItem

  var body: some View {
    VStack(alignment: .leading, spacing: 11) {
      HStack(alignment: .center, spacing: 12) {
        IconBadge(systemImage: pluginIconName, tint: pluginTint, size: 44, iconSize: 18)

        VStack(alignment: .leading, spacing: 6) {
          InlineTextField(
            text: Binding(
              get: { item.name },
              set: { value in
                item.name = value.isEmpty ? "未命名插件" : value
                model.selectedID = item.id
                model.saveOnly()
              }
            ),
            placeholder: "插件名称",
            strong: true
          )
          .padding(.horizontal, -9)

        }

        Spacer()

        Button {
          model.runItem(item.id)
        } label: {
          Label("运行", systemImage: "play.fill")
            .labelStyle(.iconOnly)
        }
        .buttonStyle(GlassLabelButtonStyle(tint: teal, prominent: true))
        .help("运行")

        Toggle(
          "",
          isOn: Binding(
            get: { item.enabled },
            set: { value in
              item.enabled = value
              model.selectedID = item.id
              model.saveAndReload()
            }
          )
        )
        .toggleStyle(.switch)
      }

      HStack(spacing: 10) {
        HotkeyCell(
          text: item.displayHotkey,
          active: model.isRecording(item.id),
          onKeyDown: { event in model.applyRecorded(event) }
        ) {
          model.selectedID = item.id
          model.startRecording(itemID: item.id)
        }
        .frame(width: 126)
        .padding(.leading, -8)

        TextField(
          "plugin:xxx.sh",
          text: Binding(
            get: { item.target },
            set: { value in
              item.target = value
              model.selectedID = item.id
              model.saveAndScheduleHotkeyReload()
            }
          )
        )
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .textFieldStyle(.plain)
        .foregroundStyle(ink)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(
          Color.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(line.opacity(0.72), lineWidth: 1))
      }

      TextField(
        "插件说明",
        text: Binding(
          get: { item.note },
          set: { value in
            item.note = value
            model.selectedID = item.id
            model.saveOnly()
          }
        )
      )
      .font(.system(size: 12, weight: .medium))
      .textFieldStyle(.plain)
      .foregroundStyle(muted)
      .padding(.horizontal, 10)
      .frame(height: 30)
      .background(
        Color.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private var pluginIconName: String {
    if item.name.contains("麦克风") { return "mic.fill" }
    if item.name.contains("输入法") { return "character.cursor.ibeam" }
    return "puzzlepiece.extension.fill"
  }

  private var pluginTint: Color {
    if item.name.contains("麦克风") { return ruby }
    if item.name.contains("输入法") { return teal }
    return violet
  }
}

struct PluginChip: View {
  let text: String
  let color: Color

  var body: some View {
    Text(text)
      .font(.system(size: 10, weight: .medium, design: .rounded))
      .foregroundStyle(color)
      .padding(.horizontal, 8)
      .frame(height: 22)
      .background(color.opacity(0.09), in: Capsule())
  }
}

struct PluginPermissionNotice: View {
  let message: String
  let action: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Label(message, systemImage: "figure.stand")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(ink)
        .lineLimit(1)

      Spacer(minLength: 8)

      Button(action: action) {
        Label("立即授权", systemImage: "lock.open.fill")
          .font(.system(size: 12, weight: .semibold))
      }
      .buttonStyle(GlassLabelButtonStyle(tint: amber))
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(
      amber.opacity(0.10),
      in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(amber.opacity(0.22), lineWidth: 1)
    )
  }
}

struct EmptyPluginView: View {
  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "shippingbox")
        .font(.system(size: 34, weight: .semibold))
        .foregroundStyle(accent)
      Text("暂无脚本插件")
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(ink)
      Text("普通使用不需要新建插件。")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(muted)
    }
    .frame(maxWidth: .infinity, minHeight: 260)
  }
}

struct SystemPreferredStrip: View {
  let items: [ShortcutItem]

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "arrow.triangle.branch")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(teal)
        .frame(width: 30, height: 30)
        .background(teal.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))

      VStack(alignment: .leading, spacing: 6) {
        Text("已改为系统级调用")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(ink)
        Text(items.map(\.name).joined(separator: "、"))
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(muted)
          .lineLimit(2)
      }

      Spacer()
    }
    .padding(13)
    .background(
      Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 15, style: .continuous)
    )
    .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.white.opacity(0.78), lineWidth: 1))
  }
}

struct ToolbarIconButton: View {
  @Environment(\.isEnabled) private var isEnabled
  @State private var hovering = false

  let systemImage: String
  let title: String
  let tint: Color
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 13, weight: .semibold))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(isEnabled ? tint : muted.opacity(0.45))
        .frame(width: 34, height: 32)
        .background(
          LinearGradient(
            colors: buttonColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          ),
          in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(hovering ? tint.opacity(0.34) : Color.white.opacity(0.82), lineWidth: 1)
        )
        .shadow(
          color: isEnabled ? tint.opacity(hovering ? 0.16 : 0.07) : Color.clear, radius: 7, x: 0,
          y: 4
        )
        .scaleEffect(hovering && isEnabled ? 1.035 : 1)
    }
    .buttonStyle(.plain)
    .help(title)
    .accessibilityLabel(title)
    .onHover { inside in hovering = inside }
    .animation(.easeOut(duration: 0.12), value: hovering)
  }

  private var buttonColors: [Color] {
    if !isEnabled {
      return [Color.white.opacity(0.46), chrome.opacity(0.36)]
    }
    if hovering {
      return [Color.white.opacity(0.98), tint.opacity(0.15)]
    }
    return [Color.white.opacity(0.94), tint.opacity(0.08)]
  }
}

struct HeaderUpdateButton: View {
  let title: String
  let isBusy: Bool
  let busyTitle: String
  let helpText: String
  let accessibilityLabel: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label(
        isBusy ? busyTitle : title,
        systemImage: isBusy ? "arrow.triangle.2.circlepath" : "arrow.down.circle.fill"
      )
      .font(.system(size: 11, weight: .semibold))
      .labelStyle(.titleAndIcon)
      .foregroundStyle(accent)
      .padding(.horizontal, 8)
      .frame(height: 24)
      .background(accent.opacity(0.09), in: Capsule())
      .overlay(Capsule().stroke(accent.opacity(0.24), lineWidth: 1))
    }
    .buttonStyle(.plain)
    .disabled(isBusy)
    .help(helpText)
    .accessibilityLabel(isBusy ? busyTitle : accessibilityLabel)
    .accessibilityIdentifier("titlebar.update")
  }
}

struct HeaderToolIconButton: View {
  @Environment(\.isEnabled) private var isEnabled
  @State private var hovering = false

  let systemImage: String
  let title: String
  let tint: Color
  var isDestructive = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 12, weight: .semibold))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(iconColor)
        .frame(width: 30, height: 29)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .stroke(borderColor, lineWidth: 1)
        )
        .scaleEffect(hovering && isEnabled ? 1.025 : 1)
    }
    .buttonStyle(.plain)
    .help(title)
    .accessibilityLabel(title)
    .onHover { inside in hovering = inside }
    .animation(.easeOut(duration: 0.12), value: hovering)
  }

  private var iconColor: Color {
    guard isEnabled else { return muted.opacity(0.38) }
    if isDestructive { return ruby.opacity(hovering ? 0.90 : 0.72) }
    return tint.opacity(hovering ? 0.88 : 0.68)
  }

  private var backgroundColor: Color {
    guard isEnabled else { return Color.white.opacity(0.30) }
    return hovering ? Color.white.opacity(0.78) : Color.white.opacity(0.48)
  }

  private var borderColor: Color {
    if !isEnabled { return Color.white.opacity(0.30) }
    return hovering ? iconColor.opacity(0.18) : Color.white.opacity(0.50)
  }
}

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
        Color.white.opacity(0.24), in: RoundedRectangle(cornerRadius: 12, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(Color.white.opacity(0.46), lineWidth: 1)
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

struct PhrasePanelView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(spacing: 0) {
      VStack(spacing: 0) {
        PhraseTableHeader()
        if model.phrases.isEmpty {
          EmptyPhraseView {
            model.addPhrase()
          }
        } else {
          ScrollView {
            LazyVStack(spacing: 10) {
              ForEach(model.phrases.map(\.id), id: \.self) { phraseID in
                if let phrase = model.bindingForPhrase(id: phraseID) {
                  PhraseCardRow(phrase: phrase)
                }
              }
            }
            .padding(12)
          }
        }
      }
      .premiumPanel(radius: 17, shadowRadius: 14, shadowY: 8)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear {
      model.refreshAccessibilityStatus()
      model.reloadPhraseExpander()
    }
  }
}

struct PhraseTableHeader: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    HStack(spacing: 12) {
      Text("启用")
        .frame(width: 48, alignment: .leading)
      Text("缩写")
        .frame(width: 140, alignment: .leading)
      Text("输出内容")
        .frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: 6) {
        ToolbarIconButton(systemImage: "plus", title: "新增快捷短语", tint: accent) {
          model.addPhrase()
        }
        ToolbarIconButton(systemImage: "trash", title: "删除选中短语", tint: amber) {
          model.deleteSelectedPhrase()
        }
        .disabled(model.selectedPhraseID == nil)
      }
    }
    .font(.system(size: 12, weight: .medium))
    .foregroundStyle(muted)
    .padding(.horizontal, 14)
    .frame(height: 40)
    .background(
      LinearGradient(
        colors: [chrome, Color.white.opacity(0.68)], startPoint: .leading, endPoint: .trailing)
    )
  }
}

struct PhraseCardRow: View {
  @EnvironmentObject private var model: AppModel
  @Binding var phrase: PhraseItem
  @State private var hovering = false

  private var selected: Bool {
    model.selectedPhraseID == phrase.id
  }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Toggle(
        "",
        isOn: Binding(
          get: { phrase.enabled },
          set: { value in
            phrase.enabled = value
            model.selectedPhraseID = phrase.id
            model.savePhrasesAndReload()
          }
        )
      )
      .toggleStyle(.checkbox)
      .frame(width: 48)
      .padding(.top, 10)

      TextField(
        "ppdz",
        text: Binding(
          get: { phrase.trigger },
          set: { value in
            phrase.trigger = normalizedPhraseTrigger(value)
            model.selectedPhraseID = phrase.id
            model.schedulePhrasesSave(reload: true)
          }
        )
      )
      .font(.system(size: 16, weight: .semibold, design: .monospaced))
      .textFieldStyle(.plain)
      .foregroundStyle(accent)
      .padding(.horizontal, 10)
      .frame(width: 140, height: 38)
      .background(Color.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 10))
      .overlay(
        RoundedRectangle(cornerRadius: 10).stroke(
          selected ? accent.opacity(0.65) : line, lineWidth: 1)
      )
      .padding(.top, 4)

      TextEditor(
        text: Binding(
          get: { phrase.output },
          set: { value in
            phrase.output = value
            model.selectedPhraseID = phrase.id
            model.schedulePhrasesSave(reload: true)
          }
        )
      )
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(ink)
      .scrollContentBackground(.hidden)
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .frame(minHeight: 70)
      .background(Color.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).stroke(line, lineWidth: 1))
    }
    .padding(10)
    .background(rowBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(
          selected ? accent.opacity(0.45) : Color.white.opacity(0.70), lineWidth: selected ? 1.5 : 1
        )
    )
    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .onTapGesture {
      model.selectedPhraseID = phrase.id
    }
    .onHover { inside in hovering = inside }
    .animation(.easeOut(duration: 0.14), value: selected)
    .animation(.easeOut(duration: 0.12), value: hovering)
  }

  private var rowBackground: some ShapeStyle {
    if selected {
      return LinearGradient(
        colors: [accent.opacity(0.12), teal.opacity(0.055)], startPoint: .leading,
        endPoint: .trailing)
    }
    if hovering {
      return LinearGradient(
        colors: [glowBlue.opacity(0.045), Color.white.opacity(0.92)], startPoint: .leading,
        endPoint: .trailing)
    }
    return LinearGradient(
      colors: [surface.opacity(0.92), Color.white.opacity(0.72)], startPoint: .topLeading,
      endPoint: .bottomTrailing)
  }
}

struct EmptyPhraseView: View {
  let add: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "text.badge.plus")
        .font(.system(size: 34, weight: .semibold))
        .foregroundStyle(accent)
      Text("还没有快捷短语")
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(ink)
      Text("新增一条后，输入缩写就能自动展开文本。")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(muted)
      Button {
        add()
      } label: {
        Label("新增快捷短语", systemImage: "plus")
      }
      .buttonStyle(GlassLabelButtonStyle(tint: teal, prominent: true))
    }
    .frame(maxWidth: .infinity, minHeight: 260)
  }
}

private func normalizedPhraseTrigger(_ value: String) -> String {
  value
    .trimmingCharacters(in: .whitespacesAndNewlines)
    .replacingOccurrences(of: " ", with: "")
    .lowercased()
}

struct ScrollPanelView: View {
  @EnvironmentObject private var model: AppModel

  private var settings: ScrollEngineSettings {
    model.scrollSettings
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      HStack(spacing: 14) {
        IconBadge(systemImage: "scroll.fill", tint: accent, size: 44, iconSize: 19)

        HStack(spacing: 8) {
          Text("滚动手感")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(ink)
          StatusPill(
            text: model.scrollEngineRunning ? "运行中" : "未启用",
            color: model.scrollEngineRunning ? teal : amber)
        }

        Spacer()

        Toggle(
          "",
          isOn: Binding(
            get: { settings.enabled },
            set: { model.setScrollEngineEnabled($0) }
          )
        )
        .toggleStyle(.switch)
      }

      VStack(alignment: .leading, spacing: 12) {
        MosCheckRow(
          label: "平滑滚动",
          title: "启用 Mos-like 丝滑滚动",
          isOn: settings.smooth,
          set: { value in
            model.updateScrollSettings { settings in settings.smooth = value }
          })
        MosCheckRow(
          label: "反转滚动",
          title: "反转滚轮方向",
          isOn: settings.reverseVertical && settings.reverseHorizontal,
          set: { value in
            model.updateScrollSettings { settings in
              settings.reverseVertical = value
              settings.reverseHorizontal = value
            }
          })
        MosCheckRow(
          label: "设备",
          title: "触控板始终保持系统原样",
          isOn: true,
          set: { _ in
            model.updateScrollSettings { settings in
              settings.affectTrackpad = false
            }
          }
        )
        .disabled(true)
        .opacity(0.72)
      }

      Divider()

      VStack(alignment: .leading, spacing: 12) {
        MosKeyRow(
          label: "加速键",
          keyText: "⌥",
          help: "长页面滚动加速")
        MosKeyRow(
          label: "转换键",
          keyText: "⇧",
          help: "垂直滚动转水平")
        MosKeyRow(
          label: "禁用键",
          keyText: "⌘",
          help: "临时绕过接管")
      }

      Divider()

      VStack(alignment: .leading, spacing: 14) {
        MosSliderRow(
          title: "最短步长",
          value: settings.step,
          range: 8.0...60.0,
          help: "单次滚动最短距离"
        ) { nextValue in
          model.updateScrollSettings { settings in settings.step = nextValue }
        }
        MosSliderRow(
          title: "速度增益",
          value: settings.speed,
          range: 0.5...5.0,
          help: "持续滚动速度"
        ) { nextValue in
          model.updateScrollSettings { settings in settings.speed = nextValue }
        }
        MosSliderRow(
          title: "持续时间",
          value: settings.duration,
          range: 1.0...6.0,
          help: "滚动缓动时间"
        ) { nextValue in
          model.updateScrollSettings { settings in settings.duration = nextValue }
        }
      }

      HStack(spacing: 10) {
        ScrollMetric(title: "参数", value: "稳定方向")
        ScrollMetric(title: "范围", value: settings.affectTrackpad ? "鼠标和触控板" : "仅鼠标滚轮")
        Spacer()
        Button {
          model.applyMosScrollPreset()
        } label: {
          Label("恢复稳定手感", systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(GlassLabelButtonStyle(tint: teal, prominent: false))
      }
    }
    .padding(16)
    .premiumPanel(radius: 17, shadowRadius: 14, shadowY: 8)
    .onAppear {
      model.refreshLegacyScrollProfile()
      model.reloadScrollEngine()
    }
  }

}

struct SystemStatusPanelView: View {
  @EnvironmentObject private var model: AppModel

  private var snapshot: SystemMonitorSnapshot {
    model.systemMonitorSnapshot
  }

  private var memoryTint: Color {
    color(for: snapshot.memory.pressure)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 14) {
          IconBadge(systemImage: "speedometer", tint: accent, size: 48, iconSize: 20)
          VStack(alignment: .leading, spacing: 5) {
            Text("系统状态")
              .font(.system(size: 18, weight: .semibold))
              .foregroundStyle(ink)
            Text("网络与内存")
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(muted)
          }
          Spacer()
          StatusPill(text: snapshot.memory.pressure.title, color: memoryTint)
        }
        .padding(16)
        .premiumPanel(radius: 17, shadowRadius: 12, shadowY: 6)

        LazyVGrid(columns: metricColumns, spacing: 12) {
          SystemStatusMetricCard(
            title: "下载",
            value: formatRate(snapshot.network.downloadBytesPerSecond),
            detail: "实时接收速率",
            systemImage: "arrow.down.circle.fill",
            tint: accent
          )
          SystemStatusMetricCard(
            title: "上传",
            value: formatRate(snapshot.network.uploadBytesPerSecond),
            detail: "实时发送速率",
            systemImage: "arrow.up.circle.fill",
            tint: teal
          )
          SystemStatusMetricCard(
            title: "内存",
            value: "\(Int((snapshot.memory.usedRatio * 100).rounded()))%",
            detail:
              "\(formatBytes(snapshot.memory.usedBytes)) / \(formatBytes(snapshot.memory.totalBytes))",
            systemImage: "memorychip.fill",
            tint: memoryTint
          )
        }

        VStack(alignment: .leading, spacing: 14) {
          HStack(alignment: .firstTextBaseline) {
            Text("内存使用")
              .font(.system(size: 15, weight: .semibold))
              .foregroundStyle(ink)
            Spacer()
            Text("更新 \(sampleTimeText)")
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(muted)
          }

          ProgressView(value: snapshot.memory.usedRatio)
            .tint(memoryTint)
            .controlSize(.small)

          LazyVGrid(columns: detailColumns, spacing: 10) {
            SystemStatusDetailLine(
              title: "已用", value: formatBytes(snapshot.memory.usedBytes), tint: memoryTint)
            SystemStatusDetailLine(
              title: "可用", value: formatBytes(snapshot.memory.availableBytes), tint: muted)
            SystemStatusDetailLine(
              title: "App 内存", value: formatBytes(snapshot.memory.appBytes), tint: accent)
            SystemStatusDetailLine(
              title: "联动内存", value: formatBytes(snapshot.memory.wiredBytes), tint: amber)
            SystemStatusDetailLine(
              title: "压缩",
              value: formatBytes(snapshot.memory.compressedBytes),
              tint: ruby
            )
          }
        }
        .padding(16)
        .premiumPanel(radius: 17, shadowRadius: 12, shadowY: 6)
      }
      .padding(.top, 4)
      .padding(.bottom, 10)
    }
    .scrollIndicators(.visible)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear {
      model.startSystemMonitor()
    }
    .onDisappear {
      model.stopSystemMonitor()
    }
  }

  private var metricColumns: [GridItem] {
    [GridItem(.adaptive(minimum: 220), spacing: 12)]
  }

  private var detailColumns: [GridItem] {
    [GridItem(.adaptive(minimum: 170), spacing: 10)]
  }

  private var sampleTimeText: String {
    guard snapshot.sampledAt.timeIntervalSince1970 > 0 else { return "--:--:--" }
    return DateFormatter.localizedString(
      from: snapshot.sampledAt, dateStyle: .none, timeStyle: .medium)
  }

  private func color(for pressure: MemoryPressureLevel) -> Color {
    switch pressure {
    case .normal: return teal
    case .elevated: return amber
    case .high: return ruby
    }
  }
}

struct SystemStatusMetricCard: View {
  let title: String
  let value: String
  let detail: String
  let systemImage: String
  let tint: Color

  var body: some View {
    HStack(spacing: 12) {
      IconBadge(systemImage: systemImage, tint: tint, size: 42, iconSize: 18, filled: false)
      VStack(alignment: .leading, spacing: 5) {
        Text(title)
          .font(.system(size: 12, weight: .bold))
          .foregroundStyle(muted)
        Text(value)
          .font(.system(size: 24, weight: .semibold, design: .rounded))
          .foregroundStyle(ink)
          .lineLimit(1)
          .minimumScaleFactor(0.72)
        Text(detail)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(muted)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .padding(14)
    .frame(minHeight: 118, alignment: .leading)
    .premiumPanel(radius: 16, shadowRadius: 10, shadowY: 5)
  }
}

struct SystemStatusDetailLine: View {
  let title: String
  let value: String
  let tint: Color

  var body: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(tint)
        .frame(width: 8, height: 8)
      Text(title)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(muted)
      Spacer()
      Text(value)
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(ink)
    }
    .padding(.horizontal, 10)
    .frame(height: 34)
    .background(softSurface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .stroke(line.opacity(0.65), lineWidth: 1)
    )
  }
}

private func formatBytes(_ bytes: UInt64) -> String {
  guard bytes > 0 else { return "0 KB" }
  let value = Double(bytes)
  let gb = value / 1_073_741_824
  if gb >= 1 {
    return String(format: "%.1f GB", gb)
  }
  let mb = value / 1_048_576
  if mb >= 1 {
    return String(format: "%.1f MB", mb)
  }
  return String(format: "%.0f KB", value / 1024)
}

private func formatRate(_ bytesPerSecond: Double) -> String {
  guard bytesPerSecond > 0 else { return "0 KB/s" }
  let mb = bytesPerSecond / 1_000_000
  if mb >= 1 {
    return String(format: "%.1f MB/s", mb)
  }
  let kb = bytesPerSecond / 1_000
  if kb >= 1 {
    return String(format: "%.0f KB/s", kb)
  }
  return String(format: "%.0f B/s", bytesPerSecond)
}

struct MosCheckRow: View {
  let label: String
  let title: String
  let isOn: Bool
  let set: @MainActor @Sendable (Bool) -> Void

  var body: some View {
    HStack(spacing: 14) {
      Text(label)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(muted)
        .frame(width: 76, alignment: .trailing)

      Toggle(
        "",
        isOn: Binding(
          get: { isOn },
          set: set
        )
      )
      .toggleStyle(.checkbox)

      Text(title)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(ink)

      Spacer()
    }
    .frame(height: 30)
  }
}

struct MosKeyRow: View {
  let label: String
  let keyText: String
  let help: String

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      Text(label)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(muted)
        .frame(width: 76, alignment: .trailing)
        .padding(.top, 8)

      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          Text(keyText)
            .font(.system(size: 16, weight: .bold, design: .rounded))
            .foregroundStyle(ink)
            .frame(width: 180, height: 34)
            .background(line.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))

          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(muted)
        }

        Text(help)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(muted)
      }

      Spacer()
    }
  }
}

struct MosSliderRow: View {
  let title: String
  let value: Double
  let range: ClosedRange<Double>
  let help: String
  let set: @MainActor @Sendable (Double) -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      Text(title)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(muted)
        .frame(width: 76, alignment: .trailing)
        .padding(.top, 8)

      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 12) {
          Slider(
            value: Binding(
              get: { value },
              set: set
            ),
            in: range
          )
          .frame(width: 320)

          Text(String(format: "%.2f", value))
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(ink)
            .frame(width: 78, height: 32)
            .background(.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(line, lineWidth: 1))
        }

        Text(help)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(muted)
      }
    }
  }
}

struct StatusPill: View {
  let text: String
  let color: Color

  var body: some View {
    Text(text)
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(color)
      .padding(.horizontal, 8)
      .frame(height: 22)
      .background(color.opacity(0.10), in: Capsule())
  }
}

struct ScrollModeButton: View {
  let title: String
  let subtitle: String
  let systemImage: String
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: systemImage)
          .font(.system(size: 16, weight: .semibold))
          .frame(width: 30, height: 30)
          .foregroundStyle(selected ? .white : accent)
          .background(
            selected ? accent : accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(ink)
          Text(subtitle)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(muted)
        }
        Spacer()
        if selected {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(teal)
        }
      }
      .padding(.horizontal, 12)
      .frame(width: 244, height: 58)
      .background(
        selected ? accent.opacity(0.08) : softSurface, in: RoundedRectangle(cornerRadius: 12)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12)
          .stroke(
            selected ? accent.opacity(0.55) : line.opacity(0.7), lineWidth: selected ? 1.5 : 1)
      )
    }
    .buttonStyle(.plain)
  }
}

struct ScrollMetric: View {
  let title: String
  let value: String

  var body: some View {
    HStack(spacing: 4) {
      Text(title)
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(muted)
      Text(value)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(ink)
    }
    .padding(.horizontal, 8)
    .frame(height: 26)
    .background(softSurface, in: Capsule())
    .overlay(Capsule().stroke(line.opacity(0.65), lineWidth: 1))
  }
}

struct ScrollToggle: View {
  let title: String
  let value: Bool
  let set: @MainActor @Sendable (Bool) -> Void

  var body: some View {
    Toggle(
      title,
      isOn: Binding(
        get: { value },
        set: set
      )
    )
    .font(.system(size: 12, weight: .bold))
    .toggleStyle(.checkbox)
  }
}

struct ScrollSlider: View {
  let title: String
  let value: Double
  let range: ClosedRange<Double>
  let set: @MainActor @Sendable (Double) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(title)
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(muted)
        Spacer()
        Text(String(format: "%.1f", value))
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(ink)
      }
      Slider(
        value: Binding(
          get: { value },
          set: set
        ),
        in: range
      )
    }
    .frame(minWidth: 138)
  }
}

struct StatusChip: View {
  let title: String
  let value: String
  let color: Color

  var body: some View {
    HStack(spacing: 6) {
      Text(title)
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(muted)
      Text(value)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(color)
    }
    .padding(.horizontal, 10)
    .frame(height: 28)
    .background(
      LinearGradient(
        colors: [Color.white.opacity(0.86), color.opacity(0.07)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      ),
      in: Capsule()
    )
    .overlay(Capsule().stroke(Color.white.opacity(0.72), lineWidth: 1))
  }
}

struct HeaderWarningChip: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.system(size: 10, weight: .semibold))
      .foregroundStyle(amber.opacity(0.92))
      .padding(.horizontal, 7)
      .frame(height: 20)
      .background(amber.opacity(0.08), in: Capsule())
      .overlay(Capsule().stroke(amber.opacity(0.16), lineWidth: 1))
  }
}

struct KeepAwakeSheetView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  let onClose: (() -> Void)?

  init(onClose: (() -> Void)? = nil) {
    self.onClose = onClose
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 16) {
        ZStack {
          Circle()
            .fill(aixlgMist)
          Image(systemName: model.keepAwakeEnabled ? "moon.stars.fill" : "moon.zzz")
            .font(.system(size: 21, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(aixlgPurple)
        }
        .frame(width: 52, height: 52)
        .overlay(Circle().stroke(aixlgPurple.opacity(0.10), lineWidth: 1))
        .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 7) {
            Circle()
              .fill(model.keepAwakeEnabled ? teal : muted.opacity(0.55))
              .frame(width: 6, height: 6)
            Text("保持唤醒")
              .font(.system(size: 11, weight: .bold))
              .foregroundStyle(aixlgPurple)
          }
          Text(model.keepAwakeEnabled ? "正在保持唤醒" : "Mac 可以正常睡眠")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(ink)
            .accessibilityIdentifier("keepAwake.statusTitle")
          Text(statusDetail)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(muted)
            .accessibilityIdentifier("keepAwake.statusDetail")
        }

        Spacer()

        if model.keepAwakeEnabled {
          Button {
            model.stopKeepAwake()
          } label: {
            Label("结束", systemImage: "stop.fill")
          }
          .buttonStyle(KeepAwakeStopButtonStyle())
          .accessibilityIdentifier("keepAwake.stop")
        }

        if onClose == nil {
          Button("完成") {
            dismiss()
          }
          .buttonStyle(KeepAwakeDoneButtonStyle())
          .accessibilityIdentifier("keepAwake.done")
        }
      }
      .padding(.horizontal, 28)
      .padding(.top, 26)
      .padding(.bottom, 22)

      Rectangle()
        .fill(hairline)
        .frame(height: 1)

      KeepAwakeSettingsPanel()
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .frame(width: 560, height: 480)
    .background(aixlgPaper)
  }

  private var statusDetail: String {
    guard model.keepAwakeEnabled else {
      return "选择一个时长，即可开始。"
    }
    return "\(model.keepAwakeStatusText) · "
      + (model.keepAwakePreventDisplaySleep ? "屏幕也会保持亮起" : "仅阻止 Mac 睡眠")
  }
}

private enum SettingsArea: String, CaseIterable, Identifiable {
  case general = "通用"
  case permissions = "权限"
  case updates = "软件更新"
  case about = "关于"

  var id: String { rawValue }

  var systemImage: String {
    switch self {
    case .general: return "gearshape"
    case .permissions: return "lock.shield"
    case .updates: return "arrow.down.app"
    case .about: return "info.circle"
    }
  }
}

struct AboutPanelView: View {
  @EnvironmentObject private var model: AppModel
  @State private var isClearPermissionConfirmationPresented = false
  @State private var isBestConfigurationConfirmationPresented = false
  @State private var isPermissionRecoveryExpanded = false
  @State private var isDiagnosticsExpanded = false

  private var updateStateText: String {
    if model.isUpdateBusy {
      return model.updateStatusText
    }
    if let failure = model.updateFailureMessage {
      return failure
    }
    if model.updateStatusText.hasPrefix("更新已安装") {
      return "更新已安装，当前已是最新版。"
    }
    if model.updateStatusText.hasPrefix("发现新版") {
      return model.updateStatusText
    }
    if model.latestUpdate != nil {
      return "有新版本可以安装。"
    }
    if model.updateStatusText.hasPrefix("运行身份无效") {
      return "当前运行身份无效，不能检查线上更新。"
    }
    if model.updateStatusText == "未检查" {
      return "还没有检查更新。"
    }
    if model.updateStatusText.contains("已是最新版") {
      return "当前已是最新版。"
    }
    return "暂时无法检查更新，可稍后再试。"
  }

  private var updateActionTitle: String {
    if model.isUpdateBusy { return "处理中" }
    if model.latestUpdate != nil { return "立即更新" }
    if model.updateStatusText.hasPrefix("发现新版") { return "显示更新" }
    if model.updateStatusText == "未检查" { return "检查更新" }
    if model.updateStatusText.hasPrefix("更新已安装") { return "再次检查" }
    if model.updateStatusText.contains("已是最新版") { return "再次检查" }
    return "重试"
  }

  private var updateActionIcon: String {
    if model.isUpdateBusy { return "hourglass" }
    return model.latestUpdate == nil ? "arrow.clockwise" : "square.and.arrow.down"
  }

  private var updateStatusIcon: String {
    if model.updateFailureMessage != nil { return "exclamationmark.triangle.fill" }
    if model.latestUpdate != nil { return "arrow.down.circle.fill" }
    if model.updateStatusText.hasPrefix("发现新版") { return "arrow.down.circle.fill" }
    if model.updateStatusText.hasPrefix("更新已安装") { return "checkmark.circle.fill" }
    if model.updateStatusText.contains("已是最新版") { return "checkmark.circle.fill" }
    if model.updateStatusText.hasPrefix("运行身份无效") { return "info.circle" }
    if model.updateStatusText == "未检查" { return "clock" }
    return "arrow.clockwise.circle"
  }

  private var updateStatusColor: Color {
    if model.updateFailureMessage != nil { return .orange }
    if model.latestUpdate != nil { return accent }
    if model.updateStatusText.hasPrefix("发现新版") { return accent }
    if model.updateStatusText.hasPrefix("更新已安装") { return teal }
    if model.updateStatusText.contains("已是最新版") { return teal }
    return .secondary
  }

  @ViewBuilder
  private var updateStatusView: some View {
    HStack(spacing: 9) {
      if model.isUpdateBusy {
        ProgressView()
          .controlSize(.small)
          .accessibilityHidden(true)
      } else {
        Image(systemName: updateStatusIcon)
          .foregroundStyle(updateStatusColor)
          .accessibilityHidden(true)
      }
      Text(updateStateText)
        .font(.body)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("软件更新状态，\(updateStateText)")
  }

  @ViewBuilder
  private var updateActionButton: some View {
    if model.updateStatusText.hasPrefix("运行身份无效") {
      EmptyView()
    } else if model.latestUpdate != nil || model.updateStatusText.hasPrefix("发现新版") {
      updateButton
        .buttonStyle(.borderedProminent)
        .tint(accent)
    } else {
      updateButton
        .buttonStyle(.bordered)
        .tint(accent)
    }
  }

  private var updateButton: some View {
    Button {
      model.runPrimaryUpdateAction()
    } label: {
      Label(updateActionTitle, systemImage: updateActionIcon)
    }
    .controlSize(.regular)
    .disabled(model.isUpdateBusy)
    .help(updateActionTitle)
    .accessibilityLabel(updateActionTitle)
  }

  var body: some View {
    HStack(spacing: 0) {
      settingsSidebar
      Divider()
      selectedSettingsPage
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .controlBackgroundColor))
    .explicitPermissionClearConfirmation(
      isPresented: $isClearPermissionConfirmationPresented,
      model: model
    )
    .alert(
      "恢复小龙哥最佳配置？",
      isPresented: $isBestConfigurationConfirmationPresented
    ) {
      Button("取消", role: .cancel) {}
      Button("自动备份并恢复", role: .destructive) {
        model.restoreBestConfigurationAfterUserConfirmation()
      }
    } message: {
      Text(
        "会替换本 App 的快捷键、短语、输入法规则、启动器固定项、游目交互和菜单栏等行为设置。"
          + "恢复前会自动备份；不会删除个人文件、使用历史、许可、钥匙串、系统权限或其他软件的配置。")
    }
    .onAppear {
      model.refreshAccessibilityStatus()
      model.refreshLaunchAtLoginStatus()
      model.checkForUpdatesIfNeeded()
      if SettingsArea(rawValue: model.selectedAboutSection) == nil {
        model.selectedAboutSection = SettingsArea.general.rawValue
      }
    }
  }

  private var activeSettingsArea: SettingsArea {
    SettingsArea(rawValue: model.selectedAboutSection) ?? .general
  }

  private var settingsSidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text("设置与关于")
          .font(.headline)
          .foregroundStyle(.primary)
        Text("按用途找设置，不用猜入口")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 18)
      .padding(.top, 22)
      .padding(.bottom, 16)

      ForEach(SettingsArea.allCases) { area in
        Button {
          model.selectedAboutSection = area.rawValue
        } label: {
          HStack(spacing: 10) {
            Image(systemName: area.systemImage)
              .font(.system(size: 13, weight: .semibold))
              .symbolRenderingMode(.hierarchical)
              .foregroundStyle(activeSettingsArea == area ? accent : Color.secondary)
              .frame(width: 18)
            Text(area.rawValue)
              .font(.system(size: 13, weight: activeSettingsArea == area ? .semibold : .medium))
              .foregroundStyle(.primary)
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 12)
          .frame(height: 38)
          .background(
            activeSettingsArea == area ? accent.opacity(0.09) : Color.clear,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("设置，\(area.rawValue)")
        .accessibilityValue(activeSettingsArea == area ? "已选" : "未选")
        .overlay(alignment: .leading) {
          if activeSettingsArea == area {
            Capsule()
              .fill(accent)
              .frame(width: 3, height: 22)
              .accessibilityHidden(true)
          }
        }
      }

      Spacer(minLength: 12)

      Text(model.appVersionText)
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(18)
    }
    .padding(.horizontal, 8)
    .frame(width: 190)
    .background(Color(nsColor: .windowBackgroundColor).opacity(0.82))
  }

  @ViewBuilder
  private var selectedSettingsPage: some View {
    switch activeSettingsArea {
    case .general:
      generalSettingsPage
    case .permissions:
      permissionSettingsPage
    case .updates:
      updateSettingsPage
    case .about:
      aboutSettingsPage
    }
  }

  private var generalSettingsPage: some View {
    settingsPage(
      title: "启动、菜单栏与恢复",
      subtitle: "最常用的入口和故障恢复都集中在这里。",
      systemImage: "gearshape"
    ) {
      SettingsGroup(title: "菜单栏") {
        HStack(spacing: 12) {
          SettingsToggleLabel(
            title: "自定义菜单栏",
            detail: "管理菜单栏图标、系统健康、内存、CPU、GPU 和快捷入口。")
          Spacer(minLength: 8)
          Button("打开…") {
            model.presentMenuBarCustomization()
          }
          .buttonStyle(.borderedProminent)
          .tint(accent)
        }
      }

      SettingsGroup(title: "启动与显示") {
        Toggle(
          isOn: Binding(
            get: { model.launchAtLoginEnabled },
            set: { model.setLaunchAtLoginEnabled($0) })
        ) {
          SettingsToggleLabel(
            title: "登录时启动",
            detail: "开启后，重新登录 Mac 时快捷键会自动恢复。")
        }
        .toggleStyle(.switch)

        Divider()

        Toggle(
          isOn: Binding(
            get: { model.dockIconVisible },
            set: { model.setDockIconVisible($0) })
        ) {
          SettingsToggleLabel(
            title: "在程序坞显示图标",
            detail: model.dockIconVisible
              ? "主窗口可从程序坞和菜单栏打开。"
              : "程序坞图标已隐藏，仍可从菜单栏打开或退出。")
        }
        .toggleStyle(.switch)
      }

      SettingsGroup(title: "防止误关") {
        CommandWProtectionSettingsView()
      }

      SettingsGroup(title: "后台快捷键") {
        Toggle(
          isOn: Binding(
            get: { !model.isPaused },
            set: { enabled in
              if enabled == model.isPaused { model.togglePaused() }
            })
        ) {
          SettingsToggleLabel(
            title: "全局快捷键",
            detail: model.isPaused
              ? "已暂停，仍可查看和修改设置。"
              : "已启用，可在其他 App 中使用。")
        }
        .toggleStyle(.switch)
      }

      SettingsGroup(title: "配置恢复") {
        HStack(alignment: .center, spacing: 12) {
          SettingsToggleLabel(
            title: "一键恢复小龙哥最佳配置",
            detail: "目标电脑配置混乱时，先自动备份，再恢复经过净化的最佳行为基线。")
          Spacer(minLength: 8)
          if model.isImportingXLGConfig {
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel("正在恢复小龙哥最佳配置")
          }
          Button(model.isImportingXLGConfig ? "恢复中" : "恢复…") {
            isBestConfigurationConfirmationPresented = true
          }
          .buttonStyle(.bordered)
          .disabled(model.isImportingXLGConfig)
        }

        if model.lastXLGConfigImportBackupURL != nil {
          Divider()
          HStack {
            SettingsToggleLabel(
              title: "最近一次恢复前备份",
              detail: "需要找回旧设置时，可以直接打开备份目录。")
            Spacer(minLength: 8)
            Button("打开备份") {
              model.openLastBestConfigurationBackup()
            }
            .buttonStyle(.bordered)
          }
        }
      }
    }
  }

  private var permissionSettingsPage: some View {
    settingsPage(
      title: "权限",
      subtitle: "只在功能需要时使用系统权限，并清楚说明用途。",
      systemImage: "lock.shield"
    ) {
      SettingsGroup(title: "权限状态") {
        HStack(alignment: .top, spacing: 10) {
          Image(
            systemName: model.allRequiredPermissionsComplete
              ? "checkmark.shield.fill" : "exclamationmark.triangle.fill"
          )
          .foregroundStyle(model.allRequiredPermissionsComplete ? teal : amber)
          .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 3) {
            Text(
              model.allRequiredPermissionsComplete
                ? "两项基础权限均已开启。"
                : "还有基础权限未完成，软件会按顺序带你设置。"
            )
            .font(.body.weight(.medium))
            .foregroundStyle(.primary)
            Text("辅助功能用于快捷键与窗口操作；输入监控用于 Caps 与滚轮；屏幕录制只在你主动使用游目时读取画面。")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }

        SettingsStatusRow(
          title: "辅助功能",
          value: model.advancedListeningAuthorized ? "已开启" : "待开启",
          color: model.advancedListeningAuthorized ? teal : amber)
        SettingsStatusRow(
          title: "输入监控",
          value: model.inputMonitoringAuthorized ? "已开启" : "待开启",
          color: model.inputMonitoringAuthorized ? teal : amber)
        SettingsStatusRow(
          title: "屏幕录制",
          value: model.screenRecordingAuthorized ? "已开启" : "游目使用时开启",
          color: model.screenRecordingAuthorized ? teal : .secondary)

        HStack {
          permissionManagementButton
          Spacer(minLength: 0)
        }
      }

      SettingsGroup(title: "遇到问题") {
        DisclosureGroup("权限已经打开，但功能仍不生效？", isExpanded: $isPermissionRecoveryExpanded) {
          VStack(alignment: .leading, spacing: 10) {
            Text("仅在系统权限记录失效时使用。确认后会清理本软件的旧记录、重新打开软件，并再次引导授权。")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            clearPermissionButton
          }
          .padding(.top, 8)
        }
      }
    }
  }

  private var updateSettingsPage: some View {
    settingsPage(
      title: "软件更新",
      subtitle: "所有功能永久免费；在这里查看版本、安装更新。",
      systemImage: "arrow.down.app"
    ) {
      SettingsGroup(title: "软件更新") {
        SettingsInfoLine(title: "当前版本", value: model.appVersionText)
        SettingsInfoLine(title: "可用版本", value: model.updateLatestVersionText)

        ViewThatFits(in: .horizontal) {
          HStack(alignment: .center, spacing: 14) {
            updateStatusView
            Spacer(minLength: 10)
            updateActionButton
          }
          VStack(alignment: .leading, spacing: 12) {
            updateStatusView
            updateActionButton
          }
        }

        if let progress = model.updateDownloadProgress {
          ProgressView(value: progress)
            .progressViewStyle(.linear)
            .accessibilityLabel("更新下载进度")
            .accessibilityValue("\(Int((progress * 100).rounded(.down)))%")
        }
      }

      SettingsGroup(title: "免费与分享") {
        FreeSoftwareSettingsView()
      }

    }
  }

  private var aboutSettingsPage: some View {
    settingsPage(
      title: "关于",
      subtitle: "产品信息、帮助入口与必要的诊断工具。",
      systemImage: "info.circle"
    ) {
      SettingsGroup(title: "小龙哥 Mac 哲学") {
        HStack(alignment: .center, spacing: 16) {
          Image(nsImage: brandIcon())
            .resizable()
            .interpolation(.high)
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .shadow(color: Color.black.opacity(0.08), radius: 5, x: 0, y: 3)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 5) {
            Text("左手掌控 Mac 一切。")
              .font(.headline)
              .foregroundStyle(.primary)
            Text("把快捷键、常用应用和效率工具集中在一个入口。")
              .font(.body)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            Text(model.appVersionText)
              .font(.caption)
              .foregroundStyle(.tertiary)
          }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("小龙哥 Mac 哲学。\(model.appVersionAccessibilityText)")
      }

      SettingsGroup(title: "帮助与隐私") {
        AboutLinkButton(
          title: "反馈与建议",
          systemImage: "bubble.left.and.text.bubble.right",
          help: "在网页中填写文字、粘贴截图并提交",
          accessibilityLabel: "反馈与建议，打开反馈页"
        ) { model.openFeedbackWebsite() }
        Divider().padding(.leading, 32)
        AboutLinkButton(
          title: "使用支持",
          systemImage: "questionmark.circle",
          help: "打开使用支持",
          accessibilityLabel: "使用支持，打开支持页"
        ) { model.openSupportWebsite() }
        Divider().padding(.leading, 32)
        AboutLinkButton(
          title: "隐私政策",
          systemImage: "hand.raised",
          help: "打开隐私政策",
          accessibilityLabel: "隐私政策，打开隐私页"
        ) { model.openPrivacyWebsite() }
        Divider().padding(.leading, 32)
        AboutLinkButton(
          title: "官方网站",
          systemImage: "safari",
          help: "打开 aixlg.com",
          accessibilityLabel: "官方网站，打开 aixlg.com"
        ) { model.openProductWebsite() }
      }

      SettingsGroup(title: "安装与运行") {
        SettingsHealthRow(
          title: "安装位置",
          detail: model.appBundlePath,
          ok: model.isInstalledInApplications,
          okText: "位置正确",
          warningText: "建议移动")
        HStack {
          Button("打开“应用程序”文件夹") {
            model.openApplicationsFolder()
          }
          .buttonStyle(.bordered)
          Spacer(minLength: 0)
        }

        DisclosureGroup("诊断与技术信息", isExpanded: $isDiagnosticsExpanded) {
          VStack(alignment: .leading, spacing: 12) {
            Toggle(
              isOn: Binding(
                get: { model.diagnosticsEnabled },
                set: { model.setDiagnosticsEnabled($0) })
            ) {
              SettingsToggleLabel(
                title: "诊断日志",
                detail: "只在排查问题时临时开启。")
            }
            .toggleStyle(.switch)

            SettingsInfoLine(title: "日志位置", value: model.diagnosticsLogPath)

            ViewThatFits(in: .horizontal) {
              HStack(spacing: 10) {
                diagnosticsButtons
              }
              VStack(alignment: .leading, spacing: 8) {
                diagnosticsButtons
              }
            }
          }
          .padding(.top, 8)
        }
      }
    }
  }

  @ViewBuilder
  private var diagnosticsButtons: some View {
    Button("在访达中显示日志") { model.openDiagnosticsLog() }
      .buttonStyle(.bordered)
    Button("复制日志") { model.copyDiagnosticsLog() }
      .buttonStyle(.bordered)
    Button("在访达中显示配置文件") { model.openConfigFile() }
      .buttonStyle(.bordered)
  }

  private func settingsPage<Content: View>(
    title: String,
    subtitle: String,
    systemImage: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack(alignment: .center, spacing: 13) {
          Image(systemName: systemImage)
            .font(.system(size: 17, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary)
            .frame(width: 36, height: 36)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 3) {
            Text(title)
              .font(.title2.weight(.semibold))
              .foregroundStyle(.primary)
            Text(subtitle)
              .font(.callout)
              .foregroundStyle(.secondary)
          }
          Spacer(minLength: 0)
        }
        content()
      }
      .frame(maxWidth: 720, alignment: .topLeading)
      .frame(maxWidth: .infinity, alignment: .top)
      .padding(.horizontal, 28)
      .padding(.vertical, 24)
    }
    .scrollIndicators(.visible)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var permissionManagementButton: some View {
    Button {
      model.presentAuthorizationCenter()
    } label: {
      Label(
        model.allRequiredPermissionsComplete ? "检测 / 管理权限" : "立即检测并授权",
        systemImage: model.allRequiredPermissionsComplete
          ? "checkmark.shield" : "lock.open.fill")
    }
    .buttonStyle(.bordered)
    .tint(model.allRequiredPermissionsComplete ? teal : amber)
    .help("检测两项基础权限；屏幕录制由游目在使用时单独请求")
    .accessibilityLabel(
      model.allRequiredPermissionsComplete ? "检测或管理系统权限" : "立即检测并开启系统权限")
  }

  private var clearPermissionButton: some View {
    Button {
      isClearPermissionConfirmationPresented = true
    } label: {
      Label(
        model.isRepairingAuthorization ? "正在修复权限…" : "修复失效权限…",
        systemImage: "arrow.counterclockwise.circle")
    }
    .buttonStyle(.bordered)
    .tint(amber)
    .disabled(model.isRepairingAuthorization)
    .help("清理本 App 的旧权限记录，随后自动重启并重新引导授权")
    .accessibilityLabel("修复本软件失效的系统权限")
  }
}

private struct SettingsToggleLabel: View {
  let title: String
  let detail: String

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.primary)
      Text(detail)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

private struct SettingsGroup<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      Text(title)
        .font(.headline)
        .foregroundStyle(.primary)
      content
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(
      Color(nsColor: .windowBackgroundColor).opacity(0.78),
      in: RoundedRectangle(cornerRadius: 13, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 13, style: .continuous)
        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
    )
  }
}

struct AboutLinkButton: View {
  let title: String
  let systemImage: String
  let help: String
  let accessibilityLabel: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Image(systemName: systemImage)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(accent)
          .frame(width: 20, height: 20)
          .accessibilityHidden(true)

        Text(title)
          .font(.body.weight(.medium))
          .foregroundStyle(.primary)

        Spacer(minLength: 12)

        Image(systemName: "arrow.up.right")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }
      .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(help)
    .accessibilityLabel(accessibilityLabel)
  }
}

struct KeepAwakeSettingsPanel: View {
  @EnvironmentObject private var model: AppModel

  private let columns = [
    GridItem(.flexible(), spacing: 10),
    GridItem(.flexible(), spacing: 10),
    GridItem(.flexible(), spacing: 10),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text("保持多久")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(ink)
        Text("选择后立即生效，新的时长会替换当前会话。")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(muted)
      }

      LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
        ForEach(AppModel.keepAwakeDurationOptions) { option in
          Button {
            model.startKeepAwake(minutes: option.minutes)
          } label: {
            HStack(spacing: 8) {
              Image(systemName: option.minutes == 0 ? "infinity" : "timer")
                .font(.system(size: 13, weight: .semibold))
              Text(option.title)
            }
            .frame(maxWidth: .infinity)
          }
          .buttonStyle(KeepAwakeDurationButtonStyle())
          .accessibilityIdentifier("keepAwake.duration.\(option.minutes)")
        }
      }
      .padding(.top, 13)

      HStack(spacing: 14) {
        VStack(alignment: .leading, spacing: 3) {
          Text("自定义时长")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(ink)
          Text("适合下载、渲染或长时间会议。")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(muted)
        }

        Spacer(minLength: 4)

        HStack(spacing: 0) {
          Button {
            model.setKeepAwakeCustomHours(model.keepAwakeCustomHours - 1)
          } label: {
            Image(systemName: "minus")
              .frame(width: 34, height: 34)
          }
          .buttonStyle(.plain)
          .disabled(model.keepAwakeCustomHours <= 1)
          .accessibilityLabel("减少自定义时长")

          Rectangle()
            .fill(hairline)
            .frame(width: 1, height: 18)

          Text("\(model.keepAwakeCustomHours) 小时")
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(ink)
            .monospacedDigit()
            .frame(width: 58)
            .accessibilityIdentifier("keepAwake.customHours")

          Rectangle()
            .fill(hairline)
            .frame(width: 1, height: 18)

          Button {
            model.setKeepAwakeCustomHours(model.keepAwakeCustomHours + 1)
          } label: {
            Image(systemName: "plus")
              .frame(width: 34, height: 34)
          }
          .buttonStyle(.plain)
          .disabled(model.keepAwakeCustomHours >= 12)
          .accessibilityLabel("增加自定义时长")
        }
        .foregroundStyle(aixlgPurple)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(hairline, lineWidth: 1)
        )

        Button {
          model.startKeepAwakeCustomHours()
        } label: {
          Text("开始 \(model.keepAwakeCustomHours) 小时")
            .frame(minWidth: 92)
        }
        .accessibilityLabel("开始自定义 \(model.keepAwakeCustomHours) 小时")
        .accessibilityIdentifier("keepAwake.customStart")
        .buttonStyle(KeepAwakePrimaryButtonStyle())
      }
      .padding(14)
      .background(
        aixlgMist.opacity(0.68), in: RoundedRectangle(cornerRadius: 14, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(aixlgPurple.opacity(0.08), lineWidth: 1)
      )
      .padding(.top, 16)

      Rectangle()
        .fill(hairline)
        .frame(height: 1)
        .padding(.vertical, 19)

      HStack(spacing: 12) {
        Image(systemName: "display")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(aixlgPurple)
          .frame(width: 30, height: 30)
          .background(aixlgMist, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 3) {
          Text("同时保持屏幕亮起")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(ink)
          Text("开启后不锁屏、不进入屏保；关闭时只阻止 Mac 睡眠。")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(muted)
        }

        Spacer(minLength: 8)

        Toggle(
          "",
          isOn: Binding(
            get: { model.keepAwakePreventDisplaySleep },
            set: { model.setKeepAwakePreventDisplaySleep($0) }
          )
        )
        .labelsHidden()
        .toggleStyle(.switch)
        .tint(aixlgPurple)
        .accessibilityLabel("同时保持屏幕亮起")
        .accessibilityIdentifier("keepAwake.keepDisplayOn")
      }

      Text("也可在菜单栏左键“醒 / 眠”快速切换。")
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(muted.opacity(0.82))
        .padding(.top, 16)
    }
  }
}

private struct KeepAwakeDurationButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(aixlgPurple)
      .frame(height: 42)
      .background(
        configuration.isPressed ? aixlgMist : Color.white,
        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .stroke(
            configuration.isPressed ? aixlgPurple.opacity(0.32) : hairline,
            lineWidth: 1)
      )
      .scaleEffect(configuration.isPressed ? 0.985 : 1)
      .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
  }
}

private struct KeepAwakePrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(Color.white)
      .padding(.horizontal, 14)
      .frame(height: 36)
      .background(
        configuration.isPressed ? aixlgPurple.opacity(0.84) : aixlgPurple,
        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
      )
      .scaleEffect(configuration.isPressed ? 0.985 : 1)
      .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
  }
}

private struct KeepAwakeStopButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(ruby)
      .padding(.horizontal, 12)
      .frame(height: 34)
      .background(ruby.opacity(configuration.isPressed ? 0.11 : 0.055), in: Capsule())
      .overlay(Capsule().stroke(ruby.opacity(0.16), lineWidth: 1))
  }
}

private struct KeepAwakeDoneButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(ink)
      .padding(.horizontal, 12)
      .frame(height: 32)
      .background(Color.white.opacity(configuration.isPressed ? 0.55 : 0.92), in: Capsule())
      .overlay(Capsule().stroke(hairline, lineWidth: 1))
  }
}

struct SettingsStatusRow: View {
  let title: String
  let value: String
  let color: Color

  var body: some View {
    HStack {
      Text(title)
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(muted)
      Spacer()
      StatusPill(text: value, color: color)
    }
  }
}

struct SettingsHealthRow: View {
  let title: String
  let detail: String
  let ok: Bool
  let okText: String
  let warningText: String

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(ok ? teal : amber)
        .frame(width: 22)
        .padding(.top, 1)

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(ink)
        Text(detail)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(muted)
          .lineLimit(2)
          .truncationMode(.middle)
      }

      Spacer(minLength: 10)

      StatusPill(text: ok ? okText : warningText, color: ok ? teal : amber)
    }
    .padding(.vertical, 2)
  }
}

struct SettingsInfoLine: View {
  let title: String
  let value: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(title)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(ink)
        .frame(width: 72, alignment: .leading)
      Text(value)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(muted)
        .lineLimit(2)
        .truncationMode(.middle)
      Spacer(minLength: 0)
    }
    .padding(.top, 2)
  }
}

private struct ShortcutEditorPresentation: Identifiable {
  let id = UUID()
  let itemID: String?
  let draft: ShortcutItem
}

private struct ShortcutSemanticMigrationPanel: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if model.shortcutSemanticNeedsAttention {
        Text("快捷键需要你确认")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(ink)
        Text("为了让启动和系统搜索各归其位，来源不明的占用不会被自动覆盖。")
          .font(.system(size: 12))
          .foregroundStyle(muted)
      }

      if model.shortcutSemanticCapsDecisionPending {
        semanticConflictRow(
          hotkey: "Caps + Space",
          conflicts: model.shortcutSemanticAnalysis.capsSpaceConflicts,
          primaryTitle: "改为启动器",
          primaryAction: model.adoptCapsSpaceForLauncher,
          secondaryTitle: "保留现状",
          secondaryAction: model.keepCurrentCapsSpaceBehavior)
      }

      if model.shortcutSemanticCommandDecisionPending {
        semanticConflictRow(
          hotkey: "Command + Space",
          conflicts: model.shortcutSemanticAnalysis.commandSpaceConflicts,
          primaryTitle: "交还系统搜索",
          primaryAction: model.returnCommandSpaceToSystem,
          secondaryTitle: "保留现状",
          secondaryAction: model.keepCurrentCommandSpaceBehavior)
      }

      if !model.shortcutSemanticMigrationMessage.isEmpty {
        Text(model.shortcutSemanticMigrationMessage)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(indigo)
          .fixedSize(horizontal: false, vertical: true)
      }

      if model.lastShortcutSemanticBackupURL != nil {
        HStack(spacing: 12) {
          Button("查看备份") { model.openShortcutSemanticBackup() }
            .buttonStyle(.link)
          Button("撤销本次迁移") { model.undoLatestShortcutSemanticMigration() }
            .buttonStyle(.link)
        }
        .font(.system(size: 12, weight: .medium))
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(Color(red: 0.85, green: 0.81, blue: 0.88), lineWidth: 1)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("快捷键迁移状态")
  }

  private func semanticConflictRow(
    hotkey: String,
    conflicts: [ShortcutItem],
    primaryTitle: String,
    primaryAction: @escaping () -> Void,
    secondaryTitle: String,
    secondaryAction: @escaping () -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(hotkey)
        .font(.system(size: 13, weight: .semibold, design: .rounded))
        .foregroundStyle(ink)
      ForEach(conflicts) { item in
        VStack(alignment: .leading, spacing: 2) {
          Text("当前：\(item.name.isEmpty ? "未知快捷键占用" : item.name)")
          Text("动作：\(item.action.rawValue)\(item.target.isEmpty ? "" : " · \(item.target)")")
          Text("来源：无法确认，按用户自定义保护")
        }
        .font(.system(size: 11))
        .foregroundStyle(muted)
        .fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: 10) {
        Button(primaryTitle, action: primaryAction)
          .buttonStyle(.borderedProminent)
          .tint(violet)
        Button(secondaryTitle, action: secondaryAction)
          .buttonStyle(.bordered)
      }
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(hotkey)，发现 \(conflicts.count) 个受保护占用")
  }
}

struct ShortcutUnifiedPanelView: View {
  @EnvironmentObject private var model: AppModel
  @FocusState private var searchFocused: Bool
  @State private var searchText = ""
  @State private var selectedCategory = "全部"
  @State private var selectedGuideEntryID: String?
  @State private var shortcutEditorPresentation: ShortcutEditorPresentation?

  private var currentEntries: [ShortcutGuideEntry] {
    model.items.enumerated().map {
      ShortcutGuideEntry(kind: .current(index: $0.offset, item: $0.element))
    }
  }

  private var filteredCurrentEntries: [ShortcutGuideEntry] {
    return currentEntries.filter { entry in
      (selectedCategory == "全部" || entry.category == selectedCategory)
        && entry.matches(searchText)
    }
  }

  private var visibleEntries: [ShortcutGuideEntry] {
    filteredCurrentEntries
  }

  private var isPijuanPDFCategory: Bool {
    selectedCategory == "PDF类"
  }

  var body: some View {
    VStack(spacing: 12) {
      unifiedHeader
      if model.shortcutSemanticNeedsAttention || !model.shortcutSemanticMigrationMessage.isEmpty {
        ShortcutSemanticMigrationPanel()
      }
      if shouldShowStatusBanner {
        ShortcutStatusBanner()
      }
      if let notice = model.shortcutRecordingConflictNotice {
        ShortcutRecordingConflictBanner(notice: notice)
      }
      searchAndCategories

      VStack(spacing: 10) {
        if isPijuanPDFCategory {
          if let settingsView = model.makePijuanPDFShortcutSettingsView() {
            settingsView
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            ShortcutGuideEmptyState(searchText: "PDF", selectedCategory: "PDF类")
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        } else {
          ShortcutTableView(
            selectedModule: moduleHotkeys,
            itemIDs: filteredCurrentEntries.compactMap { $0.shortcutItem?.id },
            editShortcut: beginEditingShortcut
          )
          .layoutPriority(1)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .onAppear {
      applyShortcutGuideRoute()
      focusSearchSoon()
    }
    .onChange(of: model.shortcutGuideFocusRequest) { _ in
      applyShortcutGuideRoute()
      focusSearchSoon()
    }
    .onChange(of: model.shortcutCreateRequestID) { _ in
      beginAddingShortcut()
    }
    .onChange(of: selectedCategory) { _ in
      if isPijuanPDFCategory {
        searchText = ""
      }
      syncSelectedEntry()
    }
    .sheet(item: $shortcutEditorPresentation) { presentation in
      ShortcutEditorSheet(presentation: presentation)
        .environmentObject(model)
    }
  }

  private var shouldShowStatusBanner: Bool {
    model.isPaused || !model.advancedListeningAuthorized || !model.hotkeyFailures.isEmpty
  }

  private var unifiedHeader: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: 14) {
        unifiedOverview
        Spacer(minLength: 12)
        unifiedActions
      }

      VStack(alignment: .leading, spacing: 12) {
        unifiedOverview
        unifiedActions
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 13)
    .premiumPanel(radius: 17, shadowRadius: 13, shadowY: 7)
  }

  private var unifiedActions: some View {
    HStack(spacing: 8) {
      if model.deletedDefaultShortcutCount > 0 {
        Button {
          model.restoreDeletedDefaultShortcuts()
        } label: {
          Label(
            "恢复已删除（\(model.deletedDefaultShortcutCount)）",
            systemImage: "arrow.uturn.backward.circle")
        }
        .buttonStyle(GlassLabelButtonStyle(tint: muted))
        .fixedSize()
        .help("只恢复已删除的默认快捷键；用户自定义规则保持不变")
        .accessibilityLabel("恢复已删除的默认快捷键")
      }
      PrimaryAddShortcutMenu(addShortcut: beginAddingShortcut)
    }
  }

  private var unifiedOverview: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 12) {
        Text("快捷键")
          .font(.system(size: 20, weight: .semibold))
          .foregroundStyle(ink)
        Button {
          model.openFeedbackWebsite()
        } label: {
          Text("反馈")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(aixlgPurple)
        }
        .buttonStyle(.plain)
        .help("打开反馈与建议页面")
        .accessibilityLabel("反馈与建议，打开反馈页")
      }
      Text("在一个地方管理游目、披卷与 Mac 操作")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(muted)
    }
  }

  private var searchAndCategories: some View {
    VStack(spacing: 9) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) {
          categorySegmentBar
          Spacer(minLength: 0)
          resultSummary
        }

        HStack(spacing: 12) {
          categoryPicker
            .pickerStyle(.menu)
          Spacer(minLength: 0)
          resultSummary
        }
      }

      if isPijuanPDFCategory {
        HStack(spacing: 8) {
          Image(systemName: "doc.richtext")
            .foregroundStyle(aixlgPurple)
          Text("披卷只删除快捷键绑定，PDF 阅读功能始终保留。")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(muted)
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(aixlgMist.opacity(0.66), in: RoundedRectangle(cornerRadius: 9))
      } else {
        HStack(spacing: 9) {
          Image(systemName: "magnifyingglass")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(searchFocused ? aixlgPurple : muted)
          TextField(searchPlaceholder, text: $searchText)
            .textFieldStyle(.plain)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(ink)
            .focused($searchFocused)
          if !searchText.isEmpty {
            Button {
              searchText = ""
            } label: {
              Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(muted.opacity(0.72))
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(
          Color.white.opacity(0.92),
          in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 9)
            .stroke(searchFocused ? aixlgPurple.opacity(0.34) : hairline, lineWidth: 1)
        )
      }
    }
    .padding(10)
    .background(
      aixlgPaper,
      in: RoundedRectangle(cornerRadius: 12, style: .continuous)
    )
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(hairline, lineWidth: 1))
  }

  private var categorySegmentBar: some View {
    HStack(spacing: 3) {
      ForEach(shortcutGuideCategories, id: \.self) { category in
        let selected = selectedCategory == category
        Button {
          selectedCategory = category
        } label: {
          Text(shortcutGuideCategoryDisplayName(category))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(selected ? aixlgPurple : ink)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(
              selected ? aixlgMist : Color.clear,
              in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(shortcutGuideCategoryDisplayName(category))分类")
        .accessibilityValue(selected ? "已选" : "未选")
        .accessibilityIdentifier("shortcutCategory.\(category)")
      }
    }
    .padding(3)
    .background(
      Color.white.opacity(0.74),
      in: RoundedRectangle(cornerRadius: 10, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(hairline, lineWidth: 1)
    )
    .fixedSize(horizontal: true, vertical: false)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("快捷键分类")
  }

  private var categoryPicker: some View {
    Picker("快捷键分类", selection: $selectedCategory) {
      ForEach(shortcutGuideCategories, id: \.self) { category in
        Text(shortcutGuideCategoryDisplayName(category)).tag(category)
      }
    }
    .labelsHidden()
  }

  private var resultSummary: some View {
    Text(
      isPijuanPDFCategory
        ? "PDF 阅读"
        : (searchText.isEmpty ? "\(visibleEntries.count) 条" : "找到 \(visibleEntries.count) 条")
    )
    .font(.system(size: 11, weight: .medium))
    .foregroundStyle(muted)
    .fixedSize()
  }

  private var searchPlaceholder: String {
    selectedCategory == "截图类" ? "搜索游目截图、翻译、OCR 或按键" : "搜索功能、按键、分类或说明"
  }

  private func beginAddingShortcut() {
    searchText = ""
    selectedCategory = "全部"
    model.cancelRecordingIfNeeded()
    shortcutEditorPresentation = ShortcutEditorPresentation(
      itemID: nil,
      draft: model.makeShortcutDraft(module: moduleHotkeys))
  }

  private func beginEditingShortcut(itemID: String) {
    guard let item = model.items.first(where: { $0.id == itemID }) else { return }
    model.cancelRecordingIfNeeded()
    model.selectedID = itemID
    shortcutEditorPresentation = ShortcutEditorPresentation(itemID: itemID, draft: item)
  }

  private func applyShortcutGuideRoute() {
    selectedCategory =
      shortcutGuideCategories.contains(model.shortcutGuideRequestedCategory)
      ? model.shortcutGuideRequestedCategory : "全部"
    searchText = selectedCategory == "PDF类" ? "" : model.shortcutGuideRequestedSearchText
    syncSelectedEntry()
  }

  private func syncSelectedEntry() {
    if let selectedGuideEntryID,
      visibleEntries.contains(where: { $0.id == selectedGuideEntryID })
    {
      return
    }
    selectedGuideEntryID = visibleEntries.first?.id
  }

  private func focusSearchSoon() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
      searchFocused = true
    }
  }
}

private struct ShortcutRecordingConflictBanner: View {
  @EnvironmentObject private var model: AppModel
  let notice: ShortcutRecordingConflictNotice

  var body: some View {
    HStack(spacing: 9) {
      Image(systemName: notice.opensPreferences ? "checkmark.circle.fill" : "info.circle.fill")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(notice.opensPreferences ? teal : accent)

      Text(notice.message)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(ink)
        .fixedSize(horizontal: false, vertical: true)

      Spacer(minLength: 8)

      Button {
        model.shortcutRecordingConflictNotice = nil
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(muted)
          .frame(width: 22, height: 22)
      }
      .buttonStyle(.plain)
      .help("关闭提示")
      .accessibilityLabel("关闭快捷键提示")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(
      (notice.opensPreferences ? teal : accent).opacity(0.075),
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke((notice.opensPreferences ? teal : accent).opacity(0.2), lineWidth: 1)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel(notice.message)
  }
}

private struct PrimaryAddShortcutMenu: View {
  let addShortcut: () -> Void

  var body: some View {
    Button {
      addShortcut()
    } label: {
      Label("新增快捷键", systemImage: "plus")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(minHeight: 32)
        .background(accent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
    .buttonStyle(.plain)
    .fixedSize()
    .help("新增快捷键")
    .accessibilityLabel("新增快捷键")
  }
}

private struct ShortcutStatusBanner: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: icon)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(amber)

      Text(message)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(ink)
        .fixedSize(horizontal: false, vertical: true)

      Spacer(minLength: 8)

      Button(actionTitle, action: recoveryAction)
        .buttonStyle(GlassLabelButtonStyle(tint: accent))
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(amber.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(amber.opacity(0.22), lineWidth: 1))
  }

  private var icon: String {
    model.advancedListeningAuthorized
      ? "exclamationmark.triangle.fill"
      : "lock.trianglebadge.exclamationmark"
  }

  private var message: String {
    if !model.authorizationPermissionsComplete {
      return "后台监听权限尚未完整，软件会自动判断并带你完成。"
    }
    if model.isPaused {
      return "后台快捷键已暂停。当前列表仍可查看和编辑。"
    }
    return "有 \(model.hotkeyFailures.count) 个快捷键未能启用，现有配置没有改变。"
  }

  private var actionTitle: String {
    if !model.authorizationPermissionsComplete { return "立即授权" }
    if model.isPaused { return "恢复后台快捷键" }
    return "重新检测"
  }

  private func recoveryAction() {
    if !model.authorizationPermissionsComplete {
      model.presentAuthorizationCenter()
    } else if model.isPaused {
      model.togglePaused()
    } else {
      model.reloadHotkeys()
    }
  }
}

private struct ShortcutEditorSheet: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  let presentation: ShortcutEditorPresentation
  @State private var draft: ShortcutItem
  @State private var showDeleteConfirmation = false
  @State private var saveErrorMessage: String?

  init(presentation: ShortcutEditorPresentation) {
    self.presentation = presentation
    _draft = State(initialValue: presentation.draft)
  }

  private var canSave: Bool {
    !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && (draft.trigger != nil
        || !draft.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }

  private var isCapturingHotkey: Bool {
    model.isDraftShortcutRecording
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        IconBadge(systemImage: "command", tint: accent, size: 42, iconSize: 17)
        VStack(alignment: .leading, spacing: 4) {
          Text(presentation.itemID == nil ? "新增快捷键" : "编辑快捷键")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(ink)
          Text(presentation.itemID == nil ? "保存后才会加入列表。" : draft.name)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(muted)
            .lineLimit(2)
        }
        Spacer()
      }
      .padding(.horizontal, 22)
      .padding(.vertical, 18)
      .background(.bar)
      .overlay(Rectangle().fill(hairline).frame(height: 1), alignment: .bottom)

      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          ShortcutFormTextField(title: "名称", placeholder: "功能名称", text: $draft.name)

          VStack(alignment: .leading, spacing: 6) {
            Text("触发方式")
              .font(.system(size: 11, weight: .bold))
              .foregroundStyle(muted)
            Button {
              model.toggleDraftShortcutRecording { value in
                applyRecordedValue(value)
              }
            } label: {
              HStack(spacing: 8) {
                Image(systemName: isCapturingHotkey ? "record.circle.fill" : "keyboard")
                Text(
                  isCapturingHotkey
                    ? "按组合键，或连按同一个实体修饰键两次"
                    : draft.displayHotkey
                )
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
              }
              .foregroundStyle(isCapturingHotkey ? accent : ink)
              .padding(.horizontal, 10)
              .frame(height: 38)
              .background(Color.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
              .overlay(
                RoundedRectangle(cornerRadius: 8)
                  .stroke(isCapturingHotkey ? accent.opacity(0.55) : glassLine, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .background(
              KeyCaptureView(active: isCapturingHotkey) { event in
                model.applyRecorded(event)
              })
            Text("支持左／右 Control、Shift、Option 和 Command。再点一下或按 Esc 取消。")
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(muted)
          }

          HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
              Text("动作")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(muted)
              Picker("动作", selection: $draft.action) {
                ForEach(
                  ShortcutAction.allCases.filter {
                    ($0 != .showPanel && $0 != .showLauncher) || $0 == draft.action
                  }
                ) { action in
                  Text(action.title).tag(action)
                }
              }
              .labelsHidden()
              .pickerStyle(.menu)
              .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 6) {
              Text("启用")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(muted)
              Toggle("保存后启用", isOn: $draft.enabled)
                .toggleStyle(.switch)
            }
          }

          ShortcutFormTextField(
            title: "执行内容",
            placeholder: targetPlaceholder,
            text: $draft.target)

          HStack(spacing: 10) {
            if draft.action == .openApp {
              Menu {
                ForEach(model.runningAppChoices().prefix(12)) { choice in
                  Button(choice.name) {
                    applyAppChoice(choice)
                  }
                }
                Divider()
                ForEach(model.installedAppChoices(limit: 16)) { choice in
                  Button(choice.name) {
                    applyAppChoice(choice)
                  }
                }
              } label: {
                Label("选择 App", systemImage: "app.badge")
              }
              .menuStyle(.borderlessButton)

              Button {
                browseTarget()
              } label: {
                Label("文件或文件夹", systemImage: "folder")
              }
              .buttonStyle(GlassLabelButtonStyle(tint: muted))
            }

            Menu {
              Menu("窗口管理") {
                ForEach(WindowPreset.allCases) { preset in
                  Button(preset.title) {
                    draft.action = .windowPreset
                    draft.target = preset.rawValue
                    draft.name = preset.title
                    draft.scope = "窗口"
                    draft.note = "窗口管理"
                  }
                }
              }
              Button("打开 Emoji 与符号") {
                applyPreset(
                  action: .sendShortcut,
                  target: "⌃ ⌘ Space",
                  name: "打开 Emoji 与符号",
                  scope: "常用脚本",
                  note: "打开系统 Emoji 与符号面板。")
              }
              Button("输入井号 #") {
                applyPreset(
                  action: .insertText,
                  target: "#",
                  name: "输入井号 #",
                  scope: "常用脚本",
                  note: "在当前光标处输入 #。")
              }
              Button("切换麦克风") {
                applyPreset(
                  action: .runShell,
                  target: "plugin:mic-toggle.sh",
                  name: "切换麦克风",
                  scope: "常用脚本",
                  note: "Studio Display / DJI 麦克风切换。")
              }
            } label: {
              Label("常用动作", systemImage: "slider.horizontal.3")
            }
            .menuStyle(.borderlessButton)
          }

          ShortcutFormTextField(title: "分类", placeholder: "例如 窗口 / 系统", text: $draft.scope)

          VStack(alignment: .leading, spacing: 6) {
            Text("说明")
              .font(.system(size: 11, weight: .bold))
              .foregroundStyle(muted)
            TextEditor(text: $draft.note)
              .font(.system(size: 13, weight: .medium))
              .frame(minHeight: 82)
              .scrollContentBackground(.hidden)
              .padding(8)
              .background(Color.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
              .overlay(RoundedRectangle(cornerRadius: 8).stroke(glassLine, lineWidth: 1))
          }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
      }

      if let saveErrorMessage {
        HStack(spacing: 8) {
          Image(systemName: "exclamationmark.circle.fill")
          Text(saveErrorMessage)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(ruby)
        .padding(.horizontal, 22)
        .padding(.vertical, 9)
        .background(ruby.opacity(0.07))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("保存失败，\(saveErrorMessage)")
      }

      HStack(spacing: 10) {
        if let itemID = presentation.itemID {
          Button(role: .destructive) {
            showDeleteConfirmation = true
          } label: {
            Label("删除快捷键...", systemImage: "trash")
          }
          .buttonStyle(GlassLabelButtonStyle(tint: ruby))
          .disabled(!model.canDeleteShortcut(id: itemID))
          .help(model.shortcutDeletionHelp(id: itemID))
        }

        Spacer()

        Button("取消") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        .buttonStyle(GlassLabelButtonStyle(tint: muted))

        Button("保存") {
          saveErrorMessage = nil
          let saved: Bool
          if let itemID = presentation.itemID {
            saved = model.updateShortcut(id: itemID, draft: draft)
          } else {
            saved = model.createShortcut(from: draft)
          }
          if saved {
            dismiss()
          } else {
            saveErrorMessage = model.statusMessage
          }
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(GlassLabelButtonStyle(tint: accent, prominent: true))
        .disabled(!canSave || isCapturingHotkey)
      }
      .padding(.horizontal, 22)
      .padding(.vertical, 14)
      .background(.bar)
      .overlay(Rectangle().fill(hairline).frame(height: 1), alignment: .top)
    }
    .frame(width: 580, height: 650)
    .background(AppBackdrop())
    .onExitCommand {
      if isCapturingHotkey {
        model.cancelDraftShortcutRecording()
      } else {
        dismiss()
      }
    }
    .onDisappear {
      model.cancelRecordingIfNeeded()
    }
    .onChange(of: draft) { _ in
      saveErrorMessage = nil
    }
    .alert("删除这条快捷键？", isPresented: $showDeleteConfirmation) {
      Button("取消", role: .cancel) {}
      Button("删除", role: .destructive) {
        guard let itemID = presentation.itemID else { return }
        model.deleteShortcut(id: itemID)
        dismiss()
      }
    } message: {
      Text("只会移除这条按键绑定，不会删除对应功能；默认快捷键之后仍可恢复。")
    }
  }

  private var targetPlaceholder: String {
    switch draft.action {
    case .openApp: return "App 标识、App 或文件路径"
    case .openURL: return "https://"
    case .runShell: return "Shell 或 plugin:脚本名"
    case .windowPreset: return "窗口动作"
    case .sendShortcut: return "要发送的组合键"
    case .insertText: return "要输入的文字"
    default: return "此动作可留空"
    }
  }

  private func applyRecordedValue(_ value: ShortcutTriggerRecordingValue) {
    if let trigger = value.trigger {
      draft.trigger = trigger
      return
    }
    draft.key = value.key
    draft.modifiers = value.modifiers
    draft.trigger = nil
  }

  private func applyAppChoice(_ choice: AppChoice) {
    draft.action = .openApp
    draft.target = choice.target
    draft.name = "打开 \(choice.name)"
    draft.scope = "App"
    draft.note = "\(choice.source) App：打开 / 置前 / 再按隐藏。"
  }

  private func browseTarget() {
    let panel = NSOpenPanel()
    panel.title = "选择 App、文件或文件夹"
    panel.prompt = "选择"
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let name = url.deletingPathExtension().lastPathComponent
    draft.action = .openApp
    draft.target = url.path
    draft.name = "打开 \(name)"
    draft.scope = url.pathExtension == "app" ? "App" : "文件 / 文件夹"
    draft.note = url.pathExtension == "app" ? "应用程序：打开 / 置前 / 再按隐藏。" : "文件或文件夹"
  }

  private func applyPreset(
    action: ShortcutAction,
    target: String,
    name: String,
    scope: String,
    note: String
  ) {
    draft.action = action
    draft.target = target
    draft.name = name
    draft.scope = scope
    draft.note = note
  }
}

struct ShortcutTableView: View {
  @EnvironmentObject private var model: AppModel
  let selectedModule: String
  let itemIDs: [String]?
  let editShortcut: ((String) -> Void)?

  init(
    selectedModule: String,
    itemIDs: [String]? = nil,
    editShortcut: ((String) -> Void)? = nil
  ) {
    self.selectedModule = selectedModule
    self.itemIDs = itemIDs
    self.editShortcut = editShortcut
  }

  private var visibleItemIDs: [String] {
    itemIDs ?? model.items.filter { belongsToModule($0, selectedModule) }.map(\.id)
  }

  var body: some View {
    VStack(spacing: 0) {
      HeaderRow()
      if visibleItemIDs.isEmpty {
        ShortcutGuideEmptyState(searchText: "", selectedCategory: selectedModule)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .padding(.vertical, 22)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(visibleItemIDs, id: \.self) { itemID in
                if let item = model.bindingForItem(id: itemID) {
                  ShortcutRow(
                    item: item,
                    editShortcut: editShortcut
                  )
                  .id(itemID)
                }
              }
            }
          }
          .onChange(of: model.shortcutGuideFocusRequest) { _ in
            scrollToSelectedItem(using: proxy)
          }
          .onChange(of: model.selectedID) { _ in
            scrollToSelectedItem(using: proxy)
          }
          .onChange(of: visibleItemIDs) { _ in
            scrollToSelectedItem(using: proxy)
          }
          .onAppear {
            scrollToSelectedItem(using: proxy)
          }
        }
      }
    }
    .background(surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(hairline, lineWidth: 1))
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  private func scrollToSelectedItem(using proxy: ScrollViewProxy) {
    guard let selectedID = model.selectedID else { return }
    let scroll: @MainActor @Sendable () -> Void = {
      withAnimation(.easeOut(duration: 0.2)) {
        proxy.scrollTo(selectedID, anchor: .center)
      }
    }
    DispatchQueue.main.async(execute: scroll)
    // Clearing a search filter rebuilds the lazy stack after the first update cycle.
    // Retry once after layout settles so the selected existing rule is actually visible.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: scroll)
  }
}

struct HeaderRow: View {
  var body: some View {
    HStack(spacing: 0) {
      HeaderCell("启用", width: 52)
      HeaderCell("功能", width: 300)
      HeaderCell("快捷键", width: 190)
      FlexHeaderCell("说明")
    }
    .frame(height: 38)
    .background(aixlgPaper)
    .overlay(Rectangle().fill(hairline).frame(height: 1), alignment: .bottom)
  }
}

struct HeaderCell: View {
  let title: String
  let width: CGFloat

  init(_ title: String, width: CGFloat) {
    self.title = title
    self.width = width
  }

  var body: some View {
    Text(title)
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(muted)
      .frame(width: width, alignment: .leading)
      .padding(.leading, 10)
  }
}

struct FlexHeaderCell: View {
  let title: String

  init(_ title: String) {
    self.title = title
  }

  var body: some View {
    Text(title)
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(muted)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.leading, 10)
  }
}

struct ShortcutRow: View {
  @EnvironmentObject private var model: AppModel
  @Binding var item: ShortcutItem
  let editShortcut: ((String) -> Void)?
  @State private var hovering = false
  @State private var showDeleteConfirmation = false

  private var selected: Bool {
    model.selectedID == item.id
  }

  var body: some View {
    HStack(spacing: 0) {
      Toggle(
        "",
        isOn: Binding(
          get: { item.enabled },
          set: { value in
            model.selectedID = item.id
            model.updateEnabled(item.id, value)
          }
        )
      )
      .toggleStyle(.checkbox)
      .frame(width: 52)
      .accessibilityIdentifier("shortcut.enabled.\(item.id)")
      .accessibilityLabel("\(item.name)，启用")

      ShortcutFeatureCell(
        item: item,
        edit: editAction,
        delete: {
          showDeleteConfirmation = true
        }
      )
      .frame(width: 300)

      HotkeyCell(
        text: item.displayHotkey,
        active: model.isRecording(item.id),
        onKeyDown: { event in
          model.applyRecorded(event)
        }
      ) {
        model.selectedID = item.id
        model.startRecording(itemID: item.id)
      }
      .frame(width: 190)

      ShortcutDescriptionCell(item: item)
        .frame(maxWidth: .infinity)

    }
    .padding(.vertical, 5)
    .frame(minHeight: 64)
    .background(rowBackground)
    .overlay(Rectangle().fill(line).frame(height: 1), alignment: .bottom)
    .overlay(
      Rectangle()
        .fill(selected ? aixlgPurple : Color.clear)
        .frame(width: 3),
      alignment: .leading
    )
    .contextMenu {
      shortcutRowMenuContent(model: model, item: item, edit: editAction) {
        showDeleteConfirmation = true
      }
      .onAppear(perform: selectForContextMenu)
    }
    .alert("删除这条快捷键？", isPresented: $showDeleteConfirmation) {
      Button("取消", role: .cancel) {}
      Button("删除", role: .destructive) {
        model.deleteShortcut(id: item.id)
      }
    } message: {
      Text(model.shortcutDeletionHelp(id: item.id))
    }
    .onHover { inside in
      hovering = inside
    }
    .accessibilityIdentifier("shortcut.row.\(item.id)")
    .animation(.easeOut(duration: 0.14), value: selected)
    .animation(.easeOut(duration: 0.12), value: hovering)
  }

  private var rowBackground: some ShapeStyle {
    if selected {
      return LinearGradient(
        colors: [aixlgMist.opacity(0.92), aixlgPaper],
        startPoint: .leading,
        endPoint: .trailing
      )
    }
    if hovering {
      return LinearGradient(
        colors: [aixlgPaper, Color.white],
        startPoint: .leading,
        endPoint: .trailing
      )
    }
    return LinearGradient(
      colors: [surface, surface],
      startPoint: .leading,
      endPoint: .trailing
    )
  }

  private var editAction: (() -> Void)? {
    guard let editShortcut else { return nil }
    return { editShortcut(item.id) }
  }

  private func selectForContextMenu() {
    guard model.selectedID != item.id else { return }
    model.selectedID = item.id
  }
}

struct ShortcutFeatureCell: View {
  @EnvironmentObject private var model: AppModel
  let item: ShortcutItem
  let edit: (() -> Void)?
  let delete: () -> Void
  @State private var showingIssueDetail = false

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        HStack(spacing: 9) {
          ShortcutActionVisual(item: item, size: 30, iconSize: 13)

          VStack(alignment: .leading, spacing: 3) {
            Text(item.name)
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(ink)
              .fixedSize(horizontal: false, vertical: true)

            if let subtitle = shortcutActionSubtitle(item) {
              Text(subtitle)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(muted)
                .lineLimit(1)
            }
          }

          Spacer(minLength: 4)
        }
        .frame(minHeight: 44)

        if let edit {
          Button(action: edit) {
            Image(systemName: "pencil")
              .frame(width: 24, height: 24)
          }
          .buttonStyle(.borderless)
          .foregroundStyle(muted)
          .help("编辑快捷键")
          .accessibilityLabel("编辑“\(item.name)”")
        }

        Menu {
          shortcutRowMenuContent(model: model, item: item, edit: edit, delete: delete)
        } label: {
          Image(systemName: "ellipsis.circle")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(muted)
            .frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityIdentifier("shortcut.feature.\(item.id)")
        .accessibilityLabel(featureAccessibilityLabel)
        .accessibilityHint("按 Return 或空格打开菜单")
        .help("\(item.name)：打开操作菜单")

        Button {
          delete()
        } label: {
          Image(systemName: "trash")
            .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(model.canDeleteShortcut(id: item.id) ? muted : muted.opacity(0.35))
        .disabled(!model.canDeleteShortcut(id: item.id))
        .help(model.shortcutDeletionHelp(id: item.id))
        .accessibilityLabel("删除“\(item.name)”快捷键")
      }

      if let issue = model.shortcutIssue(for: item) {
        Button {
          showingIssueDetail = true
        } label: {
          ShortcutIssueChip(issue: issue)
        }
        .buttonStyle(.plain)
        .help("查看详情")
        .accessibilityLabel("\(issue.kind.label)，查看详情")
        .popover(isPresented: $showingIssueDetail, arrowEdge: .trailing) {
          ShortcutIssueDetailView(issue: issue)
        }
        .padding(.leading, 39)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.trailing, 8)
  }

  private var featureAccessibilityLabel: String {
    let category = shortcutGuideCategoryDisplayName(shortcutGuideCategory(for: item))
    return "\(item.name)，\(category)，操作菜单"
  }
}

@ViewBuilder
@MainActor
private func shortcutRowMenuContent(
  model: AppModel,
  item: ShortcutItem,
  edit: (() -> Void)? = nil,
  delete: @escaping () -> Void
) -> some View {
  if let edit {
    Button(action: edit) {
      Label("编辑快捷键…", systemImage: "slider.horizontal.3")
    }
    Divider()
  }

  Menu("打开 App / 文件 / 文件夹") {
    Menu("运行中的程序") {
      ForEach(Array(model.runningAppChoices().prefix(14))) { choice in
        Button {
          model.setOpenTarget(itemID: item.id, choice: choice)
        } label: {
          shortcutRowAppChoiceLabel(choice)
        }
      }
    }
    Menu("应用程序目录") {
      ForEach(model.installedAppChoices(limit: 24)) { choice in
        Button {
          model.setOpenTarget(itemID: item.id, choice: choice)
        } label: {
          shortcutRowAppChoiceLabel(choice)
        }
      }
    }
    Divider()
    Button {
      model.browseOpenTarget(itemID: item.id)
    } label: {
      Label("从访达选择…", systemImage: "folder.badge.plus")
    }
  }
  .disabled(!model.canChangeShortcutAction(id: item.id))
  .help(model.shortcutActionChangeHelp(id: item.id))

  Menu("窗口管理") {
    ForEach(WindowPreset.allCases) { preset in
      Button {
        model.applyActionPreset(
          itemID: item.id,
          action: .windowPreset,
          target: preset.rawValue,
          name: preset.title,
          note: "窗口管理")
      } label: {
        Label(preset.title, systemImage: windowPresetIcon(preset))
      }
    }
    Button {
      model.applyActionPreset(
        itemID: item.id,
        action: .nativeFullScreen,
        target: "entireScreen",
        name: "全屏",
        note: "进入或退出全屏")
    } label: {
      Label("进入 / 退出全屏", systemImage: "arrow.up.left.and.arrow.down.right")
    }
  }
  .disabled(!model.canChangeShortcutAction(id: item.id))
  .help(model.shortcutActionChangeHelp(id: item.id))

  Button {
    model.beginShortcutActionCapture(itemID: item.id)
  } label: {
    Label("发送按键...", systemImage: "keyboard.badge.ellipsis")
  }
  .disabled(!model.canChangeShortcutAction(id: item.id))
  .help(model.shortcutActionChangeHelp(id: item.id))

  Menu("应用中心") {
    Button {
      model.applyActionPreset(
        itemID: item.id,
        action: .showProcessViewer,
        target: "process-viewer",
        name: "打开进程查看器",
        scope: "常用脚本",
        note: "打开独立的进程查看器窗口。")
    } label: {
      Label("打开进程查看器", systemImage: "cpu")
    }
    Button {
      model.applyActionPreset(
        itemID: item.id,
        action: .showCodexNetworkProbe,
        target: "codex-network-probe",
        name: "打开测试网速",
        scope: "常用脚本",
        note: "一个球测下载、上传、延迟和抖动，一个球测 Codex 四轮连通与响应。")
    } label: {
      Label("打开测试网速", systemImage: "gauge.with.dots.needle.67percent")
    }
    Button {
      model.applyActionPreset(
        itemID: item.id,
        action: .openURL,
        target: item.target.hasPrefix("http") ? item.target : "https://aixlg.com/",
        note: "网页链接")
    } label: {
      Label("打开网址", systemImage: "safari")
    }
    Button {
      model.applyActionPreset(
        itemID: item.id,
        action: .insertText,
        target: item.target.isEmpty ? "小龙哥Mac哲学" : item.target,
        name: item.name.isEmpty ? "输入文本" : item.name,
        note: "把目标文本输入到前台光标位置")
    } label: {
      Label("输入文本", systemImage: "text.cursor")
    }
    Button {
      model.applyActionPreset(
        itemID: item.id,
        action: .sendShortcut,
        target: "⌃ ⌘ Space",
        name: "打开 Emoji 与符号",
        scope: "常用脚本",
        note: "打开系统 Emoji 与符号面板。")
    } label: {
      Label("打开 Emoji 与符号", systemImage: "face.smiling")
    }
    Button {
      model.applyActionPreset(
        itemID: item.id,
        action: .runShell,
        target: "plugin:mic-toggle.sh",
        name: "切换麦克风",
        scope: "常用脚本",
        note: "Studio Display / DJI 麦克风切换。")
    } label: {
      Label("切换麦克风", systemImage: "mic.fill")
    }
    Button {
      model.applyActionPreset(
        itemID: item.id,
        action: .runShell,
        target: "osascript -e 'tell application \"System Events\" to sleep'",
        name: "休眠",
        scope: "常用脚本",
        note: "让 Mac 进入睡眠。")
    } label: {
      Label("休眠", systemImage: "moon.zzz.fill")
    }
    Button {
      model.applyActionPreset(
        itemID: item.id,
        action: .runShell,
        target: "pmset displaysleepnow",
        name: "息屏",
        scope: "常用脚本",
        note: "立即关闭屏幕，不退出 App。")
    } label: {
      Label("息屏", systemImage: "display")
    }
    Button {
      model.applyActionPreset(
        itemID: item.id,
        action: .showSleepPanel,
        target: "sleep-panel",
        name: "保持唤醒",
        scope: "常用脚本",
        note: "打开睡眠管理，选择不睡机时长。")
    } label: {
      Label("保持唤醒", systemImage: "bolt.fill")
    }
  }
  .disabled(!model.canChangeShortcutAction(id: item.id))
  .help(model.shortcutActionChangeHelp(id: item.id))

  Button {
    model.startRecording(itemID: item.id)
  } label: {
    Label("重新录制触发方式…", systemImage: "keyboard.badge.ellipsis")
  }
  .help("可按普通组合键，或连按左／右 Control、Shift、Option、Command 两次。")

  Divider()

  Button {
    model.undoActionPreset(itemID: item.id)
  } label: {
    Label("撤销上一次调整", systemImage: "arrow.uturn.backward")
  }
  .disabled(!model.canUndoActionPreset(itemID: item.id))

  Button(role: .destructive) {
    delete()
  } label: {
    Label("删除快捷键...", systemImage: "trash")
  }
  .disabled(!model.canDeleteShortcut(id: item.id))
  .help(model.shortcutDeletionHelp(id: item.id))
}

private func shortcutRowAppChoiceLabel(_ choice: AppChoice) -> some View {
  Label {
    Text(choice.name)
  } icon: {
    if let icon = shortcutGuideAppIcon(forAppTarget: choice.target) {
      Image(nsImage: icon)
        .resizable()
        .interpolation(.high)
    } else {
      Image(systemName: "app")
    }
  }
}

struct ShortcutIssueChip: View {
  let issue: ShortcutIssue

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: issueIcon)
        .font(.system(size: 8, weight: .bold))
      Text(issue.kind.label)
        .font(.system(size: 10, weight: .semibold))
      Text("详情")
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(issueTint.opacity(0.78))
    }
    .foregroundStyle(issueTint)
    .padding(.horizontal, 7)
    .frame(height: 18)
    .background(issueTint.opacity(0.09), in: Capsule())
    .overlay(Capsule().stroke(issueTint.opacity(0.18), lineWidth: 1))
  }

  private var issueTint: Color {
    switch issue.kind {
    case .shortcutDuplicate: return ruby
    case .systemOccupied: return amber
    case .externalManaged: return indigo
    case .possibleCollision: return amber.opacity(0.88)
    case .needsCompletion: return muted
    }
  }

  private var issueIcon: String {
    switch issue.kind {
    case .shortcutDuplicate: return "exclamationmark.triangle.fill"
    case .systemOccupied: return "lock.trianglebadge.exclamationmark"
    case .externalManaged: return "arrow.triangle.branch"
    case .possibleCollision: return "exclamationmark.circle"
    case .needsCompletion: return "ellipsis.circle"
    }
  }
}

struct ShortcutIssueDetailView: View {
  let issue: ShortcutIssue

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Text(issue.kind.label)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(ink)
        StatusPill(
          text: issue.kind.isBlocking ? "需要处理" : "仅提醒",
          color: issue.kind.isBlocking ? ruby : amber)
      }

      ShortcutIssueDetailLine(title: "当前快捷键", value: issue.hotkey)
      ShortcutIssueDetailLine(title: "对象", value: issue.object)
      ShortcutIssueDetailLine(title: "影响", value: issue.impact)
      ShortcutIssueDetailLine(title: "建议", value: issue.suggestion)
    }
    .padding(14)
    .frame(width: 320, alignment: .leading)
  }
}

struct ShortcutIssueDetailLine: View {
  let title: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(muted)
      Text(value)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(ink.opacity(0.88))
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct ShortcutDescriptionCell: View {
  let item: ShortcutItem

  var body: some View {
    Text(shortcutHumanDescription(item))
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(ink.opacity(0.82))
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 10)
  }
}

private func shortcutCategoryTag(_ item: ShortcutItem) -> String? {
  shortcutGuideCategory(for: item)
}

private func shortcutActionSubtitle(_ item: ShortcutItem) -> String? {
  if item.commandID != nil { return "游目原生动作" }
  let category = shortcutGuideCategoryDisplayName(shortcutGuideCategory(for: item))
  let action = shortcutActionDisplayText(item)
  guard !category.isEmpty else { return action }
  return "\(category) · \(action)"
}

private func shortcutActionDisplayText(_ item: ShortcutItem) -> String {
  if item.commandID != nil {
    return "游目原生动作"
  }
  if item.scope == "常用脚本" {
    return "应用中心"
  }
  switch item.action {
  case .openApp: return "打开 App"
  case .openURL: return "打开网址"
  case .runShell: return "脚本"
  case .showPanel: return "功能快捷键"
  case .showLauncher: return "启动器"
  case .showProcessViewer: return "进程查看器"
  case .showClipboardHistory: return "剪贴板历史"
  case .showCodexNetworkProbe: return "测试网速"
  case .showSleepPanel: return "保持唤醒开关"
  case .windowPreset: return "排列窗口"
  case .nativeFullScreen: return "全屏"
  case .sendShortcut: return "发送按键"
  case .closeWindowSmart: return "关闭窗口"
  case .insertText: return "输入文字"
  }
}

private func shortcutHumanDescription(_ item: ShortcutItem) -> String {
  if item.commandID != nil {
    let note = item.note.trimmingCharacters(in: .whitespacesAndNewlines)
    return note.isEmpty ? "执行游目原生动作。" : note
  }
  switch item.action {
  case .openApp:
    return shortcutOpenTargetDescription(item)
  case .openURL:
    return shortcutURLDescription(item.target)
  case .runShell:
    return "按下后运行这条常用脚本，完成对应系统动作。"
  case .showPanel:
    return "打开功能快捷键页面，查看和管理当前快捷键。"
  case .showLauncher:
    return "弹出应用启动器，可以搜索应用、计算或打开网页。"
  case .showProcessViewer:
    return "打开独立的进程查看器窗口。"
  case .showClipboardHistory:
    return "打开剪贴板历史，并直接搜索或恢复之前复制的内容。"
  case .showCodexNetworkProbe:
    return "一个球测下载、上传、延迟和抖动，一个球测 Codex 四轮连通与响应。"
  case .showSleepPanel:
    return "按一次无限期保持唤醒，再按一次恢复系统默认睡眠。"
  case .windowPreset:
    return shortcutWindowDescription(item.target)
  case .nativeFullScreen:
    return "让当前窗口进入或退出 Mac 全屏。"
  case .sendShortcut:
    if isEmojiShortcut(item) {
      return "弹出 Emoji 与符号面板。"
    }
    return "把 \(shortcutSendShortcutText(item.target)) 作为真实组合键发给当前正在使用的 App，不输入文字。"
  case .closeWindowSmart:
    return "按下后关闭当前标签页或当前窗口。"
  case .insertText:
    return "把这段常用文字填到当前光标位置。"
  }
}

private func isSystemSettingsShortcut(_ item: ShortcutItem) -> Bool {
  let target = item.target.lowercased()
  return target == "bundle:com.apple.systempreferences"
    || target == "bundle:com.apple.systemsettings"
    || item.name.contains("系统设置")
}

private func isEmojiShortcut(_ item: ShortcutItem) -> Bool {
  let normalizedTarget = item.target.replacingOccurrences(of: " ", with: "")
  return item.name.localizedCaseInsensitiveContains("emoji")
    || normalizedTarget == "⌃⌘Space"
    || normalizedTarget == "ControlCommandSpace"
}

private func shortcutOpenTargetDescription(_ item: ShortcutItem) -> String {
  if isSystemSettingsShortcut(item) {
    return "打开系统设置，继续调整 Mac 的权限或偏好。"
  }
  let appName = shortcutDisplayName(item)
  let expandedTarget = (item.target.trimmingCharacters(in: .whitespacesAndNewlines) as NSString)
    .expandingTildeInPath
  if expandedTarget.hasPrefix("/") {
    let url = URL(fileURLWithPath: expandedTarget)
    if url.pathExtension != "app" {
      return "打开 \(appName)，直接到指定文件或文件夹。"
    }
  }
  return "按下后打开 \(appName)；已在后台时带到眼前，已在前台时隐藏。"
}

private func shortcutDisplayName(_ item: ShortcutItem) -> String {
  var name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
  if name.hasPrefix("打开 ") {
    name.removeFirst(3)
  } else if name.hasPrefix("打开") {
    name.removeFirst(2)
  }
  return name.isEmpty ? "这个 App" : name
}

private func shortcutURLDescription(_ target: String) -> String {
  guard let url = URL(string: target), let host = url.host, !host.isEmpty else {
    return "打开指定网页。"
  }
  return "打开 \(host) 网页，直接到常用页面。"
}

private func shortcutWindowDescription(_ target: String) -> String {
  guard let preset = WindowPreset(rawValue: target) else {
    return "调整当前窗口位置。"
  }

  switch preset {
  case .leftHalf:
    return "把当前窗口贴到屏幕左半边，方便并排查看。"
  case .rightHalf:
    return "把当前窗口贴到屏幕右半边，方便并排查看。"
  case .topHalf:
    return "把当前窗口贴到屏幕上半边。"
  case .bottomHalf:
    return "把当前窗口贴到屏幕下半边。"
  case .topLeft:
    return "把当前窗口收进左上角，留出其他工作区。"
  case .topRight:
    return "把当前窗口收进右上角，留出其他工作区。"
  case .bottomLeft:
    return "把当前窗口收进左下角，留出其他工作区。"
  case .bottomRight:
    return "把当前窗口收进右下角，留出其他工作区。"
  case .maximize:
    return "把当前窗口铺满可用区域，同时保留 Dock 和菜单栏。"
  case .center:
    return "把当前窗口移到屏幕中间，方便继续处理。"
  case .minimize:
    return "把当前窗口收进 Dock，先腾出桌面。"
  }
}

private func shortcutSendShortcutText(_ target: String) -> String {
  let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
  return trimmed.isEmpty ? "预设按键" : trimmed
}

struct InlineTextField: View {
  @Binding var text: String
  let placeholder: String
  var strong = false

  var body: some View {
    TextField(placeholder, text: $text)
      .font(.system(size: 13, weight: strong ? .bold : .semibold))
      .textFieldStyle(.plain)
      .foregroundStyle(ink)
      .lineLimit(1)
      .padding(.horizontal, 9)
      .frame(height: 30)
      .background(
        Color.white.opacity(0.001),
        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
      )
  }
}

private struct AppChoiceMenuLabel: View {
  let choice: AppChoice
  let fallbackSystemImage: String

  private var appIcon: NSImage? {
    guard let source = shortcutGuideAppIcon(forAppTarget: choice.target) else {
      return nil
    }
    let icon = (source.copy() as? NSImage) ?? source
    icon.size = NSSize(width: 16, height: 16)
    icon.isTemplate = false
    return icon
  }

  var body: some View {
    if let appIcon {
      Label {
        Text(choice.name)
      } icon: {
        Image(nsImage: appIcon)
          .renderingMode(.original)
      }
    } else {
      Label(choice.name, systemImage: fallbackSystemImage)
    }
  }
}

struct ActionMenu: View {
  @EnvironmentObject private var model: AppModel
  let item: ShortcutItem
  var compact = false

  var body: some View {
    Menu {
      Menu("打开 App / 文件 / 文件夹") {
        Menu("运行中的程序") {
          ForEach(Array(model.runningAppChoices().prefix(14))) { choice in
            Button {
              model.setOpenTarget(itemID: item.id, choice: choice)
            } label: {
              AppChoiceMenuLabel(choice: choice, fallbackSystemImage: "app.badge")
            }
          }
        }
        Menu("应用程序目录") {
          ForEach(model.installedAppChoices(limit: 24)) { choice in
            Button {
              model.setOpenTarget(itemID: item.id, choice: choice)
            } label: {
              AppChoiceMenuLabel(choice: choice, fallbackSystemImage: "app")
            }
          }
        }
        Divider()
        Button {
          model.browseOpenTarget(itemID: item.id)
        } label: {
          Label("从访达选择…", systemImage: "folder.badge.plus")
        }
      }

      Button {
        model.applyActionPreset(
          itemID: item.id,
          action: .openURL,
          target: item.target.hasPrefix("http") ? item.target : "https://aixlg.com/",
          scope: "全部应用",
          note: "网页链接"
        )
      } label: {
        Label("打开网址", systemImage: "safari")
      }

      Divider()

      Menu("窗口管理") {
        ForEach(WindowPreset.allCases) { preset in
          Button {
            model.applyActionPreset(
              itemID: item.id,
              action: .windowPreset,
              target: preset.rawValue,
              name: preset.title,
              scope: "窗口",
              note: "窗口管理"
            )
          } label: {
            Label(preset.title, systemImage: windowPresetIcon(preset))
          }
        }
        Button {
          model.applyActionPreset(
            itemID: item.id,
            action: .nativeFullScreen,
            target: "entireScreen",
            name: "全屏",
            scope: "窗口",
            note: "进入或退出全屏"
          )
        } label: {
          Label("进入 / 退出全屏", systemImage: "arrow.up.left.and.arrow.down.right")
        }
      }

      Button {
        model.beginShortcutActionCapture(itemID: item.id)
      } label: {
        Label("发送按键...", systemImage: "keyboard.badge.ellipsis")
      }

      Menu("应用中心") {
        Button {
          model.applyActionPreset(
            itemID: item.id,
            action: .showProcessViewer,
            target: "process-viewer",
            name: "打开进程查看器",
            scope: "常用脚本",
            note: "打开独立的进程查看器窗口。"
          )
        } label: {
          Label("打开进程查看器", systemImage: "cpu")
        }
        Button {
          model.applyActionPreset(
            itemID: item.id,
            action: .showCodexNetworkProbe,
            target: "codex-network-probe",
            name: "打开测试网速",
            scope: "常用脚本",
            note: "一个球测下载、上传、延迟和抖动，一个球测 Codex 四轮连通与响应。"
          )
        } label: {
          Label("打开测试网速", systemImage: "gauge.with.dots.needle.67percent")
        }
        Button {
          model.applyActionPreset(
            itemID: item.id,
            action: .sendShortcut,
            target: "⌃ ⌘ Space",
            name: "打开 Emoji 与符号",
            scope: "常用脚本",
            note: "打开系统 Emoji 与符号面板。"
          )
        } label: {
          Label("打开 Emoji 与符号", systemImage: "face.smiling")
        }
        Button {
          model.applyActionPreset(
            itemID: item.id,
            action: .insertText,
            target: "#",
            name: "输入井号 #",
            scope: "常用脚本",
            note: "在当前光标处输入 #。"
          )
        } label: {
          Label("输入井号 #", systemImage: "number")
        }
        Button {
          model.applyActionPreset(
            itemID: item.id,
            action: .runShell,
            target: "plugin:mic-toggle.sh",
            name: "切换麦克风",
            scope: "常用脚本",
            note: "Studio Display / DJI 麦克风切换。"
          )
        } label: {
          Label("切换麦克风", systemImage: "mic.fill")
        }
        Button {
          model.applyActionPreset(
            itemID: item.id,
            action: .runShell,
            target: "osascript -e 'tell application \"System Events\" to sleep'",
            name: "休眠",
            scope: "常用脚本",
            note: "让 Mac 进入睡眠。"
          )
        } label: {
          Label("休眠", systemImage: "moon.zzz.fill")
        }
        Button {
          model.applyActionPreset(
            itemID: item.id,
            action: .showSleepPanel,
            target: "sleep-infinite-toggle",
            name: "切换无限期保持唤醒",
            scope: "常用脚本",
            note: "按一次无限期保持唤醒，再按一次恢复系统默认睡眠。"
          )
        } label: {
          Label("切换无限期保持唤醒", systemImage: "bolt.fill")
        }
      }
    } label: {
      if compact {
        Label("管理", systemImage: "gearshape.fill")
          .labelStyle(.iconOnly)
          .font(.system(size: 13, weight: .semibold))
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(ink.opacity(0.70))
          .frame(width: 34, height: 30)
          .background(
            Color.white.opacity(0.78),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .stroke(line.opacity(0.55), lineWidth: 1)
          )
      } else {
        HStack(spacing: 6) {
          ShortcutActionVisual(item: item, size: 22, iconSize: 10)
          Text(actionMenuTitle(item))
            .font(.system(size: 12, weight: .bold))
            .lineLimit(1)
          Spacer(minLength: 0)
          Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(
          LinearGradient(
            colors: [Color.white.opacity(0.92), softSurface.opacity(0.70)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          ),
          in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .shadow(color: Color.black.opacity(0.018), radius: 3, x: 0, y: 2)
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(
            line.opacity(0.65), lineWidth: 1))
      }
    }
    .menuStyle(.borderlessButton)
    .help(compact ? "管理" : actionMenuTitle(item))
    .accessibilityLabel(Text(compact ? "管理" : actionMenuTitle(item)))
    .padding(.horizontal, 5)
  }

  private func actionMenuTitle(_ item: ShortcutItem) -> String {
    item.action.shortTitle
  }
}

struct ShortcutActionVisual: View {
  let item: ShortcutItem
  var size: CGFloat = 28
  var iconSize: CGFloat = 12

  private var appIcon: NSImage? {
    shortcutGuideAppIcon(for: item)
  }

  var body: some View {
    Group {
      if let appIcon {
        Image(nsImage: appIcon)
          .resizable()
          .interpolation(.high)
          .scaledToFit()
          .padding(size * 0.13)
      } else {
        Image(
          systemName: item.commandID == nil
            ? actionIconName(item.action) : "viewfinder.circle.fill"
        )
        .font(.system(size: iconSize, weight: .bold))
        .foregroundStyle(accent)
      }
    }
    .frame(width: size, height: size)
    .background(
      appIcon == nil ? accent.opacity(0.08) : Color.white.opacity(0.92),
      in: RoundedRectangle(cornerRadius: max(6, size * 0.30), style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: max(6, size * 0.30), style: .continuous)
        .stroke(appIcon == nil ? accent.opacity(0.12) : Color.white.opacity(0.80), lineWidth: 1)
    )
  }
}

private func windowPresetIcon(_ preset: WindowPreset) -> String {
  switch preset {
  case .leftHalf: return "rectangle.lefthalf.filled"
  case .rightHalf: return "rectangle.righthalf.filled"
  case .topHalf: return "rectangle.tophalf.filled"
  case .bottomHalf: return "rectangle.bottomhalf.filled"
  case .topLeft: return "square.grid.2x2.fill"
  case .topRight: return "square.grid.2x2.fill"
  case .bottomLeft: return "square.grid.2x2.fill"
  case .bottomRight: return "square.grid.2x2.fill"
  case .maximize: return "arrow.up.left.and.arrow.down.right"
  case .center: return "scope"
  case .minimize: return "minus.rectangle"
  }
}

private func actionIconName(_ action: ShortcutAction) -> String {
  switch action {
  case .openApp: return "app.badge"
  case .openURL: return "safari"
  case .runShell: return "terminal"
  case .showPanel: return "doc.text.magnifyingglass"
  case .showLauncher: return "magnifyingglass.circle"
  case .showProcessViewer: return "cpu"
  case .showClipboardHistory: return "doc.on.clipboard.fill"
  case .showCodexNetworkProbe: return "gauge.with.dots.needle.67percent"
  case .showSleepPanel: return "moon.zzz.fill"
  case .windowPreset: return "rectangle.on.rectangle"
  case .nativeFullScreen: return "arrow.up.left.and.arrow.down.right"
  case .sendShortcut: return "keyboard"
  case .closeWindowSmart: return "xmark.square"
  case .insertText: return "text.cursor"
  }
}

struct ShortcutActionCaptureSheet: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(spacing: 0) {
      VStack(spacing: 22) {
        HStack(spacing: 16) {
          Image(systemName: "keyboard")
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 64, height: 64)
            .background(accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

          VStack(alignment: .leading, spacing: 6) {
            Text("快捷键")
              .font(.system(size: 22, weight: .semibold))
              .foregroundStyle(ink)
            Text("这里设置快捷键要代你按出的组合键；不会修改启动这条动作的快捷键。")
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(muted)
              .lineLimit(2)
          }
          Spacer()
        }

        HStack(spacing: 14) {
          Text("输入：")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(ink)
          Button {
          } label: {
            Text(
              model.shortcutActionCaptureDraft.isEmpty ? "直接按组合键" : model.shortcutActionCaptureDraft
            )
            .font(.system(size: 18, weight: .semibold, design: .monospaced))
            .foregroundStyle(model.shortcutActionCaptureDraft.isEmpty ? muted : accent)
            .frame(width: 220, height: 44)
            .background(.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(accent.opacity(0.65), lineWidth: 2)
            )
            .background(
              KeyCaptureView(active: true) { event in
                model.applyShortcutActionCaptured(event)
              })
          }
          .buttonStyle(.plain)
        }

        HStack(spacing: 12) {
          Button {
            model.cancelShortcutActionCapture()
          } label: {
            Label("取消", systemImage: "xmark")
          }
          .keyboardShortcut(.cancelAction)
          .buttonStyle(GlassLabelButtonStyle(tint: muted))

          Button {
            model.confirmShortcutActionCapture()
          } label: {
            Label("确定", systemImage: "checkmark")
          }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(GlassLabelButtonStyle(tint: accent, prominent: true))
          .disabled(
            model.shortcutActionCaptureDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          )
        }
      }
      .padding(.top, 30)
      .padding(.horizontal, 34)
      .padding(.bottom, 30)
    }
    .frame(width: 520, height: 250)
    .background(softSurface)
  }
}

struct HotkeyCell: View {
  let text: String
  let active: Bool
  let onKeyDown: (NSEvent) -> Void
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: active ? "record.circle.fill" : "keyboard")
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(active ? ruby : accent.opacity(0.70))
        Text(active ? "按组合键 / 双击修饰键" : text)
          .font(.system(size: 13, weight: .semibold, design: .monospaced))
          .foregroundStyle(active ? accent : ink)
          .lineLimit(1)
          .minimumScaleFactor(0.78)
          .allowsTightening(true)
          .layoutPriority(1)
      }
      .frame(maxWidth: .infinity, alignment: .center)
      .frame(height: 32)
      .padding(.horizontal, 7)
      .background(
        active
          ? LinearGradient(
            colors: [accent.opacity(0.14), teal.opacity(0.08)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
          : LinearGradient(
            colors: [Color(red: 0.978, green: 0.984, blue: 0.990), Color.white.opacity(0.80)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          ),
        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .stroke(active ? accent : line.opacity(0.65), lineWidth: active ? 2 : 1)
      )
      .shadow(
        color: active ? accent.opacity(0.16) : Color.black.opacity(0.025),
        radius: active ? 8 : 4,
        x: 0,
        y: active ? 4 : 2
      )
      .background(KeyCaptureView(active: active, onKeyDown: onKeyDown))
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 6)
    .help(active ? "再点一下取消录制" : "点击录制组合键或实体修饰键双击")
  }
}

struct KeyCaptureView: NSViewRepresentable {
  let active: Bool
  let onKeyDown: (NSEvent) -> Void

  func makeNSView(context: Context) -> KeyCaptureNSView {
    let view = KeyCaptureNSView()
    view.onKeyDown = onKeyDown
    return view
  }

  func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
    nsView.onKeyDown = onKeyDown
    nsView.setCaptureActive(active)
  }
}

final class KeyCaptureNSView: NSView {
  var onKeyDown: ((NSEvent) -> Void)?
  private var captureActive = false

  override var acceptsFirstResponder: Bool { true }

  func setCaptureActive(_ active: Bool) {
    captureActive = active
    guard active else { return }
    claimKeyboardFocus()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard captureActive else { return }
    claimKeyboardFocus()
  }

  override func mouseDown(with event: NSEvent) {
    claimKeyboardFocus()
  }

  override func keyDown(with event: NSEvent) {
    onKeyDown?(event)
  }

  private func claimKeyboardFocus() {
    DispatchQueue.main.async { [weak self] in
      guard let self, self.captureActive, let window = self.window else { return }
      window.makeFirstResponder(self)
    }
  }
}

struct StatusFooterView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    HStack(spacing: 8) {
      Image(
        systemName: model.statusMessage.contains("未授权") || model.statusMessage.contains("失败")
          ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
      )
      .foregroundStyle(
        model.statusMessage.contains("未授权") || model.statusMessage.contains("失败") ? amber : teal)
      Text(model.statusMessage)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(muted)
        .lineLimit(2)
      Spacer()
    }
    .padding(.horizontal, 12)
    .frame(height: 38)
    .premiumPanel(radius: 13, shadowRadius: 8, shadowY: 4)
  }
}
