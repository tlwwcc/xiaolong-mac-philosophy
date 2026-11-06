import AppKit
import ApplicationServices
import Combine
import Foundation

enum ShortcutRecordingTarget: Equatable {
  case item(String)
  case draft
  case action(String)
}

struct ShortcutRecordingSession: Equatable {
  let id: UUID
  let target: ShortcutRecordingTarget
}

struct ShortcutTriggerRecordingValue: Equatable {
  let key: String
  let modifiers: [String]
  let trigger: ShortcutTrigger?

  var displayText: String {
    trigger?.displayText ?? displayHotkeyText(key: key, modifiers: modifiers)
  }
}

@MainActor
protocol ShortcutRecordingCancellation: AnyObject {
  func stop()
}

@MainActor
protocol ShortcutRecordingTap: ShortcutRecordingCancellation {
  func reenable()
}

@MainActor
protocol ShortcutRecordingPhysicalListener: ShortcutRecordingCancellation {
  var hasAcceptedPhysicalKeyboard: Bool { get }
}

@MainActor
struct ShortcutRecordingPorts {
  var accessibilityTrusted: () -> Bool
  var inputMonitoringTrusted: () -> Bool
  var makeTap: (
    @escaping @MainActor () -> Bool,
    @escaping @MainActor (UInt32, CGEventFlags) -> Void,
    @escaping @MainActor () -> Void
  ) -> (any ShortcutRecordingTap)?
  var makePhysicalListener: (
    @escaping @MainActor (PhysicalModifierKey) -> Void,
    @escaping @MainActor (PhysicalModifierDoubleTapHIDNotice) -> Void
  ) -> (any ShortcutRecordingPhysicalListener)?
  var scheduleTimeout: (
    TimeInterval, @escaping @MainActor () -> Void
  ) -> any ShortcutRecordingCancellation

  static func live() -> Self {
    Self(
      accessibilityTrusted: { AXIsProcessTrusted() },
      inputMonitoringTrusted: { CGPreflightListenEventAccess() },
      makeTap: { RecordingEventTap.create(acceptsInput: $0, onKey: $1, onDisabled: $2) },
      makePhysicalListener: { RecordingPhysicalListener.create(onTrigger: $0, onNotice: $1) },
      scheduleTimeout: { delay, callback in
        let work = DispatchWorkItem { MainActor.assumeIsolated { callback() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return RecordingTimeout(work)
      })
  }
}

/// The callback context outlives any queued delivery; it never references AppModel.
@MainActor
private final class ShortcutRecordingTapContext {
  var active = true
  let acceptsInput: () -> Bool
  let onKey: (UInt32, CGEventFlags) -> Void
  let onDisabled: () -> Void

  init(
    acceptsInput: @escaping () -> Bool,
    onKey: @escaping (UInt32, CGEventFlags) -> Void,
    onDisabled: @escaping () -> Void
  ) {
    self.acceptsInput = acceptsInput
    self.onKey = onKey
    self.onDisabled = onDisabled
  }

  var canCapture: Bool { active && acceptsInput() }
}

@MainActor
private final class RecordingEventTap: ShortcutRecordingTap {
  private var tap: CFMachPort?
  private var source: CFRunLoopSource?
  private let context: ShortcutRecordingTapContext

  private init(
    tap: CFMachPort, source: CFRunLoopSource, context: ShortcutRecordingTapContext
  ) {
    self.tap = tap
    self.source = source
    self.context = context
  }

  static func create(
    acceptsInput: @escaping () -> Bool,
    onKey: @escaping (UInt32, CGEventFlags) -> Void,
    onDisabled: @escaping () -> Void
  ) -> RecordingEventTap? {
    let context = ShortcutRecordingTapContext(
      acceptsInput: acceptsInput, onKey: onKey, onDisabled: onDisabled)
    let callback: CGEventTapCallBack = { _, type, event, userInfo in
      guard let userInfo else { return Unmanaged.passUnretained(event) }
      // This tap is scheduled exclusively on the main run loop.
      return MainActor.assumeIsolated {
        let context = Unmanaged<ShortcutRecordingTapContext>.fromOpaque(userInfo)
          .takeUnretainedValue()
        // An obsolete tap must pass the key through, not swallow it and reject it later.
        guard context.canCapture else { return Unmanaged.passUnretained(event) }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
          context.onDisabled()
          return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        DispatchQueue.main.async {
          guard context.canCapture else { return }
          context.onKey(keyCode, flags)
        }
        return nil
      }
    }
    guard let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
      eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
      callback: callback, userInfo: Unmanaged.passUnretained(context).toOpaque()
    ) else { return nil }
    guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
      context.active = false
      CGEvent.tapEnable(tap: tap, enable: false)
      CFMachPortInvalidate(tap)
      return nil
    }
    let handle = RecordingEventTap(tap: tap, source: source, context: context)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return handle
  }

