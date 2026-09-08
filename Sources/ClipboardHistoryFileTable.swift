import AppKit
import QuickLookUI
import SwiftUI

extension Notification.Name {
  static let clipboardHistoryWindowWillHide = Notification.Name(
    "cn.tlww.aixlg.clipboard-history.window-will-hide")
}

struct ClipboardHistoryFileListItem: Equatable, Identifiable {
  let index: Int
  let name: String
  let url: URL?
  let isAvailable: Bool

  var id: Int { index }
}

struct ClipboardHistoryNativeFileList: NSViewRepresentable {
  let items: [ClipboardHistoryFileListItem]
  let isBusy: Bool
  let requestPreview: (Int, @escaping (Result<ClipboardHistoryWorkingCopy, Error>) -> Void) -> Void
  let openCopy: (Int) -> Void
  let revealCopy: (Int) -> Void
  let discardCopy: (ClipboardHistoryWorkingCopy) -> Void
  let activateEntry: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let table = ClipboardHistoryFileTableView()
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("history-file"))
    column.resizingMask = .autoresizingMask
    table.addTableColumn(column)
    table.headerView = nil
    table.rowHeight = 54
    table.intercellSpacing = NSSize(width: 0, height: 0)
    table.selectionHighlightStyle = .regular
    table.allowsEmptySelection = false
    table.allowsMultipleSelection = false
    table.usesAlternatingRowBackgroundColors = false
    table.backgroundColor = .textBackgroundColor
    table.focusRingType = .default
    table.gridStyleMask = .solidHorizontalGridLineMask
    table.gridColor = .separatorColor
    table.delegate = context.coordinator
    table.dataSource = context.coordinator
    context.coordinator.tableView = table
    context.coordinator.configure(parent: self)

    let scrollView = NSScrollView()
    scrollView.documentView = table
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    context.coordinator.configure(parent: self)
    guard let table = scrollView.documentView as? ClipboardHistoryFileTableView else { return }
    let previousSelection = table.selectedRow
    let itemsChanged = table.configure(
      items: items,
      isActionEnabled: !isBusy,
      requestPreview: requestPreview,
      openCopy: openCopy,
      revealCopy: revealCopy,
      discardCopy: discardCopy,
      activateEntry: activateEntry)
    if itemsChanged {
      context.coordinator.performProgrammaticSelectionUpdate {
        table.reloadData()
        if items.indices.contains(previousSelection) {
          table.selectRowIndexes(
            IndexSet(integer: previousSelection), byExtendingSelection: false)
        } else if !items.isEmpty {
          table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
      }
    }
    table.setAccessibilityLabel("历史文件列表，共 \(items.count) 个文件")
    table.setAccessibilityHelp("单击选择，按空格快速查看；双击把整组放回剪贴板并收起面板")
  }

  static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
    (scrollView.documentView as? ClipboardHistoryFileTableView)?.prepareForDismantle()
    scrollView.documentView = nil
  }

  final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    fileprivate weak var tableView: ClipboardHistoryFileTableView?
    private var parent: ClipboardHistoryNativeFileList
    private var lastSelectedRow = -1
    private var isApplyingProgrammaticSelection = false

    init(parent: ClipboardHistoryNativeFileList) {
      self.parent = parent
    }

    func configure(parent: ClipboardHistoryNativeFileList) {
      self.parent = parent
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
      parent.items.count
    }

    fileprivate func performProgrammaticSelectionUpdate(_ update: () -> Void) {
      isApplyingProgrammaticSelection = true
      defer {
        isApplyingProgrammaticSelection = false
        lastSelectedRow = tableView?.selectedRow ?? -1
        tableView?.refreshVisiblePreviewForSelection()
      }
      update()
    }

    func tableView(
      _ tableView: NSTableView,
      viewFor tableColumn: NSTableColumn?,
      row: Int
    ) -> NSView? {
      guard parent.items.indices.contains(row) else { return nil }
      let identifier = ClipboardHistoryFileCellView.reuseIdentifier
      let cell =
        tableView.makeView(withIdentifier: identifier, owner: nil)
        as? ClipboardHistoryFileCellView ?? ClipboardHistoryFileCellView()
      cell.identifier = identifier
      cell.configure(item: parent.items[row])
      return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
      guard !isApplyingProgrammaticSelection, let tableView,
        tableView.selectedRow != lastSelectedRow
      else { return }
      lastSelectedRow = tableView.selectedRow
      tableView.refreshVisiblePreviewForSelection()
    }
  }
}

