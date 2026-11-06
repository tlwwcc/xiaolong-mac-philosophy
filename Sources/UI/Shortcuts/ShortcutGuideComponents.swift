import AppKit
import SwiftUI

struct ShortcutGuideCategoryButton: View {
  let title: String
  let count: Int
  let selected: Bool
  let action: () -> Void

  var body: some View {
    let tint = shortcutGuideCategoryTint(title)

    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: shortcutGuideCategoryIcon(title))
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(selected ? AppVisualStyle.onAccent : tint)
          .frame(width: 16)

        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 5) {
            Text(title)
              .font(.system(size: 12, weight: selected ? .semibold : .medium))
              .lineLimit(1)

            Text("\(count)")
              .font(.system(size: 10, weight: .bold, design: .rounded))
              .foregroundStyle(
                selected ? AppVisualStyle.onAccent.opacity(0.84) : tint.opacity(0.82)
              )
              .padding(.horizontal, 5)
              .frame(height: 16)
              .background(
                selected ? AppVisualStyle.surface.opacity(0.16) : tint.opacity(0.10),
                in: Capsule()
              )
          }

          Text(shortcutGuideCategoryPreview(title))
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(selected ? AppVisualStyle.onAccent.opacity(0.72) : muted.opacity(0.82))
            .lineLimit(1)
        }
      }
      .foregroundStyle(selected ? AppVisualStyle.onAccent : ink)
      .padding(.horizontal, 11)
      .frame(height: 42)
      .background(
        selected ? tint : AppVisualStyle.surface.opacity(0.92),
        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
      )
      .background(
        tint.opacity(selected ? 0 : 0.08),
        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(
            selected ? AppVisualStyle.surface.opacity(0.22) : tint.opacity(0.18), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
  }
}

struct ShortcutFormTextField: View {
  let title: String
  let placeholder: String
  @Binding var text: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(muted)
      TextField(placeholder, text: $text)
        .textFieldStyle(.plain)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(ink)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .background(
          AppVisualStyle.surface.opacity(0.78),
          in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(glassLine, lineWidth: 1))
    }
  }
}

struct ShortcutGuideRow: View {
  let entry: ShortcutGuideEntry
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        ShortcutGuideActionBadge(entry: entry, category: entry.category)

        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 7) {
            Text(entry.title)
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(ink)
              .lineLimit(1)
            StatusPill(
              text: entry.statusText, color: entry.shortcutItem?.enabled == false ? muted : teal)
          }
          ShortcutGuideKeycaps(text: entry.hotkeyText)
        }

        Spacer(minLength: 8)
      }
      .padding(.horizontal, 12)
      .frame(height: 70)
      .background(
        selected
          ? LinearGradient(
            colors: [accent.opacity(0.12), teal.opacity(0.055)], startPoint: .leading,
            endPoint: .trailing)
          : LinearGradient(
            colors: [AppVisualStyle.surface.opacity(0.96), AppVisualStyle.surface.opacity(0.82)],
            startPoint: .leading,
            endPoint: .trailing)
      )
      .overlay(Rectangle().fill(line.opacity(0.72)).frame(height: 1), alignment: .bottom)
    }
    .buttonStyle(.plain)
  }
}

struct ShortcutGuideActionBadge: View {
  let entry: ShortcutGuideEntry
  let category: String

  var body: some View {
    Group {
      if let appIcon {
        Image(nsImage: appIcon)
          .resizable()
          .interpolation(.high)
          .scaledToFit()
          .padding(5)
      } else {
        Image(systemName: iconName)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(tint)
      }
    }
    .frame(width: 34, height: 34)
    .background(
      appIcon == nil ? tint.opacity(0.10) : AppVisualStyle.surface.opacity(0.92),
      in: RoundedRectangle(cornerRadius: 10, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(
          appIcon == nil ? tint.opacity(0.12) : AppVisualStyle.surface.opacity(0.88), lineWidth: 1)
    )
  }

  private var appIcon: NSImage? {
    if let item = entry.shortcutItem {
      return shortcutGuideAppIcon(for: item)
    }
    return nil
  }

  private var iconName: String {
    shortcutGuideCategoryIcon(category)
  }

  private var tint: Color {
    shortcutGuideCategoryTint(category)
  }
}

struct ShortcutGuideKeycaps: View {
  let text: String

  var body: some View {
    HStack(spacing: 4) {
      ForEach(text.components(separatedBy: " + "), id: \.self) { key in
        Text(shortcutKeycapLabel(key))
          .font(.system(size: 11, weight: .semibold, design: .rounded))
          .foregroundStyle(accent.opacity(0.82))
          .padding(.horizontal, 7)
          .frame(height: 21)
          .background(
            softSurface.opacity(0.92), in: RoundedRectangle(cornerRadius: 6, style: .continuous)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .stroke(line.opacity(0.62), lineWidth: 1)
          )
      }
    }
  }
}

func shortcutKeycapLabel(_ key: String) -> String {
  switch key {
  case "Left": return "◀"
  case "Right": return "▶"
  case "Up": return "▲"
  case "Down": return "▼"
  default: return key
  }
}

struct ShortcutGuideDetailPane: View {
  let selectedCategory: String
  let entry: ShortcutGuideEntry?
  let totalCount: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if let entry {
        ShortcutGuideEntryDetail(
          entry: entry,
          totalCount: totalCount
        )
      } else {
        ShortcutGuideNoSelectionView()
      }
    }
    .padding(20)
  }
}

struct ShortcutGuideEntryDetail: View {
  let entry: ShortcutGuideEntry
  let totalCount: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 12) {
        ShortcutGuideActionBadge(entry: entry, category: entry.category)
        VStack(alignment: .leading, spacing: 4) {
          Text(entry.title)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(ink)
            .lineLimit(2)
          Text("第 \(entry.index + 1) 条，共 \(totalCount) 条")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(muted)
        }
        Spacer()
      }

      ShortcutGuideKeycaps(text: entry.hotkeyText)

      HStack(spacing: 8) {
        PluginChip(text: entry.category, color: accent)
        PluginChip(
          text: entry.statusText, color: entry.shortcutItem?.enabled == false ? muted : teal)
        PluginChip(text: entry.source, color: violet)
      }

      ShortcutGuideDetailBlock(title: "说明", value: entry.description)
      ShortcutGuideDetailBlock(title: "执行动作", value: entry.actionTitle)
      ShortcutGuideDetailBlock(title: "作用范围", value: entry.scopeText)

      if !entry.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        ShortcutGuideDetailBlock(title: "执行内容", value: entry.targetText)
      }

      Spacer()
    }
  }
}

struct ShortcutGuideDetailBlock: View {
  let title: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(muted)
      Text(value)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(ink)
        .lineSpacing(3)
        .textSelection(.enabled)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      AppVisualStyle.surface.opacity(0.70),
      in: RoundedRectangle(cornerRadius: 12, style: .continuous)
    )
    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(glassLine, lineWidth: 1))
  }
}