  func reenable() {
    guard context.canCapture, let tap else { return }
    CGEvent.tapEnable(tap: tap, enable: true)
  }

  func stop() {
    context.active = false
    let previousTap = tap
    let previousSource = source
    tap = nil
    source = nil
    if let previousTap { CGEvent.tapEnable(tap: previousTap, enable: false) }
    if let previousSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), previousSource, .commonModes)
      CFRunLoopSourceInvalidate(previousSource)
    }
    if let previousTap { CFMachPortInvalidate(previousTap) }
  }

  isolated deinit { stop() }
}

@MainActor
private final class RecordingPhysicalListener: ShortcutRecordingPhysicalListener {
  private let listener: PhysicalModifierDoubleTapHIDListener
  var hasAcceptedPhysicalKeyboard: Bool { listener.hasAcceptedPhysicalKeyboard }

  private init(
    onTrigger: @escaping (PhysicalModifierKey) -> Void,
    onNotice: @escaping (PhysicalModifierDoubleTapHIDNotice) -> Void
  ) {
    listener = PhysicalModifierDoubleTapHIDListener(
      modifiers: Set(PhysicalModifierKey.allCases),
      onTrigger: onTrigger, onNotice: onNotice)
  }

  static func create(
    onTrigger: @escaping (PhysicalModifierKey) -> Void,
    onNotice: @escaping (PhysicalModifierDoubleTapHIDNotice) -> Void
  ) -> RecordingPhysicalListener? {
    let handle = RecordingPhysicalListener(onTrigger: onTrigger, onNotice: onNotice)
    guard handle.listener.start() else {
      handle.stop()
      return nil
    }
    return handle
  }

  func stop() { listener.stop() }
  isolated deinit { stop() }
}

@MainActor
private final class RecordingTimeout: ShortcutRecordingCancellation {
  private var work: DispatchWorkItem?
  init(_ work: DispatchWorkItem) { self.work = work }
  func stop() {
    let previous = work
    work = nil
    previous?.cancel()
  }
}

/// A single capture owner for existing shortcuts, editor drafts and action-key capture.
/// Item persistence, conflicts and rollback are deliberately delegated to the host transaction.
@MainActor
final class ShortcutRecordingCoordinator: @MainActor ObservableObject {
  let objectWillChange = ObservableObjectPublisher()
  private(set) var session: ShortcutRecordingSession?
  private(set) var actionCaptureDraft = ""

  private let ports: ShortcutRecordingPorts
  private let hasGlobalInputOwnership: () -> Bool
  private let ownershipBlockedMessage: () -> String
  private var onStatus: ((String) -> Void)?
  private var suspendHotkeys: (() -> Void)?
  private var resumeHotkeys: (() -> Void)?
  private var onItemCaptured: ((ShortcutRecordingSession, ShortcutTriggerRecordingValue) -> Void)?
  private var onCancelledItem: ((String) -> Void)?
  private var draftHandler: ((ShortcutTriggerRecordingValue) -> Void)?
  private var tap: (any ShortcutRecordingTap)?
  private var physicalListener: (any ShortcutRecordingPhysicalListener)?
  private var timeout: (any ShortcutRecordingCancellation)?
  private(set) var hotkeysSuspendedForRecording = false
  private var epoch = UUID()
  private var deliveryOwner: UUID?
  private var stopping = false
  private var isShutdown = false

