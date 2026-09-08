import Foundation

enum CapsCoreTransition: Equatable {
  case none
  case press
  case release
}

struct CapsCoreHIDReadinessState: Equatable {
  private(set) var matchedDeviceIDs = Set<UInt64>()
  private(set) var inputReadyDeviceIDs = Set<UInt64>()

  var isPrimaryActive: Bool {
    !inputReadyDeviceIDs.isEmpty
  }

  mutating func deviceMatched(_ deviceID: UInt64) {
    matchedDeviceIDs.insert(deviceID)
  }

  @discardableResult
  mutating func inputObserved(_ deviceID: UInt64) -> Bool {
    matchedDeviceIDs.insert(deviceID)
    return inputReadyDeviceIDs.insert(deviceID).inserted
  }

  mutating func deviceRemoved(_ deviceID: UInt64) {
    matchedDeviceIDs.remove(deviceID)
    inputReadyDeviceIDs.remove(deviceID)
  }

  mutating func reset() {
    matchedDeviceIDs.removeAll()
    inputReadyDeviceIDs.removeAll()
  }
}

struct CapsCoreStateMachine {
  static let eventTapFallbackDeviceID = UInt64.max

  private(set) var pressedDeviceIDs = Set<UInt64>()

  var isDown: Bool {
    !pressedDeviceIDs.isEmpty
  }

  var pressedDeviceCount: Int {
    pressedDeviceIDs.count
  }

  mutating func transition(to isDown: Bool) -> CapsCoreTransition {
    transition(deviceID: Self.eventTapFallbackDeviceID, to: isDown)
  }

  mutating func transition(deviceID: UInt64, to isDown: Bool) -> CapsCoreTransition {
    let wasDown = self.isDown
    if isDown {
      pressedDeviceIDs.insert(deviceID)
    } else {
      pressedDeviceIDs.remove(deviceID)
    }
    return transitionResult(wasDown: wasDown)
  }

  mutating func adoptHIDTransition(deviceID: UInt64, isDown: Bool) -> CapsCoreTransition {
    let wasDown = self.isDown
    pressedDeviceIDs.remove(Self.eventTapFallbackDeviceID)
    if isDown {
      pressedDeviceIDs.insert(deviceID)
    } else {
      pressedDeviceIDs.remove(deviceID)
    }
    return transitionResult(wasDown: wasDown)
  }

  mutating func removeDevice(_ deviceID: UInt64) -> CapsCoreTransition {
    let wasDown = isDown
    pressedDeviceIDs.remove(deviceID)
    return transitionResult(wasDown: wasDown)
  }

  mutating func reconcileHIDPressedDevices(_ deviceIDs: Set<UInt64>) -> CapsCoreTransition {
    let wasDown = isDown
    pressedDeviceIDs = deviceIDs
    return transitionResult(wasDown: wasDown)
  }

  mutating func reset() -> CapsCoreTransition {
    let wasDown = isDown
    pressedDeviceIDs.removeAll()
    return wasDown ? .release : .none
  }

  private func transitionResult(wasDown: Bool) -> CapsCoreTransition {
    if !wasDown, isDown { return .press }
    if wasDown, !isDown { return .release }
    return .none
  }
}

enum CapsCoreHIDPhysicalState: Equatable {
  case down
  case up
  case unavailable
}

struct CapsCoreHIDReconciliationPlan: Equatable {
  let safePressedDeviceIDs: Set<UInt64>
  let unavailableDeviceIDs: Set<UInt64>
  let shouldBlockCurrentAction: Bool

  var hasConfirmedDown: Bool {
    !safePressedDeviceIDs.isEmpty
  }
}

enum CapsCoreHIDReconciler {
  static func plan(
    pressedDeviceIDs: Set<UInt64>,
    physicalStates: [UInt64: CapsCoreHIDPhysicalState]
  ) -> CapsCoreHIDReconciliationPlan {
    guard !pressedDeviceIDs.isEmpty else {
      return CapsCoreHIDReconciliationPlan(
        safePressedDeviceIDs: [],
        unavailableDeviceIDs: [],
        shouldBlockCurrentAction: false)
    }

    var confirmedDown = Set<UInt64>()
    var unavailable = Set<UInt64>()
    for deviceID in pressedDeviceIDs {
      switch physicalStates[deviceID] ?? .unavailable {
      case .down:
        confirmedDown.insert(deviceID)
      case .up:
        break
      case .unavailable:
        unavailable.insert(deviceID)
      }
    }

    // A partially unreadable snapshot cannot prove which physical keyboard still owns Caps.
    // Fail closed and release every synthetic modifier instead of carrying uncertain state.
    let safePressedDeviceIDs = unavailable.isEmpty ? confirmedDown : []
    return CapsCoreHIDReconciliationPlan(
      safePressedDeviceIDs: safePressedDeviceIDs,
      unavailableDeviceIDs: unavailable,
      shouldBlockCurrentAction: safePressedDeviceIDs.isEmpty || !unavailable.isEmpty)
  }
}

enum CapsCoreHotkeyReconciliationState: Equatable {
  case inactive
  case confirmedCapsDown
  case failClosedRelease
}

