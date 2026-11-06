import SwiftUI

struct WorkspaceNotice: View {
  enum Tone {
    case information, warning, error
    var color: Color {
      switch self {
      case .information: return AppVisualStyle.accent
      case .warning: return AppVisualStyle.warning
      case .error: return AppVisualStyle.danger
      }
    }
  }
  let message: String
  let symbol: String
  var tone: Tone = .information

  var body: some View {
    Label {
      Text(message)
        .font(.callout)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    } icon: {
      Image(systemName: symbol).foregroundStyle(tone.color)
    }
    .padding(AppVisualStyle.Spacing.standard)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(tone.color.opacity(0.08))
    .accessibilityElement(children: .combine)
  }
}