  init(
    onStatus: @escaping (String) -> Void,
    hasGlobalInputOwnership: @escaping () -> Bool,
    ownershipBlockedMessage: @escaping () -> String,
    suspendHotkeys: @escaping () -> Void,
    resumeHotkeys: @escaping () -> Void,
    onItemCaptured: @escaping (ShortcutRecordingSession, ShortcutTriggerRecordingValue) -> Void,
    onCancelledItem: @escaping (String) -> Void,
    ports: ShortcutRecordingPorts? = nil
  ) {
    self.onStatus = onStatus
    self.hasGlobalInputOwnership = hasGlobalInputOwnership
    self.ownershipBlockedMessage = ownershipBlockedMessage
    self.suspendHotkeys = suspendHotkeys
    self.resumeHotkeys = resumeHotkeys
    self.onItemCaptured = onItemCaptured
    self.onCancelledItem = onCancelledItem
    self.ports = ports ?? .live()
  }

  isolated deinit { shutdown() }

  var sessionID: UUID? { session?.id }
  var recordingItemID: String? {
    if case .item(let id) = session?.target { return id }
    return nil
  }
  var isDraftShortcutRecording: Bool { session?.target == .draft }
  var isRecording: Bool { recordingItemID != nil || isDraftShortcutRecording }
  var actionCaptureItemID: String? {
    if case .action(let id) = session?.target { return id }
    return nil
  }
  var isCapturingAction: Bool { actionCaptureItemID != nil }
  var hasAnyCaptureSession: Bool { session != nil }

  func owns(_ ownerID: UUID) -> Bool {
    !isShutdown && !stopping && session?.id == ownerID
  }

  func beginItem(itemID: String) {
    guard !isShutdown, !stopping else { return }
    if recordingItemID == itemID {
      cancelCurrent(message: "已取消快捷键录入。")
      return
    }
    begin(target: .item(itemID), draftHandler: nil)
  }

  func toggleDraft(onCaptured: @escaping (ShortcutTriggerRecordingValue) -> Void) {
    guard !isShutdown, !stopping else { return }
    if isDraftShortcutRecording {
      cancelCurrent(message: "已取消快捷键录入。")
      return
    }
    begin(target: .draft, draftHandler: onCaptured)
  }

  func beginAction(itemID: String, initialDraft: String) {
    begin(target: .action(itemID), draftHandler: nil, initialDraft: initialDraft)
  }

  func cancelDraft(ownerID: UUID? = nil) {
    guard isDraftShortcutRecording, ownerID == nil || session?.id == ownerID else { return }
    cancelCurrent(message: "已取消快捷键录入。")
  }

  func cancelAction(ownerID: UUID? = nil) {
    guard isCapturingAction, ownerID == nil || session?.id == ownerID else { return }
    cancelCurrent(message: "已取消发送按键设置。")
  }

  func stopCurrent(reloadHotkeys: Bool = true) {
    _ = end(ownerID: nil, reloadHotkeys: reloadHotkeys, cancelled: true)
  }

  /// The host must call this once after accepting/rejecting an item capture. Successful config
  /// writes use false, because saveAndReload owns registration; conflict exits use true.
  @discardableResult
  func finish(ownerID: UUID, reloadHotkeys: Bool) -> Bool {
    guard let ticket = end(ownerID: ownerID, reloadHotkeys: reloadHotkeys, cancelled: false)
    else { return false }
    return epoch == ticket && !isShutdown
  }

  func shutdown() {
    guard !isShutdown else { return }
    isShutdown = true
    _ = end(ownerID: nil, reloadHotkeys: false, cancelled: true)
    onStatus = nil
    suspendHotkeys = nil
    resumeHotkeys = nil
    onItemCaptured = nil
    onCancelledItem = nil
  }

