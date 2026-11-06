import AppKit
import SwiftUI

struct LauncherOverlayView: View {
  @EnvironmentObject private var model: AppModel
  let onClose: () -> Void
  let onOpen: (LauncherApp) -> Void

  var body: some View {
    LauncherOverlayContent(
      workspace: model.launcherWorkspace, actions: LauncherFeatureActions(model: model),
      onClose: onClose, onOpen: onOpen)
  }
}

struct LauncherOverlayContent: View {
  @ObservedObject var workspace: LauncherWorkspace
  let actions: LauncherFeatureActions
  @FocusState private var searchFocused: Bool
  @FocusState private var pinnedFocusID: String?
  @FocusState private var resultFocusID: String?
  @State private var launcherWidth: CGFloat = 720

  let onClose: () -> Void
  let onOpen: (LauncherApp) -> Void

  private var results: [LauncherApp] {
    Array(workspace.launcherResultApps.prefix(40))
  }

  private var utilityItem: LauncherUtilityItem? {
    workspace.launcherUtilityItem
  }

  private var pinnedItems: [ResolvedLauncherPinnedItem] {
    workspace.launcherPinnedItems
  }

  private var showsPinnedItems: Bool {
    LauncherPinnedPresentation.shouldShowPinnedItems(
      query: workspace.launcherQuery,
      itemCount: pinnedItems.count
    )
  }

  private var pinnedLayout: LauncherPinnedLayout {
    LauncherPinnedLayout(width: launcherWidth)
  }

