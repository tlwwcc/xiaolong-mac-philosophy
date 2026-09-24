import AppKit
import SwiftUI

struct FreeSoftwareSettingsView: View {
  private let shareCopy = """
  小龙哥 Mac 哲学，把快捷键练成你的连招。
  像 LOL 里的英雄连招：游戏里，伤害打满；Mac 上，效率拉满。
  截图、切到微信、粘贴，一气呵成。用成习惯，把时间留给真正想做的事。
  全部功能永久免费，无需注册。
  https://aixlg.com/mac/
  """
  @State private var copyStatus = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("所有功能，永久免费", systemImage: "heart.fill").font(.headline)
      Text("无需登录，没有使用期限。把快捷键串成连招，也把这份顺手分享给朋友。")
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
