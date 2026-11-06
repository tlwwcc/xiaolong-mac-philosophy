import ApplicationServices
import Darwin
import Foundation
import Security

struct JumpRemoteProcessIdentity: Equatable, Sendable {
  let pid: pid_t
  let birthSeconds: UInt64
  let birthMicroseconds: UInt64
}

/// A single observed key press, never a standing permission to use remote flags.
struct JumpRemoteChordTrustState: Sendable {
  private struct Pending: Sendable {
    let process: JumpRemoteProcessIdentity
    let keyCode: UInt16
    let modifiers: Set<String>
    let createdAt: TimeInterval
  }

  private let lifetime: TimeInterval
  private var pending: Pending?

  init(lifetime: TimeInterval = 0.35) {
    self.lifetime = lifetime
  }

  var pendingProcess: JumpRemoteProcessIdentity? { pending?.process }

  mutating func record(
    process: JumpRemoteProcessIdentity?, keyCode: UInt16, modifiers: Set<String>,
    isRepeat: Bool, now: TimeInterval
  ) {
    pending = nil
    guard let process, !isRepeat, modifiers.contains("control"), modifiers.contains("option"),
      !(54...63).contains(keyCode)
    else { return }
    pending = Pending(process: process, keyCode: keyCode, modifiers: modifiers, createdAt: now)
  }

  mutating func consume(
    keyCode: UInt16, modifiers: Set<String>, process: JumpRemoteProcessIdentity?,
    now: TimeInterval
  ) -> Bool {
    let candidate = pending
    pending = nil
    guard let candidate, let process, candidate.process == process,
      candidate.keyCode == keyCode, candidate.modifiers == modifiers,
      now >= candidate.createdAt, now - candidate.createdAt <= lifetime
    else { return false }
    return true
  }

  mutating func reset() { pending = nil }

  mutating func invalidate(pid: pid_t) {
    if pending?.process.pid == pid { pending = nil }
  }
}

enum JumpRemoteProcessVerifier {
  static let executablePath =
    "/Applications/Jump Desktop Connect.app/Contents/MacOS/JumpConnect"
  private static let requirementText =
    "identifier \"com.p5sys.jump.connect\" and anchor apple generic"
    + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
    + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    + " and certificate leaf[subject.OU] = \"2HCKV38EEC\""

  /// Kernel metadata only; safe to recheck without code-signature IPC in an input callback.
  static func currentIdentity(pid: pid_t) -> JumpRemoteProcessIdentity? {
    guard pid > 0 else { return nil }
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
      info.pbi_status != UInt32(SZOMB), path(pid: pid) == executablePath
    else { return nil }
    return JumpRemoteProcessIdentity(
      pid: pid, birthSeconds: info.pbi_start_tvsec, birthMicroseconds: info.pbi_start_tvusec)
  }

  /// Call only from a background task. Bind the actual running code to the same process birth.
  static func verifiedIdentity(pid: pid_t) -> JumpRemoteProcessIdentity? {
    guard let before = currentIdentity(pid: pid) else { return nil }
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(
      requirementText as CFString, SecCSFlags(rawValue: 0), &requirement) == errSecSuccess,
      let requirement
    else { return nil }
    var code: SecCode?
    guard SecCodeCopyGuestWithAttributes(
      nil, [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary,
      SecCSFlags(rawValue: 0), &code) == errSecSuccess,
      let code,
      SecCodeCheckValidity(code, SecCSFlags(rawValue: 0), requirement) == errSecSuccess,
      currentIdentity(pid: pid) == before
    else { return nil }
    return before
  }

  static func candidatePIDs() -> [pid_t] {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(count) + 32)
    let copied = pids.withUnsafeMutableBytes {
      proc_listallpids($0.baseAddress, Int32($0.count))
    }
    guard copied > 0 else { return [] }
    return pids.prefix(Int(copied)).filter { $0 > 0 && path(pid: $0) == executablePath }
  }

  private static func path(pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    let copied = buffer.withUnsafeMutableBytes {
      proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
    }
    guard copied > 0 else { return nil }
    return String(
      decoding: buffer.prefix(Int(copied)).prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
      as: UTF8.self)
  }
}

@MainActor
final class JumpRemoteSessionTapContext {
  weak var trust: JumpRemoteInputTrust?
  let generation: UInt64

  init(trust: JumpRemoteInputTrust, generation: UInt64) {
    self.trust = trust
    self.generation = generation
  }

