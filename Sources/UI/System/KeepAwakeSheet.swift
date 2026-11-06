import AppKit
import SwiftUI

struct KeepAwakeSheetView: View {
  @EnvironmentObject private var model: AppModel
  let onClose: (() -> Void)?

  init(onClose: (() -> Void)? = nil) {
    self.onClose = onClose
  }

  var body: some View {
    KeepAwakeSheetContent(
      workspace: model.keepAwakeWorkspace, durationOptions: AppModel.keepAwakeDurationOptions,
      onClose: onClose)
  }
}

struct KeepAwakeSheetContent: View {
  @ObservedObject var workspace: KeepAwakeWorkspace
  @Environment(\.dismiss) private var dismiss
  let durationOptions: [KeepAwakeDurationOption]
  let onClose: (() -> Void)?

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 16) {
        ZStack {
          Circle()
            .fill(AppVisualStyle.selection)
          Image(systemName: workspace.enabled ? "moon.stars.fill" : "moon.zzz")
            .font(.system(size: 21, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(AppVisualStyle.accent)
        }
        .frame(width: 52, height: 52)
        .overlay(Circle().stroke(AppVisualStyle.accent.opacity(0.10), lineWidth: 1))
        .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 7) {
            Circle()
              .fill(workspace.enabled ? teal : muted.opacity(0.55))
              .frame(width: 6, height: 6)
            Text("保持唤醒")
              .font(.system(size: 11, weight: .bold))
              .foregroundStyle(AppVisualStyle.accent)
          }
          Text(workspace.enabled ? "正在保持唤醒" : "Mac 可以正常睡眠")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(ink)
            .accessibilityIdentifier("keepAwake.statusTitle")
          Text(statusDetail)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(muted)
            .accessibilityIdentifier("keepAwake.statusDetail")
        }

        Spacer()

        if workspace.enabled {
          Button {
            workspace.stop()
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

      KeepAwakeControls(workspace: workspace, durationOptions: durationOptions)
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .frame(width: 560, height: 480)
    .background(AppVisualStyle.surface)
  }

  private var statusDetail: String {
    guard workspace.enabled else {
      return "选择一个时长，即可开始。"
    }
    return "\(workspace.statusText) · "
      + (workspace.preventDisplaySleep ? "屏幕也会保持亮起" : "仅阻止 Mac 睡眠")
  }
}
