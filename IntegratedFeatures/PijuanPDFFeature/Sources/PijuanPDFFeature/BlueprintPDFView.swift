import AppKit
import PDFKit

final class BlueprintPDFView: PDFView {
  private var scrollEventMonitor: Any?
  private lazy var panRecognizer: NSPanGestureRecognizer = {
    let recognizer = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    recognizer.buttonMask = 0x1
    recognizer.delaysPrimaryMouseButtonEvents = true
    return recognizer
  }()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    addGestureRecognizer(panRecognizer)
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    addGestureRecognizer(panRecognizer)
  }

  deinit {
    // PDFView is an AppKit object and this instance is created/owned on the main actor. Swift 6
    // treats deinit as nonisolated, so calling the actor-isolated helper directly is rejected even
    // though AppKit guarantees this destruction path. Keep the monitor cleanup synchronous while
    // making that invariant explicit.
    MainActor.assumeIsolated {
      removeScrollMonitor()
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      removeScrollMonitor()
    } else {
      installScrollMonitorIfNeeded()
    }
    window?.invalidateCursorRects(for: self)
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    addCursorRect(visibleRect, cursor: .openHand)
  }

  @discardableResult
  func applyScrollZoom(scrollingDeltaY: CGFloat, hasPreciseDeltas: Bool) -> CGFloat {
    autoScales = false
    let nextScale = PDFZoomPolicy.scale(
      from: scaleFactor,
      scrollingDeltaY: scrollingDeltaY,
      hasPreciseDeltas: hasPreciseDeltas)
    scaleFactor = nextScale
    return nextScale
  }

  @discardableResult
  func applyMagnification(_ magnification: CGFloat) -> CGFloat {
    autoScales = false
    let nextScale = PDFZoomPolicy.scale(
      from: scaleFactor,
      magnification: magnification)
    scaleFactor = nextScale
    return nextScale
  }

  override func magnify(with event: NSEvent) {
    guard document != nil else {
      super.magnify(with: event)
      return
    }
    applyMagnification(event.magnification)
  }

  @discardableResult
  func applyPanTranslation(_ translation: CGPoint) -> CGPoint? {
    guard document != nil, let scrollView = documentScrollView else { return nil }
    let clipView = scrollView.contentView
    var origin = clipView.bounds.origin
    origin.x -= translation.x
    origin.y -= translation.y
    let constrained = clipView.constrainBoundsRect(
      NSRect(origin: origin, size: clipView.bounds.size)).origin
    clipView.scroll(to: constrained)
    scrollView.reflectScrolledClipView(clipView)
    return constrained
  }

  private func installScrollMonitorIfNeeded() {
    guard scrollEventMonitor == nil else { return }
    scrollEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
      [weak self] event in
      guard let self,
        let window = self.window,
        event.window === window,
        self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)),
        abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX),
        event.scrollingDeltaY != 0
      else { return event }
      guard PDFScrollGesturePolicy.shouldZoom(
        hasPreciseDeltas: event.hasPreciseScrollingDeltas,
        optionKeyDown: event.modifierFlags.contains(.option))
      else {
        return event
      }
      self.applyScrollZoom(
        scrollingDeltaY: event.scrollingDeltaY,
        hasPreciseDeltas: event.hasPreciseScrollingDeltas)
      return nil
    }
  }

  private func removeScrollMonitor() {
    if let scrollEventMonitor {
      NSEvent.removeMonitor(scrollEventMonitor)
      self.scrollEventMonitor = nil
    }
  }

  @objc private func handlePan(_ recognizer: NSPanGestureRecognizer) {
    guard document != nil, let scrollView = documentScrollView else { return }
    switch recognizer.state {
    case .began:
      NSCursor.closedHand.push()
    case .changed:
      let translation = recognizer.translation(in: scrollView.contentView)
      applyPanTranslation(translation)
      recognizer.setTranslation(.zero, in: scrollView.contentView)
    case .ended, .cancelled, .failed:
      NSCursor.pop()
    default:
      break
    }
  }

  private var documentScrollView: NSScrollView? {
    firstScrollView(in: self)
  }

  private func firstScrollView(in view: NSView) -> NSScrollView? {
    for subview in view.subviews {
      if let scrollView = subview as? NSScrollView { return scrollView }
      if let nested = firstScrollView(in: subview) { return nested }
    }
    return nil
  }
}
