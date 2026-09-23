import AppKit
import SwiftUI

struct FreeSoftwareSettingsView: View {
  private let shareCopy = """
  发现一个真正顺手的 Mac 工具：小龙哥 Mac 哲学。
  把截图、剪贴板、PDF、快捷键和常用工具收在一起，少找一步，少打断一次。
  全部功能永久免费，无需注册，打开就能用。
  https://aixlg.com/mac/
  """
  @State private var copyStatus = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("所有功能，永久免费", systemImage: "heart.fill").font(.headline)
      Text("无需登录，没有使用期限。把好用的 Mac 工具分享给朋友，让更多人认识小龙哥。")
        .font(.subheadline).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shareCopy, forType: .string)
        copyStatus = "已复制，粘贴到微信或飞书即可。"
      } label: {
        Label("复制分享文案", systemImage: "doc.on.doc")
      }
      .buttonStyle(.borderedProminent)
      if !copyStatus.isEmpty {
        Text(copyStatus)
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityLabel(copyStatus)
      }
      Divider()
      Text("感谢最初的支持").font(.headline)
      Text("感谢最早购买或收到赠送的 14 位朋友。既有的永久 AI 答疑支持继续保留，遇到问题，随时联系小龙哥。")
        .font(.subheadline).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Text("联系小龙哥").font(.subheadline)
      FeedbackRequestPanelView()
    }
  }
}
