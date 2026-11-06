import AppKit
import Combine
import Foundation

struct GlobalInputPermissions: Equatable {
  var accessibility: Bool
  var inputMonitoring: Bool
}

@MainActor
protocol GlobalInputLeasePort: AnyObject {
  var isOwned: Bool { get }
  var lastFailure: String { get }
  func acquire() -> Bool
  func release()
}
extension GlobalInputLease: GlobalInputLeasePort {}

@MainActor
protocol GlobalHotkeyPort: AnyObject {
  var failures: [String] { get }
  var commandWProtectionRunning: Bool { get }
  var requiresAdvancedListener: Bool { get }
  var advancedListenerRunning: Bool { get }
  func register(_ items: [ShortcutItem])
  func suspendAll()
  func registrationState(for itemID: String) -> String
}
extension HotkeyManager: GlobalHotkeyPort {
  var requiresAdvancedListener: Bool { listenerHealth.advancedListenerRequired }
  var advancedListenerRunning: Bool { listenerHealth.advancedListenerRunning }
}

@MainActor
protocol GlobalPhrasePort: AnyObject {
  var isListening: Bool { get }
  var requiresListening: Bool { get }
  @discardableResult func reload(_ phrases: [PhraseItem]) -> Bool
  func stop()
}
extension PhraseExpander: GlobalPhrasePort {}

@MainActor
protocol GlobalCapsPort: AnyObject {
  var onRoutingChordChange: ((Bool) -> Void)? { get set }
  var allowsRoutingKeyDown: (() -> Bool)? { get set }
  var isRunning: Bool { get }
  func start(requestPermission: Bool) -> Bool
  func stop(reason: String)
  func shouldAllowHotkeyTrigger(modifiers: [String], keyCode: UInt16?) -> Bool
}
extension CapsCoreEngine: GlobalCapsPort {}

@MainActor
protocol GlobalJumpFocusPort: AnyObject {
  var allowsChordKeyDown: Bool { get }
  func setChordHeld(_ held: Bool)
  var shouldYieldLocalHotkeys: Bool { get }
  func start()
  func stop()
}
extension JumpDesktopFocusMonitor: GlobalJumpFocusPort {}

/// Read on the engine's callback thread before it queues delivery to MainActor.
/// The UUID never repeats across a reload, recording transition or shutdown.
final class GlobalInputCallbackEpoch: @unchecked Sendable {
  private let lock = NSLock()
  private var owner: UUID?
  @discardableResult func renew() -> UUID {
    lock.lock()
    defer { lock.unlock() }
    let next = UUID()
    owner = next
    return next
  }
  func invalidate() { lock.lock(); owner = nil; lock.unlock() }
  func snapshot() -> UUID? { lock.lock(); defer { lock.unlock() }; return owner }
  func accepts(_ candidate: UUID?) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return candidate != nil && owner == candidate
  }
}

@MainActor
struct GlobalInputEnvironment {
  var lease: GlobalInputLeasePort
  var eligible: () -> Bool
  var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  var conflict: () -> CapsCoreConflict?
  var makeHotkeys: (
    @escaping (ShortcutItem, HotkeyTriggerContext) -> Void, @escaping (String) -> Void
  ) -> GlobalHotkeyPort
  var makePhrases: (@escaping (String) -> Void) -> GlobalPhrasePort
  var makeCaps: (@escaping (CapsCoreEngineStatus) -> Void) -> GlobalCapsPort
  var makeJump: (@escaping (Bool) -> Void) -> GlobalJumpFocusPort
  var deliver: (@escaping @MainActor @Sendable () -> Void) -> Void = HotkeyActionDelivery.deliver

  static func live(identity: AppRuntimeIdentity) -> Self {
    Self(
      lease: GlobalInputLease(),
      eligible: { identity.mayRequestGlobalInputLease(runningProcesses: []) },
      conflict: GlobalInputConflictDetection.current,
      makeHotkeys: { HotkeyManager(onTrigger: $0, onNotice: $1) },
      makePhrases: { PhraseExpander(onNotice: $0) },
      makeCaps: {
        CapsCoreEngine(allowsSystemMappingProtection: !identity.isInvalid, onStatusChange: $0)
      },
      makeJump: { JumpDesktopFocusMonitor(onChange: $0) })
  }
}

/// Feature data and effects are supplied by the composition root; no AppModel reference is stored.
@MainActor
struct GlobalInputFeaturePorts {
  var refreshPermissions: () -> GlobalInputPermissions
  var registrationItems: () -> [ShortcutItem]
  var committedItems: () -> [ShortcutItem]
  var committedPhrases: () -> [PhraseItem]
  var recordingOwner: () -> UUID?
  var repairMissingApps: () -> Void
  var perform: (ShortcutItem, HotkeyTriggerContext) -> Void
  var cancelRecording: () -> Void
  var willYieldOwnership: () -> Void
  var reloadScroll: () -> Void
  var shutdownScroll: () -> Void
  var scrollHealth: () -> (required: Bool, running: Bool)
  var synchronizeRetiredClassic: () -> Void
}
