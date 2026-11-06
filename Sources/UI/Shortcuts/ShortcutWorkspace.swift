import AppKit
import SwiftUI

struct ShortcutEditorPresentation: Identifiable {
  let id = UUID()
  let itemID: String?
  let draft: ShortcutItem
}

struct ShortcutSemanticMigrationPanel: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if model.shortcutSemanticNeedsAttention {
        Text("快捷键需要你确认")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(ink)
        Text("为了让启动和系统搜索各归其位，来源不明的占用不会被自动覆盖。")
          .font(.system(size: 12))
          .foregroundStyle(muted)
      }

      if model.shortcutSemanticCapsDecisionPending {
        semanticConflictRow(
          hotkey: "Caps + Space",
          conflicts: model.shortcutSemanticAnalysis.capsSpaceConflicts,
          primaryTitle: "改为启动器",
          primaryAction: model.adoptCapsSpaceForLauncher,
          secondaryTitle: "保留现状",
          secondaryAction: model.keepCurrentCapsSpaceBehavior)
      }

      if model.shortcutSemanticCommandDecisionPending {
        semanticConflictRow(
          hotkey: "Command + Space",
          conflicts: model.shortcutSemanticAnalysis.commandSpaceConflicts,
          primaryTitle: "交还系统搜索",
          primaryAction: model.returnCommandSpaceToSystem,
          secondaryTitle: "保留现状",
          secondaryAction: model.keepCurrentCommandSpaceBehavior)
      }

      if !model.shortcutSemanticMigrationMessage.isEmpty {
        Text(model.shortcutSemanticMigrationMessage)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(indigo)
          .fixedSize(horizontal: false, vertical: true)
      }

      if model.lastShortcutSemanticBackupURL != nil {
        HStack(spacing: 12) {
          Button("查看备份") { model.openShortcutSemanticBackup() }
            .buttonStyle(.link)
          Button("撤销本次迁移") { model.undoLatestShortcutSemanticMigration() }
            .buttonStyle(.link)
        }
        .font(.system(size: 12, weight: .medium))
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(AppVisualStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(AppVisualStyle.separator, lineWidth: 1)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("快捷键迁移状态")
  }

  private func semanticConflictRow(
    hotkey: String,
    conflicts: [ShortcutItem],
    primaryTitle: String,
    primaryAction: @escaping () -> Void,
    secondaryTitle: String,
    secondaryAction: @escaping () -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(hotkey)
        .font(.system(size: 13, weight: .semibold, design: .rounded))
        .foregroundStyle(ink)
      ForEach(conflicts) { item in
        VStack(alignment: .leading, spacing: 2) {
          Text("当前：\(item.name.isEmpty ? "未知快捷键占用" : item.name)")
          Text("动作：\(item.action.rawValue)\(item.target.isEmpty ? "" : " · \(item.target)")")
          Text("来源：无法确认，按用户自定义保护")
        }
        .font(.system(size: 11))
        .foregroundStyle(muted)
        .fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: 10) {
        Button(primaryTitle, action: primaryAction)
          .buttonStyle(.borderedProminent)
          .tint(AppVisualStyle.emphasizedSelection)
        Button(secondaryTitle, action: secondaryAction)
          .buttonStyle(.bordered)
      }
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(hotkey)，发现 \(conflicts.count) 个受保护占用")
  }
}

struct ShortcutUnifiedPanelView: View {
  @EnvironmentObject private var model: AppModel
  @FocusState private var searchFocused: Bool
  private var searchText: String {
    get { model.mainWorkspace.shortcutSearchText }
    nonmutating set { model.mainWorkspace.shortcutSearchText = newValue }
  }
  private var selectedCategory: String {
    get { model.mainWorkspace.shortcutCategory }
    nonmutating set { model.mainWorkspace.shortcutCategory = newValue }
  }
  private var searchBinding: Binding<String> {
    Binding(get: { searchText }, set: { searchText = $0 })
  }
  private var categoryBinding: Binding<String> {
    Binding(get: { selectedCategory }, set: { selectedCategory = $0 })
  }
  @State private var selectedGuideEntryID: String?
  @State private var shortcutEditorPresentation: ShortcutEditorPresentation?

