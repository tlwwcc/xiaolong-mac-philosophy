import AppKit
import MacFeatureCatalog
import SwiftUI

typealias ApplicationCenterMode = ProductFeatureMode

/// Static product facts are shared with CLI; only live presentation belongs to the UI.
struct ApplicationCenterItem: Identifiable {
  let feature: ProductFeatureDescriptor
  let tint: Color
  let statusText: String?
  let statusImage: String
  let statusColor: Color
  let isEnabled: Binding<Bool>?

  var id: String { feature.id }
  var name: String { feature.name }
  var purpose: String { feature.purpose }
  var valueDescription: String { feature.valueDescription }
  var assetName: String? { feature.assetName }
  var systemImage: String { feature.systemImage }
  var category: String { feature.category.title }
  var mode: ApplicationCenterMode { feature.mode }
  var isFeatured: Bool { feature.isFeatured }
}

struct ApplicationCenterIcon: View {
  let item: ApplicationCenterItem
  let size: CGFloat

  private var bundledImage: NSImage? {
    guard let assetName = item.assetName,
      let url = Bundle.main.url(forResource: assetName, withExtension: "png")
    else { return nil }
    return NSImage(contentsOf: url)
  }

  var body: some View {
    Group {
      if let bundledImage {
        Image(nsImage: bundledImage)
          .resizable()
          .interpolation(.high)
          .renderingMode(.original)
          .scaledToFit()
          .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
          .shadow(color: Color.black.opacity(0.10), radius: size * 0.08, x: 0, y: size * 0.04)
      } else {
        Image(systemName: item.systemImage)
          .font(.system(size: size * 0.50, weight: .semibold))
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(item.tint)
          .frame(width: size, height: size)
          .background(
            item.tint.opacity(0.09),
            in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
          )
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

struct PluginCenterView: View {
  @EnvironmentObject private var model: AppModel
  @AppStorage("processViewerPluginEnabledV1") private var processViewerPluginEnabled = true
  @AppStorage("codexNetworkProbePluginEnabledV1") private var codexNetworkProbePluginEnabled = true
  @FocusState private var searchFocused: Bool
  private var searchText: String {
    get { model.mainWorkspace.applicationSearchText }
    nonmutating set { model.mainWorkspace.applicationSearchText = newValue }
  }
  private var category: String {
    get { model.mainWorkspace.applicationCategory }
    nonmutating set { model.mainWorkspace.applicationCategory = newValue }
  }
  private var searchBinding: Binding<String> {
    Binding(get: { searchText }, set: { searchText = $0 })
  }
  private var categoryBinding: Binding<String> {
    Binding(get: { category }, set: { category = $0 })
  }

  var requestedSelectionID: String? = nil

  private var allItems: [ApplicationCenterItem] {
    ProductFeatureCatalog.all.map { feature in
      let presentation = runtimePresentation(for: feature.id)
      return ApplicationCenterItem(
        feature: feature,
        tint: presentation.tint,
        statusText: presentation.statusText,
        statusImage: presentation.statusImage,
        statusColor: presentation.statusColor,
        isEnabled: presentation.isEnabled)
    }
  }

  private struct RuntimePresentation {
    var tint: Color = accent
    var statusText: String? = nil
    var statusImage = "arrow.up.right.square.fill"
    var statusColor: Color = accent
    var isEnabled: Binding<Bool>? = nil
  }

  private func runtimePresentation(for id: String) -> RuntimePresentation {
    switch id {
    case applicationYoumuID, applicationPijuanPDFID:
      return RuntimePresentation(tint: AppVisualStyle.accent)
    case "caps-core":
      return RuntimePresentation(
        tint: accent, statusText: capsStatusText, statusImage: capsStatusImage,
        statusColor: capsStatusColor,
        isEnabled: Binding(
          get: { model.capsCorePluginEnabled },
          set: { model.setCapsCorePluginEnabled($0) }))
    case AppModel.launcherPluginID:
      return RuntimePresentation(
        tint: indigo, statusText: launcherStatusText,
        statusImage: "exclamationmark.triangle.fill", statusColor: amber,
        isEnabled: Binding(
          get: { model.launcherPluginEnabled },
          set: { model.setLauncherPluginEnabled($0) }))
    case applicationPhrasesID:
      return RuntimePresentation(
        tint: violet, statusText: "\(model.phrases.count) 条短语",
        statusImage: "text.badge.checkmark", statusColor: muted)
    case applicationClipboardHistoryID:
      return RuntimePresentation(
        tint: accent, statusText: clipboardHistoryStatusText,
        statusImage: clipboardHistoryStatusImage, statusColor: clipboardHistoryStatusColor,
        isEnabled: Binding(
          get: { model.clipboardHistory.isEnabled },
          set: { model.clipboardHistory.setEnabled($0) }))
    case "mouse-scroll":
      return RuntimePresentation(
        tint: indigo, statusText: mouseScrollStatusText,
        statusImage: "lock.trianglebadge.exclamationmark", statusColor: amber,
        isEnabled: Binding(
          get: { model.scrollSettings.enabled },
          set: { model.setScrollEngineEnabled($0) }))
    case "mouse-volume":
      return RuntimePresentation(
        tint: violet, statusText: mouseVolumeStatusText,
        statusImage: "lock.trianglebadge.exclamationmark", statusColor: amber,
        isEnabled: Binding(
          get: { model.mouseVolumePluginEnabled },
          set: { model.setMouseVolumePluginEnabled($0) }))
    case "process-viewer":
      return RuntimePresentation(tint: teal)
    case "codex-network-probe":
      return RuntimePresentation(tint: indigo)
    case "sleep":
      return RuntimePresentation(
        tint: violet, statusText: model.keepAwakeEnabled ? model.keepAwakeStatusText : nil,
        statusImage: "moon.zzz.fill", statusColor: teal)
    default:
      return RuntimePresentation()
    }
  }

  private var visibleItems: [ApplicationCenterItem] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    return allItems.filter { item in
      let categoryMatches = category == "全部" || item.category == category
      return categoryMatches
        && (query.isEmpty
          || item.name.localizedCaseInsensitiveContains(query)
          || item.purpose.localizedCaseInsensitiveContains(query)
          || item.valueDescription.localizedCaseInsensitiveContains(query)
          || item.mode.title.localizedCaseInsensitiveContains(query))
    }
  }

  private var categories: [String] {
    ["全部"] + ProductFeatureCatalog.categories.map(\.title)
  }

  private var selectedItem: ApplicationCenterItem? {
    guard let selectedID = model.selectedPluginID else { return nil }
    return allItems.first(where: { $0.id == selectedID })
  }

  var body: some View {
    HSplitView {
      overviewList
        .frame(minWidth: 240, idealWidth: 280, maxWidth: 320)
      Group {
        if let selectedItem {
          applicationDetail(item: selectedItem)
        } else {
          ApplicationCenterOverviewView(
            featuredItems: allItems.filter(\.isFeatured),
            selectFeatureShortcuts: { model.selectedModuleName = moduleHotkeys },
            select: { model.selectPlugin(id: $0) })
        }
      }
      .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
    }
    .toolbar {
      if selectedItem != nil {
        ToolbarItem(placement: .navigation) {
          Button {
            model.selectPlugin(id: nil)
          } label: {
            Label("返回应用中心", systemImage: "chevron.backward")
          }
          .keyboardShortcut("[", modifiers: .command)
          .help("返回应用中心")
        }
      }
    }
    .background {
      Button("搜索应用中心") {
        model.selectPlugin(id: nil)
        searchFocused = true
      }
      .keyboardShortcut("f", modifiers: .command)
      .hidden()
    }
    .background(Color(nsColor: .controlBackgroundColor))
    .onAppear {
      applyRequestedSelection()
      if model.selectedPluginID != nil && selectedItem == nil {
        model.selectPlugin(id: nil)
      }
    }
    .onChange(of: requestedSelectionID) { _ in
      applyRequestedSelection()
    }
    .onReceive(model.clipboardHistory.objectWillChange) { _ in
      model.objectWillChange.send()
    }
  }

  private var overviewList: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("应用中心")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.primary)
          Spacer(minLength: 4)
          Text("\(allItems.count) 项")
            .font(.caption.monospacedDigit())
            .foregroundStyle(AppVisualStyle.textSecondary)
        }
        WorkspaceSearchField(
          placeholder: "搜索应用或功能", text: searchBinding,
          focus: $searchFocused, accessibilityName: "搜索应用中心")
        HStack {
          Picker("应用分类", selection: categoryBinding) {
            ForEach(categories, id: \.self) { Text($0).tag($0) }
          }
          .labelsHidden()
          .controlSize(.small)
          .accessibilityLabel("应用分类")
          Spacer(minLength: 4)
          if category != "全部" || !searchText.isEmpty {
            Button("清除筛选") { clearFilters() }
              .buttonStyle(.plain)
              .font(.caption)
              .foregroundStyle(AppVisualStyle.accent)
          }
        }
      }
      .padding(16)

