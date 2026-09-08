import AppKit
import Dispatch
import Foundation
import IOKit.hid

struct PhysicalModifierDoubleTapConfiguration: Equatable {
  static let defaultMaximumPressDuration: TimeInterval = 0.300
  static let defaultMaximumInterTapInterval: TimeInterval = 0.400

  let maximumPressDuration: TimeInterval
  let maximumInterTapInterval: TimeInterval

  init(
    maximumPressDuration: TimeInterval = Self.defaultMaximumPressDuration,
    maximumInterTapInterval: TimeInterval = Self.defaultMaximumInterTapInterval
  ) {
    precondition(
      maximumPressDuration.isFinite && maximumPressDuration >= 0,
      "maximumPressDuration must be finite and nonnegative")
    precondition(
      maximumInterTapInterval.isFinite && maximumInterTapInterval >= 0,
      "maximumInterTapInterval must be finite and nonnegative")
    self.maximumPressDuration = maximumPressDuration
    self.maximumInterTapInterval = maximumInterTapInterval
  }
}

enum PhysicalModifierDoubleTapOutcome: Equatable {
  case none
  case triggered(PhysicalModifierKey)
}

/// Pure device-identity gate kept separate from IOKit so the physical-key boundary is testable.
func shouldAcceptHIDDevice(
  isVirtual: Bool,
  manufacturer: String?,
  product: String?,
  transport: String?
) -> Bool {
  guard !isVirtual else { return false }
  let identityText = [manufacturer, product, transport]
    .compactMap { $0?.lowercased() }
    .joined(separator: " ")
  return !identityText.contains("karabiner") && !identityText.contains("virtual")
}

/// A pure state machine fed by raw keyboard HID transitions.
///
/// A tap is one clean down/up cycle of a configured physical modifier. Both taps must come from
/// the same HID device and usage. Any other key-down contaminates the gesture and resets it. The
/// second clean key-up is the only transition that can emit `.triggered`.
struct PhysicalModifierDoubleTapRecognizer {
  private struct PhysicalModifierDeviceKey: Equatable, Hashable {
    let deviceID: UInt64
    let usage: UInt32
  }

  private enum Phase: Equatable {
    case idle
    case firstDown(
      key: PhysicalModifierDeviceKey,
      modifier: PhysicalModifierKey,
      beganAt: TimeInterval)
    case waitingForSecond(
      key: PhysicalModifierDeviceKey,
      modifier: PhysicalModifierKey,
      firstEndedAt: TimeInterval)
    case secondDown(
      key: PhysicalModifierDeviceKey,
      modifier: PhysicalModifierKey,
      beganAt: TimeInterval)
  }

  let modifiers: Set<PhysicalModifierKey>
  let configuration: PhysicalModifierDoubleTapConfiguration

  private var phase: Phase = .idle
  private var pressedKeys = Set<PhysicalModifierDeviceKey>()

  init(
    modifiers: Set<PhysicalModifierKey> = [.rightOption],
    configuration: PhysicalModifierDoubleTapConfiguration = .init()
  ) {
    self.modifiers = modifiers
    self.configuration = configuration
  }

  mutating func handleKeyboardUsage(
    deviceID: UInt64,
    usage: UInt32,
    isDown: Bool,
    timestamp: TimeInterval
  ) -> PhysicalModifierDoubleTapOutcome {
    guard timestamp.isFinite else {
      reset()
      return .none
    }

    let key = PhysicalModifierDeviceKey(deviceID: deviceID, usage: usage)
    if isDown {
      // Ignore repeat reports. One physical down/up cycle may advance the recognizer only once.
      guard pressedKeys.insert(key).inserted else {
        return .none
      }
    } else {
      guard pressedKeys.remove(key) != nil else {
        phase = .idle
        return .none
      }
    }

    guard let modifier = configuredModifier(for: usage) else {
      if isDown {
        phase = .idle
      }
      return .none
    }

    if isDown {
      guard pressedKeys == [key] else {
        phase = .idle
        return .none
      }
      return handleTargetDown(key: key, modifier: modifier, timestamp: timestamp)
    }

    guard pressedKeys.isEmpty else {
      phase = .idle
      return .none
    }
    return handleTargetUp(key: key, modifier: modifier, timestamp: timestamp)
  }

  /// A removal invalidates the complete gesture, even when the removed device was not the target.
  mutating func deviceRemoved(_ deviceID: UInt64) {
    pressedKeys = pressedKeys.filter { $0.deviceID != deviceID }
    phase = .idle
  }

