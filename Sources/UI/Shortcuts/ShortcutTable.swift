import AppKit
import SwiftUI

/// Native table selection owns navigation; cells submit mutations through AppModel.
struct ShortcutTableView: View {
  @EnvironmentObject private var model: AppModel
  let selectedModule: String
  let itemIDs: [String]?
  let viewportKey: String
  let editShortcut: ((String) -> Void)?
  @State private var pendingDeletion: ShortcutItem?

  init(
    selectedModule: String, itemIDs: [String]? = nil, viewportKey: String = "",
    editShortcut: ((String) -> Void)? = nil
  ) {
    self.selectedModule = selectedModule
    self.itemIDs = itemIDs
    self.viewportKey = viewportKey
    self.editShortcut = editShortcut
  }

  private var rows: [ShortcutItem] {
    let allowed = itemIDs.map(Set.init)
    return model.items.filter { item in
      allowed?.contains(item.id) ?? belongsToModule(item, selectedModule)
    }
  }

  var body: some View {
    Group {
      if rows.isEmpty {
        ShortcutGuideEmptyState(searchText: "", selectedCategory: selectedModule)
      } else {
        GeometryReader { geometry in
          let columns = ShortcutTableColumnWidths(availableWidth: geometry.size.width)
          NativeShortcutTable(
            model: model, rows: rows, columns: columns,
            viewports: model.mainWorkspace.shortcutTableViewports,
            viewportKey: selectedModule + "\n" + viewportKey,
            edit: editShortcut.map { edit in { id in selectAndEdit(id, edit: edit) } },
            delete: requestDeletion
          )
          .accessibilityLabel("快捷键列表")
          .accessibilityIdentifier("shortcuts.table")
        }
      }
    }
    .alert(
      "删除这条快捷键？",
      isPresented: Binding(
        get: { pendingDeletion != nil },
        set: { if !$0 { pendingDeletion = nil } }
      ), presenting: pendingDeletion
    ) { item in
      Button("取消", role: .cancel) { pendingDeletion = nil }
      Button("删除", role: .destructive) {
        model.deleteShortcut(id: item.id)
        pendingDeletion = nil
      }
    } message: { item in
      Text(model.shortcutDeletionHelp(id: item.id))
    }
  }

  private func selectAndEdit(_ id: String, edit: (String) -> Void) {
    model.selectedID = id
    edit(id)
  }

  private func requestDeletion(_ item: ShortcutItem) {
    model.selectedID = item.id
    guard model.canDeleteShortcut(id: item.id) else { return }
    model.cancelRecordingIfNeeded()
    pendingDeletion = item
  }
}

/// Native cell insets plus the reusable cells' horizontal padding take 96 points.
/// Reserve that space so the enabled control remains visible at the minimum window width.
struct ShortcutTableColumnWidths {
  let feature: CGFloat
  let hotkey: CGFloat
  let description: CGFloat

  init(availableWidth: CGFloat) {
    hotkey = availableWidth < 760 ? 150 : 185
    let flexible = max(280, availableWidth - 96 - hotkey - 46)
    feature = max(190, min(340, flexible * 0.52))
    description = max(90, flexible - feature)
  }
}

struct HeaderRow: View {
  var body: some View {
    HStack(spacing: 0) {
      HeaderCell("启用", width: 52)
      HeaderCell("功能", width: 300)
      HeaderCell("快捷键", width: 190)
      FlexHeaderCell("说明")
    }
    .frame(height: 38)
    .background(AppVisualStyle.surface)
    .overlay(Rectangle().fill(hairline).frame(height: 1), alignment: .bottom)
  }
}

struct HeaderCell: View {
  let title: String
  let width: CGFloat

  init(_ title: String, width: CGFloat) {
    self.title = title
    self.width = width
  }

  var body: some View {
    Text(title)
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(muted)
      .padding(.leading, 10)
      .frame(width: width, alignment: .leading)
  }
}

struct FlexHeaderCell: View {
  let title: String

  init(_ title: String) {
    self.title = title
  }

  var body: some View {
    Text(title)
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(muted)
      .padding(.leading, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct ShortcutRow: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Binding var item: ShortcutItem
  let editShortcut: ((String) -> Void)?
  @State private var hovering = false
  @State private var showDeleteConfirmation = false

  private var selected: Bool {
    model.selectedID == item.id
  }

  var body: some View {
    HStack(spacing: 0) {
      Toggle(
        "",
        isOn: Binding(
          get: { item.enabled },
          set: { value in
            model.selectedID = item.id
            model.updateEnabled(item.id, value)
          }
        )
      )
      .toggleStyle(.checkbox)
      .frame(width: 52)
      .accessibilityIdentifier("shortcut.enabled.\(item.id)")
      .accessibilityLabel("\(item.name)，启用")

      ShortcutFeatureCell(
        model: model,
        item: item,
        edit: editAction,
        delete: {
          showDeleteConfirmation = true
        }
      )
      .frame(width: 300)

      HotkeyCell(
        text: item.displayHotkey,
        active: model.isRecording(item.id),
        recordingOwnerID: model.isRecording(item.id) ? model.shortcutRecordingSessionID : nil,
        isProtected: !model.canDeleteShortcut(id: item.id),
        onKeyDown: { event, ownerID in
          model.applyRecorded(event, ownerID: ownerID)
        }
      ) {
        model.selectedID = item.id
        model.startRecording(itemID: item.id)
      }
      .frame(width: 190)

      ShortcutDescriptionCell(item: item)
        .frame(maxWidth: .infinity)

    }
    .padding(.vertical, 5)
    .frame(minHeight: 64)
    .background(rowBackground)
    .overlay(Rectangle().fill(line).frame(height: 1), alignment: .bottom)
    .overlay(
      Rectangle()
        .fill(selected ? AppVisualStyle.accent : Color.clear)
        .frame(width: 3),
      alignment: .leading
    )
    .contextMenu {
      shortcutRowMenuContent(model: model, item: item, edit: editAction) {
        showDeleteConfirmation = true
      }
      .onAppear(perform: selectForContextMenu)
    }
    .alert("删除这条快捷键？", isPresented: $showDeleteConfirmation) {
      Button("取消", role: .cancel) {}
      Button("删除", role: .destructive) {
        model.deleteShortcut(id: item.id)
      }
    } message: {
      Text(model.shortcutDeletionHelp(id: item.id))
    }
    .onHover { inside in
      hovering = inside
    }
    .accessibilityIdentifier("shortcut.row.\(item.id)")
    .accessibilityAddTraits(selected ? .isSelected : [])
    .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: selected)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
  }

  private var rowBackground: Color {
    if selected { return AppVisualStyle.selection }
    return hovering ? AppVisualStyle.hover : AppVisualStyle.surface
  }

  private var editAction: (() -> Void)? {
    guard let editShortcut else { return nil }
    return { editShortcut(item.id) }
  }

  private func selectForContextMenu() {
    guard model.selectedID != item.id else { return }
    model.selectedID = item.id
  }
}