  private func begin(
    target: ShortcutRecordingTarget,
    draftHandler: ((ShortcutTriggerRecordingValue) -> Void)?,
    initialDraft: String = ""
  ) {
    guard !isShutdown, !stopping,
      let stoppedTicket = end(ownerID: nil, reloadHotkeys: true, cancelled: true),
      epoch == stoppedTicket, !isShutdown
    else { return }
    let next = ShortcutRecordingSession(id: UUID(), target: target)
    epoch = UUID()
    session = next
    deliveryOwner = nil
    actionCaptureDraft = initialDraft
    self.draftHandler = draftHandler
    let owner = next.id
    // Commit the coherent state before notifying observers; reentrant intents see the new owner.
    objectWillChange.send()
    guard owns(owner) else { return }
    if case .action = target {
      emit("正在录入要发送的按键。", ownerID: owner)
      return
    }

    // Suspend before factories can synchronously deliver a capture. A later lease grant still
    // leaves runtime registration suspended until this session is explicitly finished.
    hotkeysSuspendedForRecording = true
    if hasGlobalInputOwnership() { suspendHotkeys?() }
    guard owns(owner) else { return }
    var tapStarted = false
    if hasGlobalInputOwnership(), ports.accessibilityTrusted() {
      let createdTap = ports.makeTap(
        { [weak self] in self?.acceptsTapInput(ownerID: owner) == true },
        { [weak self] code, flags in self?.receiveGlobal(keyCode: code, flags: flags, ownerID: owner) },
        { [weak self] in self?.reenableTap(ownerID: owner) })
      guard owns(owner) else { createdTap?.stop(); return }
      tap = createdTap
      tapStarted = createdTap != nil
    }
    var physicalStarted = false
    if hasGlobalInputOwnership(), ports.inputMonitoringTrusted() {
      let createdListener = ports.makePhysicalListener(
        { [weak self] modifier in
          self?.receivePhysical(
            trigger: ShortcutTrigger(kind: .modifierDoubleTap, modifier: modifier), ownerID: owner)
        },
        { [weak self] notice in self?.receiveNotice(notice, ownerID: owner) })
      guard owns(owner) else { createdListener?.stop(); return }
      physicalListener = createdListener
      physicalStarted = createdListener?.hasAcceptedPhysicalKeyboard == true
    }
    guard owns(owner) else { return }
    let message: String
    if !hasGlobalInputOwnership() {
      message = ownershipBlockedMessage()
    } else if tapStarted && physicalStarted {
      message = "录制中：按普通组合键，或连按同一个实体修饰键两次。再点一下取消。"
    } else if physicalStarted {
      message = "录制中：可连按实体修饰键两次；系统保留组合键需辅助功能授权。"
    } else if tapStarted {
      message = "录制中：可录入普通组合键；实体修饰键需输入监控权限和物理键盘。"
    } else {
      message = "录制未开始：请开启辅助功能和输入监控权限后重试。"
    }
    emit(message, ownerID: owner)
    guard owns(owner) else { return }
    let createdTimeout = ports.scheduleTimeout(12) { [weak self] in
      guard let self, self.owns(owner) else { return }
      self.cancelCurrent(message: "已取消快捷键录入。")
    }
    guard owns(owner) else { createdTimeout.stop(); return }
    timeout = createdTimeout
  }

  private func acceptsGlobalInput(ownerID: UUID) -> Bool {
    owns(ownerID) && isRecording && deliveryOwner != ownerID && hasGlobalInputOwnership()
  }

  private func acceptsTapInput(ownerID: UUID) -> Bool {
    acceptsGlobalInput(ownerID: ownerID) && ports.accessibilityTrusted()
  }

  private func reenableTap(ownerID: UUID) {
    guard acceptsTapInput(ownerID: ownerID) else { return }
    tap?.reenable()
  }

  private func receiveNotice(_ notice: PhysicalModifierDoubleTapHIDNotice, ownerID: UUID) {
    guard owns(ownerID), isRecording else { return }
    switch notice {
    case .permissionLost:
      emit("实体修饰键录入已停止：请重新开启输入监控权限。", ownerID: ownerID)
    case .physicalKeyboardUnavailable:
      emit("未检测到可用物理键盘；仍可录入普通组合键。", ownerID: ownerID)
    default:
      break
    }
  }

  func receiveGlobal(keyCode: UInt32, flags: CGEventFlags, ownerID: UUID) {
    guard acceptsTapInput(ownerID: ownerID) else { return }
    receiveLocal(keyCode: keyCode, modifiers: modifierNames(from: flags), ownerID: ownerID)
  }