private final class ClipboardHistoryFileTableView: NSTableView, QLPreviewPanelDataSource,
  QLPreviewPanelDelegate
{
  private final class PreviewRetirementToken {
    var isCancelled = false
    var isCompleted = false
  }

  private struct RetiredPreviewCopy {
    let row: Int
    let workingCopy: ClipboardHistoryWorkingCopy
    let token: PreviewRetirementToken
  }

  private var fileItems: [ClipboardHistoryFileListItem] = []
  private var isActionEnabled = true
  private var requestPreview:
    ((Int, @escaping (Result<ClipboardHistoryWorkingCopy, Error>) -> Void) -> Void)?
  private var openCopy: ((Int) -> Void)?
  private var revealCopy: ((Int) -> Void)?
  private var discardCopy: ((ClipboardHistoryWorkingCopy) -> Void)?
  private var activateEntry: (() -> Void)?
  private var previewCopy: ClipboardHistoryWorkingCopy?
  private var previewCopyRow: Int?
  private var retiredPreviewCopies: [RetiredPreviewCopy] = []
  private var previewRequestGeneration = 0
  private var previewRequestInFlight = false
  private var pendingPreviewRow: Int?
  private var expectsPreview = false
  private var windowHideObserver: NSObjectProtocol?

  private static let previewDiscardDelay: TimeInterval = 8

  override var acceptsFirstResponder: Bool { true }

  func configure(
    items: [ClipboardHistoryFileListItem],
    isActionEnabled: Bool,
    requestPreview:
      @escaping (Int, @escaping (Result<ClipboardHistoryWorkingCopy, Error>) -> Void) -> Void,
    openCopy: @escaping (Int) -> Void,
    revealCopy: @escaping (Int) -> Void,
    discardCopy: @escaping (ClipboardHistoryWorkingCopy) -> Void,
    activateEntry: @escaping () -> Void
  ) -> Bool {
    let itemsChanged = fileItems != items
    fileItems = items
    self.isActionEnabled = isActionEnabled
    self.requestPreview = requestPreview
    self.openCopy = openCopy
    self.revealCopy = revealCopy
    self.discardCopy = discardCopy
    self.activateEntry = activateEntry
    target = self
    doubleAction = #selector(activateSelectedHistoryEntry)
    setAccessibilityCustomActions([
      NSAccessibilityCustomAction(name: "复制整组并收起面板") { [weak self] in
        guard let self, self.isActionEnabled else { return false }
        self.activateEntry?()
        return true
      },
      NSAccessibilityCustomAction(name: "快速查看所选文件") { [weak self] in
        guard let self else { return false }
        let canClosePreview = self.expectsPreview || self.ownsVisiblePreviewPanel
        guard canClosePreview || self.actionableSelectedRow != nil else { return false }
        self.toggleQuickLook()
        return true
      },
      NSAccessibilityCustomAction(name: "打开所选文件副本") { [weak self] in
        guard let self, self.actionableSelectedRow != nil else { return false }
        self.openSelectedCopy()
        return true
      },
      NSAccessibilityCustomAction(name: "在访达中显示所选副本") { [weak self] in
        guard let self, self.actionableSelectedRow != nil else { return false }
        self.revealSelectedCopy()
        return true
      },
    ])
    return itemsChanged
  }

  deinit {
    cancelPreviewAndClosePanel()
    if let windowHideObserver {
      NotificationCenter.default.removeObserver(windowHideObserver)
    }
  }

  override func keyDown(with event: NSEvent) {
    let blockingModifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
    if event.keyCode == 49, blockingModifiers.isEmpty, !event.isARepeat {
      toggleQuickLook()
      return
    }
    super.keyDown(with: event)
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    let location = convert(event.locationInWindow, from: nil)
    let clickedRow = row(at: location)
    guard fileItems.indices.contains(clickedRow) else { return nil }
    selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
    window?.makeFirstResponder(self)

    let enabled = isActionEnabled && fileItems[clickedRow].isAvailable
    let menu = NSMenu()
    let previewItem = NSMenuItem(
      title: "快速查看",
      action: #selector(toggleQuickLookFromMenu),
      keyEquivalent: " ")
    previewItem.target = self
    previewItem.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
    previewItem.isEnabled = enabled
    menu.addItem(previewItem)

    let openItem = NSMenuItem(
      title: "打开副本",
      action: #selector(openSelectedCopy),
      keyEquivalent: "")
    openItem.target = self
    openItem.image = NSImage(
      systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil)
    openItem.isEnabled = enabled
    menu.addItem(openItem)

    menu.addItem(.separator())
    let revealItem = NSMenuItem(
      title: "在访达中显示副本",
      action: #selector(revealSelectedCopy),
      keyEquivalent: "")
    revealItem.target = self
    revealItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
    revealItem.isEnabled = enabled
    menu.addItem(revealItem)
    return menu
  }

  @objc private func toggleQuickLookFromMenu() {
    toggleQuickLook()
  }

  private func toggleQuickLook() {
    if ownsVisiblePreviewPanel {
      cancelPreviewAndClosePanel()
      return
    }
    if expectsPreview {
      cancelPreviewAndClosePanel()
      return
    }
    guard let row = actionableSelectedRow else {
      NSSound.beep()
      return
    }
    expectsPreview = true
    requestPreviewForRow(row)
  }

  private var ownsVisiblePreviewPanel: Bool {
    guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared() else {
      return false
    }
    return panel.isVisible && ownsPreviewPanel(panel) && canClaimPreviewPanel(panel)
  }

  private func ownsPreviewPanel(_ panel: QLPreviewPanel) -> Bool {
    (panel.currentController as AnyObject?) === self
      || (panel.dataSource as AnyObject?) === self
      || (panel.delegate as AnyObject?) === self
  }

  private func canClaimPreviewPanel(_ panel: QLPreviewPanel) -> Bool {
    (panel.currentController == nil || (panel.currentController as AnyObject?) === self)
      && (panel.dataSource == nil || (panel.dataSource as AnyObject?) === self)
      && (panel.delegate == nil || (panel.delegate as AnyObject?) === self)
  }

  @objc private func openSelectedCopy() {
    guard let row = actionableSelectedRow else {
      NSSound.beep()
      return
    }
    openCopy?(row)
  }

  @objc private func activateSelectedHistoryEntry() {
    guard isActionEnabled else {
      NSSound.beep()
      return
    }
    activateEntry?()
  }

  @objc private func revealSelectedCopy() {
    guard let row = actionableSelectedRow else {
      NSSound.beep()
      return
    }
    revealCopy?(row)
  }

  fileprivate func refreshVisiblePreviewForSelection() {
    let panelIsOurs: Bool
    if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared() {
      panelIsOurs =
        panel.isVisible && ownsPreviewPanel(panel) && canClaimPreviewPanel(panel)
    } else {
      panelIsOurs = false
    }
    guard expectsPreview || panelIsOurs else { return }
    guard fileItems.indices.contains(selectedRow), fileItems[selectedRow].isAvailable else {
      cancelPreviewAndClosePanel()
      return
    }
    let row = selectedRow
    requestPreviewForRow(row)
  }

  private var actionableSelectedRow: Int? {
    guard isActionEnabled, fileItems.indices.contains(selectedRow),
      fileItems[selectedRow].isAvailable
    else { return nil }
    return selectedRow
  }

  private func requestPreviewForRow(_ row: Int) {
    if let workingCopy = takeRetiredPreviewCopy(for: row) {
      pendingPreviewRow = nil
      presentPreview(workingCopy, row: row)
      return
    }
    pendingPreviewRow = row
    drainPendingPreviewRequest()
  }

  private func drainPendingPreviewRequest() {
    guard expectsPreview, !previewRequestInFlight, let row = pendingPreviewRow,
      fileItems.indices.contains(row), fileItems[row].isAvailable
    else { return }
    pendingPreviewRow = nil
    previewRequestInFlight = true
    let generation = previewRequestGeneration
    let discard = discardCopy
    requestPreview?(row) { [weak self] result in
      guard let self else {
        if case .success(let workingCopy) = result { discard?(workingCopy) }
        return
      }
      self.previewRequestInFlight = false
      guard generation == self.previewRequestGeneration, self.expectsPreview else {
        if case .success(let workingCopy) = result { self.discardCopy?(workingCopy) }
        self.drainPendingPreviewRequest()
        return
      }
      switch result {
      case .success(let workingCopy):
        if self.selectedRow == row, self.pendingPreviewRow == nil {
          self.presentPreview(workingCopy, row: row)
        } else {
          self.discardCopy?(workingCopy)
        }
      case .failure:
        if self.pendingPreviewRow == nil {
          self.cancelPreviewAndClosePanel()
          return
        }
      }
      self.drainPendingPreviewRequest()
    }
  }

  private func presentPreview(_ workingCopy: ClipboardHistoryWorkingCopy, row: Int) {
    releasePreviewReference()
    previewCopy = workingCopy
    previewCopyRow = row

    if QLPreviewPanel.sharedPreviewPanelExists(),
      let panel = QLPreviewPanel.shared(),
      panel.isVisible,
      ownsPreviewPanel(panel),
      canClaimPreviewPanel(panel)
    {
      panel.currentPreviewItemIndex = 0
      panel.reloadData()
      panel.refreshCurrentPreviewItem()
      return
    }

    window?.makeFirstResponder(self)
    guard let panel = QLPreviewPanel.shared() else {
      previewCopy = nil
      previewCopyRow = nil
      expectsPreview = false
      discardCopy?(workingCopy)
      return
    }
    panel.updateController()
    guard canClaimPreviewPanel(panel) else {
      expectsPreview = false
      releasePreviewReference()
      return
    }
    if !ownsPreviewPanel(panel) {
      panel.dataSource = self
      panel.delegate = self
    }
    guard ownsPreviewPanel(panel) else {
      expectsPreview = false
      releasePreviewReference()
      return
    }
    panel.currentPreviewItemIndex = 0
    panel.reloadData()
    panel.makeKeyAndOrderFront(nil)
    panel.refreshCurrentPreviewItem()
  }

  override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
    expectsPreview && previewCopy != nil
  }

  override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
    panel.dataSource = self
    panel.delegate = self
    panel.currentPreviewItemIndex = 0
    panel.reloadData()
  }

  override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
    invalidatePendingPreviewRequest()
    expectsPreview = false
    pendingPreviewRow = nil
    releasePreviewReference()
    if (panel.dataSource as AnyObject?) === self { panel.dataSource = nil }
    if (panel.delegate as AnyObject?) === self { panel.delegate = nil }
  }

  func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
    previewCopy == nil ? 0 : 1
  }

  func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
    previewCopy?.url as NSURL?
  }

  func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
    guard let event, event.type == .keyDown else { return false }
    let blockingModifiers = event.modifierFlags.intersection([
      .command, .control, .option, .shift,
    ])
    guard blockingModifiers.isEmpty, !event.isARepeat else { return false }

    switch event.keyCode {
    case 49:
      cancelPreviewAndClosePanel()
      return true
    case 125:
      movePreviewSelection(by: 1)
      return true
    case 126:
      movePreviewSelection(by: -1)
      return true
    default:
      return false
    }
  }

  func windowWillClose(_ notification: Notification) {
    guard notification.object as? QLPreviewPanel != nil else { return }
    cancelPreviewAndClosePanel()
  }

  func windowDidResignKey(_ notification: Notification) {
    guard let panel = notification.object as? QLPreviewPanel else { return }
    DispatchQueue.main.async { [weak self, weak panel] in
      guard let self, let panel, !panel.isVisible else { return }
      self.cancelPreviewAndClosePanel()
    }
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil {
      cancelPreviewAndClosePanel()
      if let windowHideObserver {
        NotificationCenter.default.removeObserver(windowHideObserver)
        self.windowHideObserver = nil
      }
    } else if windowHideObserver == nil {
      windowHideObserver = NotificationCenter.default.addObserver(
        forName: .clipboardHistoryWindowWillHide,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.cancelPreviewAndClosePanel()
      }
    }
    super.viewWillMove(toWindow: newWindow)
  }

  private func cancelPreviewAndClosePanel() {
    invalidatePendingPreviewRequest()
    expectsPreview = false
    pendingPreviewRow = nil
    releasePreviewReference()
    if QLPreviewPanel.sharedPreviewPanelExists(),
      let panel = QLPreviewPanel.shared()
    {
      if ownsPreviewPanel(panel) && canClaimPreviewPanel(panel) {
        panel.orderOut(nil)
        if (panel.dataSource as AnyObject?) === self { panel.dataSource = nil }
        if (panel.delegate as AnyObject?) === self { panel.delegate = nil }
        panel.updateController()
      }
    }
  }

  private func invalidatePendingPreviewRequest() {
    previewRequestGeneration &+= 1
  }

  private func movePreviewSelection(by offset: Int) {
    guard !fileItems.isEmpty else { return }
    let current = fileItems.indices.contains(selectedRow) ? selectedRow : 0
    let destination = min(max(0, current + offset), fileItems.count - 1)
    guard destination != selectedRow else { return }
    selectRowIndexes(IndexSet(integer: destination), byExtendingSelection: false)
    scrollRowToVisible(destination)
  }

  fileprivate func prepareForDismantle() {
    cancelPreviewAndClosePanel()
  }

  private func releasePreviewReference() {
    guard let previewCopy, let previewCopyRow else { return }
    self.previewCopy = nil
    self.previewCopyRow = nil
    retiredPreviewCopies.removeAll { $0.token.isCompleted }
    let token = PreviewRetirementToken()
    retiredPreviewCopies.append(
      RetiredPreviewCopy(row: previewCopyRow, workingCopy: previewCopy, token: token))
    let discard = discardCopy
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.previewDiscardDelay) {
      guard !token.isCancelled else { return }
      token.isCompleted = true
      discard?(previewCopy)
    }
  }

  private func takeRetiredPreviewCopy(for row: Int) -> ClipboardHistoryWorkingCopy? {
    retiredPreviewCopies.removeAll { $0.token.isCompleted }
    guard let index = retiredPreviewCopies.lastIndex(where: { $0.row == row }) else {
      return nil
    }
    let retired = retiredPreviewCopies.remove(at: index)
    retired.token.isCancelled = true
    return retired.workingCopy
  }
}