  var body: some View {
    ZStack {
      Color(nsColor: .windowBackgroundColor)

      VStack(spacing: 0) {
        VStack(spacing: 8) {
          HStack(spacing: 11) {
            Menu {
              ForEach(LauncherSearchEngine.allCases) { engine in
                Button {
                  workspace.setLauncherSearchEngine(engine)
                  searchFocused = true
                } label: {
                  Label(engine.title, systemImage: engine.systemImage)
                }
              }
            } label: {
              Image(systemName: workspace.launcherSearchEngine.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(searchFocused ? accent : muted)
                .frame(width: 26, height: 30)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("搜索引擎：\(workspace.launcherSearchEngine.title)")
            .accessibilityLabel("选择搜索引擎，当前是 \(workspace.launcherSearchEngine.title)")

            TextField(
              "搜索 App 或计算", text: $workspace.launcherQuery
            )
            .textFieldStyle(.plain)
            .font(.system(size: 22, weight: .medium))
            .focused($searchFocused)
            .onSubmit { openFirstResult() }
            .onMoveCommand { direction in
              guard direction == .down, showsPinnedItems, let first = pinnedItems.first else {
                return
              }
              searchFocused = false
              pinnedFocusID = first.id
            }

            if !workspace.launcherQuery.isEmpty {
              Button {
                workspace.launcherQuery = ""
              } label: {
                Image(systemName: "xmark.circle.fill")
                  .font(.system(size: 16, weight: .semibold))
                  .foregroundStyle(muted.opacity(0.72))
              }
              .buttonStyle(.plain)
              .help("清空")
            }
          }
          .padding(.horizontal, 14)
          .frame(height: LauncherPinnedPresentation.searchFieldHeight(for: launcherWidth))
          .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.92),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
              .stroke(
                searchFocused ? accent : AppVisualStyle.separator,
                lineWidth: searchFocused ? 1.5 : 1)
          )

        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 12)

        if showsPinnedItems {
          LauncherPinnedSection(
            workspace: workspace, actions: actions,
            items: pinnedItems,
            layout: pinnedLayout,
            focusedID: $pinnedFocusID,
            focusSearch: {
              pinnedFocusID = nil
              searchFocused = true
            },
            focusNextControl: {
              pinnedFocusID = nil
              DispatchQueue.main.async {
                NSApp.keyWindow?.selectNextKeyView(nil)
              }
            },
            onOpen: { item in
              if let app = item.app {
                onOpen(app)
              } else {
                workspace.reportUnavailableLauncherPinnedItem(item)
              }
            }
          )
        }

        VStack(spacing: 0) {
          if workspace.isLauncherScanning {
            VStack(spacing: 12) {
              ProgressView()
                .controlSize(.small)
              Text("正在扫描本机 App")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else if results.isEmpty && utilityItem == nil {
            VStack(spacing: 12) {
              Image(systemName: "app.dashed")
                .font(.system(size: 38, weight: .bold))
                .foregroundStyle(muted.opacity(0.54))
              Text(workspace.launcherQuery.isEmpty ? "输入一个字母开始搜索" : "没有匹配的 App")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ink)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            ScrollView {
              VStack(spacing: 10) {
                if let utilityItem {
                  LauncherUtilityCard(item: utilityItem, compact: true) {
                    let shouldStayOpen = workspace.launcherCalculatorItem != nil
                    if actions.runUtility(), !shouldStayOpen {
                      onClose()
                    }
                  }
                }

                if workspace.launcherDisplayMode == .list {
                  LazyVStack(spacing: 4) {
                    ForEach(results) { app in
                      LauncherResultRow(workspace: workspace, actions: actions, app: app) {
                        workspace.launcherSelectedResultID = app.id
                        onOpen(app)
                      }
                      .focused($resultFocusID, equals: app.id)
                    }
                  }
                } else {
                  LazyVGrid(
                    columns: [
                      GridItem(.adaptive(minimum: 96, maximum: 132), spacing: 12)
                    ],
                    spacing: 12
                  ) {
                    ForEach(results) { app in
                      LauncherResultGridItem(workspace: workspace, actions: actions, app: app) {
                        workspace.launcherSelectedResultID = app.id
                        onOpen(app)
                      }
                      .focused($resultFocusID, equals: app.id)
                    }
                  }
                }
              }
              .padding(.horizontal, 18)
              .padding(.vertical, 10)
            }
            .scrollIndicators(.automatic)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          }
        }
        .background(Color.clear)
      }
    }
    .overlay(alignment: .bottom) {
      if !workspace.launcherPinnedStatusText.isEmpty {
        Label(workspace.launcherPinnedStatusText, systemImage: "checkmark")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(ink)
          .lineLimit(1)
          .padding(.horizontal, 13)
          .frame(height: 32)
          .background(.regularMaterial, in: Capsule())
          .overlay(Capsule().stroke(AppVisualStyle.separator, lineWidth: 1))
          .shadow(color: Color.black.opacity(0.10), radius: 12, x: 0, y: 5)
          .padding(.bottom, 14)
          .transition(.move(edge: .bottom).combined(with: .opacity))
          .accessibilityLabel("启动器状态，\(workspace.launcherPinnedStatusText)")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background {
      GeometryReader { proxy in
        Color.clear
          .onAppear { launcherWidth = proxy.size.width }
          .onChange(of: proxy.size.width) { launcherWidth = $0 }
      }
    }
    .onAppear {
      workspace.ensureLauncherAppsReady()
      workspace.markLauncherInteractive()
      workspace.markLauncherFirstResultsIfAvailable(source: "cache")
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        searchFocused = true
      }
    }
    .onExitCommand {
      onClose()
    }
    .onChange(of: workspace.launcherQuery) { _ in
      if !workspace.launcherHasEmptyQuery {
        pinnedFocusID = nil
      }
      workspace.launcherSelectedResultID = nil
      workspace.markLauncherFirstResultsIfAvailable(source: "query")
    }
    .onChange(of: workspace.launcherDisplayMode) { _ in
      guard let selectedID = workspace.launcherSelectedResultID else { return }
      DispatchQueue.main.async { resultFocusID = selectedID }
    }
    .onChange(of: resultFocusID) { focusedID in
      if let focusedID {
        workspace.launcherSelectedResultID = focusedID
      }
    }
    .onChange(of: results.map(\.id)) { _ in
      workspace.markLauncherFirstResultsIfAvailable(source: "results")
    }
    .onChange(of: workspace.launcherFocusRequestID) { _ in
      DispatchQueue.main.async {
        pinnedFocusID = nil
        resultFocusID = nil
        searchFocused = true
      }
    }
    .onChange(of: workspace.launcherPinnedStatusText) { message in
      guard !message.isEmpty else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
        workspace.clearLauncherPinnedStatus(ifMatching: message)
      }
    }
    .animation(.easeOut(duration: 0.18), value: workspace.launcherPinnedStatusText)
  }

  private func openFirstResult() {
    let shouldStayOpen = workspace.launcherCalculatorItem != nil
    if actions.runUtility() {
      if !shouldStayOpen {
        onClose()
      }
      return
    }
    if let selectedID = workspace.launcherSelectedResultID,
      let selected = results.first(where: { $0.id == selectedID })
    {
      onOpen(selected)
      return
    }
    guard let first = results.first else { return }
    onOpen(first)
  }
}

struct LauncherPinnedLayout {
  let width: CGFloat

  var isNarrow: Bool { width < 600 }
  var columnCount: Int { LauncherPinnedPresentation.columnCount(for: width) }
  var horizontalPadding: CGFloat { width < 420 ? 14 : (isNarrow ? 16 : (width >= 800 ? 20 : 18)) }
  var columnSpacing: CGFloat { width < 420 ? 6 : (isNarrow ? 8 : (width >= 800 ? 8 : 6)) }
  var rowSpacing: CGFloat { isNarrow ? columnSpacing : 0 }
  var iconSize: CGFloat { width < 420 ? 38 : (isNarrow ? 42 : (width >= 800 ? 50 : 46)) }
  var tileHeight: CGFloat { width < 420 ? 68 : (isNarrow ? 72 : (width >= 800 ? 76 : 72)) }
  var labelSize: CGFloat { isNarrow ? 11 : 12 }
  var sectionHeight: CGFloat { width < 420 ? 154 : (isNarrow ? 160 : (width >= 800 ? 92 : 88)) }
}

struct LauncherPinnedSection: View {
  @ObservedObject var workspace: LauncherWorkspace
  let actions: LauncherFeatureActions

  let items: [ResolvedLauncherPinnedItem]
  let layout: LauncherPinnedLayout
  let focusedID: FocusState<String?>.Binding
  let focusSearch: () -> Void
  let focusNextControl: () -> Void
  let onOpen: (ResolvedLauncherPinnedItem) -> Void

  var body: some View {
    Group {
      if layout.isNarrow {
        LazyVGrid(
          columns: Array(
            repeating: GridItem(.flexible(), spacing: layout.columnSpacing),
            count: layout.columnCount),
          spacing: layout.rowSpacing
        ) {
          pinnedTiles
        }
      } else {
        HStack(spacing: layout.width >= 800 ? 18 : 14) {
          pinnedTiles
        }
        .frame(maxWidth: .infinity)
      }
    }
    .padding(.horizontal, layout.horizontalPadding)
    .padding(.bottom, 4)
    .frame(height: layout.sectionHeight, alignment: .center)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("已固定，\(items.count) 项")
  }

  @ViewBuilder
  private var pinnedTiles: some View {
    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
      LauncherPinnedTile(
        workspace: workspace, actions: actions,
        item: item,
        index: index,
        itemCount: items.count,
        layout: layout,
        focusedID: focusedID,
        focusSearch: focusSearch,
        focusNextControl: focusNextControl,
        onOpen: onOpen
      )
      .frame(width: layout.isNarrow ? nil : (layout.width >= 800 ? 82 : 76))
    }
  }
}

struct LauncherPinnedTile: View {
  @ObservedObject var workspace: LauncherWorkspace
  let actions: LauncherFeatureActions
  @State private var isHovering = false

