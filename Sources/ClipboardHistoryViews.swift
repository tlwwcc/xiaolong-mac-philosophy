import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

private enum ClipboardHistoryPalette {
  static let brand = Color(red: 107 / 255, green: 35 / 255, blue: 142 / 255)
  static let brandMist = Color(red: 244 / 255, green: 240 / 255, blue: 248 / 255)
  static let paper = Color(red: 252 / 255, green: 251 / 255, blue: 253 / 255)
  static let ink = Color(red: 23 / 255, green: 19 / 255, blue: 28 / 255)
  static let copy = Color(red: 81 / 255, green: 72 / 255, blue: 87 / 255)
  static let muted = Color(red: 113 / 255, green: 104 / 255, blue: 120 / 255)
  static let line = Color(red: 46 / 255, green: 34 / 255, blue: 53 / 255).opacity(0.14)
  static let success = Color(red: 0.00, green: 0.49, blue: 0.42)
  static let warning = Color(red: 0.86, green: 0.52, blue: 0.10)
  static let danger = Color(red: 0.82, green: 0.17, blue: 0.23)
}

struct ClipboardHistoryApplicationDetailView: View {
  @ObservedObject private var controller: ClipboardHistoryController

  private let openHistory: () -> Void
  private let openShortcutSettings: () -> Void

  init(
    controller: ClipboardHistoryController,
    openHistory: @escaping () -> Void,
    openShortcutSettings: @escaping () -> Void
  ) {
    _controller = ObservedObject(wrappedValue: controller)
    self.openHistory = openHistory
    self.openShortcutSettings = openShortcutSettings
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        header

        if let failureMessage = captureFailureMessage {
          ClipboardHistoryNotice(
            icon: "exclamationmark.triangle.fill",
            title: "保存失败",
            message: failureMessage,
            color: ClipboardHistoryPalette.danger
          )
        } else if controller.quotaBlocked {
          ClipboardHistoryNotice(
            icon: "externaldrive.badge.exclamationmark",
            title: "存储空间已满",
            message: "先清理旧记录或提高空间上限，新的文件副本才能继续保存。",
            color: ClipboardHistoryPalette.danger
          )
        } else if let message = controller.statusMessage,
          message.hasPrefix("本次文件未保存")
        {
          ClipboardHistoryNotice(
            icon: "info.circle",
            title: "已跳过这次文件复制",
            message: message,
            color: ClipboardHistoryPalette.warning
          )
        } else if !controller.isEnabled {
          ClipboardHistoryNotice(
            icon: "pause.circle.fill",
            title: "历史记录已暂停",
            message: "暂停期间的新复制不会写入历史。现有记录仍可查看和复制。",
            color: ClipboardHistoryPalette.warning
          )
        } else if controller.pendingDeletionBytes > 0 {
          ClipboardHistoryNotice(
            icon: "arrow.triangle.2.circlepath",
            title: "正在完成磁盘清理",
            message: "历史记录已经移除；暂未释放的空间会在后台和下次启动时继续清理。",
            color: ClipboardHistoryPalette.warning
          )
        }

        Button(action: openHistory) {
          Label("打开剪贴板历史", systemImage: "rectangle.stack.fill")
            .font(.system(size: 14, weight: .semibold))
            .frame(maxWidth: .infinity)
            .frame(minHeight: 32)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(ClipboardHistoryPalette.brand)
        .keyboardShortcut(.defaultAction)
        .disabled(controller.isBusy)
        .accessibilityHint("打开可搜索和预览的历史记录窗口")

        ClipboardHistorySnapshotCard(controller: controller)

        ClipboardHistoryExcludedApplicationsView(controller: controller)

        ClipboardHistorySettingsView(controller: controller)

        VStack(alignment: .leading, spacing: 12) {
          ClipboardHistorySectionHeading(
            title: "快捷键",
            detail: "快捷键只在“功能快捷键”统一管理。"
          )

          HStack(spacing: 12) {
            Label("建议连按物理右 Option 两次", systemImage: "keyboard")
              .foregroundStyle(ClipboardHistoryPalette.ink)
            Spacer(minLength: 12)
            Button("前往功能快捷键", action: openShortcutSettings)
              .buttonStyle(.bordered)
              .accessibilityHint("离开当前详情并打开功能快捷键设置")
          }
          .font(.system(size: 13, weight: .medium))
        }
        .clipboardHistoryPanel()

        VStack(alignment: .leading, spacing: 10) {
          ClipboardHistorySectionHeading(
            title: "隐私",
            detail: "历史文字和文件副本只保存在这台 Mac，不会上传。"
          )
          Label("关闭记录后，已有内容仍按当前清理规则保留。", systemImage: "lock.fill")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(ClipboardHistoryPalette.copy)
        }
        .clipboardHistoryPanel()
      }
      .padding(24)
      .frame(maxWidth: 720, alignment: .topLeading)
      .frame(maxWidth: .infinity)
    }
    .background(ClipboardHistoryPalette.paper)
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 16) {
      Image(systemName: "doc.on.clipboard.fill")
        .font(.system(size: 24, weight: .semibold))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(ClipboardHistoryPalette.brand)
        .frame(width: 52, height: 52)
        .background(
          ClipboardHistoryPalette.brandMist,
          in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 5) {
        Text("剪贴板历史保存")
          .font(.title2.weight(.semibold))
          .foregroundStyle(ClipboardHistoryPalette.ink)
        Text("每次复制自动保存；相同内容再次出现时，只更新原记录。")
          .font(.body)
          .foregroundStyle(ClipboardHistoryPalette.copy)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 16)

      Toggle(
        "记录剪贴板历史",
        isOn: Binding(
          get: { controller.isEnabled },
          set: { controller.setEnabled($0) }
        )
      )
      .labelsHidden()
      .toggleStyle(.switch)
      .tint(ClipboardHistoryPalette.brand)
      .accessibilityLabel("记录剪贴板历史")
      .accessibilityValue(controller.isEnabled ? "已打开" : "已关闭")
    }
  }

  private var captureFailureMessage: String? {
    guard !controller.quotaBlocked,
      let message = controller.statusMessage,
      message.hasPrefix("保存失败")
    else { return nil }
    return message
  }
}

struct ClipboardHistoryWindowView: View {
  @ObservedObject private var controller: ClipboardHistoryController
  private let activateEntry: (ClipboardHistoryEntry) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var searchText = ""
  @State private var kindFilter = ClipboardHistoryKindFilter.all
  @State private var isShowingSettings = false
  @State private var isShowingDeleteConfirmation = false
  @State private var pendingDeleteID: AnyHashable?
  @State private var observedCopyCounts: [AnyHashable: Int] = [:]
  @State private var mergeNotice: String?
  @State private var mergeNoticeToken = UUID()
  @State private var expandedFileEntryID: AnyHashable?
  @FocusState private var searchFocused: Bool

