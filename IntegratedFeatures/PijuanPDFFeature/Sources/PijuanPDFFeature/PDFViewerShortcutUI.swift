import AppKit
import SwiftUI

struct PDFViewerShortcutSettingsView: View {
  @ObservedObject var shortcuts: PDFViewerShortcutStore
  let embedded: Bool
  @State private var feedbackText: String?
  @State private var feedbackAction: PDFViewerShortcutAction?

  init(shortcuts: PDFViewerShortcutStore, embedded: Bool = false) {
    self.shortcuts = shortcuts
    self.embedded = embedded
  }

  private let groups: [(String, [PDFViewerShortcutAction])] = [
    ("翻页", [.previousPage, .nextPage]),
    ("缩放", [.zoomOut, .zoomIn, .actualSize, .fitPage]),
    ("方向", [.rotateLeft, .rotateRight, .resetRotation]),
    ("投影", [.togglePresentation]),
  ]

  var body: some View {
    VStack(spacing: 0) {
      sectionHeader

      Divider()

      ScrollView {
        if shortcuts.activeShortcutCount == 0 {
          emptyState
        } else {
          VStack(spacing: 20) {
            ForEach(groups, id: \.0) { group in
              let activeActions = group.1.filter { !shortcuts.isDeleted($0) }
              if !activeActions.isEmpty {
                shortcutGroup(title: group.0, actions: activeActions)
              }
            }
          }
          .padding(embedded ? 20 : 24)
        }
      }

      Divider()

      HStack(spacing: 10) {
        Text(
          feedbackAction == nil
            ? (feedbackText ?? "至少包含 ⌘、⌥ 或 ⌃ · Esc 取消录制")
            : "至少包含 ⌘、⌥ 或 ⌃ · Esc 取消录制"
        )
        .font(.caption)
        .foregroundStyle(
          feedbackAction == nil && feedbackText != nil ? pdfBrandPurple : Color.secondary)
        Spacer()
      }
      .padding(.horizontal, embedded ? 20 : 24)
      .frame(height: 48)
      .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }
    .frame(width: embedded ? nil : 620, height: embedded ? nil : 720)
    .frame(
      maxWidth: embedded ? .infinity : nil,
      maxHeight: embedded ? .infinity : nil
    )
    .background(Color(nsColor: .windowBackgroundColor))

  }

