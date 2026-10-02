import AppKit
import SwiftUI

enum UpdateReminderAppearance {
  static let blue = Color(
    nsColor: NSColor(name: "UpdateReminderBlue") { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0.46, green: 0.73, blue: 1, alpha: 1)
        : NSColor(srgbRed: 0.02, green: 0.34, blue: 0.70, alpha: 1)
    })
}

struct AvailableUpdateCard: View {
  let version: String
  let isBusy: Bool
  let action: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("新版本 \(version) 已可用", systemImage: "arrow.down.circle.fill")
        .font(.headline)
        .foregroundStyle(UpdateReminderAppearance.blue)
      Text(isBusy ? "正在更新，请在更新窗口中查看进度。" : "看看这次的改进。确认后下载并安装，完成后会重启软件。")
        .font(.body)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
      Button(isBusy ? "查看更新进度" : "查看并更新", action: action)
        .buttonStyle(.bordered)
        .tint(UpdateReminderAppearance.blue)
        .accessibilityIdentifier("update.available.action")
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(UpdateReminderAppearance.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(UpdateReminderAppearance.blue.opacity(0.3)))
    .accessibilityIdentifier("update.available.card")
  }
}
