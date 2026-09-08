import AppKit
import ApplicationServices
import Carbon

struct PhraseInputOwner: Equatable {
  let processIdentifier: pid_t
  let focusedElement: AXUIElement

  static func == (lhs: PhraseInputOwner, rhs: PhraseInputOwner) -> Bool {
    lhs.processIdentifier == rhs.processIdentifier
      && CFEqual(lhs.focusedElement, rhs.focusedElement)
  }
}

struct PhraseInputBufferState {
  private(set) var owner: PhraseInputOwner?
  private(set) var text = ""

  mutating func prepare(for owner: PhraseInputOwner) {
    guard self.owner != owner else { return }
    self.owner = owner
    text.removeAll()
  }

  mutating func append(_ value: String, maximumLength: Int = 48) {
    text.append(value)
    if text.count > maximumLength {
      text = String(text.suffix(maximumLength))
    }
  }

  mutating func deleteLast() {
    if !text.isEmpty { text.removeLast() }
  }

  mutating func reset() {
    owner = nil
    text.removeAll()
  }
}

@MainActor
final class PhraseExpander {
  private var eventTap: CFMachPort?
  private var eventTapSource: CFRunLoopSource?
  private var phrases: [PhraseItem] = []
  private var inputState = PhraseInputBufferState()
  private var isExpanding = false
  private let onNotice: (String) -> Void

  private(set) var isListening = false
  var requiresListening: Bool { !phrases.isEmpty }

  init(onNotice: @escaping (String) -> Void) {
    self.onNotice = onNotice
  }

  isolated deinit {
    stop()
  }

  @discardableResult
  func reload(_ phrases: [PhraseItem]) -> Bool {
    stop()
    self.phrases = phrases
      .filter { $0.enabled && !$0.normalizedTrigger.isEmpty && !$0.output.isEmpty }
      .sorted { $0.normalizedTrigger.count > $1.normalizedTrigger.count }
    inputState.reset()
    guard !self.phrases.isEmpty else {
      stop()
      return true
    }
    return startIfPossible()
  }

