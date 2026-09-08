import AppKit
import ApplicationServices
import Carbon

struct HotkeyTriggerContext {
  let openAppActivateOnly: Bool

  static let standard = HotkeyTriggerContext(openAppActivateOnly: false)
}

final class HotkeyEventTapLifecycle {
  private let lock = NSLock()
  private var generation: UInt64 = 0
  private var active = false

  func beginStart() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    generation &+= 1
    active = true
    return generation
  }

  func cancelStart(_ candidate: UInt64, cleanup: () -> Void = {}) {
    lock.lock()
    if generation == candidate {
      active = false
      cleanup()
    }
    lock.unlock()
  }

  @discardableResult
  func beginStop() -> UInt64 {
    beginStop(cleanup: {}).0
  }

  @discardableResult
  func beginStop<T>(cleanup: () -> T) -> (UInt64, T) {
    lock.lock()
    defer { lock.unlock() }
    generation &+= 1
    active = false
    return (generation, cleanup())
  }

  func allows(_ candidate: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return active && generation == candidate
  }

  func withActiveGeneration<T>(_ candidate: UInt64, _ operation: () -> T) -> T? {
    lock.lock()
    defer { lock.unlock() }
    guard active, generation == candidate else { return nil }
    return operation()
  }

  func finishGeneration(_ candidate: UInt64, cleanup: () -> Void) {
    lock.lock()
    if generation == candidate {
      active = false
      cleanup()
    }
    lock.unlock()
  }

  func read<T>(_ operation: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return operation()
  }
}

private final class HotkeyEventTapContext {
  weak var manager: HotkeyManager?
  let generation: UInt64

  init(manager: HotkeyManager, generation: UInt64) {
    self.manager = manager
    self.generation = generation
  }
}

final class HotkeyManager {
  struct ListenerHealth: Equatable {
    let carbonRegistrationCount: Int
    let advancedListenerRequired: Bool
    let advancedListenerRunning: Bool
  }

  private struct OpenAppHoldSession {
    let modifiers: Set<String>
    var lastTarget: String
    var lastTriggeredAt: TimeInterval
  }

  private struct EventTapResources {
    let port: CFMachPort?
    let source: CFRunLoopSource?
    let runLoop: CFRunLoop?
  }

  private var eventHandlerRef: EventHandlerRef?
  private var hotkeyRefs: [EventHotKeyRef] = []
  private var hotkeyMap: [UInt32: ShortcutItem] = [:]
  private var carbonKeyCodeByID: [UInt32: UInt32] = [:]
  private var carbonEventTapReleaseWatchIDs = Set<UInt32>()
  private var carbonPressGate = CarbonHotkeyPressGate()
  private var openAppHoldSession: OpenAppHoldSession?
  private var eventTap: CFMachPort?
  private var eventTapSource: CFRunLoopSource?
  private var eventTapRunLoop: CFRunLoop?
  private var eventTapThread: Thread?
  private var eventTapItems: [ShortcutItem] = []
  private var eventTapItemMap: [String: ShortcutItem] = [:]
  private let eventTapLifecycle = HotkeyEventTapLifecycle()
  private var modifierDoubleTapItems: [PhysicalModifierKey: ShortcutItem] = [:]
  private var modifierDoubleTapListener: PhysicalModifierDoubleTapHIDListener?
  private let eventTapPressLock = NSLock()
  private var eventTapHeldKeyCodes = Set<UInt32>()
  private var commandWProtection = CommandWProtectionPolicy(bundleIDs: [])
  private var nextID: UInt32 = 1
  private let signature = fourCharCode("AXLG")
  private let openAppHoldSessionIdleTimeout: TimeInterval = 1.2
  private let physicalKeyboardUnavailableFailure =
    "未检测到可用的实体键盘；虚拟键盘不会用于物理修饰键手势。"
  private let onTrigger: (ShortcutItem, HotkeyTriggerContext) -> Void
  private let onNotice: (String) -> Void

