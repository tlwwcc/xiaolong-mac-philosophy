import SwiftUI

struct FreeSoftwareSettingsView: View {
  private let productURL = URL(string: "https://aixlg.com/mac/")!
  private let supportURL = URL(string: "https://aixlg.com/support.html")!

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("所有功能，永久免费", systemImage: "heart.fill").font(.headline)
      Text("无需登录，没有使用期限。把好用的 Mac 工具分享给朋友，让更多人认识小龙哥。")
        .font(.subheadline).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      ShareLink(item: productURL, subject: Text("小龙哥 Mac 哲学"),
        message: Text("左手掌控 Mac 一切。快捷键、截图、剪贴板、游目、披卷、听澜，所有功能永久免费。")) {
        Label("分享给朋友", systemImage: "square.and.arrow.up")
      }
      Divider()
      Text("感谢最初的支持").font(.headline)
      Text("感谢最早购买或收到赠送的 14 位朋友。既有的永久 AI 答疑支持继续保留，遇到问题，随时联系小龙哥。")
        .font(.subheadline).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Link(destination: supportURL) {
        Label("联系小龙哥", systemImage: "bubble.left.and.bubble.right")
      }
    }
  }
}