  init(
    controller: ClipboardHistoryController,
    activateEntry: @escaping (ClipboardHistoryEntry) -> Void
  ) {
    _controller = ObservedObject(wrappedValue: controller)
    self.activateEntry = activateEntry
  }

  var body: some View {
    historyPane
      .frame(minWidth: 440, idealWidth: 500, maxWidth: 620, minHeight: 500, idealHeight: 680)
      .background(ClipboardHistoryPalette.paper)
      .tint(ClipboardHistoryPalette.brand)
      .sheet(isPresented: $isShowingSettings) {
        ClipboardHistorySettingsSheet(controller: controller)
      }
      .confirmationDialog(
        "删除这条历史记录？",
        isPresented: $isShowingDeleteConfirmation,
        titleVisibility: .visible
      ) {
        Button("删除", role: .destructive) {
          guard let entry = pendingDeleteEntry else { return }
          controller.delete(entry)
          pendingDeleteID = nil
        }
        Button("取消", role: .cancel) {
          pendingDeleteID = nil
        }
      } message: {
        Text("删除后无法从剪贴板历史中恢复。原始文件不会被删除。")
      }
      .onAppear {
        snapshotCopyCounts()
        ensureSelection()
        DispatchQueue.main.async { searchFocused = true }
      }
      .onChange(of: searchText) { _ in ensureSelection() }
      .onChange(of: kindFilter) { _ in ensureSelection() }
      .onChange(of: controller.searchFocusRequest) { _ in
        searchFocused = true
      }
      .onChange(of: controller.entries) { entries in
        observeControllerEntries(entries)
      }
  }

  private var historyPane: some View {
    VStack(spacing: 0) {
      searchBar
        .padding(.horizontal, 12)
        .padding(.vertical, 10)

      Divider()

      statusArea

      if controller.entries.isEmpty {
        ClipboardHistoryEmptyState(
          icon: controller.quotaBlocked
            ? "externaldrive.badge.exclamationmark"
            : (controller.isEnabled ? "doc.on.clipboard" : "pause.circle"),
          title: controller.quotaBlocked
            ? "空间已满"
            : (controller.isEnabled ? "还没有历史记录" : "记录已暂停"),
          message: controller.quotaBlocked
            ? "调整空间上限或清理旧记录后再继续。"
            : (controller.isEnabled
              ? "复制任何文字、图片或文件，它会自动出现在这里。"
              : "继续记录后，新复制的内容会出现在这里。")
        )
      } else if filteredEntries.isEmpty {
        ClipboardHistoryEmptyState(
          icon: "magnifyingglass",
          title: "没有匹配结果",
          message: searchText.isEmpty ? "换一种内容类型试试。" : "没有找到“\(searchText)”。",
          actionTitle: "清除筛选"
        ) {
          searchText = ""
          kindFilter = .all
          searchFocused = true
        }
      } else {
        historyList
      }

      Divider()

      HStack(spacing: 8) {
        Text("\(filteredEntries.count) 条")
        Text("·")
        Text(ClipboardHistoryFormatting.bytes(controller.usedBytes))
        Spacer()
        Button {
          isShowingSettings = true
        } label: {
          Label("设置", systemImage: "gearshape")
        }
        .buttonStyle(.borderless)
        .help("打开排除软件、空间与自动清理设置")
      }
      .font(.caption)
      .foregroundStyle(ClipboardHistoryPalette.muted)
      .padding(.horizontal, 12)
      .frame(minHeight: 36)
    }
    .background(Color(nsColor: .windowBackgroundColor).opacity(0.72))
  }

  private var searchBar: some View {
    HStack(spacing: 8) {
      filterPills
        .layoutPriority(1)

      compactSearchField
        .frame(minWidth: 128, maxWidth: .infinity)
    }
  }