  private(set) var failures: [String] = []

  var commandWProtectionRunning: Bool {
    guard !commandWProtection.bundleIDs.isEmpty else { return false }
    return eventTapLifecycle.read {
      guard let eventTap, eventTapRunLoop != nil, CFMachPortIsValid(eventTap) else { return false }
      return CGEvent.tapIsEnabled(tap: eventTap)
    }
  }

  var listenerHealth: ListenerHealth {
    let eventTapRequired =
      !eventTapItems.isEmpty || !carbonEventTapReleaseWatchIDs.isEmpty
      || !commandWProtection.bundleIDs.isEmpty
    let modifierDoubleTapRequired = !modifierDoubleTapItems.isEmpty
    let advancedListenerRequired = eventTapRequired || modifierDoubleTapRequired
    let eventTapRunning = eventTapLifecycle.read {
      eventTap != nil && eventTapRunLoop != nil
    }
    return ListenerHealth(
      carbonRegistrationCount: hotkeyMap.count,
      advancedListenerRequired: advancedListenerRequired,
      advancedListenerRunning: (!eventTapRequired || eventTapRunning)
        && (!modifierDoubleTapRequired
          || (modifierDoubleTapListener?.isRunning == true
            && modifierDoubleTapListener?.hasAcceptedPhysicalKeyboard == true))
    )
  }

  init(
    onTrigger: @escaping (ShortcutItem, HotkeyTriggerContext) -> Void,
    onNotice: @escaping (String) -> Void
  ) {
    self.onTrigger = onTrigger
    self.onNotice = onNotice
    installCarbonHandler()
  }

  deinit {
    stopEventTap()
    unregisterAll()
    if let eventHandlerRef {
      RemoveEventHandler(eventHandlerRef)
    }
  }

  func register(_ items: [ShortcutItem]) {
    stopEventTap()
    unregisterAll()
    failures = []
    commandWProtection = .load()
    nextID = 1
    let trustedForGlobalTap = AXIsProcessTrusted()
    var globalTapItems: [ShortcutItem] = []
    var globalTapMap: [String: ShortcutItem] = [:]
    var gestureItems: [PhysicalModifierKey: ShortcutItem] = [:]
    var registeredSignatures: [String: ShortcutItem] = [:]

    for item in items.filter(\.enabled) {
      let shortcutSignature = shortcutTriggerSignature(for: item)
      if let existing = registeredSignatures[shortcutSignature] {
        failures.append("\(item.name)：\(item.displayHotkey) 与「\(existing.name)」冲突，已跳过。")
        continue
      }
      registeredSignatures[shortcutSignature] = item

      if let trigger = item.trigger {
        switch trigger.kind {
        case .modifierDoubleTap:
          gestureItems[trigger.modifier] = item
        }
        continue
      }

      guard let keyCode = keyCode(for: item.key) else {
        failures.append("\(item.name)：不支持按键 \(item.key)")
        continue
      }

      // Keep a user-defined Cmd-W on the same scoped route; Carbon would claim it globally.
      if !commandWProtection.bundleIDs.isEmpty, keyCode == 13,
        Set(item.modifiers) == Set(["command"])
      {
        globalTapItems.append(item)
        globalTapMap[eventTapSignature(code: UInt32(keyCode), modifiers: item.modifiers)] = item
        continue
      }

      var hotkeyRef: EventHotKeyRef?
      let hotkeyID = EventHotKeyID(signature: signature, id: nextID)
      let status = RegisterEventHotKey(
        UInt32(keyCode),
        carbonModifiers(item.modifiers),
        hotkeyID,
        GetApplicationEventTarget(),
        0,
        &hotkeyRef
      )

      if status == noErr, let hotkeyRef {
        hotkeyRefs.append(hotkeyRef)
        hotkeyMap[nextID] = item
        carbonKeyCodeByID[nextID] = UInt32(keyCode)
        if item.action == .openApp || item.action == .sendShortcut {
          carbonEventTapReleaseWatchIDs.insert(nextID)
        }
        nextID += 1
      } else if item.id == "builtin-launcher-caps-space" {
        failures.append(
          "小龙哥启动器：Caps + Space 当前被系统或外部工具占用，未抢占。")
        AppDiagnostics.log(
          "builtin_launcher_registration_blocked",
          ["status": "\(status)", "key": item.displayHotkey])
      } else {
        globalTapItems.append(item)
        globalTapMap[eventTapSignature(code: UInt32(keyCode), modifiers: item.modifiers)] = item
        failures.append("\(item.name)：\(item.displayHotkey) 已改用高级监听。")
      }
    }

    eventTapItems = globalTapItems
    eventTapItemMap = globalTapMap
    modifierDoubleTapItems = gestureItems
    _ = startModifierDoubleTapListenerIfPossible()
    _ = startEventTapIfPossible(
      requiresAuthorizationNotice: !commandWProtection.bundleIDs.isEmpty
        || (!trustedForGlobalTap
          && (!globalTapItems.isEmpty || !carbonEventTapReleaseWatchIDs.isEmpty))
    )
    AppDiagnostics.log(
      "hotkey_register",
      [
        "carbon": "\(hotkeyMap.count)",
        "fallback": "\(eventTapItems.count)",
        "modifierDoubleTap": "\(modifierDoubleTapItems.count)",
        "failures": "\(failures.count)",
      ])
  }

