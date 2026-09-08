import AppKit
import ApplicationServices
import Carbon
import IOKit.hid

enum CapsCoreEngineStatus: Equatable {
  case stopped
  case running
  case waitingForPermission(String)
  case failed(String)
}

private enum CapsCoreHardwareReconciliationOutcome: Equatable {
  case inactive
  case confirmedDown
  case releasedAndBlocked
}

@MainActor
final class CapsCoreEngine {
  private static let syntheticEventMarker: Int64 = 0x58_4C47_4341_5053
  private static let fallbackModifierDeviceID = UInt64.max - 1

  private let onStatusChange: (CapsCoreEngineStatus) -> Void
  private var eventTap: CFMachPort?
  private var eventTapSource: CFRunLoopSource?
  private var hidManager: IOHIDManager?
  private var hidSystemConnection: io_connect_t = 0
  private var hidDevices: [UInt64: IOHIDDevice] = [:]
  private var capsInputElements: [UInt64: IOHIDElement] = [:]
  private var ledReadyDeviceIDs = Set<UInt64>()
  private var ledDeniedDeviceIDs = Set<UInt64>()
  private var hidReadiness = CapsCoreHIDReadinessState()
  private let systemMappingController: CapsCoreSystemMappingController
  private let allowsSystemMappingProtection: Bool
  private var systemMappingProtectionActive = false
  private var capsLockControllerWriteDenied = false
  private var capsState = CapsCoreStateMachine()
  private var physicalModifierState = CapsCorePhysicalModifierState()
  private var syntheticModifierEventFilter = CapsCoreSyntheticModifierEventFilter()
  private var syntheticEventSource: CGEventSource?
  private var postedControl = false
  private var postedOption = false
  private var watchdog: Timer?
  private var sleepObserver: NSObjectProtocol?
  private var wakeObserver: NSObjectProtocol?
  private var screenSleepObserver: NSObjectProtocol?
  private var screenWakeObserver: NSObjectProtocol?

  private(set) var isRunning = false

  init(
    systemMappingController: CapsCoreSystemMappingController? = nil,
    allowsSystemMappingProtection: Bool = true,
    onStatusChange: @escaping (CapsCoreEngineStatus) -> Void
  ) {
    self.systemMappingController =
      systemMappingController
      ?? CapsCoreSystemMappingController { event, fields in
        AppDiagnostics.log(event, fields)
      }
    self.allowsSystemMappingProtection = allowsSystemMappingProtection
    self.onStatusChange = onStatusChange
  }

  isolated deinit {
    teardown(reason: "deinit")
  }

  @discardableResult
  func start(requestPermission: Bool) -> Bool {
    guard hasRequiredPermissions(requestIfNeeded: requestPermission) else {
      teardown(reason: "permissionMissing")
      onStatusChange(.waitingForPermission("需要完成系统授权，请点“立即授权”。"))
      return false
    }

    if isRunning {
      repairEventTapIfNeeded(reason: "alreadyRunning")
      return true
    }

    teardown(reason: "restart")
    startCapsLockController()
    guard startEventTap() else {
      teardown(reason: "eventTapStartFailed")
      let message = "系统授权尚未生效，Caps 监听已安全停止。"
      onStatusChange(.failed(message))
      return false
    }

    let hidMonitorStarted = startHIDMonitor()
    syntheticEventSource = CGEventSource(stateID: .hidSystemState)
    isRunning = true
    installPowerObservers()
    startWatchdog()
    if !systemMappingProtectionActive {
      forceSystemCapsLockOff()
      scheduleAllCapsLEDsOff()
    }
    AppDiagnostics.log(
      "caps_core_started",
      lifecycleFields(
        extra: [
          "hidMonitor": "\(hidMonitorStarted)",
          "hidPrimary": "\(hidPrimaryActive)",
        ]))
    onStatusChange(.running)
    return true
  }

  func stop(reason: String = "stop") {
    let wasRunning = isRunning
    teardown(reason: reason)
    AppDiagnostics.log(
      "caps_core_stopped",
      lifecycleFields(extra: ["wasRunning": "\(wasRunning)", "reason": reason]))
    onStatusChange(.stopped)
  }