  /// Use for pause, configuration changes, permission loss, and other lifecycle discontinuities.
  mutating func reset() {
    phase = .idle
    pressedKeys.removeAll()
  }

  private func configuredModifier(for usage: UInt32) -> PhysicalModifierKey? {
    guard let modifier = PhysicalModifierKey(hidUsage: usage), modifiers.contains(modifier) else {
      return nil
    }
    return modifier
  }

  private mutating func handleTargetDown(
    key: PhysicalModifierDeviceKey,
    modifier: PhysicalModifierKey,
    timestamp: TimeInterval
  ) -> PhysicalModifierDoubleTapOutcome {
    switch phase {
    case .waitingForSecond(let firstKey, let firstModifier, let firstEndedAt):
      let interval = timestamp - firstEndedAt
      if firstKey == key, firstModifier == modifier,
        isWithinLimit(interval, configuration.maximumInterTapInterval)
      {
        phase = .secondDown(key: key, modifier: modifier, beganAt: timestamp)
      } else {
        phase = .firstDown(key: key, modifier: modifier, beganAt: timestamp)
      }
    case .idle, .firstDown, .secondDown:
      phase = .firstDown(key: key, modifier: modifier, beganAt: timestamp)
    }
    return .none
  }

  private mutating func handleTargetUp(
    key: PhysicalModifierDeviceKey,
    modifier: PhysicalModifierKey,
    timestamp: TimeInterval
  ) -> PhysicalModifierDoubleTapOutcome {
    switch phase {
    case .firstDown(let firstKey, let firstModifier, let beganAt):
      guard firstKey == key, firstModifier == modifier,
        isCleanPress(from: beganAt, to: timestamp)
      else {
        phase = .idle
        return .none
      }
      phase = .waitingForSecond(
        key: key,
        modifier: modifier,
        firstEndedAt: timestamp)
      return .none
    case .secondDown(let secondKey, let secondModifier, let beganAt):
      guard secondKey == key, secondModifier == modifier,
        isCleanPress(from: beganAt, to: timestamp)
      else {
        phase = .idle
        return .none
      }
      phase = .idle
      return .triggered(modifier)
    case .idle, .waitingForSecond:
      phase = .idle
      return .none
    }
  }

  private func isCleanPress(from beganAt: TimeInterval, to endedAt: TimeInterval) -> Bool {
    let duration = endedAt - beganAt
    return isWithinLimit(duration, configuration.maximumPressDuration)
  }

  private func isWithinLimit(_ value: TimeInterval, _ limit: TimeInterval) -> Bool {
    // Decimal test fixtures and mach-time conversion can land one or two ULPs above the boundary.
    let floatingPointTolerance = max(limit.ulp * 8, Double.ulpOfOne)
    return value >= 0 && value <= limit + floatingPointTolerance
  }
}

enum PhysicalModifierDoubleTapHIDNotice: Equatable {
  case noConfiguredModifiers
  case openFailed(code: IOReturn)
  case mouseResetMonitorUnavailable
  case physicalKeyboardAvailable
  case physicalKeyboardUnavailable
  case deviceRemoved(deviceID: UInt64)
  case permissionLost
}

/// Passively observes raw keyboard input. It never seizes a device, suppresses an event, changes a
/// key mapping, posts a synthetic key event, or starts CapsCore. Lifecycle calls and callbacks are
/// expected on the main thread because the HID manager is scheduled on the main run loop.
final class PhysicalModifierDoubleTapHIDListener {
  private static let virtualDevicePropertyKey = "HIDVirtualDevice"

  typealias TriggerHandler = (PhysicalModifierKey) -> Void
  typealias NoticeHandler = (PhysicalModifierDoubleTapHIDNotice) -> Void

  private var recognizer: PhysicalModifierDoubleTapRecognizer
  private let onTrigger: TriggerHandler
  private let onNotice: NoticeHandler
  private var hidManager: IOHIDManager?
  private var localMouseResetMonitor: Any?
  private var globalMouseResetMonitor: Any?
  private var workspaceObservers: [NSObjectProtocol] = []
  private var acceptedDeviceIDs = Set<UInt64>()
  private var rejectedDeviceIDs = Set<UInt64>()
  private var isPaused = false

  private(set) var isRunning = false
  private(set) var hasAcceptedPhysicalKeyboard = false
  private(set) var lastOpenResult: IOReturn?

