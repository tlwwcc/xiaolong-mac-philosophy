import AppKit
import SwiftUI

struct ReleaseAnnouncementSheetView: View {
  @ObservedObject var workspace: UpdateWorkspace
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
          workspace.openReleaseNotesChangelog()
        } label: {
          Label("查看更新记录", systemImage: "safari")
        }
        .buttonStyle(GlassLabelButtonStyle(tint: muted))

        Spacer()

        Button {
          workspace.markReleaseNoteSeen()
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

struct ReleaseNoteBullet: View {
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

let shortcutGuideCategories = [
  "全部", "截图类", "PDF类", "工具类", "窗口类", "软件类", "系统级", "脚本类", "其他类",
]