  let item: ResolvedLauncherPinnedItem
  let index: Int
  let itemCount: Int
  let layout: LauncherPinnedLayout
  let focusedID: FocusState<String?>.Binding
  let focusSearch: () -> Void
  let focusNextControl: () -> Void
  let onOpen: (ResolvedLauncherPinnedItem) -> Void

  private var isFocused: Bool { focusedID.wrappedValue == item.id }
  private var canMoveBackward: Bool { workspace.canMoveLauncherPinnedItem(id: item.id, offset: -1) }
  private var canMoveForward: Bool { workspace.canMoveLauncherPinnedItem(id: item.id, offset: 1) }

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Button {
        onOpen(item)
      } label: {
        VStack(spacing: 5) {
          Group {
            if let app = item.app {
              PlainLauncherAppIcon(app: app, size: layout.iconSize)
            } else if let systemImageName = item.systemImageName {
              Image(systemName: systemImageName)
                .font(.system(size: layout.iconSize * 0.64, weight: .medium))
                .foregroundStyle(violet)
            } else {
              Image(systemName: "questionmark.app.dashed")
                .font(.system(size: layout.iconSize * 0.70, weight: .medium))
                .foregroundStyle(muted)
            }
          }
          .frame(width: layout.iconSize, height: layout.iconSize)
          .saturation(item.isAvailable ? 1 : 0)
          .opacity(item.isAvailable ? 1 : 0.45)

          if workspace.launcherShowsPinnedNames || !item.isAvailable {
            Text(item.isAvailable ? item.name : "\(item.name) · 已不可用")
              .foregroundStyle(item.isAvailable ? ink : ruby)
              .font(.system(size: layout.labelSize, weight: .medium))
              .lineLimit(1)
              .truncationMode(.tail)
          }
        }
        .padding(.horizontal, 3)
        .frame(maxWidth: .infinity, minHeight: layout.tileHeight, maxHeight: layout.tileHeight)
        .background(
          (isHovering || isFocused) ? Color.primary.opacity(0.050) : Color.clear,
          in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(isFocused ? Color.accentColor.opacity(0.72) : Color.clear, lineWidth: 1.5)
        )
        .scaleEffect(isHovering ? 1.04 : 1)
      }
      .buttonStyle(LauncherPinnedButtonStyle())
      .focused(focusedID, equals: item.id)
      .help(item.name)
      .accessibilityLabel(accessibilityLabel)
      .accessibilityHint(accessibilityHint)
      .accessibilityActions {
        Button("取消固定") { workspace.unpinLauncherItem(id: item.id) }
        if canMoveBackward {
          Button("向前移动") { workspace.moveLauncherPinnedItem(id: item.id, offset: -1) }
        }
        if canMoveForward {
          Button("向后移动") { workspace.moveLauncherPinnedItem(id: item.id, offset: 1) }
        }
      }
      .onMoveCommand(perform: moveFocus)
      .onHover { isHovering = $0 }
      .animation(.easeOut(duration: 0.14), value: isHovering)
      .draggable(item.id)
      .dropDestination(for: String.self) { values, _ in
        guard let sourceID = values.first else { return false }
        workspace.moveLauncherPinnedItem(id: sourceID, before: item.id)
        return true
      }
      .contextMenu { pinnedMenuContent }

