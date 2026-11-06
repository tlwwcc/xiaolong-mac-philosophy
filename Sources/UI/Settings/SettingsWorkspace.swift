import AppKit
import SwiftUI

enum SettingsArea: String, CaseIterable, Identifiable {
  case general = "通用"
  case permissions = "权限"
  case about = "关于与更新"
  case automation = "CLI"

  var id: String { rawValue }

  var systemImage: String {
    switch self {
    case .general: return "gearshape"
    case .permissions: return "lock.shield"
    case .about: return "info.circle"
    case .automation: return "terminal"
    }
  }
}

struct AboutPanelView: View {
  @EnvironmentObject private var model: AppModel
  @State private var isClearPermissionConfirmationPresented = false
  @State private var isBestConfigurationConfirmationPresented = false
  @State private var isPermissionRecoveryExpanded = false
  @State private var isRecoveryExpanded = false
  @AppStorage(WindowSplitPreference.key) private var leftSplitPercent = WindowSplitPreference.defaultLeftPercent

  var body: some View {
    VStack(spacing: 0) {
      Picker(
        "设置分类",
        selection: Binding(
          get: { activeSettingsArea },
          set: { model.selectedAboutSection = $0.rawValue }
        )
      ) {
        ForEach(SettingsArea.allCases) { area in
          Text(area.rawValue).tag(area)
        }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal, AppVisualStyle.Spacing.page)
      .padding(.vertical, AppVisualStyle.Spacing.large)
      .frame(maxWidth: AppVisualStyle.Layout.readableWidth)
      .accessibilityIdentifier("settings.sections")
      Divider()
      selectedSettingsPage.id(activeSettingsArea)
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
        "会先备份，再清空本 App 的旧配置，应用 \(XLGConfigImporter.bundledConfigurationDate) 的小龙哥配置，不与旧设置合并。"
          + "自定义短语会清空；听澜数据、旧输入法规则、个人文件、使用历史、钥匙串和系统权限保留。")
    }
    .onAppear {
      model.refreshAccessibilityStatus()
      model.refreshLaunchAtLoginStatus()
      model.refreshFileAssociationStatus()
      model.checkForUpdatesIfNeeded()
      if SettingsArea(rawValue: model.selectedAboutSection) == nil {
        model.selectedAboutSection = SettingsNavigationPolicy.normalized(model.selectedAboutSection)
      }
    }
  }

  private var activeSettingsArea: SettingsArea {
    SettingsArea(rawValue: model.selectedAboutSection)
      ?? SettingsArea(rawValue: SettingsNavigationPolicy.normalized(model.selectedAboutSection))
      ?? .general
  }

  @ViewBuilder
  private var selectedSettingsPage: some View {
    switch activeSettingsArea {
    case .general:
      generalSettingsPage
    case .permissions:
      permissionSettingsPage
    case .about:
      aboutSettingsPage
    case .automation:
      AutomationSettingsView()
    }
  }

  private var generalSettingsPage: some View {
    settingsPage(title: "通用", subtitle: "顺手，按你的习惯来。", systemImage: "gearshape") {
      SettingsGroup(title: "日常使用") {
        AppAppearanceSetting()
        Divider()
        Toggle(
          isOn: Binding(
            get: { model.launchAtLoginEnabled },
            set: { model.setLaunchAtLoginEnabled($0) }
          )
        ) { Text("登录时启动") }
        .toggleStyle(.switch)
        Divider()
        Toggle(
          isOn: Binding(
            get: { !model.isPaused },
            set: { enabled in if enabled == model.isPaused { model.togglePaused() } }
          )
        ) {
          SettingsToggleLabel(title: "全局快捷键", detail: model.isPaused ? "已暂停" : "在其他 App 中也能使用")
        }
        .toggleStyle(.switch)
        Divider()
        HStack(spacing: 12) {
          SettingsToggleLabel(title: "菜单栏", detail: "选择要显示的图标与快捷入口")
          Spacer(minLength: 8)
          Button("自定义…") { model.presentMenuBarCustomization() }
            .buttonStyle(.bordered)
        }
      }
      SettingsGroup(title: "窗口分屏比例") {
        Stepper(value: $leftSplitPercent, in: WindowSplitPreference.range) {
          Text("左 \(leftSplitPercent)% · 右 \(100 - leftSplitPercent)%")
        }
        Text("Caps＋Command＋←／→ 按此比例分屏。")
          .foregroundStyle(.secondary)
      }
      SettingsGroup(title: "防止误关") {
        CommandWProtectionSettingsView()
      }
      SettingsGroup(title: "恢复设置") {
        DisclosureGroup("恢复小龙哥默认配置", isExpanded: $isRecoveryExpanded) {
          VStack(alignment: .leading, spacing: 12) {
            Text("先备份，再恢复 \(XLGConfigImporter.bundledConfigurationDate) 的默认设置。")
              .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
              if model.isImportingXLGConfig { ProgressView().controlSize(.small) }
              Button(model.isImportingXLGConfig ? "恢复中…" : "备份并恢复…") {
                isBestConfigurationConfirmationPresented = true
              }
              .buttonStyle(.bordered)
              .disabled(model.isImportingXLGConfig)
              if model.lastXLGConfigImportBackupURL != nil {
                Button("打开上次备份") { model.openLastBestConfigurationBackup() }
                  .buttonStyle(.bordered)
              }
            }
            ConfigurationRestoreFeedback(workspace: model.configRestore)
          }
          .padding(.top, 8)
        }
      }
    }
  }

  private var permissionSettingsPage: some View {
    settingsPage(title: "权限", subtitle: "看清用途，再开启。", systemImage: "lock.shield") {
      SettingsGroup(title: model.allRequiredPermissionsComplete ? "已就绪" : "完成授权即可使用") {
        permissionRow("辅助功能", detail: "快捷键与窗口操作", granted: model.advancedListeningAuthorized)
        Divider()
        permissionRow("输入监控", detail: "Caps 与鼠标滚轮", granted: model.inputMonitoringAuthorized)
        Divider()
        permissionRow("屏幕录制", detail: "仅主动截图时读取画面", granted: model.screenRecordingAuthorized)
        Divider()
        HStack {
          permissionManagementButton
          Spacer(minLength: 8)
          Button {
            model.refreshAccessibilityStatus()
          } label: {
            Label("刷新", systemImage: "arrow.clockwise")
          }
          .buttonStyle(.borderless)
          .help("重新读取系统权限状态")
        }
      }
      SettingsGroup(title: "遇到问题") {
        DisclosureGroup("已开启，仍无法使用？", isExpanded: $isPermissionRecoveryExpanded) {
          VStack(alignment: .leading, spacing: 10) {
            Text("修复会清理本软件的失效权限记录，重启后重新授权。")
              .font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            clearPermissionButton
          }
          .padding(.top, 8)
        }
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      model.refreshAccessibilityStatus()
    }
  }

  private func permissionRow(_ title: String, detail: String, granted: Bool) -> some View {
    HStack(spacing: 12) {
      SettingsToggleLabel(title: title, detail: detail)
      Spacer(minLength: 8)
      Label(granted ? "已开启" : "未开启", systemImage: granted ? "checkmark.circle.fill" : "circle")
        .font(.callout)
        .foregroundStyle(granted ? teal : amber)
    }
    .padding(.vertical, 3)
    .accessibilityElement(children: .combine)
  }

  private var aboutSettingsPage: some View {
    settingsPage(title: "关于与更新", subtitle: "左手，掌控 Mac 一切。", systemImage: "info.circle") {
      UpdateSettingsCard(
        workspace: model.updateWorkspace,
        versionText: model.appVersionText,
        isInstalledInApplications: model.isInstalledInApplications,
        openApplicationsFolder: model.openApplicationsFolder
      )
      SettingsGroup(title: "新功能优先体验") {
        FriendProfileSettingsView()
      }
      SettingsGroup(title: "分享") {
        FreeSoftwareSettingsView()
      }
    }
  }

  private func settingsPage<Content: View>(
    title: String,
    subtitle: String,
    systemImage: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
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
      .frame(maxWidth: 680, alignment: .topLeading)
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
        model.allRequiredPermissionsComplete ? "管理权限…" : "开启权限…",
        systemImage: model.allRequiredPermissionsComplete
          ? "checkmark.shield" : "lock.open.fill")
    }
    .buttonStyle(.bordered)
    .tint(model.allRequiredPermissionsComplete ? teal : amber)
    .help("检查辅助功能、屏幕录制和输入监控")
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

