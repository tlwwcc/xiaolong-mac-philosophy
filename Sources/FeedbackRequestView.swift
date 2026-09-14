import AppKit
import SwiftUI

struct FeedbackRequestPanelView: View {

  private var groupQRCode: NSImage? {
    guard let url = Bundle.main.url(forResource: "CommunityGroupQRCode", withExtension: "png") else { return nil }
    return NSImage(contentsOf: url)
  }

  var body: some View {
    VStack(spacing: 14) {
      Text("小龙哥 Mac 哲学交流群")
        .font(.headline)
      if let image = groupQRCode {
        Image(nsImage: image)
          .resizable()
          .interpolation(.none)
          .scaledToFit()
          .frame(width: 264, height: 264)
          .padding(12)
          .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
          .accessibilityLabel("小龙哥 Mac 哲学企业微信群入群二维码")
        Text("微信扫一扫，加入企业微信群")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        Text("二维码未能载入。")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(20)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
  }
}