  private var filterPills: some View {
    HStack(spacing: 4) {
      ForEach(ClipboardHistoryKindFilter.allCases) { filter in
        let selected = kindFilter == filter
        Button {
          kindFilter = filter
        } label: {
          Text(filter.title)
            .font(.caption.weight(selected ? .semibold : .medium))
            .foregroundStyle(selected ? Color.white : ClipboardHistoryPalette.copy)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(
              selected
                ? ClipboardHistoryPalette.brand
                : ClipboardHistoryPalette.brandMist.opacity(0.46),
              in: Capsule()
            )
            .overlay(
              Capsule()
                .stroke(
                  selected ? Color.clear : ClipboardHistoryPalette.line,
                  lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
        .help("只看\(filter.title)")
        .accessibilityLabel(filter.title)
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
    .fixedSize(horizontal: true, vertical: false)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("剪贴板类型筛选")
  }

  private var compactSearchField: some View {
    HStack(spacing: 7) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(searchFocused ? ClipboardHistoryPalette.brand : .secondary)
        .accessibilityHidden(true)

      TextField("搜索", text: $searchText)
        .textFieldStyle(.plain)
        .focused($searchFocused)
        .onSubmit(activateSelectedEntryIfPossible)
        .accessibilityLabel("搜索剪贴板历史")

      if !searchText.isEmpty {
        Button {
          searchText = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("清除搜索")
        .accessibilityLabel("清除搜索")
      }
    }
    .padding(.horizontal, 9)
    .frame(height: 32)
    .background(
      Color(nsColor: .textBackgroundColor),
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(
          searchFocused
            ? ClipboardHistoryPalette.brand.opacity(0.55)
            : ClipboardHistoryPalette.line,
          lineWidth: searchFocused ? 1.5 : 1
        )
    )
  }

  @ViewBuilder
  private var statusArea: some View {
    VStack(spacing: 0) {
      if let mergeNotice {
        ClipboardHistoryCompactNotice(
          text: mergeNotice,
          systemImage: "square.on.square",
          color: ClipboardHistoryPalette.brand
        )
        .transition(reduceMotion ? .identity : .opacity)
      } else if controller.quotaBlocked {
        ClipboardHistoryCompactNotice(
          text: "空间已满；新的文件副本暂未保存。",
          systemImage: "externaldrive.badge.exclamationmark",
          color: ClipboardHistoryPalette.danger,
          actionTitle: "调整"
        ) {
          isShowingSettings = true
        }
      } else if !controller.isEnabled {
        ClipboardHistoryCompactNotice(
          text: "历史记录已暂停。",
          systemImage: "pause.fill",
          color: ClipboardHistoryPalette.warning,
          actionTitle: "继续记录"
        ) {
          controller.setEnabled(true)
        }
      } else if controller.pendingDeletionBytes > 0 {
        ClipboardHistoryCompactNotice(
          text: "部分已删除内容仍在后台释放磁盘空间。",
          systemImage: "arrow.triangle.2.circlepath",
          color: ClipboardHistoryPalette.warning
        )
      } else if let statusMessage = controller.statusMessage,
        !statusMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        let failed = statusMessage.hasPrefix("保存失败")
        ClipboardHistoryCompactNotice(
          text: statusMessage,
          systemImage: controller.isBusy
            ? "arrow.triangle.2.circlepath"
            : (failed ? "exclamationmark.triangle.fill" : "info.circle"),
          color: failed ? ClipboardHistoryPalette.danger : ClipboardHistoryPalette.copy
        )
      }
    }
  }

  private var historyList: some View {
    List(
      selection: Binding(
        get: { controller.selectedEntryID },
        set: { selectedID in
          guard controller.selectedEntryID != selectedID else { return }
          controller.selectedEntryID = selectedID
        }
      )
    ) {
      ForEach(historySections) { section in
        Section(section.title) {
          ForEach(section.entries, id: \.id) { entry in
            VStack(spacing: 0) {
              ClipboardHistoryRow(
                entry: entry,
                selected: controller.selectedEntryID == entry.id,
                activationEnabled: !controller.isBusy,
                fileDetailsExpanded: expandedFileEntryID == AnyHashable(entry.id),
                payloadURLs: controller.payloadURLs(for: entry),
                activateEntry: activateEntry,
                toggleFileDetails: {
                  controller.selectedEntryID = entry.id
                  let entryID = AnyHashable(entry.id)
                  expandedFileEntryID = expandedFileEntryID == entryID ? nil : entryID
                },
                copy: { plainText in
                  controller.copyToPasteboard(entry: entry, plainText: plainText) { _ in }
                },
                togglePinned: {
                  controller.setPinned(entry, pinned: !entry.isPinned)
                },
                requestDelete: {
                  requestDelete(entry)
                }
              )

              if expandedFileEntryID == AnyHashable(entry.id), entry.kind == .files {
                ClipboardHistoryInlineFileList(
                  entry: entry,
                  controller: controller,
                  activateEntry: { activateEntryIfPossible(entry) }
                )
                .padding(.horizontal, 4)
                .padding(.bottom, 6)
              }
            }
            .tag(entry.id)
          }
        }
      }
    }
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
    .background(ClipboardHistoryPalette.paper)
    .onDeleteCommand {
      guard let selectedEntry else { return }
      requestDelete(selectedEntry)
    }
    .onCommand(#selector(NSResponder.insertNewline(_:))) {
      activateSelectedEntryIfPossible()
    }
    .onCommand(#selector(NSText.copy(_:))) {
      guard let selectedEntry, !controller.isBusy else { return }
      controller.copyToPasteboard(entry: selectedEntry) { _ in }
    }
  }

  private func activateSelectedEntryIfPossible() {
    guard let selectedEntry else { return }
    activateEntryIfPossible(selectedEntry)
  }

  private func activateEntryIfPossible(_ entry: ClipboardHistoryEntry) {
    guard !controller.isBusy else { return }
    activateEntry(entry)
  }

  private var filteredEntries: [ClipboardHistoryEntry] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    return controller.entries
      .filter { entry in
        kindFilter.matches(entry)
          && (query.isEmpty
            || ClipboardHistoryFormatting.matches(entry, query: query))
      }
      .sorted { $0.lastCopiedAt > $1.lastCopiedAt }
  }

  private var historySections: [ClipboardHistorySection] {
    var values: [ClipboardHistoryDateBucket: [ClipboardHistoryEntry]] = [:]
    for entry in filteredEntries {
      values[ClipboardHistoryDateBucket.bucket(for: entry.lastCopiedAt), default: []].append(entry)
    }
    return ClipboardHistoryDateBucket.allCases.compactMap { bucket in
      guard let entries = values[bucket], !entries.isEmpty else { return nil }
      return ClipboardHistorySection(id: bucket.rawValue, title: bucket.title, entries: entries)
    }
  }

  private var selectedEntry: ClipboardHistoryEntry? {
    guard let selectedID = controller.selectedEntryID else { return nil }
    return controller.entries.first { $0.id == selectedID }
  }

  private var pendingDeleteEntry: ClipboardHistoryEntry? {
    guard let pendingDeleteID else { return nil }
    return controller.entries.first { AnyHashable($0.id) == pendingDeleteID }
  }

  private func requestDelete(_ entry: ClipboardHistoryEntry) {
    if expandedFileEntryID == AnyHashable(entry.id) {
      expandedFileEntryID = nil
    }
    pendingDeleteID = AnyHashable(entry.id)
    isShowingDeleteConfirmation = true
  }

  private func ensureSelection() {
    if let selectedID = controller.selectedEntryID,
      filteredEntries.contains(where: { $0.id == selectedID })
    {
      return
    }
    let desiredID = filteredEntries.first?.id
    guard controller.selectedEntryID != desiredID else { return }
    controller.selectedEntryID = desiredID
  }

  private func snapshotCopyCounts() {
    observedCopyCounts = Dictionary(
      uniqueKeysWithValues: controller.entries.map { (AnyHashable($0.id), $0.copyCount) })
  }

  private func observeControllerEntries(_ entries: [ClipboardHistoryEntry]) {
    var newestMerge: ClipboardHistoryEntry?
    let latestCopyCounts = Dictionary(
      uniqueKeysWithValues: entries.map { (AnyHashable($0.id), $0.copyCount) })

    for entry in entries {
      let key = AnyHashable(entry.id)
      if let previous = observedCopyCounts[key], entry.copyCount > previous {
        if newestMerge == nil || entry.lastCopiedAt > newestMerge!.lastCopiedAt {
          newestMerge = entry
        }
      }
    }

    if latestCopyCounts != observedCopyCounts {
      observedCopyCounts = latestCopyCounts
    }

    let currentIDs = Set(latestCopyCounts.keys)
    if let expandedFileEntryID, !currentIDs.contains(expandedFileEntryID) {
      self.expandedFileEntryID = nil
    }

    if let newestMerge {
      presentMergeNotice(copyCount: newestMerge.copyCount)
    }
    ensureSelection()
  }

  private func presentMergeNotice(copyCount: Int) {
    let message = "已合并重复内容 · \(copyCount) 次"
    mergeNotice = message
    ClipboardHistoryAccessibilityAnnouncer.announce(message)

    let token = UUID()
    mergeNoticeToken = token
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
      guard mergeNoticeToken == token else { return }
      if reduceMotion {
        mergeNotice = nil
      } else {
        withAnimation(.easeOut(duration: 0.16)) {
          mergeNotice = nil
        }
      }
    }
  }
}

private struct ClipboardHistoryInlineFileList: View {
  let entry: ClipboardHistoryEntry
  @ObservedObject var controller: ClipboardHistoryController
  let activateEntry: () -> Void

  private var displayNames: [String] {
    if !entry.fileNames.isEmpty { return entry.fileNames }
    return entry.payloadRelativePaths.map { URL(fileURLWithPath: $0).lastPathComponent }
  }

  private var items: [ClipboardHistoryFileListItem] {
    displayNames.enumerated().map { index, name in
      let url = controller.payloadURL(for: entry, at: index)
      return ClipboardHistoryFileListItem(
        index: index,
        name: name,
        url: url,
        isAvailable: url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
    }
  }

  private var tableHeight: CGFloat {
    CGFloat(min(max(displayNames.count * 54, 72), 180))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ClipboardHistoryNativeFileList(
        items: items,
        isBusy: controller.isBusy,
        requestPreview: { index, completion in
          controller.prepareWorkingCopy(
            for: entry,
            at: index,
            actionDescription: "快速查看",
            completion: completion)
        },
        openCopy: { index in controller.openWorkingCopy(for: entry, at: index) },
        revealCopy: { index in controller.revealWorkingCopy(for: entry, at: index) },
        discardCopy: controller.discardWorkingCopy,
        activateEntry: activateEntry
      )
      .id(entry.id)
      .frame(height: tableHeight)
      .background(Color(nsColor: .textBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .stroke(ClipboardHistoryPalette.line, lineWidth: 1)
      )

      Text("空格快速查看 · 双击整组复制并收起 · 右键打开副本")
        .font(.caption2)
        .foregroundStyle(ClipboardHistoryPalette.muted)
        .padding(.horizontal, 4)
    }
    .accessibilityElement(children: .contain)
  }
}

private struct ClipboardHistoryRowThumbnail: View {
  let entry: ClipboardHistoryEntry
  let urls: [URL]

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      Group {
        if let primaryURL, entry.kind == .image || entry.kind == .files {
          ClipboardHistoryDownsampledThumbnail(
            url: primaryURL,
            fallbackSymbol: ClipboardHistoryFormatting.symbol(entry)
          )
        } else {
          Image(systemName: ClipboardHistoryFormatting.symbol(entry))
            .font(.system(size: 19, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(ClipboardHistoryPalette.brand)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ClipboardHistoryPalette.brandMist)
        }
      }
      .frame(width: 74, height: 56)
      .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .stroke(ClipboardHistoryPalette.line, lineWidth: 1)
      )

      if entry.kind == .files && entry.fileNames.count > 1 {
        Text("\(entry.fileNames.count)")
          .font(.system(size: 9, weight: .bold, design: .rounded))
          .foregroundStyle(.white)
          .padding(.horizontal, 5)
          .frame(minHeight: 17)
          .background(ClipboardHistoryPalette.brand, in: Capsule())
          .offset(x: 4, y: 4)
      }
    }
    .frame(width: 78, height: 60, alignment: .topLeading)
    .accessibilityHidden(true)
  }

  private var primaryURL: URL? { urls.first }
}

private struct ClipboardHistoryDownsampledThumbnail: NSViewRepresentable {
  let url: URL
  let fallbackSymbol: String