private final class ClipboardHistoryFileCellView: NSTableCellView {
  static let reuseIdentifier = NSUserInterfaceItemIdentifier("history-file-cell")

  private let fileIcon = NSImageView()
  private let titleLabel = NSTextField(labelWithString: "")
  private let unavailableLabel = NSTextField(labelWithString: "")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    fileIcon.translatesAutoresizingMaskIntoConstraints = false
    fileIcon.imageScaling = .scaleProportionallyUpOrDown
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = .systemFont(ofSize: 14)
    titleLabel.lineBreakMode = .byTruncatingMiddle
    titleLabel.maximumNumberOfLines = 2
    unavailableLabel.translatesAutoresizingMaskIntoConstraints = false
    unavailableLabel.font = .systemFont(ofSize: 11, weight: .medium)
    unavailableLabel.textColor = .systemOrange

    addSubview(fileIcon)
    addSubview(titleLabel)
    addSubview(unavailableLabel)
    NSLayoutConstraint.activate([
      fileIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      fileIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
      fileIcon.widthAnchor.constraint(equalToConstant: 28),
      fileIcon.heightAnchor.constraint(equalToConstant: 28),
      titleLabel.leadingAnchor.constraint(equalTo: fileIcon.trailingAnchor, constant: 12),
      titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      titleLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: unavailableLabel.leadingAnchor, constant: -8),
      unavailableLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
      unavailableLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    nil
  }

  func configure(item: ClipboardHistoryFileListItem) {
    titleLabel.stringValue = item.name
    unavailableLabel.stringValue = item.isAvailable ? "" : "不可用"
    if let url = item.url, item.isAvailable {
      fileIcon.image = NSWorkspace.shared.icon(forFile: url.path)
    } else {
      fileIcon.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
    }
    toolTip =
      item.isAvailable
      ? "\(item.name)：单击选择，空格快速查看；双击把整组放回剪贴板并收起面板"
      : "\(item.name)：历史副本不可用"
    setAccessibilityLabel(
      "\(item.name)，\(item.isAvailable ? "历史副本存在" : "历史副本不可用")")
    setAccessibilityHelp(
      item.isAvailable
        ? "按空格快速查看；双击把整组放回剪贴板并收起面板，右键可安全打开副本"
        : "无法打开")
  }

  override var backgroundStyle: NSView.BackgroundStyle {
    didSet {
      titleLabel.textColor =
        backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .labelColor
    }
  }
}