  func unregisterAll() {
    for ref in hotkeyRefs {
      UnregisterEventHotKey(ref)
    }
    hotkeyRefs.removeAll()
    hotkeyMap.removeAll()
    carbonKeyCodeByID.removeAll()
    carbonEventTapReleaseWatchIDs.removeAll()
    carbonPressGate.reset()
    resetEventTapPressGate()
    openAppHoldSession = nil
    stopModifierDoubleTapListener()
  }

  func suspendAll() {
    stopEventTap()
    commandWProtection = CommandWProtectionPolicy(bundleIDs: [])
    unregisterAll()
    failures = []
  }

  private func installCarbonHandler() {
    var specs = [
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
    ]
    let callback: EventHandlerUPP = { _, eventRef, userData in
      guard let eventRef, let userData else { return noErr }
      var hotkeyID = EventHotKeyID()
      let status = GetEventParameter(
        eventRef,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotkeyID
      )
      guard status == noErr else { return status }
      let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
      switch GetEventKind(eventRef) {
      case UInt32(kEventHotKeyPressed):
        manager.handleCarbonPressed(id: hotkeyID.id)
      case UInt32(kEventHotKeyReleased):
        manager.handleCarbonReleased(id: hotkeyID.id)
      default:
        break
      }
      return noErr
    }
    let installStatus = specs.withUnsafeMutableBufferPointer { buffer in
      InstallEventHandler(
        GetApplicationEventTarget(),
        callback,
        buffer.count,
        buffer.baseAddress,
        Unmanaged.passUnretained(self).toOpaque(),
        &eventHandlerRef
      )
    }
    if installStatus != noErr {
      AppDiagnostics.log("hotkey_carbon_handler_failed", ["status": "\(installStatus)"])
    }
  }