  func makeNSView(context: Context) -> ClipboardHistoryThumbnailImageView {
    let imageView = ClipboardHistoryThumbnailImageView()
    imageView.imageAlignment = .alignCenter
    imageView.imageScaling = .scaleProportionallyUpOrDown
    return imageView
  }

  func updateNSView(_ imageView: ClipboardHistoryThumbnailImageView, context: Context) {
    let normalizedURL = url.standardizedFileURL
    guard imageView.representedURL != normalizedURL else { return }
    imageView.representedURL = normalizedURL
    imageView.image = NSImage(
      systemSymbolName: fallbackSymbol,
      accessibilityDescription: nil)
    ClipboardHistoryThumbnailPipeline.load(url: normalizedURL, maximumPixelSize: 224) {
      [weak imageView] image in
      guard let imageView, imageView.representedURL == normalizedURL else { return }
      imageView.image = image
    }
  }
}

private final class ClipboardHistoryThumbnailImageView: NSImageView {
  var representedURL: URL?

  // This view is decorative. Let the history row own selection, double-click and its menu.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private enum ClipboardHistoryThumbnailPipeline {
  private static let queue = DispatchQueue(
    label: "cn.tlww.aixlg.clipboard-history.thumbnail",
    qos: .userInitiated,
    attributes: .concurrent)
  private static let lock = NSLock()
  private static let cache: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 256
    cache.totalCostLimit = 64 * 1_024 * 1_024
    return cache
  }()
  private static var pending: [String: [(NSImage) -> Void]] = [:]

  static func load(
    url: URL,
    maximumPixelSize: Int,
    completion: @escaping (NSImage) -> Void
  ) {
    let key = "\(url.path)#\(maximumPixelSize)"
    if let cached = cache.object(forKey: key as NSString) {
      completion(cached)
      return
    }

    lock.lock()
    if pending[key] != nil {
      pending[key, default: []].append(completion)
      lock.unlock()
      return
    }
    pending[key] = [completion]
    lock.unlock()

    queue.async {
      let thumbnail = downsampledImage(at: url, maximumPixelSize: maximumPixelSize)
      DispatchQueue.main.async {
        let image = thumbnail ?? fallbackIcon(for: url, maximumPixelSize: maximumPixelSize)
        let cost = max(1, Int(image.size.width * image.size.height * 4))
        cache.setObject(image, forKey: key as NSString, cost: cost)
        lock.lock()
        let completions = pending.removeValue(forKey: key) ?? []
        lock.unlock()
        for completion in completions {
          completion(image)
        }
      }
    }
  }

  private static func downsampledImage(at url: URL, maximumPixelSize: Int) -> NSImage? {
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
    let thumbnailOptions =
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
      ] as CFDictionary
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
      return nil
    }
    return NSImage(cgImage: image, size: .zero)
  }

  private static func fallbackIcon(for url: URL, maximumPixelSize: Int) -> NSImage {
    let source = NSWorkspace.shared.icon(forFile: url.path)
    let image = (source.copy() as? NSImage) ?? source
    image.size = NSSize(width: maximumPixelSize, height: maximumPixelSize)
    return image
  }
}

