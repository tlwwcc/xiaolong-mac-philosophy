import AppKit
import SwiftUI

struct ClassicTabSwitcherHUDView: View {
  @EnvironmentObject private var model: AppModel

  private var state: ClassicTabSwitcherHUDState {
    model.classicTabSwitcherHUDState
  }

  var body: some View {
    VStack(spacing: 12) {
      HStack(alignment: .center) {
        HStack(spacing: 8) {
          Image(nsImage: hudLogo)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: 24, height: 24)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
          Text("窗口切换")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(ink.opacity(0.86))
        }

        Spacer()

        Text(candidateCountText)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(muted.opacity(0.86))
      }

      if let message = state.message {
        Spacer(minLength: 2)
        Text(message)
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(ink)
          .multilineTextAlignment(.center)
        Spacer(minLength: 2)
      } else {
        ScrollViewReader { proxy in
          ScrollView(.vertical, showsIndicators: state.apps.count > 12) {
            LazyVGrid(columns: gridColumns, alignment: .center, spacing: 10) {
              ForEach(allApps, id: \.index) { item in
                ClassicTabSwitcherAppItem(
                  app: item.app,
                  selected: item.index == state.selectedIndex
                )
                .id(item.index)
              }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
          }
          .frame(maxHeight: 326)
          .onAppear { scrollSelectedApp(in: proxy) }
          .onChange(of: state.selectedIndex) { _ in scrollSelectedApp(in: proxy) }
        }
      }
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 18)
    .frame(width: 780, height: 430)
    .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .stroke(AppVisualStyle.separator, lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.22), radius: 42, x: 0, y: 22)
  }

  private var hudLogo: NSImage {
    NSImage(named: "AppIcon") ?? NSApp.applicationIconImage ?? NSImage()
  }

  private var allApps: [(index: Int, app: ClassicTabSwitcherAppSnapshot)] {
    state.apps.enumerated().map { ($0.offset, $0.element) }
  }

  private var gridColumns: [GridItem] {
    Array(
      repeating: GridItem(.flexible(minimum: 136, maximum: 160), spacing: 10, alignment: .top),
      count: 4)
  }

  private var candidateCountText: String {
    if state.apps.isEmpty {
      return "正在准备窗口"
    }
    let shortcut =
      model.classicTabSwitcherCommandTabTakeoverConfirmed ? "Command + Tab" : "Option + Tab"
    return "\(state.apps.count) 个窗口 · \(shortcut)"
  }

  private func scrollSelectedApp(in proxy: ScrollViewProxy) {
    guard state.apps.indices.contains(state.selectedIndex) else { return }
    DispatchQueue.main.async {
      withAnimation(.easeOut(duration: 0.12)) {
        proxy.scrollTo(state.selectedIndex, anchor: .center)
      }
    }
  }
}

struct ClassicTabSwitcherAppItem: View {
  let app: ClassicTabSwitcherAppSnapshot
  let selected: Bool

  var body: some View {
    VStack(spacing: 9) {
      HStack(alignment: .top, spacing: 9) {
        Image(nsImage: icon)
          .resizable()
          .interpolation(.high)
          .scaledToFit()
          .padding(5)
          .frame(width: 42, height: 42)
          .background(
            AppVisualStyle.surface.opacity(selected ? 0.58 : 0.42),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
          )
          .opacity(selected ? 1 : 0.86)

        VStack(alignment: .leading, spacing: 3) {
          Text(app.name)
            .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
            .foregroundStyle(ink.opacity(selected ? 0.88 : 0.70))
            .lineLimit(1)
            .truncationMode(.tail)
          Text(title)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(muted.opacity(selected ? 0.86 : 0.68))
            .lineLimit(2)
            .truncationMode(.tail)
            .frame(minHeight: 25, alignment: .topLeading)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      HStack(spacing: 5) {
        ForEach(statusBadges, id: \.self) { badge in
          Text(badge)
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(selected ? teal : muted)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .frame(height: 16)
            .background((selected ? teal : muted).opacity(0.10), in: Capsule())
        }
        Spacer(minLength: 0)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 9)
    .frame(height: 108)
    .background(cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(
          selected ? teal.opacity(0.70) : AppVisualStyle.surface.opacity(0.24),
          lineWidth: selected ? 1.4 : 1)
    )
    .shadow(color: selected ? Color.black.opacity(0.08) : Color.clear, radius: 8, x: 0, y: 4)
  }

  private var icon: NSImage {
    if let icon = app.icon { return icon }
    return NSImage(named: NSImage.applicationIconName) ?? NSImage()
  }

  private var title: String {
    let title = app.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    if title.isEmpty || genericWindowTitles.contains(title.lowercased()) {
      return app.name
    }
    return title
  }

  private var genericWindowTitles: Set<String> {
    ["window", "untitled", "未命名窗口", "无标题"]
  }

  private var statusBadges: [String] {
    var badges: [String] = []
    if selected {
      badges.append("选中")
    }
    if app.isCurrentWindow {
      badges.append("当前")
    }
    if app.isMinimized {
      badges.append("最小化")
    }
    if app.isHidden {
      badges.append("隐藏")
    }
    if app.isFullscreen {
      badges.append("全屏")
    }
    return badges.isEmpty ? ["可切换"] : Array(badges.prefix(3))
  }

  private var cardBackground: some ShapeStyle {
    selected ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(AppVisualStyle.surface.opacity(0.14))
  }
}

struct LauncherKeyPill: View {
  let systemImage: String

  var body: some View {
    Image(systemName: systemImage)
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(accent.opacity(0.78))
      .frame(width: 30, height: 28)
      .background(accent.opacity(0.085), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .stroke(AppVisualStyle.separator, lineWidth: 1)
      )
  }
}

struct LauncherShortcutPill: View {
  let text: String
  var compact = false
  var active = false

  var body: some View {
    Text(text)
      .font(.system(size: compact ? 8 : 10, weight: .bold, design: .rounded))
      .foregroundStyle(active ? accent : teal)
      .lineLimit(1)
      .minimumScaleFactor(0.72)
      .padding(.horizontal, compact ? 5 : 7)
      .frame(height: compact ? 17 : 22)
      .background((active ? accent : teal).opacity(active ? 0.14 : 0.10), in: Capsule())
      .overlay(Capsule().stroke(AppVisualStyle.separator, lineWidth: 1))
  }
}

struct LauncherRecordingBadge: View {
  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: "record.circle.fill")
        .font(.system(size: 10, weight: .semibold))
      Text("录入中")
        .font(.system(size: 10, weight: .bold))
    }
    .foregroundStyle(accent)
    .padding(.horizontal, 8)
    .frame(height: 28)
    .background(accent.opacity(0.12), in: Capsule())
    .overlay(Capsule().stroke(accent.opacity(0.25), lineWidth: 1))
  }
}