      Divider()

      if visibleItems.isEmpty {
        WorkspaceEmptyState(
          systemImage: "magnifyingglass", title: "没有找到匹配的应用",
          detail: "换个关键词，或查看全部应用。",
          actionTitle: "查看全部应用", action: clearFilters
        )
        .frame(maxHeight: .infinity)
      } else {
        ScrollViewReader { reader in
          List {
            ForEach(categories.filter { $0 != "全部" }, id: \.self) { group in
              let items = visibleItems.filter { $0.category == group }
              if !items.isEmpty {
                Section(group) {
                  ForEach(items) { item in
                    ApplicationCenterOverviewRow(item: item, selected: model.selectedPluginID == item.id) {
                      model.selectPlugin(id: item.id)
                    }
                    .id(item.id)
                  }
                }
              }
            }
          }
          .listStyle(.inset)
          .onAppear {
            if let anchor = model.pluginCenterScrollAnchorID {
              reader.scrollTo(anchor, anchor: .center)
            }
          }
          .accessibilityIdentifier("applications.catalog")
        }
      }
    }
    .background(AppVisualStyle.background)
  }

  private func clearFilters() {
    searchText = ""
    category = "全部"
  }

  @ViewBuilder
  private func applicationDetail(item: ApplicationCenterItem) -> some View {
    VStack(spacing: 0) {
      ApplicationCenterDetailHeader(item: item) {
        model.selectPlugin(id: nil)
      }
      Divider()

      switch item.id {
      case applicationYoumuID:
        YoumuApplicationDetailView()
      case applicationPijuanPDFID:
        PijuanApplicationDetailView()
      case applicationPhrasesID:
        PhrasePanelView()
      case applicationClipboardHistoryID:
        ClipboardHistoryApplicationDetailView(
          controller: model.clipboardHistory,
          openHistory: { model.showClipboardHistory() },
          openShortcutSettings: {
            model.openShortcutManager(action: .showClipboardHistory)
          })
      case AppModel.launcherPluginID:
        LauncherPluginDetailView()
      case "process-viewer":
        OnDemandApplicationDetailView(
          productName: item.name,
          headline: "查看运行状态",
          description: "查看 CPU、内存和交换空间；关闭窗口后停止刷新。"
        ) {
          processViewerPluginEnabled = true
          model.showProcessViewer()
        }
      case "codex-network-probe":
        NetworkProbeApplicationDetailView {
          codexNetworkProbePluginEnabled = true
          model.showCodexNetworkProbe()
        }
      default:
        ScrollView {
          Group {
            switch item.id {
            case "caps-core": CapsCorePluginCard()
            case "mouse-scroll": MouseScrollPluginCard()
            case "mouse-volume": MouseVolumePluginCard()
            case "network-speed": NetworkSpeedPluginCard()
            case "sleep": SleepPluginCard()
            default:
              Text("这个应用入口暂时不可用。")
                .foregroundStyle(muted)
            }
          }
          .padding(16)
          .frame(maxWidth: .infinity, alignment: .topLeading)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func applyRequestedSelection() {
    guard let requestedSelectionID else { return }
    guard allItems.contains(where: { $0.id == requestedSelectionID }) else { return }
    model.selectPlugin(id: requestedSelectionID)
  }

  private var launcherStatusText: String? {
    guard model.launcherPluginEnabled else { return nil }
    return model.launcherHotkeySummary == "Caps + Space" ? nil : "需要处理"
  }

  private var capsStatusText: String? {
    guard model.capsCorePluginEnabled else { return nil }
    if !model.authorizationPermissionsComplete { return "需要授权" }
    switch model.capsCorePluginStatus {
    case .running: return nil
    case .stopped, .paused: return "需要处理"
    case .waitingForPermission: return "需要授权"
    case .conflict(let conflict): return conflict.displayText
    case .failed: return "失败，可重试"
    }
  }

  private var capsStatusImage: String {
    if !model.authorizationPermissionsComplete { return "lock.trianglebadge.exclamationmark" }
    if case .waitingForPermission = model.capsCorePluginStatus {
      return "lock.trianglebadge.exclamationmark"
    }
    return "exclamationmark.triangle.fill"
  }

  private var capsStatusColor: Color {
    switch model.capsCorePluginStatus {
    case .conflict, .failed: return ruby
    default: return amber
    }
  }

  private var mouseScrollStatusText: String? {
    guard model.scrollSettings.enabled, !model.scrollEngineRunning else { return nil }
    return model.advancedListeningAuthorized ? "需要处理" : "需要授权"
  }

  private var mouseVolumeStatusText: String? {
    guard model.mouseVolumePluginEnabled, !model.scrollEngineRunning else { return nil }
    return model.advancedListeningAuthorized ? "需要处理" : "需要授权"
  }

  private var clipboardHistoryStatusText: String? {
    if !model.clipboardHistory.isEnabled { return "已暂停" }
    if model.clipboardHistory.quotaBlocked { return "空间已满" }
    if model.clipboardHistory.statusMessage?.hasPrefix("保存失败") == true {
      return "保存失败"
    }
    if model.clipboardHistory.pendingDeletionBytes > 0 { return "正在清理" }
    return nil
  }

  private var clipboardHistoryStatusImage: String {
    if model.clipboardHistory.quotaBlocked {
      return "externaldrive.badge.exclamationmark"
    }
    if model.clipboardHistory.statusMessage?.hasPrefix("保存失败") == true {
      return "exclamationmark.triangle.fill"
    }
    if model.clipboardHistory.pendingDeletionBytes > 0 {
      return "arrow.triangle.2.circlepath"
    }
    return "pause.circle.fill"
  }

  private var clipboardHistoryStatusColor: Color {
    if model.clipboardHistory.quotaBlocked
      || model.clipboardHistory.statusMessage?.hasPrefix("保存失败") == true
    {
      return ruby
    }
    if model.clipboardHistory.pendingDeletionBytes > 0 { return amber }
    return amber
  }
}