  private func teardown(reason: String) {
    releaseAll(reason: reason)
    forceSystemCapsLockOff()
    stopWatchdog()
    removePowerObservers()
    stopHIDMonitor()
    stopEventTap()
    if allowsSystemMappingProtection {
      systemMappingController.deactivate()
    }
    stopCapsLockController()
    capsState = CapsCoreStateMachine()
    physicalModifierState.reset()
    syntheticModifierEventFilter.reset()
    syntheticEventSource = nil
    hidReadiness.reset()
    systemMappingProtectionActive = false
    capsLockControllerWriteDenied = false
    isRunning = false
  }

  private func hasRequiredPermissions(requestIfNeeded: Bool) -> Bool {
    var accessibilityGranted = AXIsProcessTrusted()
    if requestIfNeeded, !accessibilityGranted {
      let options = ["AXTrustedCheckOptionPrompt": true]
      accessibilityGranted = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    var listenGranted = CGPreflightListenEventAccess()
    if requestIfNeeded, !listenGranted {
      listenGranted = CGRequestListenEventAccess()
    }
    AppDiagnostics.log(
      "caps_core_permission_check",
      [
        "accessibility": "\(accessibilityGranted)",
        "inputMonitoring": "\(listenGranted)",
        "request": "\(requestIfNeeded)",
      ])
    return accessibilityGranted && listenGranted
  }

  private func startEventTap() -> Bool {
    let eventTypes: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
    let mask = eventTypes.reduce(CGEventMask(0)) { partial, type in
      partial | (CGEventMask(1) << type.rawValue)
    }
    let callback: CGEventTapCallBack = { _, type, event, context in
      guard let context else { return Unmanaged.passUnretained(event) }
      let engine = Unmanaged<CapsCoreEngine>.fromOpaque(context).takeUnretainedValue()
      return engine.handleEvent(type: type, event: event)
    }

    for location in [CGEventTapLocation.cghidEventTap, .cgSessionEventTap] {
      guard
        let tap = CGEvent.tapCreate(
          tap: location,
          place: .headInsertEventTap,
          options: .defaultTap,
          eventsOfInterest: mask,
          callback: callback,
          userInfo: Unmanaged.passUnretained(self).toOpaque())
      else {
        continue
      }
      eventTap = tap
      eventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
      if let eventTapSource {
        CFRunLoopAddSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
      }
      CGEvent.tapEnable(tap: tap, enable: true)
      AppDiagnostics.log("caps_core_event_tap_started", ["location": "\(location.rawValue)"])
      return true
    }
    AppDiagnostics.log("caps_core_event_tap_failed")
    return false
  }

  private func stopEventTap() {
    if let eventTap {
      CGEvent.tapEnable(tap: eventTap, enable: false)
    }
    if let eventTapSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
    }
    eventTapSource = nil
    eventTap = nil
  }