  private var currentEntries: [ShortcutGuideEntry] {
    model.items.enumerated().map {
      ShortcutGuideEntry(kind: .current(index: $0.offset, item: $0.element))
    }
  }

  private var filteredCurrentEntries: [ShortcutGuideEntry] {
    return currentEntries.filter { entry in
      (selectedCategory == "全部" || entry.category == selectedCategory)
        && entry.matches(searchText)
    }
  }

  private var visibleEntries: [ShortcutGuideEntry] {
    filteredCurrentEntries
  }

  private var isPijuanPDFCategory: Bool {
    selectedCategory == "PDF类"
  }

  var body: some View {
    VStack(spacing: 12) {
      if model.shortcutSemanticNeedsAttention || !model.shortcutSemanticMigrationMessage.isEmpty {
        ShortcutSemanticMigrationPanel()
      }
      if shouldShowStatusBanner {
        ShortcutStatusBanner()
      }
      if let notice = model.shortcutRecordingConflictNotice {
        ShortcutRecordingConflictBanner(notice: notice)
      }
      searchAndCategories

      VStack(spacing: 10) {
        if isPijuanPDFCategory {
          if let settingsView = model.makePijuanPDFShortcutSettingsView() {
            settingsView
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            WorkspaceEmptyState(
              systemImage: "doc.richtext", title: "PDF 设置暂未就绪",
              detail: "可先从应用中心打开PDF 浏览器，再回来调整快捷键。"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        } else if visibleEntries.isEmpty && hasActiveFilters {
          WorkspaceEmptyState(
            systemImage: "magnifyingglass", title: "没有匹配的快捷键",
            detail: "换个关键词，或清除筛选查看全部快捷键。",
            actionTitle: "清除筛选"
          ) {
            searchText = ""
            selectedCategory = "全部"
            searchFocused = true
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ShortcutTableView(
            selectedModule: moduleHotkeys,
            itemIDs: filteredCurrentEntries.compactMap { $0.shortcutItem?.id },
            viewportKey: selectedCategory + "\n" + searchText,
            editShortcut: beginEditingShortcut
          )
          .layoutPriority(1)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .toolbar {
      ToolbarItemGroup { unifiedActions }
    }
    .background {
      Button("搜索快捷键") {
        if isPijuanPDFCategory { selectedCategory = "全部" }
        searchFocused = true
      }
      .keyboardShortcut("f", modifiers: .command)
      .hidden()
    }
    .onAppear {
      syncSelectedEntry()
    }
    .onChange(of: model.shortcutGuideFocusRequest) { _ in
      applyShortcutGuideRoute()
      focusSearchSoon()
    }
    .onChange(of: model.shortcutCreateRequestID) { _ in
      beginAddingShortcut()
    }
    .onChange(of: selectedCategory) { _ in
      if isPijuanPDFCategory {
        searchText = ""
      }
      syncSelectedEntry()
    }
    .sheet(item: $shortcutEditorPresentation) { presentation in
      ShortcutEditorSheet(presentation: presentation)
        .environmentObject(model)
    }
  }

  private var shouldShowStatusBanner: Bool {
    model.isPaused || !model.advancedListeningAuthorized || !model.hotkeyFailures.isEmpty
  }

  private var unifiedHeader: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: 14) {
        unifiedOverview
        Spacer(minLength: 12)
        unifiedActions
      }

      VStack(alignment: .leading, spacing: 12) {
        unifiedOverview
        unifiedActions
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
    .padding(.horizontal, 2)
    .padding(.vertical, 4)
  }

  private var unifiedActions: some View {
    HStack(spacing: 8) {
      Button {
        model.presentSoftwareShortcutEditor()
      } label: {
        Label("添加软件快捷键", systemImage: "plus.app")
      }
      .buttonStyle(.borderedProminent)
      .tint(AppVisualStyle.emphasizedSelection)
      .help("先选软件，再按下你想用的快捷键")
      if model.deletedDefaultShortcutCount > 0 {
        Button {
          model.restoreDeletedDefaultShortcuts()
        } label: {
          Label(
            "恢复已删除（\(model.deletedDefaultShortcutCount)）",
            systemImage: "arrow.uturn.backward.circle")
        }
        .buttonStyle(GlassLabelButtonStyle(tint: muted))
        .fixedSize()
        .help("只恢复已删除的默认快捷键；用户自定义规则保持不变")
        .accessibilityLabel("恢复已删除的默认快捷键")
      }
      PrimaryAddShortcutMenu(addShortcut: beginAddingShortcut)
    }
  }

  private var unifiedOverview: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 12) {
        Text("快捷键")
          .font(.system(size: 20, weight: .semibold))
          .foregroundStyle(ink)
        Button {
          model.presentCommunityQRCode()
        } label: {
          Text("交流群")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(AppVisualStyle.accent)
        }
        .buttonStyle(.plain)
        .help("显示交流群二维码")
        .accessibilityLabel("加入交流群，显示入群二维码")
      }
      Text("在一个地方管理截图、PDF 浏览器与 Mac 操作")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(muted)
    }
  }

  private var hasActiveFilters: Bool {
    selectedCategory != "全部" || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var searchAndCategories: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        if isPijuanPDFCategory {
          Label("PDF 浏览器内置快捷键可点击改键，不能删除。", systemImage: "doc.richtext")
            .font(.system(size: 12))
            .foregroundStyle(muted)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        } else {
          WorkspaceSearchField(
            placeholder: searchPlaceholder, text: searchBinding,
            focus: $searchFocused, accessibilityName: "搜索快捷键")
        }
        resultSummary
      }

      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) {
          categorySegmentBar
          Spacer(minLength: 0)
        }
        HStack(spacing: 12) {
          categoryPicker
            .pickerStyle(.menu)
          Spacer(minLength: 0)
        }
      }
    }
  }

  private var categorySegmentBar: some View {
    HStack(spacing: 3) {
      ForEach(shortcutGuideCategories, id: \.self) { category in
        let selected = selectedCategory == category
        Button {
          selectedCategory = category
        } label: {
          Text(shortcutGuideCategoryDisplayName(category))
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            .foregroundStyle(ink)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
              selected ? AppVisualStyle.selection : Color.clear,
              in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(shortcutGuideCategoryDisplayName(category))分类")
        .accessibilityValue(selected ? "已选" : "未选")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("shortcutCategory.\(category)")
      }
    }
    .padding(3)
    .fixedSize(horizontal: true, vertical: false)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("快捷键分类")
  }

  private var categoryPicker: some View {
    Picker("快捷键分类", selection: categoryBinding) {
      ForEach(shortcutGuideCategories, id: \.self) { category in
        Text(shortcutGuideCategoryDisplayName(category)).tag(category)
      }
    }
    .labelsHidden()
  }

  private var resultSummary: some View {
    Text(
      isPijuanPDFCategory
        ? "PDF 阅读"
        : (searchText.isEmpty ? "\(visibleEntries.count) 条" : "找到 \(visibleEntries.count) 条")
    )
    .font(.system(size: 11, weight: .medium))
    .foregroundStyle(muted)
    .fixedSize()
  }

  private var searchPlaceholder: String {
    selectedCategory == "截图类" ? "搜索截图、翻译、OCR 或按键" : "搜索功能、按键、分类或说明"
  }

  private func beginAddingShortcut() {
    searchText = ""
    selectedCategory = "全部"
    model.cancelRecordingIfNeeded()
    shortcutEditorPresentation = ShortcutEditorPresentation(
      itemID: nil,
      draft: model.makeShortcutDraft(module: moduleHotkeys))
  }

  private func beginEditingShortcut(itemID: String) {
    guard let item = model.items.first(where: { $0.id == itemID }) else { return }
    if item.action == .openApp, model.canChangeShortcutAction(id: itemID) {
      model.presentSoftwareShortcutEditor(item: item)
      return
    }
    model.cancelRecordingIfNeeded()
    model.selectedID = itemID
    shortcutEditorPresentation = ShortcutEditorPresentation(itemID: itemID, draft: item)
  }

  private func applyShortcutGuideRoute() {
    selectedCategory =
      shortcutGuideCategories.contains(model.shortcutGuideRequestedCategory)
      ? model.shortcutGuideRequestedCategory : "全部"
    searchText = selectedCategory == "PDF类" ? "" : model.shortcutGuideRequestedSearchText
    syncSelectedEntry()
  }

  private func syncSelectedEntry() {
    if let selectedGuideEntryID,
      visibleEntries.contains(where: { $0.id == selectedGuideEntryID })
    {
      return
    }
    selectedGuideEntryID = visibleEntries.first?.id
  }

  private func focusSearchSoon() {
    searchFocused = true
  }
}