enum CapsCoreHotkeySafetyGate {
  static func shouldAllowCapsStyleShortcut(
    reconciliationState: CapsCoreHotkeyReconciliationState,
    physicalControlActive: Bool,
    physicalOptionActive: Bool
  ) -> Bool {
    switch reconciliationState {
    case .confirmedCapsDown:
      return true
    case .failClosedRelease:
      return false
    case .inactive:
      break
    }

    return physicalControlActive && physicalOptionActive
  }
}

struct CapsCorePhysicalModifierState: Equatable {
  static let leftControlUsage: UInt32 = 0xE0
  static let leftOptionUsage: UInt32 = 0xE2
  static let rightControlUsage: UInt32 = 0xE4
  static let rightOptionUsage: UInt32 = 0xE6

  private struct Key: Hashable {
    let deviceID: UInt64
    let usage: UInt32
  }

  private var pressedControlKeys = Set<Key>()
  private var pressedOptionKeys = Set<Key>()

  var controlActive: Bool { !pressedControlKeys.isEmpty }
  var optionActive: Bool { !pressedOptionKeys.isEmpty }

  static func tracks(usage: UInt32) -> Bool {
    [leftControlUsage, rightControlUsage, leftOptionUsage, rightOptionUsage]
      .contains(usage)
  }

  mutating func update(deviceID: UInt64, usage: UInt32, isDown: Bool) {
    let key = Key(deviceID: deviceID, usage: usage)
    if usage == Self.leftControlUsage || usage == Self.rightControlUsage {
      if isDown {
        pressedControlKeys.insert(key)
      } else {
        pressedControlKeys.remove(key)
      }
    } else if usage == Self.leftOptionUsage || usage == Self.rightOptionUsage {
      if isDown {
        pressedOptionKeys.insert(key)
      } else {
        pressedOptionKeys.remove(key)
      }
    }
  }

  mutating func removeDevice(_ deviceID: UInt64) {
    pressedControlKeys = pressedControlKeys.filter { $0.deviceID != deviceID }
    pressedOptionKeys = pressedOptionKeys.filter { $0.deviceID != deviceID }
  }

  mutating func reset() {
    pressedControlKeys.removeAll()
    pressedOptionKeys.removeAll()
  }
}

struct CapsCoreSyntheticModifierEventFilter {
  private struct Expectation: Equatable {
    let token: UInt64
    let isDown: Bool
  }

  private var expectations: [UInt16: [Expectation]] = [:]
  private var nextToken: UInt64 = 1

  mutating func register(keyCode: UInt16, isDown: Bool) -> UInt64 {
    let token = nextToken
    nextToken &+= 1
    expectations[keyCode, default: []].append(Expectation(token: token, isDown: isDown))
    return token
  }

  mutating func consume(keyCode: UInt16, isDown: Bool) -> Bool {
    guard var queue = expectations[keyCode],
      let index = queue.firstIndex(where: { $0.isDown == isDown })
    else {
      return false
    }
    queue.remove(at: index)
    expectations[keyCode] = queue.isEmpty ? nil : queue
    return true
  }

  mutating func expire(token: UInt64) {
    for keyCode in Array(expectations.keys) {
      guard var queue = expectations[keyCode] else { continue }
      queue.removeAll { $0.token == token }
      expectations[keyCode] = queue.isEmpty ? nil : queue
    }
  }

  mutating func reset() {
    expectations.removeAll()
  }
}

enum CapsCoreKarabinerRuleDetector {
  static func selectedProfileHasCapsMapping(data: Data) -> Bool {
    guard
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let profiles = root["profiles"] as? [[String: Any]]
    else {
      return false
    }

    let selectedProfiles = profiles.filter { $0["selected"] as? Bool == true }
    let searchableProfiles = selectedProfiles.isEmpty ? profiles : selectedProfiles
    return searchableProfiles.contains(where: profileHasCapsMapping)
  }

  private static func profileHasCapsMapping(_ profile: [String: Any]) -> Bool {
    guard
      let complex = profile["complex_modifications"] as? [String: Any],
      let rules = complex["rules"] as? [[String: Any]]
    else {
      return false
    }

    return rules.contains { rule in
      guard let manipulators = rule["manipulators"] as? [[String: Any]] else { return false }
      return manipulators.contains(where: manipulatorMapsCapsToControlOption)
    }
  }

  private static func manipulatorMapsCapsToControlOption(_ manipulator: [String: Any]) -> Bool {
    guard
      let from = manipulator["from"] as? [String: Any],
      from["key_code"] as? String == "caps_lock",
      let to = manipulator["to"] as? [[String: Any]]
    else {
      return false
    }

    let controlKeys = Set(["left_control", "right_control", "control"])
    let optionKeys = Set(["left_option", "right_option", "option"])
    let outputKeys = Set(to.compactMap { $0["key_code"] as? String })
    if !outputKeys.isDisjoint(with: controlKeys), !outputKeys.isDisjoint(with: optionKeys) {
      return true
    }

    return to.contains { entry in
      guard let keyCode = entry["key_code"] as? String else { return false }
      let modifiers = Set(entry["modifiers"] as? [String] ?? [])
      return (controlKeys.contains(keyCode) && !modifiers.isDisjoint(with: optionKeys))
        || (optionKeys.contains(keyCode) && !modifiers.isDisjoint(with: controlKeys))
    }
  }
}
