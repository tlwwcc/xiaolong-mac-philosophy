import AppKit
import SwiftUI

struct ShortcutActionCaptureSheet: View {
  @EnvironmentObject private var model: AppModel
  let recordingOwnerID: UUID

  var body: some View {
    VStack(spacing: 0) {
      VStack(spacing: 22) {
        HStack(spacing: 16) {
          Image(systemName: "keyboard")
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(AppVisualStyle.onAccent)
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
            .background(
              AppVisualStyle.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay(
              RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(accent.opacity(0.65), lineWidth: 2)
            )
            .background(
              KeyCaptureView(
                ownerID: recordingOwnerID == model.shortcutActionCaptureSessionID
                  ? recordingOwnerID : nil
              ) { event, ownerID in
                model.applyShortcutActionCaptured(event, ownerID: ownerID)
              })
          }
          .buttonStyle(.plain)
        }

        HStack(spacing: 12) {
          Button {
            cancelOwnedCapture()
          } label: {
            Label("取消", systemImage: "xmark")
          }
          .keyboardShortcut(.cancelAction)
          .buttonStyle(GlassLabelButtonStyle(tint: muted))

          Button {
            model.confirmShortcutActionCapture(ownerID: recordingOwnerID)
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
    .onDisappear { cancelOwnedCapture() }
  }

  private func cancelOwnedCapture() {
    model.cancelShortcutActionCapture(ownerID: recordingOwnerID)
  }
}
