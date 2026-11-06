import AppKit
import Combine
import Foundation

/// The single runtime owner of global keyboard input. Feature documents remain separate.
@MainActor
final class GlobalInputWorkspace: @MainActor ObservableObject {
  private struct State {
    var hasOwnership = false
    var isPaused = false
    var hotkeyFailures: [String] = []
    var capsEnabled = false
    var capsRunning = false
    var capsStatus: CapsCorePluginStatus = .stopped
    var permissions = GlobalInputPermissions(accessibility: false, inputMonitoring: false)
    var recordingOwnerID: UUID?
  }
  private var state = State()
  let objectWillChange = ObservableObjectPublisher()
  private(set) var hasOwnership: Bool {
    get { state.hasOwnership }
    set { publish(\.hasOwnership, newValue) }
  }
  private(set) var isPaused: Bool {
    get { state.isPaused }
    set { publish(\.isPaused, newValue) }
  }
  private(set) var hotkeyFailures: [String] {
    get { state.hotkeyFailures }
    set { publish(\.hotkeyFailures, newValue) }
  }
  private(set) var capsEnabled: Bool {
    get { state.capsEnabled }
    set { publish(\.capsEnabled, newValue) }
  }
  private(set) var capsRunning: Bool {
    get { state.capsRunning }
    set { publish(\.capsRunning, newValue) }
  }
  private(set) var capsStatus: CapsCorePluginStatus {
    get { state.capsStatus }
    set { publish(\.capsStatus, newValue) }
  }
  private(set) var permissions: GlobalInputPermissions {
    get { state.permissions }
    set { publish(\.permissions, newValue) }
  }
  private(set) var recordingOwnerID: UUID? {
    get { state.recordingOwnerID }
    set { publish(\.recordingOwnerID, newValue) }
  }
  private(set) var isStopped = false
  var onStatus: ((String) -> Void)?

  private let defaults: UserDefaults
  private let environment: GlobalInputEnvironment
  private let features: GlobalInputFeaturePorts
  private var hotkeys: GlobalHotkeyPort?
  private var phrases: GlobalPhrasePort?
  private var caps: GlobalCapsPort?
  private var jump: GlobalJumpFocusPort?
  private var started = false
  private var ownershipInitialized = false
  private var changingOwnership = false
  private var ownershipBlockReason = "全局输入独占权尚未取得"
  private var detectedConflict: CapsCoreConflict?
  private var lastConflictCheckAt: TimeInterval = 0
  private var stateOwner = UUID()
  private var capsPreferenceOwner = UUID()
  private let hotkeyEpoch = GlobalInputCallbackEpoch()
  private let phraseEpoch = GlobalInputCallbackEpoch()
  private let capsEpoch = GlobalInputCallbackEpoch()
  private let lifetimeEpoch = GlobalInputCallbackEpoch()
  private enum Component: CaseIterable { case hotkeys, phrases, caps, scroll, retiredClassic }
  private var reloading = false
  private var pending = Set<Component>()
  private var completed = Set<Component>()
  private static let capsEnabledDefaultsKey = "capsCorePluginEnabledV1"
  private var requestCapsPermission = false

  init(defaults: UserDefaults = .standard, environment: GlobalInputEnvironment,
       features: GlobalInputFeaturePorts, onStatus: ((String) -> Void)? = nil) {
    self.defaults = defaults
    self.environment = environment
    self.features = features
    self.onStatus = onStatus
  }

  var ownershipBlockedMessage: String { "\(ownershipBlockReason)：已暂停全局监听。" }

  func loadPreferences() {
    guard !isStopped else { return }
    capsPreferenceOwner = UUID()
    advanceState()
    capsEnabled = defaults.bool(forKey: Self.capsEnabledDefaultsKey)
  }

  /// Acquire before feature startup; creating this workspace alone never creates an input tap.
  func initializeOwnership() {
    guard !isStopped, !ownershipInitialized else { return }
    ownershipInitialized = true
    let eligible = environment.eligible()
    guard !isStopped else { return }
    guard eligible else {
      ownershipBlockReason = "运行身份无效"
      return
    }
    let acquired = environment.lease.acquire()
    guard !isStopped else {
      if acquired { environment.lease.release() }
      return
    }
    hasOwnership = acquired
    guard !isStopped else { return }
    if !hasOwnership { recordLeaseFailure() }
  }

