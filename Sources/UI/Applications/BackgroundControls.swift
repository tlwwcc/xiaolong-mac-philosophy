import AppKit
import SwiftUI

struct OneClickOptimizePanelView: View {
  var body: some View {
    PluginCenterView()
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
          AppVisualStyle.surface.opacity(0.30),
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
        AppVisualStyle.surface.opacity(0.50),
        in: RoundedRectangle(
          cornerRadius: 14,
          style: .continuous
        )
      )
      .overlay(
        RoundedRectangle(cornerRadius: 14)
          .stroke(AppVisualStyle.separator, lineWidth: 1))
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