private struct ConfigurationRestoreFeedback: View {
  @ObservedObject var workspace: ConfigRestoreCoordinator

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let failure = workspace.failureMessage {
        Label {
          Text(failure).fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "exclamationmark.triangle")
        }
        .foregroundStyle(.red)
        .accessibilityIdentifier("settings.restore.failure")
      }
      if workspace.lastBackupURL != nil {
        Text("恢复前的配置已保留，可通过“打开上次备份”查看。")
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("settings.restore.backup")
      }
    }
    .font(.caption)
    .textSelection(.enabled)
  }
}

struct UpdateSettingsCard: View {
  @ObservedObject var workspace: UpdateWorkspace
  let versionText: String
  let isInstalledInApplications: Bool
  let openApplicationsFolder: () -> Void

  private var hasAvailableUpdate: Bool { workspace.availableUpdateVersion != nil }

  private var updateStateText: String {
    if workspace.isUpdateBusy {
      return workspace.updateStatusText
    }
    if let failure = workspace.updateFailureMessage {
      return failure
    }
    if workspace.updateStatusText.hasPrefix("更新已安装") {
      return "更新已安装，当前已是最新版。"
    }
    if workspace.updateStatusText.hasPrefix("发现新版") {
      return workspace.updateStatusText
    }
    if hasAvailableUpdate {
      return "有新版本可以安装。"
    }
    if workspace.updateStatusText.hasPrefix("运行身份无效") {
      return "当前运行身份无效，不能检查线上更新。"
    }
    if workspace.updateStatusText == "未检查" {
      return "还没有检查更新。"
    }
    if workspace.updateStatusText == "自动检查已开启。" {
      return "自动检查已开启，也可以手动检查。"
    }
    if workspace.updateStatusText.hasPrefix("当前版本高于") {
      return workspace.updateStatusText
    }
    if workspace.updateStatusText.contains("已是最新版") {
      return "当前已是最新版。"
    }
    return "暂时无法检查更新，可稍后再试。"
  }

