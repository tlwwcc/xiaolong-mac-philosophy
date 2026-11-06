import AppKit
import SwiftUI

struct StatusFooterView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    HStack(spacing: 8) {
      Image(
        systemName: model.statusMessage.contains("未授权") || model.statusMessage.contains("失败")
          ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
      )
      .foregroundStyle(
        model.statusMessage.contains("未授权") || model.statusMessage.contains("失败") ? amber : teal)
      Text(model.statusMessage)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(muted)
        .lineLimit(2)
      Spacer()
    }
    .padding(.horizontal, 12)
    .frame(height: 38)
    .premiumPanel(radius: 13)
  }
}
