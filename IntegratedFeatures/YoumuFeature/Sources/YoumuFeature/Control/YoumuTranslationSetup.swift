import SwiftUI

/// The host owns when onboarding appears; Youmu owns model availability and the download UI.
@MainActor
public enum YoumuTranslationSetup {
  public static func needsModelDownload() async -> Bool {
    guard #available(macOS 15.0, *) else { return false }
    return await AppleLocalModelAvailability.status() == .downloadable
  }

  public static func makeView(dismiss: @escaping () -> Void) -> AnyView? {
    guard #available(macOS 15.0, *) else { return nil }
    return AnyView(TranslationModelSetupView(dismiss: dismiss))
  }
}

@available(macOS 15.0, *)
private struct TranslationModelSetupView: View {
  let dismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Label("下载翻译模型", systemImage: "character.book.closed")
        .font(.title2.weight(.semibold))
      Text("下载 Apple 的英中语言模型后，就能在游目里离线翻译文字和截图。")
        .fixedSize(horizontal: false, vertical: true)
      AppleLocalModelControlRow(onReady: dismiss)
      Text("也可以稍后从“游目 → 翻译 → Apple 本机翻译”下载。")
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("稍后", action: dismiss).keyboardShortcut(.cancelAction)
      }
    }
    .padding(24)
    .frame(width: 420)
  }
}
