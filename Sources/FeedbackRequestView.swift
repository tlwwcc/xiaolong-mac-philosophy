import SwiftUI

private let feedbackAccent = Color(red: 0.02, green: 0.36, blue: 0.95)
private let feedbackTeal = Color(red: 0.00, green: 0.49, blue: 0.42)
private let feedbackInk = Color(red: 0.07, green: 0.08, blue: 0.09)
private let feedbackMuted = Color(red: 0.40, green: 0.45, blue: 0.47)
private let feedbackSurface = Color.white
private let feedbackSoftSurface = Color(red: 0.97, green: 0.98, blue: 0.985)
private let feedbackLine = Color(red: 0.84, green: 0.87, blue: 0.88)

struct FeedbackRequestPanelView: View {
  @EnvironmentObject private var model: AppModel

  var showsHeader = true

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if showsHeader {
        header
      }
      mainCard
    }
    .padding(.top, showsHeader ? 4 : 0)
    .padding(.bottom, 18)
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 14) {
      Image(systemName: "bubble.left.and.text.bubble.right.fill")
        .font(.system(size: 22, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 48, height: 48)
        .background(feedbackAccent, in: RoundedRectangle(cornerRadius: 13, style: .continuous))

      VStack(alignment: .leading, spacing: 5) {
        Text("提需求")
          .font(.system(size: 22, weight: .semibold))
          .foregroundStyle(feedbackInk)
        Text("打开网页反馈页，可以直接粘贴截图。")
          .font(.system(size: 13))
          .foregroundStyle(feedbackMuted)
      }

      Spacer()
    }
    .padding(.horizontal, 4)
  }

  private var mainCard: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .top, spacing: 14) {
        Image(systemName: "safari.fill")
          .font(.system(size: 20, weight: .semibold))
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(feedbackAccent)
          .frame(width: 44, height: 44)
          .background(feedbackAccent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

        VStack(alignment: .leading, spacing: 8) {
          Text("去网页提需求")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(feedbackInk)
          Text("文字、截图粘贴、图片预览和提交都在网页反馈页完成。")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(feedbackMuted)
            .fixedSize(horizontal: false, vertical: true)
          Text("如果网页后端还没接好，会明确提示暂时不能留存，不会假装提交成功。")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(feedbackTeal)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      Divider()

      Button {
        model.openFeedbackWebsite()
      } label: {
        Label("去网页提需求", systemImage: "arrow.up.right.square")
          .frame(minWidth: 168, minHeight: 38)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .tint(feedbackAccent)
      .help("打开网页提需求")
      .accessibilityLabel("提需求，打开网页反馈页")
    }
    .padding(18)
    .feedbackCard()
  }
}

extension View {
  fileprivate func feedbackCard() -> some View {
    background(feedbackSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(Color.white.opacity(0.82), lineWidth: 1))
      .shadow(color: Color.black.opacity(0.040), radius: 10, x: 0, y: 6)
  }
}