  private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      DispatchQueue.main.async { [weak self] in
        self?.handleEventTapDisabled(type)
      }
      return Unmanaged.passUnretained(event)
    }

    guard type == .keyDown || type == .keyUp || type == .flagsChanged else {
      return Unmanaged.passUnretained(event)
    }

    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    let isDown = keyEventIsPressed(type: type, keyCode: keyCode, flags: event.flags)
    if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker {
      return Unmanaged.passUnretained(event)
    }
    if let isDown, syntheticModifierEventFilter.consume(keyCode: keyCode, isDown: isDown) {
      return Unmanaged.passUnretained(event)
    }

    // Fn belongs to macOS and third-party voice-input providers. It must never
    // inherit Caps' synthetic Control/Option state or be rewritten by this tap.
    if type == .flagsChanged, keyCode == UInt16(kVK_Function) {
      return Unmanaged.passUnretained(event)
    }

    updateFallbackPhysicalModifierState(type: type, keyCode: keyCode, flags: event.flags)
    if keyCode == UInt16(kVK_CapsLock) {
      let capsPressed = event.flags.contains(.maskAlphaShift)
      scheduleForceSystemCapsLockOff()
      if capsPressed {
        scheduleAllCapsLEDsOff()
      }
      if !hidPrimaryActive {
        let transition = capsState.transition(to: capsPressed)
        if transition == .none {
          AppDiagnostics.log("caps_core_event_ignored", ["pressed": "\(capsPressed)"])
        }
        applyCapsTransition(transition, source: "eventTapFallback")
      } else if capsState.isDown {
        _ = reconcileCapsHardwareState(reason: "eventTapCaps")
      }
      return nil
    }

    let reconciliation = reconcileCapsHardwareState(reason: "event:\(keyCode)")
    var flags = event.flags
    flags.remove(.maskAlphaShift)
    if reconciliation == .confirmedDown {
      flags.insert(.maskControl)
      flags.insert(.maskAlternate)
    } else if reconciliation == .releasedAndBlocked {
      if !physicalModifierState.controlActive {
        flags.remove(.maskControl)
      }
      if !physicalModifierState.optionActive {
        flags.remove(.maskAlternate)
      }
    }
    event.flags = flags
    return Unmanaged.passUnretained(event)
  }

  private func keyEventIsPressed(
    type: CGEventType,
    keyCode: UInt16,
    flags: CGEventFlags
  ) -> Bool? {
    if type == .keyDown { return true }
    if type == .keyUp { return false }
    guard type == .flagsChanged else { return nil }
    switch Int(keyCode) {
    case kVK_Control, kVK_RightControl:
      return flags.contains(.maskControl)
    case kVK_Option, kVK_RightOption:
      return flags.contains(.maskAlternate)
    default:
      return nil
    }
  }

  private func updateFallbackPhysicalModifierState(
    type: CGEventType,
    keyCode: UInt16,
    flags: CGEventFlags
  ) {
    guard !hidPrimaryActive, type == .flagsChanged else { return }
    let usage: UInt32
    switch Int(keyCode) {
    case kVK_Control: usage = CapsCorePhysicalModifierState.leftControlUsage
    case kVK_RightControl: usage = CapsCorePhysicalModifierState.rightControlUsage
    case kVK_Option: usage = CapsCorePhysicalModifierState.leftOptionUsage
    case kVK_RightOption: usage = CapsCorePhysicalModifierState.rightOptionUsage
    default: return
    }
    guard let isDown = keyEventIsPressed(type: type, keyCode: keyCode, flags: flags) else { return }
    physicalModifierState.update(
      deviceID: Self.fallbackModifierDeviceID,
      usage: usage,
      isDown: isDown)
  }

  private func handleEventTapDisabled(_ type: CGEventType) {
    let reason = type == .tapDisabledByTimeout ? "tapDisabledByTimeout" : "tapDisabledByUserInput"
    releaseAll(reason: reason)
    resetPhysicalInputLedgers(reason: reason)
    repairEventTapIfNeeded(reason: reason)
  }

  private func repairEventTapIfNeeded(reason: String) {
    guard isRunning, let eventTap else { return }
    if !CGEvent.tapIsEnabled(tap: eventTap) {
      CGEvent.tapEnable(tap: eventTap, enable: true)
      AppDiagnostics.log("caps_core_event_tap_reenabled", ["reason": reason])
    }
    guard CGEvent.tapIsEnabled(tap: eventTap) else {
      fail("Caps 监听被系统停止，请重新检测。", reason: "eventTapRepairFailed")
      return
    }
  }

  private func startHIDMonitor() -> Bool {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(
      manager,
      [
        kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
        kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard,
      ] as CFDictionary)
    IOHIDManagerRegisterDeviceMatchingCallback(
      manager,
      { context, _, _, device in
        guard let context else { return }
        let engine = Unmanaged<CapsCoreEngine>.fromOpaque(context).takeUnretainedValue()
        engine.handleHIDDeviceMatched(device)
      },
      Unmanaged.passUnretained(self).toOpaque())
    IOHIDManagerRegisterDeviceRemovalCallback(
      manager,
      { context, _, _, device in
        guard let context else { return }
        let engine = Unmanaged<CapsCoreEngine>.fromOpaque(context).takeUnretainedValue()
        engine.handleHIDDeviceRemoved(device)
      },
      Unmanaged.passUnretained(self).toOpaque())
    IOHIDManagerRegisterInputValueCallback(
      manager,
      { context, _, _, value in
        guard let context else { return }
        let engine = Unmanaged<CapsCoreEngine>.fromOpaque(context).takeUnretainedValue()
        engine.handleHIDValue(value)
      },
      Unmanaged.passUnretained(self).toOpaque())
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

    let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    guard result == kIOReturnSuccess else {
      IOHIDManagerUnscheduleFromRunLoop(
        manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
      AppDiagnostics.log("caps_core_hid_open_failed", ["result": "\(result)"])
      return false
    }
    hidManager = manager
    return true
  }

  private func stopHIDMonitor() {
    guard let hidManager else {
      hidDevices.removeAll()
      capsInputElements.removeAll()
      ledReadyDeviceIDs.removeAll()
      ledDeniedDeviceIDs.removeAll()
      hidReadiness.reset()
      return
    }
    IOHIDManagerUnscheduleFromRunLoop(
      hidManager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
    self.hidManager = nil
    hidDevices.removeAll()
    capsInputElements.removeAll()
    ledReadyDeviceIDs.removeAll()
    ledDeniedDeviceIDs.removeAll()
    hidReadiness.reset()
  }

  private func handleHIDDeviceMatched(_ device: IOHIDDevice) {
    let deviceID = registryID(for: device)
    hidDevices[deviceID] = device
    cacheCapsInputElement(for: device, deviceID: deviceID)
    hidReadiness.deviceMatched(deviceID)
    scheduleCapsLEDOff(deviceID: deviceID)
    AppDiagnostics.log("caps_core_hid_device_matched", ["id": "\(deviceID)"])
  }

  private func handleHIDDeviceRemoved(_ device: IOHIDDevice) {
    let deviceID = registryID(for: device)
    applyCapsTransition(capsState.removeDevice(deviceID), source: "deviceRemoved")
    physicalModifierState.removeDevice(deviceID)
    hidDevices.removeValue(forKey: deviceID)
    capsInputElements.removeValue(forKey: deviceID)
    ledReadyDeviceIDs.remove(deviceID)
    ledDeniedDeviceIDs.remove(deviceID)
    hidReadiness.deviceRemoved(deviceID)
    if !hidPrimaryActive {
      if allowsSystemMappingProtection {
        systemMappingController.deactivate()
      }
      systemMappingProtectionActive = false
    }
    AppDiagnostics.log("caps_core_hid_device_removed", ["id": "\(deviceID)"])
  }

  private func handleHIDValue(_ value: IOHIDValue) {
    let element = IOHIDValueGetElement(value)
    let usagePage = IOHIDElementGetUsagePage(element)
    let usage = IOHIDElementGetUsage(element)
    guard usagePage == kHIDPage_KeyboardOrKeypad else { return }
    let device = IOHIDElementGetDevice(element)
    let deviceID = registryID(for: device)
    let isDown = IOHIDValueGetIntegerValue(value) != 0

    if hidReadiness.inputObserved(deviceID) {
      AppDiagnostics.log("caps_core_hid_input_ready", ["id": "\(deviceID)"])
      ensureSystemCapsLockSuppression()
    }

    if CapsCorePhysicalModifierState.tracks(usage: usage) {
      physicalModifierState.update(deviceID: deviceID, usage: usage, isDown: isDown)
      return
    }
    guard usage == kHIDUsage_KeyboardCapsLock else { return }
    capsInputElements[deviceID] = element
    if !systemMappingProtectionActive {
      forceSystemCapsLockOff()
      scheduleCapsLEDOff(deviceID: deviceID)
    }
    applyCapsTransition(
      capsState.adoptHIDTransition(deviceID: deviceID, isDown: isDown),
      source: "hid")
  }

  private func cacheCapsInputElement(for device: IOHIDDevice, deviceID: UInt64) {
    let matching =
      [
        kIOHIDElementUsagePageKey as String: kHIDPage_KeyboardOrKeypad,
        kIOHIDElementUsageKey as String: kHIDUsage_KeyboardCapsLock,
      ] as CFDictionary
    guard
      let rawElements = IOHIDDeviceCopyMatchingElements(
        device,
        matching,
        IOOptionBits(kIOHIDOptionsTypeNone)),
      let elements = rawElements as? [IOHIDElement],
      let element = elements.first
    else {
      return
    }
    capsInputElements[deviceID] = element
  }

  private func readPhysicalCapsState(deviceID: UInt64) -> CapsCoreHIDPhysicalState {
    guard
      let device = hidDevices[deviceID],
      let element = capsInputElements[deviceID]
    else {
      return .unavailable
    }

    let valuePointer = UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity: 1)
    defer { valuePointer.deallocate() }
    let result = IOHIDDeviceGetValue(device, element, valuePointer)
    guard result == kIOReturnSuccess else {
      AppDiagnostics.log(
        "caps_core_hid_snapshot_failed",
        ["id": "\(deviceID)", "result": "\(result)"])
      return .unavailable
    }
    let value = valuePointer.pointee.takeUnretainedValue()
    return IOHIDValueGetIntegerValue(value) == 0 ? .up : .down
  }

  @discardableResult
  private func reconcileCapsHardwareState(
    reason: String
  ) -> CapsCoreHardwareReconciliationOutcome {
    guard capsState.isDown || postedControl || postedOption else {
      return .inactive
    }
    guard capsState.isDown else {
      markFailClosedRelease(reason: reason, unavailableDeviceIDs: [])
      releaseAll(reason: "orphanedVirtualModifiers:\(reason)")
      return .releasedAndBlocked
    }

    if hidPrimaryActive {
      let snapshotDeviceIDs = Set(capsInputElements.keys)
      guard !snapshotDeviceIDs.isEmpty else {
        markFailClosedRelease(reason: reason, unavailableDeviceIDs: [])
        releaseAll(reason: "missingHIDOwner:\(reason)")
        return .releasedAndBlocked
      }

      var physicalStates: [UInt64: CapsCoreHIDPhysicalState] = [:]
      for deviceID in snapshotDeviceIDs {
        physicalStates[deviceID] = readPhysicalCapsState(deviceID: deviceID)
      }
      let plan = CapsCoreHIDReconciler.plan(
        pressedDeviceIDs: snapshotDeviceIDs,
        physicalStates: physicalStates)
      let previousOwners = capsState.pressedDeviceIDs
      applyCapsTransition(
        capsState.reconcileHIDPressedDevices(plan.safePressedDeviceIDs),
        source: "hidSnapshot:\(reason)")

      if plan.shouldBlockCurrentAction {
        markFailClosedRelease(
          reason: reason,
          unavailableDeviceIDs: plan.unavailableDeviceIDs)
        releaseAll(reason: "hidSnapshotFailClosed:\(reason)")
        return .releasedAndBlocked
      }
      if previousOwners != plan.safePressedDeviceIDs {
        AppDiagnostics.log(
          "caps_core_hid_snapshot_reconciled",
          [
            "after": "\(plan.safePressedDeviceIDs.count)",
            "before": "\(previousOwners.count)",
            "reason": reason,
          ])
      }
      return .confirmedDown
    }

    let physicalDown = CGEventSource.keyState(
      .hidSystemState,
      key: CGKeyCode(kVK_CapsLock))
    if physicalDown {
      return .confirmedDown
    }
    markFailClosedRelease(reason: reason, unavailableDeviceIDs: [])
    releaseAll(reason: "eventTapSnapshotFailClosed:\(reason)")
    return .releasedAndBlocked
  }

  private func markFailClosedRelease(
    reason: String,
    unavailableDeviceIDs: Set<UInt64>
  ) {
    AppDiagnostics.log(
      "caps_core_fail_closed_release",
      [
        "reason": reason,
        "unavailableDevices": unavailableDeviceIDs.sorted().map(String.init).joined(separator: ","),
      ])
  }

  func shouldAllowHotkeyTrigger(modifiers: [String]) -> Bool {
    let modifiers = Set(modifiers)
    guard modifiers.contains("control"), modifiers.contains("option") else {
      return true
    }

    let reconciliationState: CapsCoreHotkeyReconciliationState
    switch reconcileCapsHardwareState(reason: "beforeHotkeyAction") {
    case .confirmedDown:
      reconciliationState = .confirmedCapsDown
    case .releasedAndBlocked:
      reconciliationState = .failClosedRelease
    case .inactive:
      reconciliationState = .inactive
    }
    return CapsCoreHotkeySafetyGate.shouldAllowCapsStyleShortcut(
      reconciliationState: reconciliationState,
      physicalControlActive: physicalModifierState.controlActive,
      physicalOptionActive: physicalModifierState.optionActive)
  }

  private func resetPhysicalInputLedgers(reason: String) {
    physicalModifierState.reset()
    syntheticModifierEventFilter.reset()
    AppDiagnostics.log("caps_core_physical_ledgers_reset", ["reason": reason])
  }

  private func applyCapsTransition(_ transition: CapsCoreTransition, source: String) {
    switch transition {
    case .none:
      return
    case .press:
      postVirtualModifiersDown()
      AppDiagnostics.log("caps_core_down", ["source": source])
    case .release:
      releaseVirtualModifiers()
      AppDiagnostics.log("caps_core_up", ["source": source])
    }
  }

  private func postVirtualModifiersDown() {
    var flags = physicalModifierFlags()
    if !postedControl {
      flags.insert(.maskControl)
      postModifier(keyCode: UInt16(kVK_Control), isDown: true, flags: flags)
      postedControl = true
    }
    if !postedOption {
      flags.insert(.maskAlternate)
      postModifier(keyCode: UInt16(kVK_Option), isDown: true, flags: flags)
      postedOption = true
    }
  }

  private func releaseVirtualModifiers() {
    let flags = physicalModifierFlags()
    if postedOption {
      postModifier(keyCode: UInt16(kVK_Option), isDown: false, flags: flags)
      postedOption = false
    }
    if postedControl {
      postModifier(keyCode: UInt16(kVK_Control), isDown: false, flags: flags)
      postedControl = false
    }
  }

  private func releaseAll(reason: String) {
    let hadPressedState = capsState.reset() == .release
    if hadPressedState || postedControl || postedOption {
      releaseVirtualModifiers()
      AppDiagnostics.log("caps_core_release_all", ["reason": reason])
    }
  }

  private func physicalModifierFlags() -> CGEventFlags {
    var flags: CGEventFlags = []
    if physicalModifierState.controlActive { flags.insert(.maskControl) }
    if physicalModifierState.optionActive { flags.insert(.maskAlternate) }
    return flags
  }

  private func postModifier(keyCode: UInt16, isDown: Bool, flags: CGEventFlags) {
    let token = syntheticModifierEventFilter.register(keyCode: keyCode, isDown: isDown)
    guard
      let event = CGEvent(
        keyboardEventSource: syntheticEventSource,
        virtualKey: CGKeyCode(keyCode),
        keyDown: isDown)
    else {
      syntheticModifierEventFilter.expire(token: token)
      return
    }
    event.flags = flags
    event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
    event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
    event.post(tap: .cghidEventTap)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
      self?.syntheticModifierEventFilter.expire(token: token)
    }
  }

  private func startCapsLockController() {
    let service = IOServiceGetMatchingService(
      kIOMainPortDefault,
      IOServiceMatching(kIOHIDSystemClass))
    guard service != 0 else {
      AppDiagnostics.log("caps_core_lock_controller_unavailable")
      return
    }
    defer { IOObjectRelease(service) }
    let result = IOServiceOpen(
      service,
      mach_task_self_,
      UInt32(kIOHIDParamConnectType),
      &hidSystemConnection)
    if result != kIOReturnSuccess {
      hidSystemConnection = 0
      AppDiagnostics.log("caps_core_lock_controller_open_failed", ["result": "\(result)"])
    }
  }

  private func stopCapsLockController() {
    guard hidSystemConnection != 0 else { return }
    IOServiceClose(hidSystemConnection)
    hidSystemConnection = 0
  }

  private func forceSystemCapsLockOff() {
    guard hidSystemConnection != 0, !capsLockControllerWriteDenied else { return }
    let result = IOHIDSetModifierLockState(
      hidSystemConnection,
      Int32(kIOHIDCapsLockState),
      false)
    if result != kIOReturnSuccess {
      AppDiagnostics.log("caps_core_lock_state_off_failed", ["result": "\(result)"])
      if result == kIOReturnNotPermitted {
        capsLockControllerWriteDenied = true
      }
    }
  }

  private func scheduleAllCapsLEDsOff() {
    guard !systemMappingProtectionActive else { return }
    for deviceID in hidDevices.keys {
      scheduleCapsLEDOff(deviceID: deviceID)
    }
  }

  private func scheduleForceSystemCapsLockOff() {
    for delay in [0.0, 0.05, 0.15, 0.3] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        self?.forceSystemCapsLockOff()
      }
    }
  }

  private func scheduleCapsLEDOff(deviceID: UInt64) {
    guard !systemMappingProtectionActive, !ledDeniedDeviceIDs.contains(deviceID) else { return }
    for delay in [0.0, 0.04, 0.15] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        guard let self, let device = self.hidDevices[deviceID] else { return }
        self.forceCapsLEDOff(device: device, deviceID: deviceID)
      }
    }
  }

  private func forceCapsLEDOff(device: IOHIDDevice, deviceID: UInt64) {
    guard !systemMappingProtectionActive, !ledDeniedDeviceIDs.contains(deviceID) else { return }
    let matching =
      [
        kIOHIDElementUsagePageKey as String: kHIDPage_LEDs,
        kIOHIDElementUsageKey as String: kHIDUsage_LED_CapsLock,
      ] as CFDictionary
    guard
      let rawElements = IOHIDDeviceCopyMatchingElements(
        device,
        matching,
        IOOptionBits(kIOHIDOptionsTypeNone)),
      let elements = rawElements as? [IOHIDElement],
      !elements.isEmpty
    else {
      return
    }

    var didWrite = false
    for element in elements {
      let value = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, 0, 0)
      let result = IOHIDDeviceSetValue(device, element, value)
      if result == kIOReturnSuccess {
        didWrite = true
      } else {
        AppDiagnostics.log(
          "caps_core_led_off_failed",
          ["id": "\(deviceID)", "result": "\(result)"])
        if result == kIOReturnNotPermitted {
          ledDeniedDeviceIDs.insert(deviceID)
        }
      }
    }
    if didWrite, ledReadyDeviceIDs.insert(deviceID).inserted {
      AppDiagnostics.log("caps_core_led_control_ready", ["id": "\(deviceID)"])
    }
  }

  private func registryID(for device: IOHIDDevice) -> UInt64 {
    var registryID: UInt64 = 0
    let service = IOHIDDeviceGetService(device)
    if service != 0 {
      IORegistryEntryGetRegistryEntryID(service, &registryID)
    }
    if registryID != 0 { return registryID }
    return UInt64(UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque()))
  }

  private func installPowerObservers() {
    removePowerObservers()
    let center = NSWorkspace.shared.notificationCenter
    sleepObserver = center.addObserver(
      forName: NSWorkspace.willSleepNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.releaseAll(reason: "systemSleep")
        self?.resetPhysicalInputLedgers(reason: "systemSleep")
        self?.forceSystemCapsLockOff()
      }
    }
    wakeObserver = center.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.releaseAll(reason: "systemWake")
        self.resetPhysicalInputLedgers(reason: "systemWake")
        self.forceSystemCapsLockOff()
        self.scheduleAllCapsLEDsOff()
        self.repairEventTapIfNeeded(reason: "systemWake")
      }
    }
    screenSleepObserver = center.addObserver(
      forName: NSWorkspace.screensDidSleepNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.releaseAll(reason: "screenSleep")
        self?.resetPhysicalInputLedgers(reason: "screenSleep")
        self?.forceSystemCapsLockOff()
      }
    }
    screenWakeObserver = center.addObserver(
      forName: NSWorkspace.screensDidWakeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.releaseAll(reason: "screenWake")
        self.resetPhysicalInputLedgers(reason: "screenWake")
        self.forceSystemCapsLockOff()
        self.scheduleAllCapsLEDsOff()
        self.repairEventTapIfNeeded(reason: "screenWake")
      }
    }
  }

  private func removePowerObservers() {
    let center = NSWorkspace.shared.notificationCenter
    if let sleepObserver { center.removeObserver(sleepObserver) }
    if let wakeObserver { center.removeObserver(wakeObserver) }
    if let screenSleepObserver { center.removeObserver(screenSleepObserver) }
    if let screenWakeObserver { center.removeObserver(screenWakeObserver) }
    sleepObserver = nil
    wakeObserver = nil
    screenSleepObserver = nil
    screenWakeObserver = nil
  }

  private func startWatchdog() {
    stopWatchdog()
    let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.isRunning else { return }
        guard AXIsProcessTrusted(), CGPreflightListenEventAccess() else {
          self.permissionWasLost()
          return
        }
        if !self.systemMappingProtectionActive {
          self.forceSystemCapsLockOff()
        }
        _ = self.reconcileCapsHardwareState(reason: "watchdog")
        self.repairEventTapIfNeeded(reason: "watchdog")
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    watchdog = timer
  }

  private func stopWatchdog() {
    watchdog?.invalidate()
    watchdog = nil
  }

  private func permissionWasLost() {
    teardown(reason: "permissionLost")
    AppDiagnostics.log("caps_core_permission_lost")
    onStatusChange(.waitingForPermission("系统授权已关闭，Caps 监听已安全停止。请点“立即授权”。"))
  }

  private func fail(_ message: String, reason: String) {
    teardown(reason: reason)
    AppDiagnostics.log("caps_core_failed", ["reason": reason])
    onStatusChange(.failed(message))
  }

  private func lifecycleFields(extra: [String: String] = [:]) -> [String: String] {
    var fields = [
      "capsDown": "\(capsState.isDown)",
      "deviceOwners": "\(capsState.pressedDeviceCount)",
      "hidDevices": "\(hidDevices.count)",
      "hidReadyDevices": "\(hidReadiness.inputReadyDeviceIDs.count)",
      "isRunning": "\(isRunning)",
      "postedControl": "\(postedControl)",
      "postedOption": "\(postedOption)",
      "systemMapping": "\(systemMappingProtectionActive)",
    ]
    fields.merge(extra) { _, new in new }
    return fields
  }

  private var hidPrimaryActive: Bool {
    hidReadiness.isPrimaryActive
  }

  private func ensureSystemCapsLockSuppression() {
    guard allowsSystemMappingProtection, hidPrimaryActive, !systemMappingProtectionActive else {
      return
    }
    let result = systemMappingController.activate()
    systemMappingProtectionActive = result.isProtectionActive
    switch result {
    case .applied:
      AppDiagnostics.log("caps_core_system_mapping_ready", ["source": "owned"])
    case .alreadyProtected:
      AppDiagnostics.log("caps_core_system_mapping_ready", ["source": "existing"])
    case .conflict(let message):
      AppDiagnostics.log(
        "caps_core_system_mapping_degraded",
        ["reason": "conflict", "message": message])
    case .failed(let message):
      AppDiagnostics.log(
        "caps_core_system_mapping_degraded",
        ["reason": "failed", "message": message])
    }
  }
}