  func deliver(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent> {
    trust?.observeSessionEvent(event: event, type: type, generation: generation)
    return Unmanaged.passUnretained(event)
  }
}

@MainActor
final class JumpRemoteInputTrust {
  private struct KeyDownIdentity: Equatable {
    let sourcePID: Int64
    let keyCode: UInt16
    let timestamp: CGEventTimestamp
    let flags: UInt64
  }

  private var isRunning = false
  private var generation: UInt64 = 0
  private var state = JumpRemoteChordTrustState()
  private var verified: [pid_t: JumpRemoteProcessIdentity] = [:]
  private var verificationTasks: [pid_t: Task<Void, Never>] = [:]
  private var retryAfter: [pid_t: TimeInterval] = [:]
  private var processExitSources: [pid_t: any DispatchSourceProcess] = [:]
  private var prewarmTask: Task<Void, Never>?
  private var sessionTap: CFMachPort?
  private var sessionTapSource: CFRunLoopSource?
  private var sessionTapContext: JumpRemoteSessionTapContext?
  private var sessionRepairTimer: Timer?
  private var lastKeyDown: KeyDownIdentity?
  private(set) var sessionTapGeneration: UInt64 = 0

  isolated deinit { stop() }

  func start() {
    guard !isRunning else { return }
    isRunning = true
    generation &+= 1
    startSessionTap()
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.repairSessionTapIfNeeded() }
    }
    sessionRepairTimer = timer
    RunLoop.main.add(timer, forMode: .common)
    let generation = generation
    prewarmTask = Task.detached(priority: .utility) { [weak self] in
      let pids = JumpRemoteProcessVerifier.candidatePIDs()
      guard !Task.isCancelled else { return }
      await self?.prewarm(pids: pids, generation: generation)
    }
  }

  func stop() {
    isRunning = false
    generation &+= 1
    state.reset()
    lastKeyDown = nil
    sessionRepairTimer?.invalidate()
    sessionRepairTimer = nil
    stopSessionTap()
    prewarmTask?.cancel()
    prewarmTask = nil
    for task in verificationTasks.values { task.cancel() }
    verificationTasks.removeAll()
    for source in processExitSources.values { source.cancel() }
    processExitSources.removeAll()
    verified.removeAll()
    retryAfter.removeAll()
  }

  /// Clear press evidence while preserving still-valid, asynchronously checked identities.
  func reset() { state.reset() }

  /// Observes only; never changes, posts or consumes the original keyboard event.
  func observe(event: CGEvent, type: CGEventType) {
    guard isRunning else { return }
    let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
    guard keyCode != 63 else { return }  // Fn remains entirely owned by the voice provider.
    if type == .keyUp || type == .flagsChanged {
      state.reset()
      return
    }
    guard type == .keyDown else { return }
    let source = event.getIntegerValueField(.eventSourceUnixProcessID)
    let eventIdentity = KeyDownIdentity(
      sourcePID: source, keyCode: keyCode, timestamp: event.timestamp, flags: event.flags.rawValue)
    guard lastKeyDown != eventIdentity else { return }
    lastKeyDown = eventIdentity
    state.reset()
    let modifiers = Self.modifiers(event.flags)
    guard modifiers.contains("control"), modifiers.contains("option"),
      !(54...63).contains(keyCode), event.getIntegerValueField(.keyboardEventAutorepeat) == 0
    else { return }
    AppDiagnostics.log(
      "jump_remote_session_chord_source", ["pid": "\(source)", "keyCode": "\(keyCode)"])
    guard source > 0, source <= Int64(Int32.max) else {
      AppDiagnostics.log("jump_remote_input_unverified_source", ["pid": "\(source)"])
      return
    }
    let pid = pid_t(source)
    guard let identity = verified[pid],
      JumpRemoteProcessVerifier.currentIdentity(pid: pid) == identity
    else {
      AppDiagnostics.log("jump_remote_input_unverified_source", ["pid": "\(pid)"])
      invalidate(pid: pid)
      requestVerification(pid: pid)
      return
    }
    state.record(
      process: identity, keyCode: keyCode, modifiers: modifiers, isRepeat: false,
      now: ProcessInfo.processInfo.systemUptime)
  }

  func consume(keyCode: UInt16, modifiers: [String]) -> Bool {
    guard isRunning, let process = state.pendingProcess else { return false }
    guard verified[process.pid] == process,
      JumpRemoteProcessVerifier.currentIdentity(pid: process.pid) == process
    else {
      invalidate(pid: process.pid)
      return false
    }
    return state.consume(
      keyCode: keyCode, modifiers: Set(modifiers), process: process,
      now: ProcessInfo.processInfo.systemUptime)
  }

  fileprivate func observeSessionEvent(
    event: CGEvent, type: CGEventType, generation: UInt64
  ) {
    guard isRunning, sessionTapGeneration == generation else { return }
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      state.reset()
      AppDiagnostics.log("jump_remote_session_tap_disabled", ["type": "\(type.rawValue)"])
      repairSessionTapIfNeeded()
      return
    }
    guard type == .keyDown || type == .keyUp || type == .flagsChanged,
      event.getIntegerValueField(.keyboardEventKeycode) != 63
    else { return }
    observe(event: event, type: type)
  }

  private func startSessionTap() {
    guard isRunning, sessionTap == nil else { return }
    sessionTapGeneration &+= 1
    let context = JumpRemoteSessionTapContext(trust: self, generation: sessionTapGeneration)
    let callback: CGEventTapCallBack = { _, type, event, pointer in
      guard let pointer else { return Unmanaged.passUnretained(event) }
      MainActor.assumeIsolated {
        let context = Unmanaged<JumpRemoteSessionTapContext>.fromOpaque(pointer).takeUnretainedValue()
        _ = context.deliver(type: type, event: event)
      }
      return Unmanaged.passUnretained(event)
    }
    let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) {
      $0 | (CGEventMask(1) << $1.rawValue)
    }
    guard let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
      eventsOfInterest: mask, callback: callback,
      userInfo: Unmanaged.passUnretained(context).toOpaque())
    else {
      AppDiagnostics.log("jump_remote_session_tap_unavailable", [:])
      return
    }
    guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
      CFMachPortInvalidate(tap)
      AppDiagnostics.log("jump_remote_session_tap_source_unavailable", [:])
      return
    }
    sessionTapContext = context
    sessionTap = tap
    sessionTapSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    AppDiagnostics.log("jump_remote_session_tap_started", [:])
  }

  private func repairSessionTapIfNeeded() {
    guard isRunning else { return }
    if let sessionTap, CFMachPortIsValid(sessionTap) {
      if !CGEvent.tapIsEnabled(tap: sessionTap) {
        state.reset()
        CGEvent.tapEnable(tap: sessionTap, enable: true)
      }
      return
    }
    stopSessionTap()
    startSessionTap()
  }

  private func stopSessionTap() {
    sessionTapGeneration &+= 1
    if let sessionTap {
      CGEvent.tapEnable(tap: sessionTap, enable: false)
      if let sessionTapSource {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), sessionTapSource, .commonModes)
      }
      CFMachPortInvalidate(sessionTap)
    }
    sessionTap = nil
    sessionTapSource = nil
    sessionTapContext = nil
  }

  private func prewarm(pids: [pid_t], generation: UInt64) {
    guard isRunning, self.generation == generation else { return }
    prewarmTask = nil
    for pid in pids { requestVerification(pid: pid) }
  }

  private func requestVerification(pid: pid_t) {
    let now = ProcessInfo.processInfo.systemUptime
    guard isRunning, verificationTasks[pid] == nil, now >= (retryAfter[pid] ?? 0) else { return }
    retryAfter[pid] = now + 1
    let generation = generation
    verificationTasks[pid] = Task.detached(priority: .utility) { [weak self] in
      let identity = JumpRemoteProcessVerifier.verifiedIdentity(pid: pid)
      guard !Task.isCancelled else { return }
      await self?.finishVerification(identity, pid: pid, generation: generation)
    }
  }

  private func finishVerification(
    _ identity: JumpRemoteProcessIdentity?, pid: pid_t, generation: UInt64
  ) {
    guard isRunning, self.generation == generation else { return }
    verificationTasks.removeValue(forKey: pid)
    let accepted = identity != nil && JumpRemoteProcessVerifier.currentIdentity(pid: pid) == identity
    AppDiagnostics.log("jump_remote_input_verification", ["pid": "\(pid)", "accepted": "\(accepted)"])
    guard accepted, let identity else { return }
    verified[pid] = identity
    processExitSources[pid]?.cancel()
    let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
    source.setEventHandler { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, self.generation == generation, self.verified[pid] == identity else { return }
        self.invalidate(pid: pid)
      }
    }
    source.resume()
    processExitSources[pid] = source
  }

  private func invalidate(pid: pid_t) {
    state.invalidate(pid: pid)
    verified.removeValue(forKey: pid)
    processExitSources.removeValue(forKey: pid)?.cancel()
  }

  private static func modifiers(_ flags: CGEventFlags) -> Set<String> {
    var result = Set<String>()
    if flags.contains(.maskControl) { result.insert("control") }
    if flags.contains(.maskAlternate) { result.insert("option") }
    if flags.contains(.maskShift) { result.insert("shift") }
    if flags.contains(.maskCommand) { result.insert("command") }
    return result
  }
}
