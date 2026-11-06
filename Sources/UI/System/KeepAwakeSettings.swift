import AppKit
import SwiftUI

struct KeepAwakeSettingsPanel: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    KeepAwakeControls(
      workspace: model.keepAwakeWorkspace, durationOptions: AppModel.keepAwakeDurationOptions)
  }
}

struct KeepAwakeControls: View {
  @ObservedObject var workspace: KeepAwakeWorkspace
  let durationOptions: [KeepAwakeDurationOption]

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
        ForEach(durationOptions) { option in
          Button {
            workspace.start(minutes: option.minutes)
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
            workspace.setCustomHours(workspace.customHours - 1)
          } label: {
            Image(systemName: "minus")
              .frame(width: 34, height: 34)
          }
          .buttonStyle(.plain)
          .disabled(workspace.customHours <= 1)
          .accessibilityLabel("减少自定义时长")

          Rectangle()
            .fill(hairline)
            .frame(width: 1, height: 18)

          Text("\(workspace.customHours) 小时")
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(ink)
            .monospacedDigit()
            .frame(width: 58)
            .accessibilityIdentifier("keepAwake.customHours")

          Rectangle()
            .fill(hairline)
            .frame(width: 1, height: 18)

          Button {
            workspace.setCustomHours(workspace.customHours + 1)
          } label: {
            Image(systemName: "plus")
              .frame(width: 34, height: 34)
          }
          .buttonStyle(.plain)
          .disabled(workspace.customHours >= 12)
          .accessibilityLabel("增加自定义时长")
        }
        .foregroundStyle(AppVisualStyle.accent)
        .background(
          AppVisualStyle.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(hairline, lineWidth: 1)
        )

        Button {
          workspace.startCustomHours()
        } label: {
          Text("开始 \(workspace.customHours) 小时")
            .frame(minWidth: 92)
        }
        .accessibilityLabel("开始自定义 \(workspace.customHours) 小时")
        .accessibilityIdentifier("keepAwake.customStart")
        .buttonStyle(KeepAwakePrimaryButtonStyle())
      }
      .padding(14)
      .background(
        AppVisualStyle.selection.opacity(0.68),
        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(AppVisualStyle.accent.opacity(0.08), lineWidth: 1)
      )
      .padding(.top, 16)

      Rectangle()
        .fill(hairline)
        .frame(height: 1)
        .padding(.vertical, 19)

      HStack(spacing: 12) {
        Image(systemName: "display")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(AppVisualStyle.accent)
          .frame(width: 30, height: 30)
          .background(
            AppVisualStyle.selection, in: RoundedRectangle(cornerRadius: 9, style: .continuous)
          )
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
            get: { workspace.preventDisplaySleep },
            set: { workspace.setPreventDisplaySleep($0) }
          )
        )
        .labelsHidden()
        .toggleStyle(.switch)
        .tint(AppVisualStyle.accent)
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

struct KeepAwakeDurationButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(AppVisualStyle.accent)
      .frame(height: 42)
      .background(
        configuration.isPressed ? AppVisualStyle.selection : AppVisualStyle.surface,
        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .stroke(
            configuration.isPressed ? AppVisualStyle.accent.opacity(0.32) : hairline,
            lineWidth: 1)
      )
      .scaleEffect(configuration.isPressed ? 0.985 : 1)
      .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
  }
}

struct KeepAwakePrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(AppVisualStyle.onAccent)
      .padding(.horizontal, 14)
      .frame(height: 36)
      .background(
        configuration.isPressed ? AppVisualStyle.accent.opacity(0.84) : AppVisualStyle.accent,
        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
      )
      .scaleEffect(configuration.isPressed ? 0.985 : 1)
      .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
  }
}

struct KeepAwakeStopButtonStyle: ButtonStyle {
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

struct KeepAwakeDoneButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(ink)
      .padding(.horizontal, 12)
      .frame(height: 32)
      .background(
        AppVisualStyle.surface.opacity(configuration.isPressed ? 0.55 : 0.92), in: Capsule()
      )
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
