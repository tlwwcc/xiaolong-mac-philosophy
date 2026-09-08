import Darwin
import Dispatch
import Foundation

/// Shared preference contract for the menu-bar health card.
///
/// The switch defaults to on so an existing installation gains the card without a migration.
/// Writing `false` is an explicit user choice and must always win.
enum SystemHealthMonitorPreferences {
  static let enabledKey = "systemHealthMonitorEnabledV1"

  static func isEnabled(in defaults: UserDefaults) -> Bool {
    guard defaults.object(forKey: enabledKey) != nil else { return true }
    return defaults.bool(forKey: enabledKey)
  }

  static func helperDefaults() -> UserDefaults {
    let suiteName = ProcessInfo.processInfo.environment["AIXLG_DEFAULTS_SUITE"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let suiteName, !suiteName.isEmpty, let defaults = UserDefaults(suiteName: suiteName)
    else {
      return .standard
    }
    return defaults
  }
}

enum SystemHealthSeverity: String, Equatable, Sendable {
  case healthy
  case warning
  case critical
  case unavailable

  var title: String {
    switch self {
    case .healthy: return "运行流畅"
    case .warning: return "需要留意"
    case .critical: return "系统压力较高"
    case .unavailable: return "暂无健康数据"
    }
  }
}

enum SystemHealthReason: String, Equatable, Sendable {
  case normal
  case memoryPressure
  case activeSwap
  case thermalPressure
  case insufficientData
}

enum SystemMemoryPressureState: String, Equatable, Sendable {
  case normal
  case warning
  case critical
  case unavailable

  var title: String {
    switch self {
    case .normal: return "正常"
    case .warning: return "偏高"
    case .critical: return "紧张"
    case .unavailable: return "不支持"
    }
  }
}

enum SystemThermalState: String, Equatable, Sendable {
  case nominal
  case fair
  case serious
  case critical
  case unavailable

  var title: String {
    switch self {
    case .nominal: return "正常"
    case .fair: return "轻微受限"
    case .serious: return "明显受限"
    case .critical: return "严重受限"
    case .unavailable: return "不支持"
    }
  }
}

struct SystemHealthAssessment: Equatable, Sendable {
  let severity: SystemHealthSeverity
  let reason: SystemHealthReason

  var title: String { severity.title }

  var detail: String {
    switch reason {
    case .normal: return "内存与温控状态正常"
    case .memoryPressure: return "内存压力正在升高"
    case .activeSwap: return "近期换页活跃，响应可能变慢"
    case .thermalPressure: return "系统正在因温度降低性能"
    case .insufficientData: return "当前设备没有可靠数据"
    }
  }
}

struct SystemHealthPressurePoint: Equatable, Sendable {
  let sampledAt: Date
  let value: Double
}

struct SystemHealthSnapshot: Equatable, Sendable {
  let sampledAt: Date
  let assessment: SystemHealthAssessment
  let memoryPressure: SystemMemoryPressureState
  let memoryPressureRatio: Double?
  let pressureHistory: [SystemHealthPressurePoint]
  let physicalMemoryBytes: UInt64?
  let usedMemoryBytes: UInt64?
  let availableMemoryBytes: UInt64?
  let compressedMemoryBytes: UInt64?
  let swapUsedBytes: UInt64?
  let swapTotalBytes: UInt64?
  let swapInBytesPerSecond: Double?
  let swapOutBytesPerSecond: Double?
  let cpuUsagePercent: Double?
  let gpuUsagePercent: Double?
  let temperatureCelsius: Double?
  let fanRPM: Double?
  let thermalState: SystemThermalState

  var swapActivityBytesPerSecond: Double? {
    guard let swapInBytesPerSecond, let swapOutBytesPerSecond else { return nil }
    return swapInBytesPerSecond + swapOutBytesPerSecond
  }
}

struct SystemHealthEvaluationInput: Equatable, Sendable {
  let memoryPressure: SystemMemoryPressureState
  let memoryPressureRatio: Double?
  let swapUsedBytes: UInt64?
  let swapInBytesPerSecond: Double?
  let swapOutBytesPerSecond: Double?
  let thermalState: SystemThermalState
  let hasUsableMetric: Bool
}

enum SystemHealthEvaluator {
  private static let bytesPerMiB = 1_048_576.0