private struct ClipboardHistoryRow: View {
  let entry: ClipboardHistoryEntry
  let selected: Bool
  let activationEnabled: Bool
  let fileDetailsExpanded: Bool
  let payloadURLs: [URL]
  let activateEntry: (ClipboardHistoryEntry) -> Void
  let toggleFileDetails: () -> Void
  let copy: (Bool) -> Void
  let togglePinned: () -> Void
  let requestDelete: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.controlActiveState) private var controlActiveState
  @State private var duplicateHighlight = false

  private var usesEmphasizedSelection: Bool {
    selected && controlActiveState == .key
  }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      ClipboardHistoryRowThumbnail(entry: entry, urls: payloadURLs)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(ClipboardHistoryFormatting.title(entry))
            .font(.callout.weight(.semibold))
            .foregroundStyle(
              usesEmphasizedSelection ? Color.white : ClipboardHistoryPalette.ink
            )
            .lineLimit(1)

          if entry.isPinned {
            Image(systemName: "pin.fill")
              .font(.caption2)
              .foregroundStyle(
                usesEmphasizedSelection ? Color.white : ClipboardHistoryPalette.brand
              )
              .accessibilityHidden(true)
          }

          Spacer(minLength: 4)

          if entry.copyCount > 1 {
            Text("×\(entry.copyCount)")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(
                usesEmphasizedSelection ? Color.white : ClipboardHistoryPalette.brand)
          }

          if entry.kind == .files {
            Button(action: toggleFileDetails) {
              Image(
                systemName: fileDetailsExpanded
                  ? "chevron.up.circle.fill" : "chevron.down.circle"
              )
              .font(.callout)
              .foregroundStyle(
                usesEmphasizedSelection ? Color.white : ClipboardHistoryPalette.brand
              )
            }
            .buttonStyle(.borderless)
            .help(fileDetailsExpanded ? "收起文件明细" : "查看文件明细")
            .accessibilityHidden(true)
          }
        }

        let summary = ClipboardHistoryFormatting.summary(entry)
        if !summary.isEmpty {
          Text(summary)
            .font(.caption)
            .foregroundStyle(
              usesEmphasizedSelection
                ? Color.white.opacity(0.88) : ClipboardHistoryPalette.copy
            )
            .lineLimit(2)
        }

        Text(ClipboardHistoryFormatting.metadata(entry))
          .font(.caption2)
          .foregroundStyle(
            usesEmphasizedSelection
              ? Color.white.opacity(0.76) : ClipboardHistoryPalette.muted
          )
          .lineLimit(1)
      }
    }
    .padding(.horizontal, 4)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
    .background(
      duplicateHighlight ? ClipboardHistoryPalette.brand.opacity(0.10) : Color.clear,
      in: RoundedRectangle(cornerRadius: 9, style: .continuous)
    )
    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: duplicateHighlight)
    .contentShape(Rectangle())
    .onTapGesture(count: 2) {
      guard activationEnabled else { return }
      activateEntry(entry)
    }
    .contextMenu {
      Button {
        copy(false)
      } label: {
        Label("复制到剪贴板", systemImage: "doc.on.doc")
      }
      .disabled(!activationEnabled)

      if entry.kind == .text || entry.kind == .link {
        Button {
          copy(true)
        } label: {
          Label("复制纯文本", systemImage: "textformat")
        }
        .disabled(!activationEnabled)
      }

      if entry.kind == .files {
        Button(action: toggleFileDetails) {
          Label(
            fileDetailsExpanded ? "收起文件明细" : "查看文件明细",
            systemImage: fileDetailsExpanded ? "chevron.up" : "chevron.down"
          )
        }
      }

      Divider()

      Button(action: togglePinned) {
        Label(
          entry.isPinned ? "取消保留" : "保留",
          systemImage: entry.isPinned ? "pin.slash" : "pin"
        )
      }

      Button(role: .destructive, action: requestDelete) {
        Label("删除", systemImage: "trash")
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(ClipboardHistoryFormatting.accessibilityLabel(entry))
    .accessibilityAddTraits(selected ? .isSelected : [])
    .modifier(
      ClipboardHistoryRowActivationAccessibilityModifier(
        enabled: activationEnabled,
        activate: { activateEntry(entry) },
        copy: { copy(false) }
      )
    )
    .modifier(
      ClipboardHistoryRowFileDetailsAccessibilityModifier(
        title: entry.kind == .files
          ? (fileDetailsExpanded ? "收起文件明细" : "查看文件明细")
          : nil,
        action: toggleFileDetails
      )
    )
    .accessibilityAction(named: entry.isPinned ? "取消保留" : "保留") { togglePinned() }
    .accessibilityAction(named: "删除") { requestDelete() }
    .onChange(of: entry.copyCount) { newValue in
      guard newValue > 1 else { return }
      duplicateHighlight = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
        duplicateHighlight = false
      }
    }
  }
}

private struct ClipboardHistoryRowActivationAccessibilityModifier: ViewModifier {
  let enabled: Bool
  let activate: () -> Void
  let copy: () -> Void

  @ViewBuilder
  func body(content: Content) -> some View {
    if enabled {
      content
        .accessibilityHint("激活后放回剪贴板并收起面板")
        .accessibilityAction(.default) { activate() }
        .accessibilityAction(named: "复制并收起面板") { activate() }
        .accessibilityAction(named: "复制到剪贴板") { copy() }
    } else {
      content
        .accessibilityHint("正在处理上一条记录")
        .accessibilityValue("暂不可用")
    }
  }
}

private struct ClipboardHistoryRowFileDetailsAccessibilityModifier: ViewModifier {
  let title: String?
  let action: () -> Void

  @ViewBuilder
  func body(content: Content) -> some View {
    if let title {
      content.accessibilityAction(named: Text(title)) { action() }
    } else {
      content
    }
  }
}

private struct ClipboardHistorySnapshotCard: View {
  @ObservedObject var controller: ClipboardHistoryController

  private var usageFraction: Double {
    let maximum = Swift.max(Int64(controller.maxBytes), 1)
    return Swift.min(Double(Int64(controller.usedBytes)) / Double(maximum), 1)
  }