  func stop() {
    if let eventTap {
      CGEvent.tapEnable(tap: eventTap, enable: false)
    }
    if let eventTapSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
    }
    eventTap = nil
    eventTapSource = nil
    isListening = false
    inputState.reset()
  }

  @discardableResult
  private func startIfPossible() -> Bool {
    guard eventTap == nil else { return isListening }
    guard AXIsProcessTrusted(), CGPreflightListenEventAccess() else {
      onNotice("快捷短语需要完成系统授权，请点“立即授权”。")
      return false
    }

    let mask = 1 << CGEventType.keyDown.rawValue
    let callback: CGEventTapCallBack = { _, type, event, userInfo in
      guard let userInfo else {
        return Unmanaged.passUnretained(event)
      }
      let expander = Unmanaged<PhraseExpander>.fromOpaque(userInfo).takeUnretainedValue()
      if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        expander.reenable()
        return Unmanaged.passUnretained(event)
      }
      guard type == .keyDown else {
        return Unmanaged.passUnretained(event)
      }
      if expander.handle(event) {
        return nil
      }
      return Unmanaged.passUnretained(event)
    }

    eventTap = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: CGEventMask(mask),
      callback: callback,
      userInfo: Unmanaged.passUnretained(self).toOpaque()
    )

    guard let eventTap else {
      onNotice("系统授权尚未生效，快捷短语监听已安全停止。")
      return false
    }
    guard let eventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
    else {
      CFMachPortInvalidate(eventTap)
      self.eventTap = nil
      onNotice("快捷短语监听启动失败：无法建立事件循环源。")
      return false
    }
    self.eventTapSource = eventTapSource
    CFRunLoopAddSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
    CGEvent.tapEnable(tap: eventTap, enable: true)
    isListening = true
    return true
  }

  private func reenable() {
    guard let eventTap else { return }
    inputState.reset()
    CGEvent.tapEnable(tap: eventTap, enable: true)
    onNotice("快捷短语监听已自动恢复。")
  }

  private func handle(_ event: CGEvent) -> Bool {
    guard !isExpanding, !phrases.isEmpty else { return false }
    guard let owner = currentInputOwner() else {
      inputState.reset()
      return false
    }
    inputState.prepare(for: owner)
    let flags = event.flags
    if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
      inputState.reset()
      return false
    }

    let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
    if keyCode == UInt32(kVK_Delete) {
      inputState.deleteLast()
      return false
    }
    if keyCode == UInt32(kVK_Escape) || keyCode == UInt32(kVK_Return) || keyCode == UInt32(kVK_Tab) {
      inputState.reset()
      return false
    }

    guard let typed = typedText(from: event), typed.count == 1 else {
      inputState.reset()
      return false
    }
    let lower = typed.lowercased()
    guard lower.rangeOfCharacter(from: CharacterSet.alphanumerics) != nil else {
      inputState.reset()
      return false
    }

    inputState.append(lower)

    guard let phrase = phrases.first(where: { inputState.text.hasSuffix($0.normalizedTrigger) }) else {
      return false
    }
    expand(phrase, owner: owner)
    inputState.reset()
    return true
  }

  private func currentInputOwner() -> PhraseInputOwner? {
    guard let application = NSWorkspace.shared.frontmostApplication,
      application.bundleIdentifier != Bundle.main.bundleIdentifier
    else { return nil }
    let appElement = AXUIElementCreateApplication(application.processIdentifier)
    var rawFocusedElement: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      appElement,
      kAXFocusedUIElementAttribute as CFString,
      &rawFocusedElement) == .success,
      let rawFocusedElement,
      CFGetTypeID(rawFocusedElement) == AXUIElementGetTypeID()
    else { return nil }
    return PhraseInputOwner(
      processIdentifier: application.processIdentifier,
      focusedElement: rawFocusedElement as! AXUIElement)
  }

  private func typedText(from event: CGEvent) -> String? {
    var actualLength = 0
    var chars = [UniChar](repeating: 0, count: 8)
    event.keyboardGetUnicodeString(
      maxStringLength: chars.count,
      actualStringLength: &actualLength,
      unicodeString: &chars
    )
    guard actualLength > 0 else { return nil }
    return String(utf16CodeUnits: chars, count: actualLength)
  }

  private func expand(_ phrase: PhraseItem, owner: PhraseInputOwner) {
    isExpanding = true
    let deleteCount = max(phrase.normalizedTrigger.count - 1, 0)
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      guard self.currentInputOwner() == owner else {
        self.isExpanding = false
        return
      }
      let pasteboard = NSPasteboard.general
      TemporaryPasteboardWrite.writeString(
        phrase.output,
        to: pasteboard,
        validateBeforeWrite: { [weak self] in self?.currentInputOwner() == owner }
      ) { [weak self] temporaryWrite in
        guard let self else { return }
        guard let temporaryWrite else {
          self.isExpanding = false
          self.onNotice("快捷短语展开失败：未改动原剪贴板。")
          return
        }
        ClipboardHistorySuppression.markCurrentPasteboardChange()
        self.deletePreviousCharacters(deleteCount)
        self.postPasteShortcut()
        self.onNotice("已展开快捷短语：\(phrase.trigger)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
          self.isExpanding = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
          if temporaryWrite.restoreIfStillOwned(on: pasteboard) != nil {
            ClipboardHistorySuppression.markCurrentPasteboardChange()
          }
        }
      }
    }
  }

  private func deletePreviousCharacters(_ count: Int) {
    guard count > 0 else { return }
    let source = CGEventSource(stateID: .hidSystemState)
    for _ in 0..<count {
      CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: true)?
        .post(tap: .cghidEventTap)
      CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: false)?
        .post(tap: .cghidEventTap)
    }
  }

  private func postPasteShortcut() {
    let source = CGEventSource(stateID: .hidSystemState)
    for isDown in [true, false] {
      guard let event = CGEvent(
        keyboardEventSource: source,
        virtualKey: CGKeyCode(kVK_ANSI_V),
        keyDown: isDown)
      else { continue }
      event.flags = .maskCommand
      event.post(tap: .cghidEventTap)
    }

  }
}