  /// Classifies user-visible health. Swap *stock* is deliberately absent from every decision.
  /// A yellow swap warning requires both current memory pressure and recent paging activity.
  static func evaluate(_ input: SystemHealthEvaluationInput) -> SystemHealthAssessment {
    guard input.hasUsableMetric else {
      return SystemHealthAssessment(severity: .unavailable, reason: .insufficientData)
    }

    if input.memoryPressure == .critical || input.thermalState == .critical {
      return SystemHealthAssessment(
        severity: .critical,
        reason: input.thermalState == .critical ? .thermalPressure : .memoryPressure)
    }

    let pressure = input.memoryPressureRatio.map(SystemHealthMath.clampUnit)
    let swapIn = max(0, input.swapInBytesPerSecond ?? 0)
    let swapOut = max(0, input.swapOutBytesPerSecond ?? 0)
    let swapActivity = swapIn + swapOut

    if let pressure, pressure >= 0.97 {
      return SystemHealthAssessment(severity: .critical, reason: .memoryPressure)
    }

    if input.memoryPressure == .warning {
      return SystemHealthAssessment(severity: .warning, reason: .memoryPressure)
    }

    if input.thermalState == .fair || input.thermalState == .serious {
      return SystemHealthAssessment(severity: .warning, reason: .thermalPressure)
    }

    if let pressure,
      (pressure >= 0.65 && swapOut >= 0.25 * bytesPerMiB)
        || (pressure >= 0.70 && swapActivity >= bytesPerMiB)
    {
      return SystemHealthAssessment(severity: .warning, reason: .activeSwap)
    }

    if let pressure, pressure >= 0.90 {
      return SystemHealthAssessment(severity: .warning, reason: .memoryPressure)
    }

    return SystemHealthAssessment(severity: .healthy, reason: .normal)
  }
}

enum SystemHealthMath {
  static func clampUnit(_ value: Double) -> Double {
    min(1, max(0, value.isFinite ? value : 0))
  }

  static func counterDelta(current: UInt64, previous: UInt64) -> UInt64? {
    guard current >= previous else { return nil }
    return current - previous
  }

  static func rate(current: UInt64, previous: UInt64, elapsed: TimeInterval) -> Double? {
    guard elapsed.isFinite, elapsed > 0,
      let delta = counterDelta(current: current, previous: previous)
    else { return nil }
    return Double(delta) / elapsed
  }
}

struct SystemHealthPressureHistoryBuffer {
  private(set) var points: [SystemHealthPressurePoint] = []
  let window: TimeInterval
  let maximumPointCount: Int

  init(window: TimeInterval = 5 * 60, maximumPointCount: Int = 180) {
    self.window = max(1, window)
    self.maximumPointCount = max(2, maximumPointCount)
  }

  mutating func append(value: Double?, at sampledAt: Date) {
    guard let value, value.isFinite else {
      prune(relativeTo: sampledAt)
      return
    }
    points.append(
      SystemHealthPressurePoint(sampledAt: sampledAt, value: SystemHealthMath.clampUnit(value)))
    prune(relativeTo: sampledAt)
  }

  mutating func removeAll() {
    points.removeAll(keepingCapacity: true)
  }

  private mutating func prune(relativeTo sampledAt: Date) {
    let cutoff = sampledAt.addingTimeInterval(-window)
    if let firstValidIndex = points.firstIndex(where: { $0.sampledAt >= cutoff }) {
      if firstValidIndex > points.startIndex {
        points.removeFirst(firstValidIndex)
      }
    } else {
      points.removeAll(keepingCapacity: true)
    }
    if points.count > maximumPointCount {
      points.removeFirst(points.count - maximumPointCount)
    }
  }
}

private final class SystemMemoryPressureObserver {
  private let lock = NSLock()
  private var latestState: SystemMemoryPressureState?
  private let source: DispatchSourceMemoryPressure

  init() {
    source = DispatchSource.makeMemoryPressureSource(
      eventMask: [.normal, .warning, .critical],
      queue: DispatchQueue(label: "cn.tlww.aixlg.system-health.memory-pressure", qos: .utility))
    source.setEventHandler { [weak self] in
      self?.captureCurrentEvent()
    }
    source.activate()
  }

  deinit {
    source.cancel()
  }

  func currentState() -> SystemMemoryPressureState? {
    lock.lock()
    defer { lock.unlock() }
    return latestState
  }