  private var updateActionTitle: String {
    if workspace.isUpdateBusy { return "处理中" }
    if hasAvailableUpdate { return "查看并更新" }
    if workspace.updateStatusText.hasPrefix("发现新版") { return "显示更新" }
    if workspace.updateStatusText == "未检查" { return "检查更新" }
    if workspace.updateStatusText == "自动检查已开启。" { return "检查更新" }
    if workspace.updateStatusText.hasPrefix("更新已安装") { return "再次检查" }
    if workspace.updateStatusText.contains("已是最新版") { return "再次检查" }
    if workspace.updateStatusText.hasPrefix("当前版本高于") { return "再次检查" }
    return "重试"
  }

  private var updateActionIcon: String {
    if workspace.isUpdateBusy { return "hourglass" }
    return !hasAvailableUpdate ? "arrow.clockwise" : "square.and.arrow.down"
  }

  private var updateStatusIcon: String {
    if workspace.updateFailureMessage != nil { return "exclamationmark.triangle.fill" }
    if hasAvailableUpdate { return "arrow.down.circle.fill" }
    if workspace.updateStatusText.hasPrefix("发现新版") { return "arrow.down.circle.fill" }
    if workspace.updateStatusText.hasPrefix("更新已安装") { return "checkmark.circle.fill" }
    if workspace.updateStatusText.contains("已是最新版") { return "checkmark.circle.fill" }
    if workspace.updateStatusText.hasPrefix("运行身份无效") { return "info.circle" }
    if workspace.updateStatusText == "未检查" { return "clock" }
    return "arrow.clockwise.circle"
  }