  private var statusDetail: String {
    if controller.quotaBlocked {
      return "空间上限已触发，新的内容暂未保存。"
    }
    if let message = controller.statusMessage,
      message.hasPrefix("保存失败") || message.hasPrefix("本次文件未保存")
    {
      return message
    }
    if controller.pendingDeletionBytes > 0 {
      return "历史记录已移除，部分磁盘空间正在后台释放。"
    }
    return controller.isEnabled ? "正在记录新的复制内容。" : "记录已暂停。"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      ClipboardHistorySectionHeading(
        title: "当前状态",
        detail: statusDetail
      )

      HStack(alignment: .firstTextBaseline) {
        Text(ClipboardHistoryFormatting.bytes(controller.usedBytes))
          .font(.title3.weight(.semibold))
          .foregroundStyle(ClipboardHistoryPalette.ink)
          .monospacedDigit()
        Text("/ \(ClipboardHistoryFormatting.bytes(controller.maxBytes))")
          .font(.callout)
          .foregroundStyle(ClipboardHistoryPalette.muted)
          .monospacedDigit()
        Spacer()
        Text(ClipboardHistoryFormatting.retention(controller.retentionDays))
          .font(.callout.weight(.medium))
          .foregroundStyle(ClipboardHistoryPalette.brand)
      }

      ProgressView(value: usageFraction)
        .tint(
          controller.quotaBlocked ? ClipboardHistoryPalette.danger : ClipboardHistoryPalette.brand
        )
        .accessibilityLabel("剪贴板历史空间用量")
        .accessibilityValue(
          "已使用 \(ClipboardHistoryFormatting.bytes(controller.usedBytes))，上限 \(ClipboardHistoryFormatting.bytes(controller.maxBytes))"
        )
    }
    .clipboardHistoryPanel()
  }
}

private struct ClipboardHistoryExcludedApplicationsView: View {
  @ObservedObject var controller: ClipboardHistoryController

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline) {
        ClipboardHistorySectionHeading(
          title: "排除软件",
          detail: "这些软件位于前台时，观察到的新复制不会进入历史。"
        )
        Spacer(minLength: 12)
        Button(action: chooseApplication) {
          Label("添加软件…", systemImage: "plus")
        }
        .buttonStyle(.bordered)
        .disabled(controller.isBusy)
        .accessibilityHint("选择一个不记录剪贴板内容的软件")
      }

      if controller.excludedApplications.isEmpty {
        Text("暂未排除任何软件。")
          .font(.callout)
          .foregroundStyle(ClipboardHistoryPalette.muted)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        VStack(spacing: 0) {
          ForEach(Array(controller.excludedApplications.enumerated()), id: \.element.id) {
            index, application in
            ClipboardHistoryExcludedApplicationRow(
              application: application,
              remove: { controller.removeExcludedApplication(application) }
            )
            if index < controller.excludedApplications.count - 1 {
              Divider().padding(.leading, 44)
            }
          }
        }
      }

      Text("Typeless 听写时的临时复制也会被识别并跳过；已经保存的历史不会删除。")
        .font(.caption)
        .foregroundStyle(ClipboardHistoryPalette.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
    .clipboardHistoryPanel()
  }

  private func chooseApplication() {
    let panel = NSOpenPanel()
    panel.title = "选择要排除的软件"
    panel.prompt = "排除"
    panel.message = "以后这个软件位于前台时，观察到的新复制不会进入剪贴板历史。"
    panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    panel.allowedContentTypes = [.applicationBundle]
    panel.allowsMultipleSelection = false
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.treatsFilePackagesAsDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    _ = controller.addExcludedApplication(at: url)
  }
}

private struct ClipboardHistoryExcludedApplicationRow: View {
  let application: ClipboardHistoryExcludedApplication
  let remove: () -> Void

  private var applicationURL: URL? {
    if let path = application.applicationPath,
      FileManager.default.fileExists(atPath: path)
    {
      return URL(fileURLWithPath: path)
    }
    return NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: application.bundleIdentifier)
  }

  var body: some View {
    HStack(spacing: 10) {
      Group {
        if let applicationURL {
          Image(nsImage: NSWorkspace.shared.icon(forFile: applicationURL.path))
            .resizable()
            .interpolation(.high)
            .scaledToFit()
        } else {
          Image(systemName: "app.dashed")
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(ClipboardHistoryPalette.muted)
        }
      }
      .frame(width: 32, height: 32)

      VStack(alignment: .leading, spacing: 2) {
        Text(application.applicationName)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(ClipboardHistoryPalette.ink)
        Text(
          application.bundleIdentifier == ClipboardHistoryExclusionPolicy.typelessBundleIdentifier
            ? "听写产生的临时复制不记录"
            : "它在前台产生的新复制不记录"
        )
        .font(.caption)
        .foregroundStyle(ClipboardHistoryPalette.muted)
      }

      Spacer(minLength: 12)

      Button(action: remove) {
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(ClipboardHistoryPalette.muted)
      }
      .buttonStyle(.plain)
      .help("取消排除 \(application.applicationName)")
      .accessibilityLabel("取消排除 \(application.applicationName)")
    }
    .padding(.vertical, 7)
  }
}

private struct ClipboardHistorySettingsView: View {
  @ObservedObject private var controller: ClipboardHistoryController
  @State private var quotaText = ""
  @State private var quotaUnit = ClipboardHistoryQuotaUnit.gigabytes
  @State private var quotaError: String?
  @State private var isShowingClearConfirmation = false
  @FocusState private var quotaFocused: Bool

  init(controller: ClipboardHistoryController) {
    _controller = ObservedObject(wrappedValue: controller)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      ClipboardHistorySectionHeading(
        title: "空间与清理",
        detail: cleanupSummary
      )

      VStack(spacing: 14) {
        HStack(spacing: 12) {
          Text("记录新内容")
            .foregroundStyle(ClipboardHistoryPalette.ink)
          Spacer()
          Toggle(
            "记录新内容",
            isOn: Binding(
              get: { controller.isEnabled },
              set: { controller.setEnabled($0) }
            )
          )
          .labelsHidden()
          .toggleStyle(.switch)
          .tint(ClipboardHistoryPalette.brand)
          .accessibilityLabel("记录新内容")
          .accessibilityValue(controller.isEnabled ? "已打开" : "已关闭")
        }

        Divider()

        HStack(spacing: 12) {
          Text("自动保留")
            .foregroundStyle(ClipboardHistoryPalette.ink)
          Spacer()
          Picker(
            "自动保留",
            selection: Binding(
              get: { controller.retentionDays },
              set: { controller.setRetentionDays($0) }
            )
          ) {
            ForEach(ClipboardHistoryFormatting.retentionOptions, id: \.self) { days in
              Text(ClipboardHistoryFormatting.retention(days)).tag(days)
            }
          }
          .labelsHidden()
          .frame(width: 150)
          .accessibilityLabel("自动保留时间")
        }

        Divider()

        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 8) {
            Text("空间上限")
              .foregroundStyle(ClipboardHistoryPalette.ink)
            Spacer()
            TextField("5", text: $quotaText)
              .textFieldStyle(.roundedBorder)
              .frame(width: 92)
              .focused($quotaFocused)
              .onSubmit(applyQuota)
              .accessibilityLabel("自定义空间上限数值")
            Picker("单位", selection: $quotaUnit) {
              ForEach(ClipboardHistoryQuotaUnit.allCases) { unit in
                Text(unit.title).tag(unit)
              }
            }
            .labelsHidden()
            .frame(width: 76)
            .accessibilityLabel("空间上限单位")
            Button("应用", action: applyQuota)
              .buttonStyle(.bordered)
              .disabled(controller.isBusy)
          }

          if let quotaError {
            Label(quotaError, systemImage: "exclamationmark.circle.fill")
              .font(.caption)
              .foregroundStyle(ClipboardHistoryPalette.danger)
          } else {
            Text("范围 100 MB–50 GB；达到上限时优先清理最旧的未保留记录。")
              .font(.caption)
              .foregroundStyle(ClipboardHistoryPalette.muted)
          }
        }