  private func captureCurrentEvent() {
    let event = source.data
    let state: SystemMemoryPressureState
    if event.contains(.critical) {
      state = .critical
    } else if event.contains(.warning) {
      state = .warning
    } else {
      state = .normal
    }
    lock.lock()
    latestState = state
    lock.unlock()
  }
}

/// Cheap, privilege-free system sampler for the menu helper.
///
/// GPU utilisation, sensor temperature and fan RPM intentionally remain `nil`: macOS has no
/// stable public API for those values across supported Macs. Callers must hide those fields.
final class SystemHealthSampler {
  private struct MemoryReading {
    let physicalBytes: UInt64?
    let usedBytes: UInt64?
    let availableBytes: UInt64?
    let compressedBytes: UInt64?
    let pressureRatio: Double?
    let swapUsedBytes: UInt64?
    let swapTotalBytes: UInt64?
    let swapInPages: UInt64?
    let swapOutPages: UInt64?
    let pageBytes: UInt64?
  }

  private struct CPUTicks {
    let active: UInt64
    let idle: UInt64
  }

  private struct SwapCounters {
    let swapInPages: UInt64
    let swapOutPages: UInt64
    let pageBytes: UInt64
    let sampledAtUptime: TimeInterval
  }

  private let defaults: UserDefaults
  private var memoryPressureObserver: SystemMemoryPressureObserver?
  private var previousCPU: CPUTicks?
  private var previousSwap: SwapCounters?
  private var pressureHistory: SystemHealthPressureHistoryBuffer

  init(
    defaults: UserDefaults = SystemHealthMonitorPreferences.helperDefaults(),
    historyWindow: TimeInterval = 5 * 60
  ) {
    self.defaults = defaults
    pressureHistory = SystemHealthPressureHistoryBuffer(window: historyWindow)
  }

  var isEnabled: Bool {
    SystemHealthMonitorPreferences.isEnabled(in: defaults)
  }

  var isObservingMemoryPressure: Bool {
    memoryPressureObserver != nil
  }

  func reset() {
    previousCPU = nil
    previousSwap = nil
    pressureHistory.removeAll()
    memoryPressureObserver = nil
  }

  /// Returns nil only when the user has explicitly disabled the monitor.
  func sample() -> SystemHealthSnapshot? {
    guard isEnabled else {
      memoryPressureObserver = nil
      return nil
    }
    if memoryPressureObserver == nil {
      memoryPressureObserver = SystemMemoryPressureObserver()
    }

    let sampledAt = Date()
    let uptime = ProcessInfo.processInfo.systemUptime
    let memory = Self.readMemory()
    let cpuTicks = Self.readCPUTicks()
    let cpuUsage = Self.cpuPercent(current: cpuTicks, previous: previousCPU)
    previousCPU = cpuTicks

    let currentSwap = Self.swapCounters(from: memory, uptime: uptime)
    let swapRates = Self.swapRates(current: currentSwap, previous: previousSwap)
    previousSwap = currentSwap

    let observedPressure = memoryPressureObserver?.currentState()
    let pressureState = Self.pressureState(
      observed: observedPressure,
      ratio: memory.pressureRatio)
    let thermalState = Self.readThermalState()
    pressureHistory.append(value: memory.pressureRatio, at: sampledAt)

    let input = SystemHealthEvaluationInput(
      memoryPressure: pressureState,
      memoryPressureRatio: memory.pressureRatio,
      swapUsedBytes: memory.swapUsedBytes,
      swapInBytesPerSecond: swapRates?.incoming,
      swapOutBytesPerSecond: swapRates?.outgoing,
      thermalState: thermalState,
      hasUsableMetric: memory.pressureRatio != nil || cpuUsage != nil)
    let assessment = SystemHealthEvaluator.evaluate(input)

    return SystemHealthSnapshot(
      sampledAt: sampledAt,
      assessment: assessment,
      memoryPressure: pressureState,
      memoryPressureRatio: memory.pressureRatio,
      pressureHistory: pressureHistory.points,
      physicalMemoryBytes: memory.physicalBytes,
      usedMemoryBytes: memory.usedBytes,
      availableMemoryBytes: memory.availableBytes,
      compressedMemoryBytes: memory.compressedBytes,
      swapUsedBytes: memory.swapUsedBytes,
      swapTotalBytes: memory.swapTotalBytes,
      swapInBytesPerSecond: swapRates?.incoming,
      swapOutBytesPerSecond: swapRates?.outgoing,
      cpuUsagePercent: cpuUsage,
      gpuUsagePercent: nil,
      temperatureCelsius: nil,
      fanRPM: nil,
      thermalState: thermalState)
  }

  private static func pressureState(
    observed: SystemMemoryPressureState?,
    ratio: Double?
  ) -> SystemMemoryPressureState {
    if let observed { return observed }
    guard let ratio else { return .unavailable }
    switch SystemHealthMath.clampUnit(ratio) {
    case 0.97...: return .critical
    case 0.90...: return .warning
    default: return .normal
    }
  }