  func start() {
    guard !isStopped, !started else { return }
    started = true
    initializeOwnership()
    guard !isStopped else { return }
    let owner = lifetimeEpoch.renew()
    let deliver = environment.deliver
    let hotkeyEpoch = hotkeyEpoch
    let lifetime = lifetimeEpoch
    let newHotkeys = environment.makeHotkeys(
      { [weak self] item, context in
        let eventOwner = hotkeyEpoch.snapshot()
        deliver { [weak self] in
          guard let self, lifetime.accepts(owner), hotkeyEpoch.accepts(eventOwner) else { return }
          self.receiveTrigger(item, context: context)
        }
      },
      { [weak self] message in
        let eventOwner = hotkeyEpoch.snapshot()
        deliver { [weak self] in
          guard let self, lifetime.accepts(owner), hotkeyEpoch.accepts(eventOwner) else { return }
          self.receiveHotkeyNotice(message)
        }
      })
    guard lifetime.accepts(owner), !isStopped else { newHotkeys.suspendAll(); return }
    hotkeys = newHotkeys
    let phraseEpoch = phraseEpoch
    let newPhrases = environment.makePhrases { [weak self] message in
      let eventOwner = phraseEpoch.snapshot()
      deliver { [weak self] in
        guard let self, lifetime.accepts(owner), phraseEpoch.accepts(eventOwner),
          !self.isStopped, self.hasOwnership, !self.isPaused else { return }
        self.onStatus?(message)
      }
    }
    guard lifetime.accepts(owner), !isStopped else { newPhrases.stop(); return }
    phrases = newPhrases
    let capsEpoch = capsEpoch
    let newCaps = environment.makeCaps { [weak self] status in
      let eventOwner = capsEpoch.snapshot()
      deliver { [weak self] in
        guard let self, lifetime.accepts(owner), capsEpoch.accepts(eventOwner) else { return }
        self.receiveCapsStatus(status)
      }
    }
    guard lifetime.accepts(owner), !isStopped else { newCaps.stop(reason: "cancelledStartup"); return }
    caps = newCaps
    let newJump = environment.makeJump { [weak self] _ in
      guard let self, lifetime.accepts(owner), !self.isStopped else { return }
      self.reloadHotkeys()
    }
    guard lifetime.accepts(owner), !isStopped else { newJump.stop(); return }
    jump = newJump
    newCaps.onRoutingChordChange = { [weak newJump] held in newJump?.setChordHeld(held) }
    newCaps.allowsRoutingKeyDown = { [weak newJump] in newJump?.allowsChordKeyDown ?? true }
    // ScrollWorkspace.start owns its first reload; avoid starting it twice at composition.
    requestReload([.hotkeys, .phrases, .caps, .retiredClassic])
    guard lifetime.accepts(owner), !isStopped else { return }
    newJump.start()
  }

  func shutdown() {
    guard !isStopped else { return }
    isStopped = true
    started = false
    capsPreferenceOwner = UUID()
    advanceState()
    lifetimeEpoch.invalidate()
    hotkeyEpoch.invalidate()
    phraseEpoch.invalidate()
    capsEpoch.invalidate()
    pending.removeAll()
    completed.removeAll()
    // Detach before invoking a port: a synchronous callback cannot overwrite a new owner.
    let oldHotkeys = hotkeys, oldPhrases = phrases, oldCaps = caps, oldJump = jump
    hotkeys = nil; phrases = nil; caps = nil; jump = nil
    state.hasOwnership = false
    state.recordingOwnerID = nil
    state.hotkeyFailures = []
    state.capsRunning = false
    state.capsStatus = .stopped
    onStatus = nil
    objectWillChange.send()
    features.willYieldOwnership()
    oldJump?.stop()
    oldHotkeys?.suspendAll()
    oldPhrases?.stop()
    oldCaps?.stop(reason: "appShutdown")
    features.shutdownScroll()
    environment.lease.release()
  }