  @discardableResult
  private func startModifierDoubleTapListenerIfPossible() -> Bool {
    guard !modifierDoubleTapItems.isEmpty else { return true }
    guard AXIsProcessTrusted(), CGPreflightListenEventAccess() else {
      failures.append("物理修饰键监听需要辅助功能与输入监控权限。")
      return false
    }

    let listener = PhysicalModifierDoubleTapHIDListener(
      modifiers: Set(modifierDoubleTapItems.keys),
      onTrigger: { [weak self] modifier in
        guard let self, let item = self.modifierDoubleTapItems[modifier] else { return }
        AppDiagnostics.log(
          "hotkey_modifier_double_tap_match",
          ["item": item.name, "key": item.displayHotkey, "modifier": modifier.rawValue])
        self.trigger(item)
      },
      onNotice: { [weak self] notice in
        guard let self else { return }
        switch notice {
        case .deviceRemoved(let deviceID):
          AppDiagnostics.log(
            "hotkey_modifier_double_tap_device_removed", ["id": "\(deviceID)"])
        case .noConfiguredModifiers:
          AppDiagnostics.log("hotkey_modifier_double_tap_empty", [:])
        case .openFailed(let code):
          AppDiagnostics.log("hotkey_modifier_double_tap_open_failed", ["code": "\(code)"])
        case .mouseResetMonitorUnavailable:
          AppDiagnostics.log("hotkey_modifier_double_tap_mouse_monitor_failed", [:])
        case .physicalKeyboardAvailable:
          self.failures.removeAll { $0 == self.physicalKeyboardUnavailableFailure }
          AppDiagnostics.log("hotkey_modifier_double_tap_physical_keyboard_available", [:])
          self.onNotice("已检测到实体键盘，物理修饰键手势可用。")
        case .physicalKeyboardUnavailable:
          if !self.failures.contains(self.physicalKeyboardUnavailableFailure) {
            self.failures.append(self.physicalKeyboardUnavailableFailure)
          }
          AppDiagnostics.log("hotkey_modifier_double_tap_physical_keyboard_unavailable", [:])
          self.onNotice(self.physicalKeyboardUnavailableFailure)
        case .permissionLost:
          let failure = "物理修饰键监听权限已失效；未回退到逻辑按键。"
          if !self.failures.contains(failure) {
            self.failures.append(failure)
          }
          AppDiagnostics.log("hotkey_modifier_double_tap_permission_lost", [:])
          self.onNotice(failure)
        }
      })
    guard listener.start() else {
      let code = listener.lastOpenResult.map { String($0) } ?? "unknown"
      failures.append("物理修饰键监听启动失败（\(code)）；未回退到逻辑按键，避免误触发。")
      return false
    }
    modifierDoubleTapListener = listener
    return true
  }

  private func stopModifierDoubleTapListener() {
    modifierDoubleTapListener?.stop()
    modifierDoubleTapListener = nil
    modifierDoubleTapItems.removeAll()
  }

  @discardableResult
  private func startEventTapIfPossible(requiresAuthorizationNotice: Bool) -> Bool {
    let needsFallbackKeyDown = !eventTapItems.isEmpty || !commandWProtection.bundleIDs.isEmpty
    let needsCarbonKeyUpRelease = !carbonEventTapReleaseWatchIDs.isEmpty
    let hasCarbonOpenApp = carbonEventTapReleaseWatchIDs.contains {
      hotkeyMap[$0]?.action == .openApp
    }
    let needsOpenAppSessionWatch =
      hasCarbonOpenApp || eventTapItems.contains { $0.action == .openApp }
    guard
      needsFallbackKeyDown || needsCarbonKeyUpRelease || needsOpenAppSessionWatch
    else {
      return true
    }
    guard AXIsProcessTrusted() else {
      if requiresAuthorizationNotice {
        failures.append("高级监听尚未授权：请点「立即授权」，软件会自动判断下一步。")
      }
      return false
    }
    guard CGPreflightListenEventAccess() else {
      if requiresAuthorizationNotice {
        failures.append("高级监听需要完成系统授权。")
      }
      return false
    }

    let generation = eventTapLifecycle.beginStart()
    let callbackContext = HotkeyEventTapContext(manager: self, generation: generation)

    var mask = 0
    if needsFallbackKeyDown {
      mask |= 1 << CGEventType.keyDown.rawValue
    }
    if needsFallbackKeyDown || needsCarbonKeyUpRelease {
      mask |= 1 << CGEventType.keyUp.rawValue
    }
    if needsOpenAppSessionWatch {
      mask |= 1 << CGEventType.flagsChanged.rawValue
    }
    let callback: CGEventTapCallBack = { _, type, event, userInfo in
      guard let userInfo else {
        return Unmanaged.passUnretained(event)
      }
      let context = Unmanaged<HotkeyEventTapContext>.fromOpaque(userInfo).takeUnretainedValue()
      guard let manager = context.manager else {
        return Unmanaged.passUnretained(event)
      }
      if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        manager.reenableEventTap(generation: context.generation)
        return Unmanaged.passUnretained(event)
      }
      let handled = manager.eventTapLifecycle.withActiveGeneration(context.generation) {
        manager.handle(event: event, type: type)
      }
      if handled == true {
        return nil
      }
      return Unmanaged.passUnretained(event)
    }