  private static func swapCounters(
    from memory: MemoryReading,
    uptime: TimeInterval
  ) -> SwapCounters? {
    guard let swapInPages = memory.swapInPages,
      let swapOutPages = memory.swapOutPages,
      let pageBytes = memory.pageBytes
    else { return nil }
    return SwapCounters(
      swapInPages: swapInPages,
      swapOutPages: swapOutPages,
      pageBytes: pageBytes,
      sampledAtUptime: uptime)
  }

  private static func swapRates(
    current: SwapCounters?,
    previous: SwapCounters?
  ) -> (incoming: Double, outgoing: Double)? {
    guard let current, let previous,
      current.pageBytes == previous.pageBytes
    else { return nil }
    let elapsed = current.sampledAtUptime - previous.sampledAtUptime
    guard
      let incomingPages = SystemHealthMath.rate(
        current: current.swapInPages,
        previous: previous.swapInPages,
        elapsed: elapsed),
      let outgoingPages = SystemHealthMath.rate(
        current: current.swapOutPages,
        previous: previous.swapOutPages,
        elapsed: elapsed)
    else { return nil }
    return (
      incoming: incomingPages * Double(current.pageBytes),
      outgoing: outgoingPages * Double(current.pageBytes)
    )
  }

  private static func cpuPercent(current: CPUTicks?, previous: CPUTicks?) -> Double? {
    guard let current, let previous,
      let activeDelta = SystemHealthMath.counterDelta(
        current: current.active, previous: previous.active),
      let idleDelta = SystemHealthMath.counterDelta(current: current.idle, previous: previous.idle)
    else { return nil }
    let total = activeDelta + idleDelta
    guard total > 0 else { return nil }
    return min(100, max(0, Double(activeDelta) / Double(total) * 100))
  }

  private static func readMemory() -> MemoryReading {
    let physicalBytes = readPhysicalMemoryBytes()
    var pageSize: vm_size_t = 0
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
    let pageSizeResult = host_page_size(mach_host_self(), &pageSize)
    let statisticsResult = withUnsafeMutablePointer(to: &stats) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
      }
    }
    let pageBytes = pageSizeResult == KERN_SUCCESS && pageSize > 0 ? UInt64(pageSize) : nil

    var swap = xsw_usage()
    var swapSize = MemoryLayout<xsw_usage>.stride
    let swapResult = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)
    let swapUsedBytes = swapResult == 0 ? swap.xsu_used : nil
    let swapTotalBytes = swapResult == 0 ? swap.xsu_total : nil

    guard statisticsResult == KERN_SUCCESS, let pageBytes else {
      return MemoryReading(
        physicalBytes: physicalBytes,
        usedBytes: nil,
        availableBytes: nil,
        compressedBytes: nil,
        pressureRatio: nil,
        swapUsedBytes: swapUsedBytes,
        swapTotalBytes: swapTotalBytes,
        swapInPages: nil,
        swapOutPages: nil,
        pageBytes: pageBytes)
    }

    let usedPages = saturatingAdd(
      UInt64(stats.internal_page_count),
      UInt64(stats.wire_count),
      UInt64(stats.compressor_page_count))
    let availablePages = saturatingAdd(
      UInt64(stats.free_count),
      UInt64(stats.inactive_count),
      UInt64(stats.speculative_count),
      UInt64(stats.purgeable_count))
    let usedBytes = byteCount(pages: usedPages, pageBytes: pageBytes)
      .map { measuredBytes in
        physicalBytes.map { min(measuredBytes, $0) } ?? measuredBytes
      }
    let availableBytes = byteCount(pages: availablePages, pageBytes: pageBytes)
      .map { measuredBytes in
        physicalBytes.map { min(measuredBytes, $0) } ?? measuredBytes
      }
    let compressedBytes = byteCount(
      pages: UInt64(stats.compressor_page_count), pageBytes: pageBytes)
    let pressureRatio: Double?
    if let physicalBytes, physicalBytes > 0, let usedBytes {
      pressureRatio = SystemHealthMath.clampUnit(Double(usedBytes) / Double(physicalBytes))
    } else {
      pressureRatio = nil
    }

    return MemoryReading(
      physicalBytes: physicalBytes,
      usedBytes: usedBytes,
      availableBytes: availableBytes,
      compressedBytes: compressedBytes,
      pressureRatio: pressureRatio,
      swapUsedBytes: swapUsedBytes,
      swapTotalBytes: swapTotalBytes,
      swapInPages: stats.swapins,
      swapOutPages: stats.swapouts,
      pageBytes: pageBytes)
  }

  private static func readPhysicalMemoryBytes() -> UInt64? {
    var value: UInt64 = 0
    var size = MemoryLayout<UInt64>.size
    guard sysctlbyname("hw.memsize", &value, &size, nil, 0) == 0, value > 0 else { return nil }
    return value
  }

  private static func readCPUTicks() -> CPUTicks? {
    var load = host_cpu_load_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
    let result = withUnsafeMutablePointer(to: &load) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return nil }
    let ticks = withUnsafeBytes(of: load.cpu_ticks) {
      Array($0.bindMemory(to: integer_t.self))
    }
    guard ticks.count > Int(CPU_STATE_IDLE) else { return nil }
    let user = UInt64(max(0, ticks[Int(CPU_STATE_USER)]))
    let system = UInt64(max(0, ticks[Int(CPU_STATE_SYSTEM)]))
    let nice = UInt64(max(0, ticks[Int(CPU_STATE_NICE)]))
    let idle = UInt64(max(0, ticks[Int(CPU_STATE_IDLE)]))
    return CPUTicks(active: saturatingAdd(user, system, nice), idle: idle)
  }

  private static func readThermalState() -> SystemThermalState {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: return .nominal
    case .fair: return .fair
    case .serious: return .serious
    case .critical: return .critical
    @unknown default: return .unavailable
    }
  }

  private static func byteCount(pages: UInt64, pageBytes: UInt64) -> UInt64? {
    let result = pages.multipliedReportingOverflow(by: pageBytes)
    return result.overflow ? nil : result.partialValue
  }

  private static func saturatingAdd(_ values: UInt64...) -> UInt64 {
    values.reduce(0) { partial, value in
      let result = partial.addingReportingOverflow(value)
      return result.overflow ? UInt64.max : result.partialValue
    }
  }
}

