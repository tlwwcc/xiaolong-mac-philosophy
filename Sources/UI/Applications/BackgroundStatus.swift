import AppKit
import SwiftUI

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
      AppVisualStyle.surface.opacity(0.72),
      in: RoundedRectangle(cornerRadius: 15, style: .continuous)
    )
    .overlay(RoundedRectangle(cornerRadius: 15).stroke(AppVisualStyle.separator, lineWidth: 1))
  }
}