        Divider()

        HStack(spacing: 10) {
          Button {
            controller.cleanNow()
          } label: {
            Label("立即清理", systemImage: "sparkles")
          }
          .buttonStyle(.bordered)
          .disabled(controller.isBusy)

          Button(role: .destructive) {
            isShowingClearConfirmation = true
          } label: {
            Label("清空全部历史…", systemImage: "trash")
          }
          .buttonStyle(.bordered)
          .tint(ClipboardHistoryPalette.danger)
          .disabled(controller.entries.isEmpty || controller.isBusy)

          Spacer()

          if controller.isBusy {
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel("正在处理剪贴板历史")
          }
        }
      }
      .font(.system(size: 13, weight: .medium))
    }
    .clipboardHistoryPanel()
    .onAppear(perform: loadQuota)
    .onChange(of: controller.maxBytes) { _ in
      if !quotaFocused { loadQuota() }
    }
    .confirmationDialog(
      "清空全部剪贴板历史？",
      isPresented: $isShowingClearConfirmation,
      titleVisibility: .visible
    ) {
      Button("清空全部历史", role: .destructive) {
        controller.clearAll()
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("这会删除普通记录和已保留记录，以及由历史保存的文件副本。原始文件不会被删除。")
    }
  }

  private var cleanupSummary: String {
    let retention =
      controller.retentionDays == 0
      ? "不按时间清理"
      : "超过 \(controller.retentionDays) 天"
    return
      "\(retention)或达到 \(ClipboardHistoryFormatting.bytes(controller.maxBytes)) 时，从最旧的未保留记录开始清理。"
  }

  private func loadQuota() {
    let bytes = Int64(controller.maxBytes)
    if bytes >= ClipboardHistoryQuotaUnit.gigabytes.multiplier {
      quotaUnit = .gigabytes
    } else {
      quotaUnit = .megabytes
    }

    let value = Double(bytes) / Double(quotaUnit.multiplier)
    quotaText = ClipboardHistoryFormatting.quotaNumber(value)
    quotaError = nil
  }

  private func applyQuota() {
    let normalized =
      quotaText
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: ",", with: ".")
    guard let value = Double(normalized), value.isFinite, value > 0 else {
      quotaError = "请输入有效的空间大小。"
      return
    }

    let scaledBytes = value * Double(quotaUnit.multiplier)
    let minimumBytes = 100 * ClipboardHistoryQuotaUnit.megabytes.multiplier
    let maximumBytes: Int64 = 50_000_000_000
    guard scaledBytes.isFinite, scaledBytes <= Double(maximumBytes) else {
      quotaError = "空间上限不能超过 50 GB。"
      return
    }

    guard scaledBytes >= Double(minimumBytes) else {
      quotaError = "空间上限不能低于 100 MB。"
      return
    }

    let bytes = Int64(scaledBytes.rounded(.down))

    quotaError = nil
    quotaFocused = false
    controller.setMaxBytes(bytes)
  }
}

private struct ClipboardHistorySettingsSheet: View {
  @ObservedObject var controller: ClipboardHistoryController
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("剪贴板历史设置")
            .font(.headline)
            .foregroundStyle(ClipboardHistoryPalette.ink)
          Text("排除软件、空间上限和自动清理都在这里。")
            .font(.caption)
            .foregroundStyle(ClipboardHistoryPalette.muted)
        }
        Spacer()
        Button("完成") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
      .padding(18)

      Divider()

      ScrollView {
        VStack(spacing: 16) {
          ClipboardHistorySnapshotCard(controller: controller)
          ClipboardHistoryExcludedApplicationsView(controller: controller)
          ClipboardHistorySettingsView(controller: controller)

          Label("历史文字和文件副本只保存在这台 Mac，不会上传。", systemImage: "lock.fill")
            .font(.callout)
            .foregroundStyle(ClipboardHistoryPalette.copy)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipboardHistoryPanel()
        }
        .padding(18)
      }
    }
    .frame(width: 520)
    .frame(minHeight: 520)
    .background(ClipboardHistoryPalette.paper)
  }
}

private struct ClipboardHistoryNotice: View {
  let icon: String
  let title: String
  let message: String
  let color: Color

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: icon)
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(color)
        .frame(width: 28, height: 28)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.callout.weight(.semibold))
          .foregroundStyle(ClipboardHistoryPalette.ink)
        Text(message)
          .font(.caption)
          .foregroundStyle(ClipboardHistoryPalette.copy)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 0)
    }
    .padding(13)
    .background(color.opacity(0.075), in: RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(color.opacity(0.18), lineWidth: 1)
    )
    .accessibilityElement(children: .combine)
  }
}

private struct ClipboardHistoryCompactNotice: View {
  let text: String
  let systemImage: String
  let color: Color
  var actionTitle: String? = nil
  var action: (() -> Void)? = nil

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: systemImage)
        .foregroundStyle(color)
        .accessibilityHidden(true)
      Text(text)
        .font(.caption.weight(.medium))
        .foregroundStyle(ClipboardHistoryPalette.ink)
        .lineLimit(2)
      Spacer(minLength: 6)
      if let actionTitle, let action {
        Button(actionTitle, action: action)
          .buttonStyle(.borderless)
          .font(.caption.weight(.semibold))
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(color.opacity(0.075))
    .overlay(alignment: .bottom) {
      Rectangle().fill(color.opacity(0.16)).frame(height: 1)
    }
    .accessibilityElement(children: .combine)
  }
}