      Menu {
        pinnedMenuContent
      } label: {
        Image(systemName: "ellipsis.circle")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(muted)
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .opacity(isHovering || isFocused ? 0.92 : 0.001)
      .help("\(item.name) 更多操作")
      .accessibilityLabel("\(item.name) 更多操作")
    }
  }

  @ViewBuilder
  private var pinnedMenuContent: some View {
    if let app = item.app {
      Button {
        actions.editShortcut(app)
      } label: {
        Label(
          actions.shortcut(app) == nil ? "设置快捷键…" : "修改快捷键…", systemImage: "keyboard")
      }
      Divider()
    }
    Button {
      workspace.unpinLauncherItem(id: item.id)
    } label: {
      Label(item.isAvailable ? "取消固定" : "移除固定", systemImage: "pin.slash")
    }

    if item.isAvailable {
      Divider()
      Button {
        workspace.moveLauncherPinnedItem(id: item.id, offset: -1)
      } label: {
        Label("向前移动", systemImage: "arrow.left")
      }
      .disabled(!canMoveBackward)

      Button {
        workspace.moveLauncherPinnedItem(id: item.id, offset: 1)
      } label: {
        Label("向后移动", systemImage: "arrow.right")
      }
      .disabled(!canMoveForward)
    }
  }

  private var accessibilityLabel: String {
    if item.isAvailable {
      return "\(item.name)，\(item.kindLabel)，已固定，第 \(index + 1) 项，共 \(itemCount) 项"
    }
    return "\(item.name)，已不可用，已固定，第 \(index + 1) 项，共 \(itemCount) 项"
  }

  private var accessibilityHint: String {
    item.isAvailable
      ? "按下以打开；使用操作菜单取消固定或调整顺序。"
      : "已不可用，可使用操作菜单移除固定。"
  }

  private func moveFocus(_ direction: MoveCommandDirection) {
    let columns = layout.columnCount
    let target: Int?
    switch direction {
    case .left:
      target = index % columns == 0 ? nil : index - 1
    case .right:
      target = (index + 1) % columns == 0 ? nil : index + 1
    case .up:
      if index >= columns {
        target = index - columns
      } else {
        focusSearch()
        return
      }
    case .down:
      let candidate = index + columns
      if candidate < itemCount {
        target = candidate
      } else {
        focusNextControl()
        return
      }
    default:
      target = nil
    }
    guard let target, itemsIndexContains(target) else { return }
    focusedID.wrappedValue = workspace.launcherPinnedItems[target].id
  }

  private func itemsIndexContains(_ candidate: Int) -> Bool {
    candidate >= 0 && candidate < itemCount
  }
}

struct LauncherPinnedButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.82 : 1)
  }
}

struct LauncherResultRow: View {
  @ObservedObject var workspace: LauncherWorkspace
  let actions: LauncherFeatureActions
  @State private var isHovering = false
  let app: LauncherApp
  let action: () -> Void

  private var shortcut: LauncherAppShortcut? {
    actions.shortcut(app)
  }

  private var isRecordingShortcut: Bool {
    actions.isRecordingShortcut(app)
  }

  private var isPinned: Bool {
    workspace.isLauncherAppPinned(app)
  }

  private var helpText: String {
    guard let shortcut else { return app.name }
    return "\(app.name) · \(shortcut.hotkey)"
  }

  private var accessibilityText: String {
    guard let shortcut else { return "\(app.name)，App" }
    return "\(app.name)，App，快捷键 \(shortcut.hotkey)"
  }