  private var updateStatusColor: Color {
    if workspace.updateFailureMessage != nil { return .orange }
    if hasAvailableUpdate { return UpdateReminderAppearance.blue }
    if workspace.updateStatusText.hasPrefix("发现新版") { return accent }
    if workspace.updateStatusText.hasPrefix("更新已安装") { return teal }
    if workspace.updateStatusText.contains("已是最新版") { return teal }
    return .secondary
  }

  @ViewBuilder
  private var updateStatusView: some View {
    HStack(spacing: 9) {
      if workspace.isUpdateBusy {
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
    if workspace.updateStatusText.hasPrefix("运行身份无效") {
      EmptyView()
    } else if hasAvailableUpdate {
      EmptyView()
    } else {
      updateButton
        .buttonStyle(.bordered)
        .tint(accent)
    }
  }

  private var updateButton: some View {
    Button {
      workspace.runPrimaryUpdateAction()
    } label: {
      Label(updateActionTitle, systemImage: updateActionIcon)
    }
    .controlSize(.regular)
    .disabled(workspace.isUpdateBusy)
    .help(updateActionTitle)
    .accessibilityLabel(updateActionTitle)
  }

  var body: some View {
    SettingsGroup(title: "小龙哥 Mac 哲学") {
      HStack(spacing: 12) {
        Image(nsImage: brandIcon())
          .resizable().interpolation(.high)
          .frame(width: 44, height: 44)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 3) {
          Text(versionText).font(.title3.weight(.semibold))
          Text("永久免费 · 自动检查，确认后更新")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        updateActionButton
      }
      .accessibilityElement(children: .contain)
      Divider()
      updateStatusView
      if let version = workspace.availableUpdateVersion {
        AvailableUpdateCard(version: version, isBusy: workspace.isUpdateBusy) {
          workspace.runPrimaryUpdateAction()
        }
      }
      if let progress = workspace.updateDownloadProgress {
        ProgressView(value: progress)
          .progressViewStyle(.linear)
          .accessibilityLabel("更新下载进度")
          .accessibilityValue("\(Int((progress * 100).rounded(.down)))%")
      }
      if workspace.updateFailureMessage != nil {
        Link(destination: URL(string: "https://aixlg.com/downloads/小龙哥Mac哲学.dmg")!) {
          Label("下载完整安装包", systemImage: "arrow.down.doc")
        }
        .help("从官网下载正式安装包；已有个人配置保留。")
        .accessibilityIdentifier("update.downloadFullInstaller")
      }
      if !isInstalledInApplications {
        Divider()
        HStack(spacing: 12) {
          Label("请移到“应用程序”后重新打开。", systemImage: "exclamationmark.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer(minLength: 8)
          Button("打开应用程序") { openApplicationsFolder() }
            .buttonStyle(.bordered)
        }
        .accessibilityIdentifier("about.installLocationWarning")
      }
    }
  }
}

struct SettingsToggleLabel: View {
  let title: String
  let detail: String

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(AppVisualStyle.labelFont)
        .foregroundStyle(.primary)
      Text(detail)
        .font(AppVisualStyle.detailFont)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct SettingsGroup<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      Text(title)
        .font(.headline)
        .foregroundStyle(.primary)
      content
    }
    .padding(AppVisualStyle.panelInset)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(
      AppVisualStyle.surface,
      in: RoundedRectangle(cornerRadius: 13, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 13, style: .continuous)
        .stroke(AppVisualStyle.separator, lineWidth: 1)
    )
  }
}
