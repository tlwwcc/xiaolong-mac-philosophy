import AppKit
import SwiftUI

struct SystemManagedPluginDetailView: View {
  @EnvironmentObject private var model: AppModel
  @Binding var item: ShortcutItem

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      PluginToolCard(item: $item)

      Divider()

      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("恢复设置")
            .font(.system(size: 13, weight: .semibold))
          Text("调错后可恢复为 App 内置默认值。")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(muted)
        }
        Spacer()
        Button("恢复默认设置") {
          model.restorePluginShortcut(id: item.id)
        }
        .buttonStyle(.bordered)
        .disabled(!model.canRestorePluginShortcut(id: item.id))
      }
    }
  }
}

struct ApplicationCenterOverviewRow: View {
  @State private var hovering = false

  let item: ApplicationCenterItem
  let selected: Bool
  let action: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Button(action: action) {
        HStack(spacing: 10) {
          ApplicationCenterIcon(item: item, size: 32)

          VStack(alignment: .leading, spacing: 4) {
            Text(item.name)
              .font(.callout.weight(.semibold))
              .foregroundStyle(.primary)
              .lineLimit(1)
            Text(item.purpose)
              .font(.system(size: 11))
              .foregroundStyle(AppVisualStyle.textSecondary)
              .lineLimit(2)
              .help(item.purpose)
            if let statusText = item.statusText {
              Label(statusText, systemImage: item.statusImage)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(item.statusColor)
                .lineLimit(2)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)

          Spacer(minLength: 4)
          Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(accessibilityLabel)
      .accessibilityValue(selected ? "已选" : "未选")
      .accessibilityAddTraits(selected ? .isSelected : [])
      .accessibilityHint("查看详情")

      if let isEnabled = item.isEnabled {
        Toggle("", isOn: isEnabled)
          .labelsHidden()
          .toggleStyle(.switch)
          .controlSize(.small)
          .accessibilityLabel("\(item.name)后台开关")
          .accessibilityValue(isEnabled.wrappedValue ? "已打开" : "已关闭")
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, minHeight: 56)
    .background(
      selected ? AppVisualStyle.selection : (hovering ? AppVisualStyle.hover : Color.clear),
      in: RoundedRectangle(cornerRadius: 9, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .stroke(selected ? AppVisualStyle.separator : Color.clear, lineWidth: 1)
    )
    .onHover { hovering = $0 }
  }

  private var accessibilityLabel: String {
    [item.name, item.mode.title, item.valueDescription, item.statusText]
      .compactMap { $0 }
      .joined(separator: "。")
  }
}

struct ApplicationCenterOverviewView: View {
  let featuredItems: [ApplicationCenterItem]
  let selectFeatureShortcuts: () -> Void
  let select: (String) -> Void

  var body: some View {
    ZStack {
      AppVisualStyle.background

      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
              Circle()
                .fill(AppVisualStyle.accent)
                .frame(width: 6, height: 6)
              Text("应用中心")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppVisualStyle.accent)
            }

            Text("先试一个最有感的功能")
              .font(.title2.weight(.semibold))
              .foregroundStyle(.primary)

            Text("选一件，马上得到结果；细节可以之后再慢慢设置。")
              .font(.callout)
              .foregroundStyle(.secondary)
          }

          ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { firstWinActions }
            VStack(spacing: 8) { firstWinActions }
          }

          Text("核心应用")
            .font(.headline)
            .foregroundStyle(.primary)

          VStack(spacing: 0) {
            ForEach(Array(featuredItems.enumerated()), id: \.element.id) { index, item in
              Button {
                select(item.id)
              } label: {
                HStack(spacing: 10) {
                  ApplicationCenterIcon(item: item, size: 44)

                  VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                      .font(.callout.weight(.semibold))
                      .foregroundStyle(.primary)
                    Text(item.valueDescription)
                      .font(.system(size: 12))
                      .foregroundStyle(.secondary)
                      .fixedSize(horizontal: false, vertical: true)
                  }

                  Spacer(minLength: 8)
                  Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityElement(children: .ignore)
              .accessibilityLabel("\(item.name)。\(item.purpose)")
              .accessibilityHint("查看详情")

              if index < featuredItems.count - 1 {
                Divider()
                  .padding(.leading, 70)
              }
            }
          }
          .background(
            AppVisualStyle.surface.opacity(0.92),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
              .stroke(AppVisualStyle.separator, lineWidth: 1)
          )
        }
        .padding(24)
        .frame(maxWidth: 760, alignment: .topLeading)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private var firstWinActions: some View {
    ApplicationCenterFirstWinButton(
      systemImage: "viewfinder.circle.fill",
      assetName: "YoumuAppIcon",
      tint: AppVisualStyle.accent,
      title: "看懂屏幕外文",
      hint: "打开截图"
    ) {
      select(applicationYoumuID)
    }
    ApplicationCenterFirstWinButton(
      systemImage: "magnifyingglass",
      tint: accent,
      title: "快速找到 App",
      hint: "试试 Caps + Space"
    ) {
      select(AppModel.launcherPluginID)
    }
    ApplicationCenterFirstWinButton(
      systemImage: "keyboard.badge.ellipsis",
      tint: teal,
      title: "少做重复动作",
      hint: "使用默认快捷键"
    ) {
      selectFeatureShortcuts()
    }
  }
}

struct ApplicationCenterFirstWinButton: View {
  @State private var hovering = false

  let systemImage: String
  var assetName: String? = nil
  let tint: Color
  let title: String
  let hint: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 7) {
        firstWinIcon
        Text(title)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
        Text(hint)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(16)
      .frame(minWidth: 140, maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
      .background(
        AppVisualStyle.surface.opacity(0.88),
        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .stroke(hovering ? AppVisualStyle.accent : AppVisualStyle.separator, lineWidth: 1)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(title)。\(hint)")
    .onHover { hovering = $0 }
  }

  @ViewBuilder
  private var firstWinIcon: some View {
    if let assetName, let appIcon = NSImage(named: NSImage.Name(assetName)) {
      Image(nsImage: appIcon)
        .resizable()
        .renderingMode(.original)
        .scaledToFit()
        .frame(width: 24, height: 24)
    } else {
      Image(systemName: systemImage)
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(tint)
    }
  }
}

struct ApplicationCenterDetailHeader: View {
  let item: ApplicationCenterItem
  let showOverview: () -> Void

  var body: some View {
    HStack(spacing: 11) {
      Button(action: showOverview) {
        Image(systemName: "chevron.left")
          .font(.system(size: 12, weight: .bold))
          .frame(width: 28, height: 28)
          .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
      }
      .buttonStyle(.plain)
      .help("返回应用中心总览")
      .accessibilityLabel("返回应用中心总览")

      ApplicationCenterIcon(item: item, size: 30)

      VStack(alignment: .leading, spacing: 2) {
        Text(item.name)
          .font(.headline)
          .foregroundStyle(ink)
        Text(item.purpose)
          .font(.caption)
          .foregroundStyle(muted)
          .lineLimit(1)
      }

      Spacer(minLength: 4)
      Text("永久免费")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 14)
    .frame(minHeight: 52)
    .accessibilityElement(children: .contain)
  }
}