struct ShortcutRecordingConflictBanner: View {
  @EnvironmentObject private var model: AppModel
  let notice: ShortcutRecordingConflictNotice

  var body: some View {
    HStack(spacing: 9) {
      Image(systemName: notice.opensPreferences ? "checkmark.circle.fill" : "info.circle.fill")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(notice.opensPreferences ? teal : accent)

      Text(notice.message)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(ink)
        .fixedSize(horizontal: false, vertical: true)

      Spacer(minLength: 8)

      Button {
        model.shortcutRecordingConflictNotice = nil
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(muted)
          .frame(width: 22, height: 22)
      }
      .buttonStyle(.plain)
      .help("关闭提示")
      .accessibilityLabel("关闭快捷键提示")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(
      (notice.opensPreferences ? teal : accent).opacity(0.075),
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke((notice.opensPreferences ? teal : accent).opacity(0.2), lineWidth: 1)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel(notice.message)
  }
}

struct PrimaryAddShortcutMenu: View {
  let addShortcut: () -> Void

  var body: some View {
    Button {
      addShortcut()
    } label: {
      Label("新增快捷键", systemImage: "plus")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(AppVisualStyle.onAccent)
        .padding(.horizontal, 12)
        .frame(minHeight: 32)
        .background(accent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
    .buttonStyle(.plain)
    .fixedSize()
    .help("新增快捷键")
    .accessibilityLabel("新增快捷键")
  }
}

struct ShortcutStatusBanner: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: icon)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(amber)

      Text(message)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(ink)
        .fixedSize(horizontal: false, vertical: true)

      Spacer(minLength: 8)

      Button(actionTitle, action: recoveryAction)
        .buttonStyle(GlassLabelButtonStyle(tint: accent))
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(amber.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(amber.opacity(0.22), lineWidth: 1))
  }

  private var icon: String {
    model.advancedListeningAuthorized
      ? "exclamationmark.triangle.fill"
      : "lock.trianglebadge.exclamationmark"
  }

  private var message: String {
    if !model.authorizationPermissionsComplete {
      return "后台监听权限尚未完整，软件会自动判断并带你完成。"
    }
    if model.isPaused {
      return "后台快捷键已暂停。当前列表仍可查看和编辑。"
    }
    return "有 \(model.hotkeyFailures.count) 个快捷键未能启用，现有配置没有改变。"
  }

  private var actionTitle: String {
    if !model.authorizationPermissionsComplete { return "立即授权" }
    if model.isPaused { return "恢复后台快捷键" }
    return "重新检测"
  }

  private func recoveryAction() {
    if !model.authorizationPermissionsComplete {
      model.presentAuthorizationCenter()
    } else if model.isPaused {
      model.togglePaused()
    } else {
      model.reloadHotkeys()
    }
  }
}