  private var sectionHeader: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 14) {
        sectionIdentity
        Spacer(minLength: 12)
        sectionActions
      }
      VStack(alignment: .leading, spacing: 12) {
        sectionIdentity
        sectionActions
      }
    }
    .padding(.horizontal, embedded ? 20 : 24)
    .padding(.vertical, embedded ? 14 : 18)
  }

  private var sectionIdentity: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(embedded ? "披卷" : "披卷快捷键")
        .font(.system(size: embedded ? 16 : 20, weight: .semibold))
      Text("PDF 阅读 · \(shortcuts.activeShortcutCount) 条快捷键")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
    }
  }

  private var sectionActions: some View {
    HStack(spacing: 8) {
      if shortcuts.deletedShortcutCount > 0 {
        Button {
          let count = shortcuts.deletedShortcutCount
          shortcuts.restoreAllDeleted()
          feedbackAction = nil
          feedbackText = "已恢复 \(count) 条删除的快捷键。"
          PDFViewerAccessibilityAnnouncer.announce(feedbackText ?? "")
        } label: {
          Label(
            "恢复已删除（\(shortcuts.deletedShortcutCount)）",
            systemImage: "arrow.uturn.backward.circle")
        }
        .accessibilityIdentifier("pdf-shortcuts-restore-deleted")
      }

      Button("全部恢复默认") {
        shortcuts.resetAll()
        feedbackAction = nil
        feedbackText = "已恢复全部默认快捷键。"
        PDFViewerAccessibilityAnnouncer.announce(feedbackText ?? "")
      }
      .disabled(!shortcuts.hasChanges)
      .accessibilityIdentifier("pdf-shortcuts-reset-all")
    }
    .controlSize(.small)
  }

  private var emptyState: some View {
    VStack(spacing: 10) {
      Image(systemName: "keyboard.badge.ellipsis")
        .font(.system(size: 30, weight: .light))
        .foregroundStyle(.secondary)
      Text("披卷快捷键已全部删除")
        .font(.system(size: 15, weight: .semibold))
      Text("功能仍然保留；可用菜单和界面按钮操作。")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
      Button("恢复已删除快捷键") {
        shortcuts.restoreAllDeleted()
        feedbackText = "已恢复披卷默认快捷键。"
      }
    }
    .frame(maxWidth: .infinity, minHeight: 280)
    .padding(24)
  }

  @ViewBuilder
  private func shortcutGroup(
    title: String,
    actions: [PDFViewerShortcutAction]
  ) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .padding(.bottom, 7)

      VStack(spacing: 0) {
        ForEach(Array(actions.enumerated()), id: \.element) { index, action in
          shortcutRow(action)
          if index + 1 < actions.count { Divider().padding(.leading, 4) }
        }
      }
      .background(
        Color(nsColor: .controlBackgroundColor).opacity(0.42),
        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(Color.primary.opacity(0.08), lineWidth: 0.75)
      }
    }
  }

  private func shortcutRow(_ action: PDFViewerShortcutAction) -> some View {
    let current = shortcuts.shortcut(for: action)
    let isCustom = current != PDFViewerShortcutPolicy.defaultShortcut(for: action)

    return VStack(spacing: 0) {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text(action.displayName)
            .font(.body.weight(.medium))
          if isCustom {
            Text("默认：\(PDFViewerShortcutPolicy.defaultShortcut(for: action).displayText)")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        Spacer()
        if isCustom {
          Button {
            feedbackAction = action
            if let error = shortcuts.reset(action) {
              feedbackText = error.localizedDescription
            } else {
              feedbackText = "已恢复“\(action.displayName)”的默认快捷键。"
            }
            PDFViewerAccessibilityAnnouncer.announce(feedbackText ?? "")
          } label: {
            Image(systemName: "arrow.uturn.backward")
          }
          .buttonStyle(.borderless)
          .foregroundStyle(pdfBrandPurple)
          .accessibilityLabel("恢复“\(action.displayName)”默认快捷键")
          .accessibilityIdentifier("pdf-shortcut-reset-\(action.rawValue)")
          .help("恢复默认快捷键")
        }
        PDFShortcutRecorder(
          displayText: current.displayText,
          actionName: action.displayName,
          onFeedback: { message in
            feedbackAction = action
            feedbackText = message
          }
        ) { candidate in
          feedbackAction = action
          if let error = shortcuts.update(candidate, for: action) {
            feedbackText = error.localizedDescription
          } else {
            feedbackText = "已把“\(action.displayName)”改为 \(candidate.displayText)。"
          }
          PDFViewerAccessibilityAnnouncer.announce(feedbackText ?? "")
        }
        .frame(width: 142, height: 30)
        .accessibilityIdentifier("pdf-shortcut-recorder-\(action.rawValue)")

        Button {
          // Fixed PDF capability: deletion is disabled in the UI and data model.
        } label: {
          Image(systemName: "trash")
            .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityLabel("删除“\(action.displayName)”快捷键")
        .accessibilityIdentifier("pdf-shortcut-delete-\(action.rawValue)")
        .disabled(true)
        .opacity(0.35)
        .help("内置功能，可修改按键，不能删除。")
      }
      .padding(.horizontal, 12)
      .frame(minHeight: 52)

      if feedbackAction == action, let feedbackText {
        Text(feedbackText)
          .font(.caption)
          .foregroundStyle(feedbackText.hasPrefix("已") ? Color.secondary : Color.orange)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 12)
          .padding(.bottom, 9)
          .accessibilityLabel(feedbackText)
      }
    }
  }
}

private struct PDFShortcutRecorder: NSViewRepresentable {
  let displayText: String
  let actionName: String
  let onFeedback: (String) -> Void
  let onShortcut: (PDFViewerShortcut) -> Void

  func makeNSView(context: Context) -> PDFShortcutRecorderButton {
    let button = PDFShortcutRecorderButton()
    button.displayText = displayText
    button.actionName = actionName
    button.onFeedback = onFeedback
    button.onShortcut = onShortcut
    return button
  }

  func updateNSView(_ button: PDFShortcutRecorderButton, context: Context) {
    button.displayText = displayText
    button.actionName = actionName
    button.onFeedback = onFeedback
    button.onShortcut = onShortcut
  }

