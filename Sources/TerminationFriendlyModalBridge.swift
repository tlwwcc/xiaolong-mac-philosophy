import AppKit
import SwiftUI

/// SwiftUI sheets are modal AppKit windows. Their default can delay a system "Quit & Reopen"
/// request before `applicationShouldTerminate` is called, which prevents the authorization relay
/// from checkpointing and makes the old process look frozen. This zero-size bridge changes only
/// that window policy; it does not dismiss the sheet or terminate the process itself.
private final class TerminationFriendlyModalHostView: NSView {
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    window?.preventsApplicationTerminationWhenModal = false
  }
}

private struct TerminationFriendlyModalWindowBridge: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    TerminationFriendlyModalHostView(frame: .zero)
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    nsView.window?.preventsApplicationTerminationWhenModal = false
  }
}

extension View {
  func allowsApplicationTerminationWhenModal() -> some View {
    background(
      TerminationFriendlyModalWindowBridge()
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    )
  }
}