private struct ClipboardHistoryEmptyState: View {
  let icon: String
  let title: String
  let message: String
  var actionTitle: String? = nil
  var action: (() -> Void)? = nil

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: icon)
        .font(.system(size: 30, weight: .medium))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(ClipboardHistoryPalette.brand)
        .accessibilityHidden(true)
      Text(title)
        .font(.headline)
        .foregroundStyle(ClipboardHistoryPalette.ink)
      Text(message)
        .font(.callout)
        .foregroundStyle(ClipboardHistoryPalette.muted)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      if let actionTitle, let action {
        Button(actionTitle, action: action)
          .buttonStyle(.bordered)
          .padding(.top, 4)
      }
    }
    .padding(28)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .combine)
  }
}

private struct ClipboardHistorySectionHeading: View {
  let title: String
  let detail: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.headline)
        .foregroundStyle(ClipboardHistoryPalette.ink)
      Text(detail)
        .font(.caption)
        .foregroundStyle(ClipboardHistoryPalette.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

private struct ClipboardHistoryPanelModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .padding(16)
      .background(
        Color(nsColor: .textBackgroundColor),
        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(ClipboardHistoryPalette.line, lineWidth: 1)
      )
  }
}

extension View {
  fileprivate func clipboardHistoryPanel() -> some View {
    modifier(ClipboardHistoryPanelModifier())
  }
}

private enum ClipboardHistoryKindFilter: String, CaseIterable, Identifiable {
  case all
  case text
  case image
  case files
  case favorites

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all: return "全部"
    case .text: return "文本"
    case .image: return "图片"
    case .files: return "文件"
    case .favorites: return "收藏"
    }
  }

  func matches(_ entry: ClipboardHistoryEntry) -> Bool {
    switch self {
    case .all: return true
    case .text: return entry.kind == .text || entry.kind == .link
    case .image: return entry.kind == .image
    case .files: return entry.kind == .files
    case .favorites: return entry.isPinned
    }
  }
}

private enum ClipboardHistoryDateBucket: String, CaseIterable {
  case recent
  case today
  case yesterday
  case earlier

  var title: String {
    switch self {
    case .recent: return "刚刚"
    case .today: return "今天"
    case .yesterday: return "昨天"
    case .earlier: return "更早"
    }
  }

  static func bucket(for date: Date) -> ClipboardHistoryDateBucket {
    let calendar = Calendar.current
    if date >= Date().addingTimeInterval(-10 * 60) { return .recent }
    if calendar.isDateInToday(date) { return .today }
    if calendar.isDateInYesterday(date) { return .yesterday }
    return .earlier
  }
}

private struct ClipboardHistorySection: Identifiable {
  let id: String
  let title: String
  let entries: [ClipboardHistoryEntry]
}

private enum ClipboardHistoryQuotaUnit: String, CaseIterable, Identifiable {
  case megabytes
  case gigabytes

  var id: String { rawValue }
  var title: String { self == .megabytes ? "MB" : "GB" }
  var multiplier: Int64 { self == .megabytes ? 1_000_000 : 1_000_000_000 }
}

private enum ClipboardHistoryFormatting {
  static let retentionOptions = [1, 7, 30, 90, 365]

  static func bytes<T: BinaryInteger>(_ value: T) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: Int64(value))
  }

  static func retention(_ days: Int) -> String {
    days == 0 ? "永不自动过期" : "保留 \(days) 天"
  }

  static func quotaNumber(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale.current
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = value.rounded() == value ? 0 : 2
    return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
  }

  static func title(_ entry: ClipboardHistoryEntry) -> String {
    switch entry.kind {
    case .text:
      return "文本"
    case .link:
      return "链接"
    case .image:
      return "图片"
    case .files:
      let count = entry.fileNames.count
      if count == 1 { return entry.fileNames.first ?? "1 个文件" }
      return "\(count) 个文件"
    }
  }

  static func summary(_ entry: ClipboardHistoryEntry) -> String {
    switch entry.kind {
    case .text, .link:
      let normalized = normalizedText(entry.textSummary)
      return normalized.isEmpty ? "没有可显示的文字" : normalized
    case .image:
      return ""
    case .files:
      let names = entry.fileNames.prefix(3).joined(separator: " · ")
      let suffix = entry.fileNames.count > 3 ? " 等" : ""
      return names.isEmpty ? bytes(entry.byteCount) : "\(names)\(suffix)"
    }
  }

  static func metadata(_ entry: ClipboardHistoryEntry) -> String {
    let source = (entry.source.applicationName ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let sourceName = source.isEmpty ? "未知来源" : source
    return "\(sourceName) · \(relativeDate(entry.lastCopiedAt)) · \(bytes(entry.byteCount))"
  }

  static func symbol(_ entry: ClipboardHistoryEntry) -> String {
    switch entry.kind {
    case .text: return "text.alignleft"
    case .link: return "link"
    case .image: return "photo.fill"
    case .files: return entry.fileNames.count > 1 ? "doc.on.doc.fill" : "doc.fill"
    }
  }

  static func matches(
    _ entry: ClipboardHistoryEntry,
    query: String
  ) -> Bool {
    let candidates = [entry.textSummary, entry.source.applicationName ?? ""] + entry.fileNames
    return candidates.contains { $0.localizedCaseInsensitiveContains(query) }
  }

  static func accessibilityLabel(_ entry: ClipboardHistoryEntry) -> String {
    let title = title(entry)
    let summary = summary(entry)
    var parts = [title]
    if !summary.isEmpty, summary != title {
      parts.append(summary)
    }
    parts.append(metadata(entry))
    if entry.copyCount > 1 { parts.append("复制 \(entry.copyCount) 次") }
    if entry.isPinned { parts.append("已保留") }
    return parts.joined(separator: "。")
  }

  private static func normalizedText(_ text: String) -> String {
    text
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }

  private static func relativeDate(_ date: Date) -> String {
    let now = Date()
    if abs(date.timeIntervalSince(now)) < 10 { return "刚刚" }
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = Locale.current
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: now)
  }
}

@MainActor
private enum ClipboardHistoryAccessibilityAnnouncer {
  static func announce(_ text: String) {
    guard !text.isEmpty else { return }
    NSAccessibility.post(
      element: NSApplication.shared,
      notification: .announcementRequested,
      userInfo: [
        .announcement: text,
        .priority: NSAccessibilityPriorityLevel.medium.rawValue,
      ]
    )
  }
}