  private var pinnedActionTitle: String {
    isPinned ? "取消固定" : "固定到启动器"
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        PlainLauncherAppIcon(app: app, size: 38)

        VStack(alignment: .leading, spacing: 3) {
          Text(app.name)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(ink)
            .lineLimit(1)

          if isRecordingShortcut {
            Text("按下组合键")
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(accent)
              .lineLimit(1)
          }
        }

        Spacer(minLength: 8)

        if isRecordingShortcut {
          LauncherRecordingBadge()
        }
      }
      .padding(.horizontal, 12)
      .frame(height: 52)
      .background(
        isHovering ? AppVisualStyle.hover : Color.clear,
        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .animation(.easeOut(duration: 0.14), value: isHovering)
    .help(helpText)
    .accessibilityLabel(accessibilityText)
    .accessibilityAction(named: pinnedActionTitle) {
      if isPinned {
        workspace.unpinLauncherApp(app)
      } else {
        workspace.pinLauncherApp(app)
      }
    }
    .contextMenu {
      Button {
        if isPinned {
          workspace.unpinLauncherApp(app)
        } else {
          workspace.pinLauncherApp(app)
        }
      } label: {
        Label(isPinned ? "取消固定" : "固定到启动器", systemImage: isPinned ? "pin.slash" : "pin")
      }

      Divider()

      Button {
        actions.editShortcut(app)
      } label: {
        Label(
          actions.shortcut(app) == nil ? "设置快捷键…" : "修改快捷键…", systemImage: "keyboard")
      }

      Divider()

      Button(role: .destructive) {
        actions.uninstall(app)
      } label: {
        Label {
          Text("卸载 App…")
            .foregroundColor(ruby)
        } icon: {
          Image(systemName: "trash")
            .foregroundColor(ruby)
        }
      }
    }
  }

}

struct LauncherResultGridItem: View {
  @ObservedObject var workspace: LauncherWorkspace
  let actions: LauncherFeatureActions
  @State private var isHovering = false

  let app: LauncherApp
  let action: () -> Void

  private var shortcut: LauncherAppShortcut? {
    actions.shortcut(app)
  }

  private var isRecordingShortcut: Bool {
    actions.isRecordingShortcut(app)
  }

  private var isPinned: Bool {
    workspace.isLauncherAppPinned(app)
  }

  private var helpText: String {
    guard let shortcut else { return app.name }
    return "\(app.name) · \(shortcut.hotkey)"
  }

  private var accessibilityText: String {
    guard let shortcut else { return "\(app.name)，App" }
    return "\(app.name)，App，快捷键 \(shortcut.hotkey)"
  }

  private var pinnedActionTitle: String {
    isPinned ? "取消固定" : "固定到启动器"
  }

  var body: some View {
    Button(action: action) {
      VStack(spacing: 8) {
        PlainLauncherAppIcon(app: app, size: 56)

        Text(app.name)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(ink)
          .lineLimit(1)
          .truncationMode(.tail)

        if isRecordingShortcut {
          Text("按下组合键")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(accent)
            .lineLimit(1)
        }
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 7)
      .frame(
        maxWidth: .infinity,
        minHeight: isRecordingShortcut ? 108 : 92,
        maxHeight: isRecordingShortcut ? 108 : 92
      )
      .background(
        isHovering ? Color.primary.opacity(0.055) : Color.clear,
        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(
            isRecordingShortcut ? accent.opacity(0.58) : Color.clear,
            lineWidth: isRecordingShortcut ? 1.5 : 0)
      )
      .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      .scaleEffect(isHovering ? 1.035 : 1)
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .animation(.easeOut(duration: 0.14), value: isHovering)
    .help(helpText)
    .accessibilityLabel(accessibilityText)
    .accessibilityAction(named: pinnedActionTitle) {
      if isPinned {
        workspace.unpinLauncherApp(app)
      } else {
        workspace.pinLauncherApp(app)
      }
    }
    .contextMenu {
      Button {
        if isPinned {
          workspace.unpinLauncherApp(app)
        } else {
          workspace.pinLauncherApp(app)
        }
      } label: {
        Label(isPinned ? "取消固定" : "固定到启动器", systemImage: isPinned ? "pin.slash" : "pin")
      }

      Divider()

      Button {
        actions.editShortcut(app)
      } label: {
        Label(
          actions.shortcut(app) == nil ? "设置快捷键…" : "修改快捷键…", systemImage: "keyboard")
      }

      Divider()

      Button(role: .destructive) {
        actions.uninstall(app)
      } label: {
        Label("卸载 App…", systemImage: "trash.slash")
      }
    }
  }
}