/// Owns exactly one timer and switches cadence when the status menu is open.
/// Call all methods on the main thread, as required by AppKit and `Timer`.
@MainActor
final class SystemHealthSamplingController {
  struct Cadence: Equatable, Sendable {
    let background: TimeInterval
    let menuPresented: TimeInterval

    static let standard = Cadence(background: 15, menuPresented: 2)
  }

  var onSnapshot: ((SystemHealthSnapshot) -> Void)?
  var onEnabledChanged: ((Bool) -> Void)?

  private let sampler: SystemHealthSampler
  private let cadence: Cadence
  private var timer: Timer?
  private var isStarted = false
  private var isMenuPresented = false
  private var lastKnownEnabled: Bool?
  private(set) var latestSnapshot: SystemHealthSnapshot?

  init(
    sampler: SystemHealthSampler = SystemHealthSampler(),
    cadence: Cadence = .standard
  ) {
    self.sampler = sampler
    self.cadence = Cadence(
      background: max(1, cadence.background),
      menuPresented: max(0.5, cadence.menuPresented))
  }

  var periodicTaskCount: Int { timer == nil ? 0 : 1 }
  var currentInterval: TimeInterval? { timer?.timeInterval }

  func start() {
    precondition(Thread.isMainThread)
    guard !isStarted else { return }
    isStarted = true
    refreshPreferences()
  }

  func stop() {
    precondition(Thread.isMainThread)
    isStarted = false
    lastKnownEnabled = nil
    timer?.invalidate()
    timer = nil
  }

  func setMenuPresented(_ presented: Bool) {
    precondition(Thread.isMainThread)
    guard isMenuPresented != presented else { return }
    isMenuPresented = presented
    guard isStarted, sampler.isEnabled else { return }
    refreshNow()
    scheduleTimer()
  }

  func refreshPreferences() {
    precondition(Thread.isMainThread)
    let enabled = sampler.isEnabled
    let changed = lastKnownEnabled != enabled
    lastKnownEnabled = enabled
    onEnabledChanged?(enabled)
    guard isStarted, changed else { return }
    if enabled {
      refreshNow()
      scheduleTimer()
    } else {
      timer?.invalidate()
      timer = nil
      latestSnapshot = nil
      sampler.reset()
    }
  }

  func refreshNow() {
    precondition(Thread.isMainThread)
    guard isStarted, sampler.isEnabled, let snapshot = sampler.sample() else { return }
    latestSnapshot = snapshot
    onSnapshot?(snapshot)
  }

  private func scheduleTimer() {
    timer?.invalidate()
    let interval = isMenuPresented ? cadence.menuPresented : cadence.background
    let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        if self.sampler.isEnabled {
          self.refreshNow()
        } else {
          self.refreshPreferences()
        }
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }
}