  @discardableResult
  func refreshOwnership(trigger: String) -> Bool {
    guard !isStopped, !changingOwnership else { return false }
    changingOwnership = true
    defer { changingOwnership = false }
    let owner = stateOwner
    let eligible = environment.eligible()
    guard owns(owner) else { return false }
    if !eligible {
      ownershipBlockReason = "运行身份无效"
      guard hasOwnership else { return false }
      advanceState()
      hasOwnership = false
      guard !isStopped else { return true }
      hotkeyEpoch.invalidate(); phraseEpoch.invalidate(); capsEpoch.invalidate()
      features.willYieldOwnership()
      guard !isStopped else { return true }
      features.cancelRecording()
      guard !isStopped else { return true }
      reloadAll()
      environment.lease.release()
      guard !isStopped else { return true }
      onStatus?("运行身份无效，已停止 Caps 和全局快捷键。")
      return true
    }
    if hasOwnership, environment.lease.isOwned { return false }
    let previouslyOwned = hasOwnership
    let acquired = environment.lease.acquire()
    guard owns(owner) else {
      if acquired { environment.lease.release() }
      return false
    }
    guard acquired else {
      recordLeaseFailure()
      guard previouslyOwned else { return false }
      advanceState()
      hasOwnership = false
      guard !isStopped else { return true }
      hotkeyEpoch.invalidate(); phraseEpoch.invalidate(); capsEpoch.invalidate()
      features.willYieldOwnership()
      guard !isStopped else { return true }
      features.cancelRecording()
      guard !isStopped else { return true }
      reloadAll()
      return true
    }
    advanceState()
    let acquiredOwner = stateOwner
    hasOwnership = true
    guard owns(acquiredOwner) else { return true }
    reloadAll()
    guard owns(acquiredOwner) else { return true }
    onStatus?("Caps 和全局快捷键已恢复。")
    return true
  }

  func setPaused(_ value: Bool) {
    guard !isStopped, isPaused != value else { return }
    advanceState()
    isPaused = value
    // Pause has always applied to keyboard input, not mouse scrolling/volume.
    requestReload([.hotkeys, .phrases, .caps, .retiredClassic])
  }

  func togglePaused() { setPaused(!isPaused) }

  func suspendForRecording() {
    guard !isStopped, let owner = features.recordingOwner() else { return }
    advanceState()
    recordingOwnerID = owner
    guard !isStopped, features.recordingOwner() == owner else { return }
    hotkeyEpoch.invalidate()
    hotkeys?.suspendAll()
    guard !isStopped, features.recordingOwner() == owner else { return }
    hotkeyFailures = []
  }

  func setCapsEnabled(_ enabled: Bool) {
    guard !isStopped else { return }
    advanceState()
    let owner = UUID()
    capsPreferenceOwner = owner
    capsEnabled = enabled
    guard ownsCapsPreference(owner) else { return }
    defaults.set(enabled, forKey: Self.capsEnabledDefaultsKey)
    reloadCaps(requestPermission: enabled)
    guard ownsCapsPreference(owner) else { return }
    onStatus?(enabled ? capsStatus.detailText : "Caps 核心键已关闭。")
  }

  func reloadAll() { requestReload(Set(Component.allCases)) }
  func reloadHotkeys() { requestReload([.hotkeys]) }
  func reloadPhrases() { requestReload([.phrases]) }
  func reloadCaps(requestPermission: Bool = false) {
    guard !isStopped else { return }
    requestCapsPermission = requestCapsPermission || requestPermission
    requestReload([.caps])
  }

  /// Nested permission refreshes coalesce into the current pass. State-changing commands
  /// rotate stateOwner and get a fresh pass; an old pass stops immediately after a callback.
  private func requestReload(_ components: Set<Component>) {
    guard !isStopped, started else { return }
    pending.formUnion(components.subtracting(completed))
    guard !reloading else { return }
    reloading = true
    defer { reloading = false; completed.removeAll() }
    var passOwner = stateOwner
    let snapshot = features.refreshPermissions()
    guard !isStopped else { return }
    permissions = snapshot
    guard !isStopped else { return }
    while !pending.isEmpty, !isStopped {
      if passOwner != stateOwner {
        completed.removeAll()
        passOwner = stateOwner
      }
      guard let component = Component.allCases.first(where: { pending.contains($0) }) else { break }
      pending.remove(component)
      completed.insert(component)
      switch component {
      case .hotkeys: reloadHotkeysNow(owner: passOwner)
      case .phrases: reloadPhrasesNow(owner: passOwner)
      case .caps: reloadCapsNow(owner: passOwner)
      case .scroll: features.reloadScroll()
      case .retiredClassic: features.synchronizeRetiredClassic()
      }
      // A nested command may invalidate the component after it was taken from pending.
      // Replay that incomplete component under the new owner; otherwise its epoch could
      // remain invalid while its old engine registration still appears to be installed.
      if !isStopped, passOwner != stateOwner { pending.insert(component) }
    }
  }