  init(
    modifiers: Set<PhysicalModifierKey>,
    configuration: PhysicalModifierDoubleTapConfiguration = .init(),
    onTrigger: @escaping TriggerHandler,
    onNotice: @escaping NoticeHandler = { _ in }
  ) {
    recognizer = PhysicalModifierDoubleTapRecognizer(
      modifiers: modifiers,
      configuration: configuration)
    self.onTrigger = onTrigger
    self.onNotice = onNotice
  }

  deinit {
    tearDown()
  }

  @discardableResult
  func start() -> Bool {
    dispatchPrecondition(condition: .onQueue(.main))
    if isRunning { return true }

    guard !recognizer.modifiers.isEmpty else {
      recognizer.reset()
      onNotice(.noConfiguredModifiers)
      return false
    }

    recognizer.reset()
    isPaused = false
    lastOpenResult = nil

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
        let listener = Unmanaged<PhysicalModifierDoubleTapHIDListener>.fromOpaque(context)
          .takeUnretainedValue()
        listener.handleDeviceMatched(device)
      },
      Unmanaged.passUnretained(self).toOpaque())
    IOHIDManagerRegisterDeviceRemovalCallback(
      manager,
      { context, _, _, device in
        guard let context else { return }
        let listener = Unmanaged<PhysicalModifierDoubleTapHIDListener>.fromOpaque(context)
          .takeUnretainedValue()
        listener.handleDeviceRemoved(device)
      },
      Unmanaged.passUnretained(self).toOpaque())
    IOHIDManagerRegisterInputValueCallback(
      manager,
      { context, _, _, value in
        guard let context else { return }
        let listener = Unmanaged<PhysicalModifierDoubleTapHIDListener>.fromOpaque(context)
          .takeUnretainedValue()
        listener.handleInputValue(value)
      },
      Unmanaged.passUnretained(self).toOpaque())
    IOHIDManagerScheduleWithRunLoop(
      manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

    let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    lastOpenResult = result
    guard result == kIOReturnSuccess else {
      IOHIDManagerUnscheduleFromRunLoop(
        manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
      IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
      onNotice(.openFailed(code: result))
      return false
    }

    hidManager = manager
    guard installResetObservers() else {
      tearDown()
      onNotice(.mouseResetMonitorUnavailable)
      return false
    }
    isRunning = true
    refreshMatchedDevices(manager)
    if !hasAcceptedPhysicalKeyboard {
      onNotice(.physicalKeyboardUnavailable)
    }
    return true
  }

  func stop() {
    dispatchPrecondition(condition: .onQueue(.main))
    tearDown()
  }

  func pause() {
    dispatchPrecondition(condition: .onQueue(.main))
    isPaused = true
    recognizer.reset()
  }

  func resume() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard isRunning else { return }
    recognizer.reset()
    isPaused = false
  }

  func permissionWasLost() {
    dispatchPrecondition(condition: .onQueue(.main))
    tearDown()
    onNotice(.permissionLost)
  }

  func reset() {
    dispatchPrecondition(condition: .onQueue(.main))
    recognizer.reset()
  }

  private func tearDown() {
    isRunning = false
    hasAcceptedPhysicalKeyboard = false
    isPaused = false
    recognizer.reset()
    acceptedDeviceIDs.removeAll()
    rejectedDeviceIDs.removeAll()
    removeResetObservers()
    guard let hidManager else { return }
    IOHIDManagerUnscheduleFromRunLoop(
      hidManager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
    self.hidManager = nil
  }

  private func installResetObservers() -> Bool {
    let mouseEvents: NSEvent.EventTypeMask = [
      .leftMouseDown,
      .rightMouseDown,
      .otherMouseDown,
      .scrollWheel,
    ]

    localMouseResetMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) {
      [weak self] event in
      self?.recognizer.reset()
      return event
    }
    globalMouseResetMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) {
      [weak self] _ in
      self?.recognizer.reset()
    }

    let center = NSWorkspace.shared.notificationCenter
    workspaceObservers = [
      center.addObserver(
        forName: NSWorkspace.willSleepNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.recognizer.reset()
      },
      center.addObserver(
        forName: NSWorkspace.didWakeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.recognizer.reset()
      },
    ]

    return localMouseResetMonitor != nil && globalMouseResetMonitor != nil
  }

  private func removeResetObservers() {
    if let localMouseResetMonitor {
      NSEvent.removeMonitor(localMouseResetMonitor)
      self.localMouseResetMonitor = nil
    }
    if let globalMouseResetMonitor {
      NSEvent.removeMonitor(globalMouseResetMonitor)
      self.globalMouseResetMonitor = nil
    }

    let center = NSWorkspace.shared.notificationCenter
    workspaceObservers.forEach(center.removeObserver)
    workspaceObservers.removeAll()
  }

  private func refreshMatchedDevices(_ manager: IOHIDManager) {
    guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return }
    devices.forEach(handleDeviceMatched)
  }

  private func handleDeviceMatched(_ device: IOHIDDevice) {
    guard isRunning else { return }
    let deviceID = registryID(for: device)
    guard !acceptedDeviceIDs.contains(deviceID), !rejectedDeviceIDs.contains(deviceID) else {
      return
    }
    guard acceptsHIDDevice(device) else {
      acceptedDeviceIDs.remove(deviceID)
      rejectedDeviceIDs.insert(deviceID)
      return
    }

    let wasUnavailable = acceptedDeviceIDs.isEmpty
    rejectedDeviceIDs.remove(deviceID)
    acceptedDeviceIDs.insert(deviceID)
    hasAcceptedPhysicalKeyboard = true
    if wasUnavailable {
      onNotice(.physicalKeyboardAvailable)
    }
  }

  private func handleDeviceRemoved(_ device: IOHIDDevice) {
    guard isRunning else { return }
    let deviceID = registryID(for: device)
    if rejectedDeviceIDs.remove(deviceID) != nil { return }
    guard acceptedDeviceIDs.remove(deviceID) != nil else { return }
    recognizer.deviceRemoved(deviceID)
    onNotice(.deviceRemoved(deviceID: deviceID))
    if acceptedDeviceIDs.isEmpty {
      hasAcceptedPhysicalKeyboard = false
      onNotice(.physicalKeyboardUnavailable)
    }
  }

  private func handleInputValue(_ value: IOHIDValue) {
    guard isRunning, !isPaused else { return }
    let element = IOHIDValueGetElement(value)
    let device = IOHIDElementGetDevice(element)
    guard isAcceptedDevice(device) else { return }
    let usagePage = IOHIDElementGetUsagePage(element)
    if usagePage == kHIDPage_Consumer {
      if IOHIDValueGetIntegerValue(value) != 0 {
        recognizer.reset()
      }
      return
    }
    guard usagePage == kHIDPage_KeyboardOrKeypad else { return }
    let outcome = recognizer.handleKeyboardUsage(
      deviceID: registryID(for: device),
      usage: IOHIDElementGetUsage(element),
      isDown: IOHIDValueGetIntegerValue(value) != 0,
      timestamp: Self.seconds(fromMachAbsoluteTime: IOHIDValueGetTimeStamp(value)))
    if case .triggered(let modifier) = outcome {
      onTrigger(modifier)
    }
  }

  private func isAcceptedDevice(_ device: IOHIDDevice) -> Bool {
    let deviceID = registryID(for: device)
    if acceptedDeviceIDs.contains(deviceID) { return true }
    if rejectedDeviceIDs.contains(deviceID) { return false }
    handleDeviceMatched(device)
    return acceptedDeviceIDs.contains(deviceID)
  }

  private func acceptsHIDDevice(_ device: IOHIDDevice) -> Bool {
    shouldAcceptHIDDevice(
      isVirtual: hidBooleanProperty(device, key: Self.virtualDevicePropertyKey),
      manufacturer: hidStringProperty(device, key: kIOHIDManufacturerKey),
      product: hidStringProperty(device, key: kIOHIDProductKey),
      transport: hidStringProperty(device, key: kIOHIDTransportKey))
  }

  private func hidBooleanProperty(_ device: IOHIDDevice, key: String) -> Bool {
    guard let value = IOHIDDeviceGetProperty(device, key as CFString) else { return false }
    if let boolean = value as? Bool { return boolean }
    if let number = value as? NSNumber { return number.boolValue }
    switch String(describing: value).lowercased() {
    case "1", "true", "yes": return true
    default: return false
    }
  }

  private func hidStringProperty(_ device: IOHIDDevice, key: String) -> String? {
    guard let value = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
    return value as? String ?? String(describing: value)
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

  private static func seconds(fromMachAbsoluteTime timestamp: UInt64) -> TimeInterval {
    struct Timebase {
      static let value: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
      }()
    }
    let info = Timebase.value
    guard info.denom != 0 else { return 0 }
    return Double(timestamp) * Double(info.numer) / Double(info.denom) / 1_000_000_000
  }
}
