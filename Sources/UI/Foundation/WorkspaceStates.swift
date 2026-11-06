import AppKit
import SwiftUI

struct WorkspaceSearchField: View {
  let placeholder: String
  @Binding var text: String
  var focus: FocusState<Bool>.Binding
  var accessibilityName: String

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(AppVisualStyle.textSecondary)
        .accessibilityHidden(true)
      TextField(placeholder, text: $text)
        .textFieldStyle(.plain)
        .font(.system(size: 13))
        .foregroundStyle(AppVisualStyle.textPrimary)
        .focused(focus)
        .accessibilityLabel(accessibilityName)
        .onExitCommand {
          if text.isEmpty {
            focus.wrappedValue = false
          } else {
            text = ""
          }
        }
      if !text.isEmpty {
        Button {
          text = ""
          focus.wrappedValue = true
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(AppVisualStyle.textSecondary)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("清除搜索")
        .accessibilityLabel("清除\(accessibilityName)")
      }
    }
    .padding(.horizontal, 10)
    .frame(height: 34)
    .background(AppVisualStyle.surface, in: RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(
          focus.wrappedValue ? AppVisualStyle.accent : AppVisualStyle.separator,
          lineWidth: focus.wrappedValue ? 2 : 1)
    )
  }
}

struct WorkspaceEmptyState: View {
  let systemImage: String
  let title: String
  let detail: String
  var actionTitle: String? = nil
  var action: (() -> Void)? = nil

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: systemImage)
        .font(.system(size: 28, weight: .regular))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(AppVisualStyle.textSecondary)
        .accessibilityHidden(true)
      VStack(spacing: 5) {
        Text(title)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(AppVisualStyle.textPrimary)
        Text(detail)
          .font(.system(size: 12))
          .foregroundStyle(AppVisualStyle.textSecondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let actionTitle, let action {
        Button(actionTitle, action: action)
          .buttonStyle(.bordered)
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, minHeight: 200)
    .accessibilityElement(children: .contain)
  }
}