  private func reloadHotkeysNow(owner: UUID) {
    hotkeyEpoch.invalidate()
    features.repairMissingApps()
    guard owns(owner) else { return }
    recordingOwnerID = features.recordingOwner()
    guard owns(owner) else { return }
    guard hasOwnership, !isPaused, recordingOwnerID == nil,
      jump?.shouldYieldLocalHotkeys != true else {
      hotkeys?.suspendAll()
      guard owns(owner) else { return }
      hotkeyFailures = []
      guard owns(owner) else { return }
      if !hasOwnership { onStatus?(ownershipBlockedMessage) }
      else if isPaused { onStatus?("后台快捷键已暂停。") }
      return
    }
    let items = features.registrationItems()
    guard owns(owner) else { return }
    hotkeyEpoch.renew()
    hotkeys?.register(items)
    guard owns(owner) else { return }
    hotkeyFailures = hotkeys?.failures ?? []
    guard owns(owner) else { return }
    onStatus?(hotkeyFailures.isEmpty ? "后台快捷键已启用。" : hotkeyFailures.joined(separator: "\n"))
  }

  private func reloadPhrasesNow(owner: UUID) {
    phraseEpoch.invalidate()
    guard hasOwnership, !isPaused else {
      phrases?.stop()
      guard owns(owner) else { return }
      if !hasOwnership { onStatus?(ownershipBlockedMessage) }
      return
    }
    let values = features.committedPhrases()
    guard owns(owner) else { return }
    phraseEpoch.renew()
    _ = phrases?.reload(values)
  }

  private func reloadCapsNow(owner: UUID) {
    capsEpoch.invalidate()
    let requestPermission = requestCapsPermission
    requestCapsPermission = false
    guard let caps else { return }
    guard hasOwnership else {
      caps.stop(reason: "globalInputLeaseUnavailable")
      guard owns(owner) else { return }
      publishCaps(running: false, status: .paused)
      guard owns(owner) else { return }
      onStatus?(ownershipBlockedMessage)
      return
    }
    let conflict = capsEnabled ? environment.conflict() : nil
    guard owns(owner) else { return }
    detectedConflict = conflict
    lastConflictCheckAt = environment.clock()
    guard owns(owner) else { return }
    guard capsEnabled else {
      caps.stop(reason: "pluginDisabled")
      guard owns(owner) else { return }
      publishCaps(running: false, status: .stopped)
      return
    }
    guard !isPaused else {
      caps.stop(reason: "appPaused")
      guard owns(owner) else { return }
      publishCaps(running: false, status: .paused)
      return
    }
    if let conflict {
      caps.stop(reason: "conflict")
      guard owns(owner) else { return }
      publishCaps(running: false, status: .conflict(conflict))
      return
    }
    capsEpoch.renew()
    let started = caps.start(requestPermission: requestPermission)
    guard owns(owner) else { return }
    let running = started && caps.isRunning
    publishCaps(running: running, status: running ? .running : capsStatus)
  }

  func refreshCapsConflictIfNeeded() {
    guard !isStopped, capsEnabled, started else { return }
    let owner = stateOwner
    let now = environment.clock()
    guard owns(owner), now - lastConflictCheckAt >= 3 else { return }
    lastConflictCheckAt = now
    let conflict = environment.conflict()
    guard owns(owner), conflict != detectedConflict else { return }
    advanceState()
    detectedConflict = conflict
    reloadCaps()
  }

  private func receiveTrigger(_ item: ShortcutItem, context: HotkeyTriggerContext) {
    guard !isStopped, hasOwnership, !isPaused, features.recordingOwner() == nil,
      jump?.shouldYieldLocalHotkeys != true else { return }
    let owner = stateOwner
    guard !item.usesChordTrigger
      || caps?.shouldAllowHotkeyTrigger(
        modifiers: item.modifiers, keyCode: keyCode(for: item.key).map { UInt16($0) }) ?? true
    else {
      guard owns(owner) else { return }
      onStatus?("Caps 已自动解粘，本次快捷键已安全拦截，请重新按一次。")
      return
    }
    guard owns(owner) else { return }
    features.perform(item, context)
  }