  func receivePhysical(trigger: ShortcutTrigger, ownerID: UUID) {
    guard acceptsGlobalInput(ownerID: ownerID), ports.inputMonitoringTrusted() else { return }
    deliver(ShortcutTriggerRecordingValue(key: "", modifiers: [], trigger: trigger), ownerID: ownerID)
  }

  func receiveLocal(keyCode: UInt32, modifiers: [String], ownerID: UUID) {
    guard owns(ownerID), deliveryOwner != ownerID else { return }
    if isCapturingAction {
      receiveActionKey(keyCode: keyCode, modifiers: modifiers, ownerID: ownerID)
      return
    }
    if keyCode == 53 {
      cancelCurrent(message: "已取消录制。")
      return
    }
    guard let key = keyName(for: keyCode) else {
      cancelCurrent(message: "这个按键暂不支持，请换一个常规按键。")
      return
    }
    guard !modifiers.isEmpty || !requiresModifier(key) else {
      cancelCurrent(
        message: "未保存：\(ShortcutItem.prettyKey(key)) 会劫持普通输入，请至少加 ⌃ / ⌥ / ⇧ / ⌘。")
      return
    }
    deliver(ShortcutTriggerRecordingValue(key: key, modifiers: modifiers, trigger: nil), ownerID: ownerID)
  }

  private func receiveActionKey(keyCode: UInt32, modifiers: [String], ownerID: UUID) {
    guard let key = keyName(for: keyCode) else {
      emit("这个按键暂不支持，请换一个常规按键。", ownerID: ownerID)
      return
    }
    guard !modifiers.isEmpty || canUseBareSendShortcut(key) else {
      emit("未保存：\(ShortcutItem.prettyKey(key)) 会劫持普通输入，请至少加 ⌃ / ⌥ / ⇧ / ⌘。", ownerID: ownerID)
      return
    }
    actionCaptureDraft = displayHotkeyText(key: key, modifiers: modifiers)
    objectWillChange.send()
    emit("已录入：\(actionCaptureDraft)。", ownerID: ownerID)
  }

  private func deliver(_ value: ShortcutTriggerRecordingValue, ownerID: UUID) {
    guard owns(ownerID), deliveryOwner != ownerID, let capturedSession = session else { return }
    deliveryOwner = ownerID
    switch capturedSession.target {
    case .item:
      onItemCaptured?(capturedSession, value)
    case .draft:
      let callback = draftHandler
      guard let ticket = end(ownerID: ownerID, reloadHotkeys: true, cancelled: false),
        epoch == ticket, !isShutdown
      else { return }
      callback?(value)
      emit("已识别：\(value.displayText)。", ticket: ticket)
    case .action:
      break
    }
  }

  private func cancelCurrent(message: String) {
    guard let ticket = end(ownerID: nil, reloadHotkeys: true, cancelled: true) else { return }
    emit(message, ticket: ticket)
  }

  /// Returns an immutable completion ticket, which external callbacks may supersede.
  private func end(ownerID: UUID?, reloadHotkeys: Bool, cancelled: Bool) -> UUID? {
    guard !stopping, ownerID == nil || session?.id == ownerID else { return nil }
    stopping = true
    let ticket = UUID()
    epoch = ticket
    let previousSession = session
    let previousTap = tap
    let previousListener = physicalListener
    let previousTimeout = timeout
    let shouldResume = hotkeysSuspendedForRecording
    session = nil
    actionCaptureDraft = ""
    draftHandler = nil
    deliveryOwner = nil
    tap = nil
    physicalListener = nil
    timeout = nil
    hotkeysSuspendedForRecording = false
    previousTimeout?.stop()
    previousTap?.stop()
    previousListener?.stop()
    if cancelled, case .item(let itemID) = previousSession?.target {
      onCancelledItem?(itemID)
    }
    stopping = false
    if previousSession != nil { objectWillChange.send() }
    guard epoch == ticket, !isShutdown else { return ticket }
    if shouldResume && reloadHotkeys { resumeHotkeys?() }
    return ticket
  }

  private func emit(_ message: String, ownerID: UUID) {
    guard owns(ownerID) else { return }
    onStatus?(message)
  }

  private func emit(_ message: String, ticket: UUID) {
    guard epoch == ticket, !isShutdown, !stopping else { return }
    onStatus?(message)
  }
}
