import AppKit
import SwiftUI

struct MenuBarCustomizationSheet: View {
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
          .background(AppVisualStyle.surface.opacity(0.62), in: RoundedRectangle(cornerRadius: 10))

          Text("网速主入口始终保留；可选择同时显示的资源占用。")
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
              .background(
                AppVisualStyle.surface.opacity(0.62), in: RoundedRectangle(cornerRadius: 10)
              )
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
    .background(AppVisualStyle.surface.opacity(0.62), in: RoundedRectangle(cornerRadius: 10))
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
