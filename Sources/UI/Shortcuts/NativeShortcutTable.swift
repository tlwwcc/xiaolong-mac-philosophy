import AppKit
import SwiftUI

/// Own native row geometry and reload only when the document changes. SwiftUI's estimated
/// automatic row heights otherwise move the viewport as hosted cells are materialized.
struct NativeShortcutTable: NSViewRepresentable {
  let model: AppModel
  let rows: [ShortcutItem]
  let columns: ShortcutTableColumnWidths
  let viewports: ShortcutTableViewportStore
  let viewportKey: String
  let edit: ((String) -> Void)?
  let delete: (ShortcutItem) -> Void

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    scroll.borderType = .noBorder
    let table = ShortcutNativeTableView()
    table.usesAutomaticRowHeights = false
    table.rowHeight = 64
    table.intercellSpacing = NSSize(width: 0, height: 1)
    table.usesAlternatingRowBackgroundColors = true
    table.allowsMultipleSelection = false
    table.allowsEmptySelection = true
    table.columnAutoresizingStyle = .noColumnAutoresizing
    table.setAccessibilityIdentifier("shortcuts.table")
    table.setAccessibilityLabel("快捷键列表")
    for (id, title) in [
      ("feature", "功能"), ("hotkey", "快捷键"), ("description", "说明"), ("enabled", "启用"),
    ] {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
      column.title = title
      column.resizingMask = []
      if id == "feature" {
        column.sortDescriptorPrototype = NSSortDescriptor(
          key: "name", ascending: true, selector: #selector(NSString.localizedStandardCompare(_:)))
      }
      table.addTableColumn(column)
    }
    table.dataSource = context.coordinator
    table.delegate = context.coordinator
    table.target = context.coordinator
    table.doubleAction = #selector(Coordinator.doubleClick)
    scroll.documentView = table
    context.coordinator.scroll = scroll
    table.deleteSelection = { [weak coordinator = context.coordinator] in
      coordinator?.deleteSelection()
    }
    table.activateSelection = { [weak coordinator = context.coordinator] in
      coordinator?.activateSelection()
    }
    scroll.contentView.postsBoundsChangedNotifications = true
    context.coordinator.boundsObserver = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
    ) { [weak coordinator = context.coordinator] _ in
      MainActor.assumeIsolated { coordinator?.savePosition() }
    }
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.update(self)
  }

  static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
    coordinator.savePosition()
    if let observer = coordinator.boundsObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    coordinator.boundsObserver = nil
    if let table = scroll.documentView as? ShortcutNativeTableView {
      table.deleteSelection = nil
      table.activateSelection = nil
      table.dataSource = nil
      table.delegate = nil
      table.target = nil
    }
  }

  @MainActor
  final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    weak var scroll: NSScrollView?
    var boundsObserver: NSObjectProtocol?
    private var input: NativeShortcutTable?
    private var displayedRows: [ShortcutItem] = []
    private var updating = false

    func savePosition() {
      guard let input, let scroll else { return }
      input.viewports.save(scroll.contentView.bounds.origin, for: input.viewportKey)
    }

    func update(_ value: NativeShortcutTable) {
      guard let scroll, let table = scroll.documentView as? NSTableView else { return }
      let changesFilter = input?.viewportKey != value.viewportKey
      if changesFilter { savePosition() }
      let position =
        changesFilter
        ? value.viewports.position(for: value.viewportKey)
          ?? NSPoint(x: 0, y: -(table.headerView?.frame.height ?? 0))
        : scroll.contentView.bounds.origin
      input = value
      updating = true
      defer { updating = false }
      let newRows = sorted(value.rows, by: table.sortDescriptors)
      if displayedRows != newRows {
        displayedRows = newRows
        table.reloadData()
      }
      for (index, width) in [
        value.columns.feature, value.columns.hotkey, value.columns.description, 46,
      ].enumerated() {
        if table.tableColumns[index].width != width { table.tableColumns[index].width = width }
      }
      let selected = displayedRows.firstIndex { $0.id == value.model.selectedID }
      if table.selectedRow != (selected ?? -1) {
        table.selectRowIndexes(
          selected.map { IndexSet(integer: $0) } ?? [], byExtendingSelection: false)
      }
      scroll.layoutSubtreeIfNeeded()
      scroll.contentView.scroll(to: position)
      scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func sorted(_ rows: [ShortcutItem], by descriptors: [NSSortDescriptor])
      -> [ShortcutItem]
    {
      guard let descriptor = descriptors.first else { return rows }
      return rows.sorted {
        let comparison = $0.name.localizedStandardCompare($1.name)
        return descriptor.ascending
          ? comparison == .orderedAscending : comparison == .orderedDescending
      }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { displayedRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
      -> NSView?
    {
      guard let input, displayedRows.indices.contains(row), let tableColumn else { return nil }
      let item = displayedRows[row]
      let model = input.model
      let edit = input.edit.map { action in
        {
          model.selectedID = item.id
          action(item.id)
        }
      }
      let deletion = { input.delete(item) }
      return NSHostingView(
        rootView: NativeShortcutCell(
          model: model, item: item, columnID: tableColumn.identifier.rawValue,
          edit: edit, delete: deletion))
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
      guard !updating, let table = notification.object as? NSTableView, let input else { return }
      let selected =
        displayedRows.indices.contains(table.selectedRow)
        ? displayedRows[table.selectedRow].id : nil
      if input.model.selectedID != selected { input.model.selectedID = selected }
    }

    func tableView(
      _ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
    ) {
      guard let input else { return }
      update(input)
    }

    @objc func doubleClick(_ table: NSTableView) {
      guard let input, displayedRows.indices.contains(table.clickedRow) else { return }
      let item = displayedRows[table.clickedRow]
      input.model.selectedID = item.id
      input.edit?(item.id)
    }

    func deleteSelection() {
      guard let input, input.model.recordingItemID == nil, !input.model.isDraftShortcutRecording,
        let table = scroll?.documentView as? NSTableView,
        displayedRows.indices.contains(table.selectedRow)
      else { return }
      input.delete(displayedRows[table.selectedRow])
    }

    func activateSelection() {
      guard let input, input.model.recordingItemID == nil, !input.model.isDraftShortcutRecording,
        let table = scroll?.documentView as? NSTableView,
        displayedRows.indices.contains(table.selectedRow)
      else { return }
      let item = displayedRows[table.selectedRow]
      input.model.selectedID = item.id
      input.edit?(item.id)
    }
  }
}

final class ShortcutNativeTableView: NSTableView {
  var deleteSelection: (() -> Void)?
  var activateSelection: (() -> Void)?

  override func rightMouseDown(with event: NSEvent) {
    let row = row(at: convert(event.locationInWindow, from: nil))
    if row >= 0 { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
    super.rightMouseDown(with: event)
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 51 || event.keyCode == 117 {
      deleteSelection?()
    } else if (event.keyCode == 36 || event.keyCode == 76),
      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
    {
      if !event.isARepeat { activateSelection?() }
    } else {
      super.keyDown(with: event)
    }
  }
}

private struct NativeShortcutCell: View {
  @ObservedObject var model: AppModel
  let item: ShortcutItem
  let columnID: String
  let edit: (() -> Void)?
  let delete: () -> Void

  var body: some View {
    let content: AnyView
    switch columnID {
    case "feature":
      content = AnyView(
        ShortcutFeatureCell(model: model, item: item, edit: edit, delete: delete)
          .accessibilityIdentifier("shortcut.row.\(item.id)"))
    case "hotkey":
      content = AnyView(
        HotkeyCell(
          text: item.displayHotkey, active: model.isRecording(item.id),
          recordingOwnerID: model.isRecording(item.id) ? model.shortcutRecordingSessionID : nil,
          isProtected: !model.canDeleteShortcut(id: item.id),
          onKeyDown: { model.applyRecorded($0, ownerID: $1) }
        ) {
          model.selectedID = item.id
          model.startRecording(itemID: item.id)
        })
    case "description": content = AnyView(ShortcutDescriptionCell(item: item))
    default:
      content = AnyView(
        Toggle(
          "启用",
          isOn: Binding(
            get: { model.items.first(where: { $0.id == item.id })?.enabled ?? false },
            set: {
              model.selectedID = item.id
              model.updateEnabled(item.id, $0)
            }
          )
        )
        .labelsHidden().toggleStyle(.checkbox)
        .accessibilityLabel("\(item.name)，启用")
        .accessibilityIdentifier("shortcut.enabled.\(item.id)"))
    }
    return
      content
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      .contextMenu {
        shortcutRowMenuContent(model: model, item: item, edit: edit, delete: delete)
          .onAppear { model.selectedID = item.id }
      }
  }
}