  static func dismantleNSView(_ button: PDFShortcutRecorderButton, coordinator: ()) {
    button.cancelRecording(announcement: nil)
  }
}

@MainActor
final class PDFShortcutRecorderButton: NSButton {
  var displayText = "" {
    didSet { refreshTitle() }
  }
  var actionName = "" {
    didSet { refreshAccessibility() }
  }
  var onFeedback: ((String) -> Void)?
  var onShortcut: ((PDFViewerShortcut) -> Void)?

  private var eventMonitor: Any?
  private var lifecycleObservers: [NSObjectProtocol] = []
  private var isRecordingShortcut = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    bezelStyle = .rounded
    setButtonType(.momentaryPushIn)
    font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
    focusRingType = .exterior
    target = self
    action = #selector(beginRecordingAction)
    refreshTitle()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var acceptsFirstResponder: Bool { true }

  override func resignFirstResponder() -> Bool {
    cancelRecording(announcement: "已取消录制。")
    return super.resignFirstResponder()
  }

  @objc private func beginRecordingAction() {
    guard !isRecordingShortcut else { return }
    isRecordingShortcut = true
    title = "请按新的组合键…"
    font = .systemFont(ofSize: 12, weight: .medium)
    contentTintColor = .systemPurple
    window?.makeFirstResponder(self)
    setAccessibilityValue("正在录制，按 Esc 取消")
    NSAccessibility.post(element: self, notification: .valueChanged)
    PDFViewerAccessibilityAnnouncer.announce("正在录制“\(actionName)”快捷键，按 Esc 取消。")
    installLifecycleObservers()

    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, self.isRecordingShortcut, event.window === self.window else { return event }
      self.capture(event)
      return nil
    }
  }

  private func capture(_ event: NSEvent) {
    guard !event.isARepeat else { return }
    if event.keyCode == 53 {
      cancelRecording(announcement: "已取消录制。")
      return
    }
    guard let shortcut = PDFViewerShortcut(event: event) else {
      NSSound.beep()
      finishRecording()
      let message = "这个按键暂不支持，请换一个组合。"
      onFeedback?(message)
      PDFViewerAccessibilityAnnouncer.announce(message)
      return
    }
    finishRecording()
    onShortcut?(shortcut)
  }

  func cancelRecording(announcement: String?) {
    guard isRecordingShortcut else { return }
    finishRecording()
    if let announcement {
      onFeedback?(announcement)
      PDFViewerAccessibilityAnnouncer.announce(announcement)
    }
  }

  private func finishRecording() {
    isRecordingShortcut = false
    removeEventMonitor()
    removeLifecycleObservers()
    contentTintColor = nil
    font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
    refreshTitle()
    refreshAccessibility()
    NSAccessibility.post(element: self, notification: .valueChanged)
  }

  private func removeEventMonitor() {
    guard let eventMonitor else { return }
    NSEvent.removeMonitor(eventMonitor)
    self.eventMonitor = nil
  }

  private func installLifecycleObservers() {
    removeLifecycleObservers()
    let center = NotificationCenter.default
    if let window {
      for name in [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification] {
        lifecycleObservers.append(
          center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
              self?.cancelRecording(announcement: "已取消录制。")
            }
          })
      }
    }
    lifecycleObservers.append(
      center.addObserver(
        forName: NSApplication.didResignActiveNotification,
        object: NSApp,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.cancelRecording(announcement: "已取消录制。")
        }
      })
  }

  private func removeLifecycleObservers() {
    let center = NotificationCenter.default
    lifecycleObservers.forEach(center.removeObserver)
    lifecycleObservers.removeAll()
  }

  private func refreshTitle() {
    guard !isRecordingShortcut else { return }
    title = displayText
  }

  private func refreshAccessibility() {
    setAccessibilityLabel("\(actionName)快捷键")
    if !isRecordingShortcut { setAccessibilityValue(displayText) }
    setAccessibilityHelp("点击后按新的组合键，按 Esc 取消")
  }
}

@MainActor
enum PDFViewerAccessibilityAnnouncer {
  static func announce(_ text: String) {
    guard !text.isEmpty else { return }
    NSAccessibility.post(
      element: NSApplication.shared,
      notification: .announcementRequested,
      userInfo: [
        .announcement: text,
        .priority: NSAccessibilityPriorityLevel.medium.rawValue,
      ])
  }
}