  private func receiveHotkeyNotice(_ message: String) {
    guard !isStopped, hasOwnership, !isPaused else { return }
    let owner = stateOwner
    hotkeyFailures = hotkeys?.failures ?? []
    guard owns(owner) else { return }
    onStatus?(hotkeyFailures.isEmpty ? message : hotkeyFailures.joined(separator: "\n"))
  }

  private func receiveCapsStatus(_ status: CapsCoreEngineStatus) {
    guard !isStopped, hasOwnership, capsEnabled, !isPaused, detectedConflict == nil else { return }
    switch status {
    case .stopped: publishCaps(running: false, status: capsStatus)
    case .running:
      guard caps?.isRunning == true else { return }
      publishCaps(running: true, status: .running)
    case .waitingForPermission(let message):
      publishCaps(running: false, status: .waitingForPermission(message))
    case .failed(let message):
      publishCaps(running: false, status: .failed(message))
    }
  }

  var commandWProtectionStatus: String {
    if isPaused || features.recordingOwner() != nil { return "保护已暂停。" }
    guard !isStopped, hasOwnership else { return "保护未生效，请先恢复后台快捷键。" }
    if !permissions.accessibility || !permissions.inputMonitoring {
      return "保护未生效，请在权限设置中完成系统授权。"
    }
    guard hotkeys?.commandWProtectionRunning == true else {
      return "保护未生效，请恢复后台快捷键或检查系统权限。"
    }
    return "保护已启用。"
  }

  var automationRuntimeStatus: String {
    if isStopped { return "stopped" }
    if !hasOwnership { return "inputOwnedElsewhere" }
    if isPaused { return "paused" }
    if features.recordingOwner() != nil { return "recording" }
    if jump?.shouldYieldLocalHotkeys == true { return "remoteSession" }
    guard let hotkeys else { return "starting" }
    return features.committedItems().filter(\.enabled).allSatisfy {
      hotkeys.registrationState(for: $0.id) == "registered"
    } ? "registered" : "partiallyRegistered"
  }

  func automationRuntimeStatus(for item: ShortcutItem) -> String {
    guard item.enabled else { return "disabled" }
    let overall = automationRuntimeStatus
    guard overall == "registered" || overall == "partiallyRegistered" else { return overall }
    return hotkeys?.registrationState(for: item.id) ?? "starting"
  }

  func listenerVerification() -> AuthorizationListenerVerification {
    guard !isStopped, hasOwnership else {
      return AuthorizationListenerVerification(required: [], failed: [])
    }
    var required: [String] = [], failed: [String] = []
    if let hotkeys, hotkeys.requiresAdvancedListener {
      required.append("hotkeys")
      if !hotkeys.advancedListenerRunning { failed.append("hotkeys") }
    }
    if let phrases, phrases.requiresListening {
      required.append("phrases")
      if !phrases.isListening { failed.append("phrases") }
    }
    if capsEnabled, detectedConflict == nil, !isPaused {
      required.append("capsCore")
      if caps?.isRunning != true { failed.append("capsCore") }
    }
    let scroll = features.scrollHealth()
    if scroll.required {
      required.append("scroll")
      if !scroll.running { failed.append("scroll") }
    }
    return AuthorizationListenerVerification(required: required, failed: failed)
  }

  private func publish<Value>(_ keyPath: WritableKeyPath<State, Value>, _ value: Value) {
    guard !isStopped else { return }
    // Commit before notifying. A synchronous observer can shut down or submit a newer
    // command without an outer @Published willSet subsequently overwriting that state.
    state[keyPath: keyPath] = value
    objectWillChange.send()
  }

  private func publishCaps(running: Bool, status: CapsCorePluginStatus) {
    guard !isStopped else { return }
    state.capsRunning = running
    state.capsStatus = status
    objectWillChange.send()
  }

  private func advanceState() {
    stateOwner = UUID()
    completed.removeAll()
  }

  private func owns(_ owner: UUID) -> Bool { !isStopped && stateOwner == owner }
  private func ownsCapsPreference(_ owner: UUID) -> Bool {
    !isStopped && capsPreferenceOwner == owner
  }
  private func recordLeaseFailure() {
    ownershipBlockReason = environment.lease.lastFailure == "busy"
      ? "另一版本正在接管全局输入" : "全局输入独占权建立失败"
  }
}
