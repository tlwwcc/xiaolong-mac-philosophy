import AppKit
import SwiftUI

struct FreeSoftwareSettingsView: View {
  private let shareCopy = """
    小龙哥 Mac 哲学，左手，掌控 Mac 一切。
    全部功能免费开源，无需注册；顺手分享给你。
    https://aixlg.com/mac/
    """
  @State private var copySucceeded: Bool?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Button {
        NSPasteboard.general.clearContents()
        copySucceeded = NSPasteboard.general.setString(shareCopy, forType: .string)
      } label: {
        Label("分享给身边的朋友", systemImage: "square.and.arrow.up")
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .help("点一下即可复制，粘贴给朋友就好。")
      .accessibilityIdentifier("about.shareFriends")
      .accessibilityValue(copySucceeded == true ? "分享内容已复制" : "")
      if let copySucceeded {
        Text(copySucceeded ? "已复制，粘贴给朋友就好。" : "复制失败，可在下方选中内容复制。")
          .font(.caption)
          .foregroundStyle(copySucceeded ? Color.secondary : Color.orange)
          .accessibilityIdentifier("about.shareFeedback")
        if !copySucceeded {
          Text(shareCopy)
            .font(.caption)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      HStack(spacing: 16) {
        Link("官网", destination: URL(string: "https://aixlg.com/mac/")!)
        Link("隐私", destination: URL(string: "https://aixlg.com/privacy.html")!)
      }
      .font(.caption)
      .buttonStyle(.link)
    }
  }
}
