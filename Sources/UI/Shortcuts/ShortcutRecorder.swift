import AppKit
import SwiftUI

struct HotkeyCell: View {
  let text: String
  let active: Bool
  let recordingOwnerID: UUID?
  var isProtected = false
  let onKeyDown: (NSEvent, UUID) -> Void
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: active ? "record.circle.fill" : "keyboard")
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(active ? ruby : accent.opacity(0.70))
        Text(active ? "按组合键 / 双击修饰键" : text)
          .font(.system(size: 13, weight: .semibold, design: .monospaced))
          .foregroundStyle(active ? accent : ink)
          .lineLimit(1)
          .minimumScaleFactor(0.78)
          .allowsTightening(true)
          .layoutPriority(1)
      }
      .frame(maxWidth: .infinity, alignment: .center)
      .frame(height: 32)
      .padding(.horizontal, 7)
      .background(
        active
          ? LinearGradient(
            colors: [accent.opacity(0.14), teal.opacity(0.08)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
          : LinearGradient(
            colors: isProtected
              ? [Color(nsColor: .controlBackgroundColor), Color(nsColor: .controlBackgroundColor)]
              : [AppVisualStyle.background, AppVisualStyle.surface.opacity(0.80)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          ),
        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .stroke(active ? accent : line.opacity(0.65), lineWidth: active ? 2 : 1)
      )
      .shadow(
        color: active ? accent.opacity(0.16) : Color.black.opacity(0.025),
        radius: active ? 8 : 4,
        x: 0,
        y: active ? 4 : 2
      )
      .background(KeyCaptureView(ownerID: active ? recordingOwnerID : nil, onKeyDown: onKeyDown))
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 6)
    .help(active ? "再点一下取消录制；Esc 退出" : (isProtected ? "内置快捷键：点击修改按键，不能删除" : "点击录制组合键或实体修饰键双击"))
    .accessibilityLabel(active ? "正在录制快捷键" : "修改快捷键：\(text)")
    .accessibilityHint(isProtected ? "内置功能，允许修改按键，不能删除" : "点击后按下新的快捷键")
  }
}

struct KeyCaptureView: NSViewRepresentable {
  let ownerID: UUID?
  let onKeyDown: (NSEvent, UUID) -> Void

  func makeNSView(context: Context) -> KeyCaptureNSView {
    let view = KeyCaptureNSView()
    view.onKeyDown = onKeyDown
    return view
  }

  func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
    nsView.onKeyDown = onKeyDown
    nsView.setCaptureOwner(ownerID)
  }

  static func dismantleNSView(_ nsView: KeyCaptureNSView, coordinator: ()) {
    nsView.setCaptureOwner(nil)
    nsView.onKeyDown = nil
  }
}

final class KeyCaptureNSView: NSView {
  var onKeyDown: ((NSEvent, UUID) -> Void)?
  var enqueueFocusClaim: (@escaping @MainActor () -> Void) -> Void = { claim in
    DispatchQueue.main.async(execute: claim)
  }
  private var captureOwnerID: UUID?
  private var focusClaimGeneration = UUID()
  private weak var previousResponder: NSResponder?
  private weak var focusWindow: NSWindow?

  override var acceptsFirstResponder: Bool { captureOwnerID != nil }

  func setCaptureOwner(_ ownerID: UUID?) {
    guard captureOwnerID != ownerID else { return }
    focusClaimGeneration = UUID()
    restoreOwnedFocus()
    captureOwnerID = ownerID
    if ownerID != nil { claimKeyboardFocus() }
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow !== window {
      focusClaimGeneration = UUID()
      restoreOwnedFocus()
    }
    super.viewWillMove(toWindow: newWindow)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard captureOwnerID != nil else { return }
    claimKeyboardFocus()
  }

  override func mouseDown(with event: NSEvent) {
    claimKeyboardFocus()
  }

  override func keyDown(with event: NSEvent) {
    guard let ownerID = captureOwnerID else {
      super.keyDown(with: event)
      return
    }
    onKeyDown?(event, ownerID)
  }

  private func restoreOwnedFocus() {
    // A later user click or a different recorder owns its own focus.
    if let focusWindow, focusWindow.firstResponder === self {
      focusWindow.makeFirstResponder(previousResponder)
    }
    previousResponder = nil
    focusWindow = nil
  }

  private func claimKeyboardFocus() {
    guard let ownerID = captureOwnerID else { return }
    let generation = focusClaimGeneration
    enqueueFocusClaim { [weak self] in
      guard let self, self.captureOwnerID == ownerID,
        self.focusClaimGeneration == generation, let window = self.window
      else { return }
      guard window.firstResponder !== self else { return }
      self.previousResponder = window.firstResponder
      self.focusWindow = window
      window.makeFirstResponder(self)
    }
  }
}