    let contextPointer = Unmanaged.passUnretained(callbackContext).toOpaque()
    let tapPort =
      makeEventTap(
        tap: .cghidEventTap, mask: mask, callback: callback, userInfo: contextPointer)
      ?? makeEventTap(
        tap: .cgSessionEventTap, mask: mask, callback: callback, userInfo: contextPointer)

    guard let tapPort else {
      eventTapLifecycle.cancelStart(generation)
      failures.append(
        requiresAuthorizationNotice
          ? "高级监听启动失败：请点「立即授权」，软件会自动处理。"
          : "后台全局监听启动失败：请点「立即授权」，软件会自动处理。")
      AppDiagnostics.log("hotkey_eventtap_failed", ["items": "\(eventTapItems.count)"])
      return false
    }
    guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tapPort, 0) else {
      eventTapLifecycle.cancelStart(generation)
      CFMachPortInvalidate(tapPort)
      failures.append("高级监听启动失败：无法建立事件循环源。")
      AppDiagnostics.log("hotkey_eventtap_source_failed", ["items": "\(eventTapItems.count)"])
      return false
    }

    let thread = Thread { [weak self, callbackContext] in
      guard let self else { return }
      let runLoop = CFRunLoopGetCurrent()
      let installed = self.eventTapLifecycle.withActiveGeneration(generation) {
        guard self.eventTap === tapPort, self.eventTapSource === source else { return false }
        self.eventTapRunLoop = runLoop
        CFRunLoopAddSource(runLoop, source, .commonModes)
        return true
      }
      guard installed == true else {
        CFMachPortInvalidate(tapPort)
        return
      }
      let enabled = self.eventTapLifecycle.withActiveGeneration(generation) {
        guard CFMachPortIsValid(tapPort) else { return false }
        CGEvent.tapEnable(tap: tapPort, enable: true)
        return true
      }
      guard enabled == true else {
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        CFMachPortInvalidate(tapPort)
        return
      }
      AppDiagnostics.log(
        "hotkey_eventtap_started",
        [
          "fallback": "\(self.eventTapItems.count)",
          "releaseWatch": "\(self.carbonEventTapReleaseWatchIDs.count)",
          "sessionWatch": "\(needsOpenAppSessionWatch)",
        ])
      CFRunLoopRun()
      self.eventTapLifecycle.finishGeneration(generation) {
        guard self.eventTap === tapPort else { return }
        CGEvent.tapEnable(tap: tapPort, enable: false)
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        CFMachPortInvalidate(tapPort)
        self.eventTap = nil
        self.eventTapSource = nil
        self.eventTapRunLoop = nil
        self.eventTapThread = nil
      }
      _ = callbackContext
    }
    thread.name = "\(AppRuntimeIdentity.current.mainExecutableName)-eventtap"
    thread.qualityOfService = .userInteractive
    let published = eventTapLifecycle.withActiveGeneration(generation) {
      eventTap = tapPort
      eventTapSource = source
      eventTapThread = thread
      return true
    }
    guard published == true else {
      CFMachPortInvalidate(tapPort)
      return false
    }
    thread.start()
    return true
  }

  private func makeEventTap(
    tap: CGEventTapLocation,
    mask: Int,
    callback: @escaping CGEventTapCallBack,
    userInfo: UnsafeMutableRawPointer
  ) -> CFMachPort? {
    CGEvent.tapCreate(
      tap: tap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: CGEventMask(mask),
      callback: callback,
      userInfo: userInfo
    )
  }

  private func stopEventTap() {
    let (_, resources) = eventTapLifecycle.beginStop {
      let resources = EventTapResources(
        port: eventTap,
        source: eventTapSource,
        runLoop: eventTapRunLoop)
      eventTapSource = nil
      eventTapRunLoop = nil
      eventTapThread = nil
      eventTap = nil
      eventTapItems.removeAll()
      eventTapItemMap.removeAll()
      return resources
    }
    if let port = resources.port {
      CGEvent.tapEnable(tap: port, enable: false)
      CFMachPortInvalidate(port)
    }
    if let source = resources.source, let runLoop = resources.runLoop {
      CFRunLoopRemoveSource(runLoop, source, .commonModes)
    }
    if let runLoop = resources.runLoop {
      CFRunLoopStop(runLoop)
      CFRunLoopWakeUp(runLoop)
    }
  }

  private func handle(event: CGEvent, type: CGEventType) -> Bool {
    switch type {
    case .keyDown:
      return handleKeyDown(event: event)
    case .keyUp:
      let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
      endEventTapPress(keyCode: keyCode)
      DispatchQueue.main.async { [weak self] in
        self?.releaseCarbonHeldHotkeys(keyCode: keyCode)
      }
      return false
    case .flagsChanged:
      let activeModifiers = Set(modifierNames(from: event.flags))
      DispatchQueue.main.async { [weak self] in
        self?.handleFlagsChanged(activeModifiers: activeModifiers)
      }
      return false
    default:
      return false
    }
  }

  private func handleKeyDown(event: CGEvent) -> Bool {
    let code = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags
    if commandWProtection.blocks(
      keyCode: code, flags: flags,
      bundleID: code == 13 ? NSWorkspace.shared.frontmostApplication?.bundleIdentifier : nil
    ) {
      return true
    }
    guard let item = eventTapItemMap[eventTapSignature(code: code, flags: flags)] else {
      return false
    }
    if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
      AppDiagnostics.log(
        "hotkey_eventtap_autorepeat_ignored",
        ["item": item.name, "key": item.displayHotkey]
      )
      return true
    }
    guard beginEventTapPress(keyCode: code) else {
      AppDiagnostics.log(
        "hotkey_eventtap_held_repeat_ignored",
        ["item": item.name, "key": item.displayHotkey]
      )
      return true
    }
    AppDiagnostics.log("hotkey_eventtap_match", ["item": item.name, "key": item.displayHotkey])
    trigger(item)
    return true
  }

  private func releaseCarbonHeldHotkeys(keyCode: UInt32) {
    let releasedIDs = carbonPressGate.heldIDs.filter {
      carbonKeyCodeByID[$0] == keyCode
    }
    for id in releasedIDs {
      releaseCarbonHeldHotkey(id: id, source: "eventtap_keyup")
    }
  }

  private func handleFlagsChanged(activeModifiers: Set<String>) {
    guard let session = openAppHoldSession else { return }
    guard !session.modifiers.isSubset(of: activeModifiers) else { return }
    openAppHoldSession = nil
    AppDiagnostics.log(
      "hotkey_openapp_hold_session_end",
      ["modifiers": session.modifiers.sorted().joined(separator: "+")]
    )
  }

  private func handleCarbonPressed(id: UInt32) {
    guard let item = hotkeyMap[id] else { return }
    guard carbonPressGate.begin(id: id) else {
      AppDiagnostics.log(
        "hotkey_carbon_held_repeat_ignored",
        [
          "action": item.action.rawValue,
          "id": "\(id)",
          "item": item.name,
          "key": item.displayHotkey,
        ]
      )
      return
    }
    AppDiagnostics.log("hotkey_carbon_match", ["item": item.name, "key": item.displayHotkey])
    trigger(item)
  }

  private func handleCarbonReleased(id: UInt32) {
    releaseCarbonHeldHotkey(id: id, source: "carbon")
  }

  private func releaseCarbonHeldHotkey(id: UInt32, source: String) {
    guard let item = hotkeyMap[id] else { return }
    if carbonPressGate.end(id: id) {
      AppDiagnostics.log(
        "hotkey_carbon_release",
        [
          "action": item.action.rawValue,
          "id": "\(id)",
          "item": item.name,
          "key": item.displayHotkey,
          "source": source,
        ]
      )
    }
  }

  private func trigger(_ item: ShortcutItem) {
    let now = ProcessInfo.processInfo.systemUptime
    let context = triggerContext(for: item, at: now)
    AppDiagnostics.log("hotkey_trigger", ["action": item.action.rawValue, "item": item.name])
    onTrigger(item, context)
  }

  private func triggerContext(
    for item: ShortcutItem,
    at now: TimeInterval
  ) -> HotkeyTriggerContext {
    guard item.action == .openApp, item.usesChordTrigger else {
      return .standard
    }
    let modifiers = Set(item.modifiers)
    guard !modifiers.isEmpty else {
      openAppHoldSession = nil
      return .standard
    }

    let previousSession = openAppHoldSession
    let isSameHoldSession =
      previousSession?.modifiers == modifiers
      && previousSession.map { now - $0.lastTriggeredAt <= openAppHoldSessionIdleTimeout } == true
    let previousTarget = isSameHoldSession ? previousSession?.lastTarget : nil
    let activateOnly = previousTarget != nil && previousTarget != item.target

    openAppHoldSession = OpenAppHoldSession(
      modifiers: modifiers,
      lastTarget: item.target,
      lastTriggeredAt: now
    )

    if activateOnly {
      AppDiagnostics.log(
        "hotkey_openapp_cross_session_activate_only",
        [
          "item": item.name,
          "modifiers": modifiers.sorted().joined(separator: "+"),
          "previousTarget": previousTarget ?? "",
          "target": item.target,
        ])
    }
    return HotkeyTriggerContext(openAppActivateOnly: activateOnly)
  }

  private func eventTapSignature(code: UInt32, modifiers: [String]) -> String {
    "\(code)|\(modifiers.sorted().joined(separator: "+"))"
  }

  private func eventTapSignature(code: UInt32, flags: CGEventFlags) -> String {
    eventTapSignature(code: code, modifiers: modifierNames(from: flags))
  }

  private func beginEventTapPress(keyCode: UInt32) -> Bool {
    eventTapPressLock.lock()
    defer { eventTapPressLock.unlock() }
    return eventTapHeldKeyCodes.insert(keyCode).inserted
  }

  private func endEventTapPress(keyCode: UInt32) {
    eventTapPressLock.lock()
    eventTapHeldKeyCodes.remove(keyCode)
    eventTapPressLock.unlock()
  }

  private func resetEventTapPressGate() {
    eventTapPressLock.lock()
    eventTapHeldKeyCodes.removeAll()
    eventTapPressLock.unlock()
  }

  private func reenableEventTap(generation: UInt64) {
    let reenabled = eventTapLifecycle.withActiveGeneration(generation) {
      guard let eventTap, CFMachPortIsValid(eventTap) else { return false }
      resetEventTapPressGate()
      CGEvent.tapEnable(tap: eventTap, enable: true)
      return true
    }
    guard reenabled == true else { return }
    DispatchQueue.main.async {
      self.onNotice("高级监听已自动恢复。")
    }
  }

}
