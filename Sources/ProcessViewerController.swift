import AppKit
import Darwin
import Foundation

@MainActor
final class ProcessViewerController: ObservableObject {
  @Published private(set) var processes: [ProcessViewerProcess] = []
  @Published private(set) var memory = ProcessViewerMemorySnapshot.empty
  @Published private(set) var memoryOccupancyHistory: [Double] = []
  @Published private(set) var sampledAt: Date?
  @Published private(set) var isLoading = false
  @Published private(set) var sampleError: String?
  @Published private(set) var reducedFrequency = false
  @Published var isPaused = false {
    didSet { updateTimer() }
  }

  private let sampler = ProcessViewerSampler()
  private var timer: Timer?
  private var isVisible = false
  private var isEnabled = true
  private var isAppActive = true
  private var slowSampleCount = 0

  var periodicTaskCount: Int { timer == nil ? 0 : 1 }

  func setVisible(_ visible: Bool) {
    isVisible = visible
    if visible {
      refresh()
    }
    updateTimer()
  }

  func setEnabled(_ enabled: Bool) {
    isEnabled = enabled
    if !enabled { stopTimer() } else if isVisible { refresh() }
    updateTimer()
  }

  func setAppActive(_ active: Bool) {
    isAppActive = active
    updateTimer()
  }

  func refresh() {
    guard isEnabled, !isLoading else { return }
    isLoading = true
    let previous = Dictionary(uniqueKeysWithValues: processes.map { ($0.identity.pid, $0) })
    Task {
      do {
        let snapshot = try await sampler.sample(previous: previous)
        apply(snapshot)
      } catch {
        sampleError = "本次刷新失败：\(error.localizedDescription)"
      }
      isLoading = false
    }
  }

  func requestQuit(_ process: ProcessViewerProcess) {
    performTermination(process, force: false)
  }

  func requestForceQuit(_ process: ProcessViewerProcess) {
    guard process.actionState.allowsForce else { return }
    performTermination(process, force: true)
  }

  private func performTermination(_ process: ProcessViewerProcess, force: Bool) {
    guard process.canQuit || (force && process.actionState.allowsForce) else { return }
    mutate(process.identity) { $0.actionState = .quitting }
    Task {
      let result = await sampler.terminate(identity: process.identity, force: force)
      switch result {
      case .exited:
        mutate(process.identity) { $0.actionState = .exited }
        try? await Task.sleep(nanoseconds: 550_000_000)
        refresh()
      case .identityChanged:
        mutate(process.identity) {
          $0.actionState =
            force
            ? .forceFailed("进程已经变化，未执行操作。")
            : .quitFailed("进程已经变化，未执行操作。")
        }
      case .permissionDenied:
        mutate(process.identity) {
          $0.actionState =
            force
            ? .forceFailed("权限不足，未执行任何操作。")
            : .quitFailed("权限不足，未执行任何操作。")
        }
      case .stillRunning:
        mutate(process.identity) {
          $0.actionState =
            force
            ? .forceFailed("强制结束失败，进程仍在运行。")
            : .quitFailed("进程没有响应。")
        }
      }
    }
  }

  private func mutate(
    _ identity: ProcessStableIdentity,
    change: (inout ProcessViewerProcess) -> Void
  ) {
    guard let index = processes.firstIndex(where: { $0.identity == identity }) else { return }
    change(&processes[index])
  }

  private func apply(_ snapshot: ProcessViewerSnapshot) {
    processes = snapshot.processes
    memory = snapshot.memory
    memoryOccupancyHistory.append(snapshot.memory.occupancyRatio)
    if memoryOccupancyHistory.count > 90 {
      memoryOccupancyHistory.removeFirst(memoryOccupancyHistory.count - 90)
    }
    sampledAt = snapshot.sampledAt
    sampleError = nil
    slowSampleCount = snapshot.duration > 0.15 ? slowSampleCount + 1 : 0
    if slowSampleCount >= 2 { reducedFrequency = true }
    updateTimer()
  }

  private func updateTimer() {
    stopTimer()
    guard isEnabled, isVisible, !isPaused else { return }
    let interval: TimeInterval = (!isAppActive || reducedFrequency) ? 5 : 2
    let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func stopTimer() {
    timer?.invalidate()
    timer = nil
  }
}

enum ProcessTerminationResult {
  case exited
  case identityChanged
  case permissionDenied
  case stillRunning
}

actor ProcessViewerSampler {
  private struct Counters {
    let totalNanoseconds: UInt64
    let sampledAt: TimeInterval
  }

  private var counters: [pid_t: Counters] = [:]

  func sample(previous: [pid_t: ProcessViewerProcess]) throws -> ProcessViewerSnapshot {
    let started = ProcessInfo.processInfo.systemUptime
    let pids = listAllPIDs()
    let now = ProcessInfo.processInfo.systemUptime
    var nextCounters: [pid_t: Counters] = [:]
    var rows: [ProcessViewerProcess] = []
    rows.reserveCapacity(pids.count)

    for pid in pids where pid > 0 {
      guard let raw = readProcess(pid: pid) else { continue }
      let current = Counters(totalNanoseconds: raw.totalCPUTime, sampledAt: now)
      nextCounters[pid] = current
      let cpu: Double?
      if let old = counters[pid], now > old.sampledAt,
        current.totalNanoseconds >= old.totalNanoseconds
      {
        cpu =
          Double(current.totalNanoseconds - old.totalNanoseconds)
          / ((now - old.sampledAt) * 1_000_000_000) * 100
      } else {
        cpu = nil
      }
      var row = ProcessViewerProcess(
        identity: raw.identity,
        name: raw.name,
        executablePath: raw.path,
        bundleIdentifier: raw.bundleID,
        ownerName: raw.ownerName,
        parentPID: raw.parentPID,
        cpuPercent: cpu,
        residentBytes: raw.residentBytes,
        state: raw.state,
        protectionReason: raw.protectionReason)
      if let old = previous[pid], old.identity == row.identity { row.actionState = old.actionState }
      rows.append(row)
    }
    counters = nextCounters
    return ProcessViewerSnapshot(
      processes: rows,
      memory: readMemory(),
      sampledAt: Date(),
      duration: ProcessInfo.processInfo.systemUptime - started)
  }

  func terminate(identity: ProcessStableIdentity, force: Bool) async -> ProcessTerminationResult {
    guard let current = readProcess(pid: identity.pid), current.identity == identity else {
      if kill(identity.pid, 0) != 0, errno == ESRCH { return .exited }
      return .identityChanged
    }
    guard current.protectionReason == nil else { return .permissionDenied }

    let signal = force ? SIGKILL : SIGTERM
    if let app = NSRunningApplication(processIdentifier: identity.pid) {
      _ = force ? app.forceTerminate() : app.terminate()
    } else if kill(identity.pid, signal) != 0 {
      return errno == EPERM ? .permissionDenied : .stillRunning
    }

    let deadline = Date().addingTimeInterval(force ? 2 : 5)
    while Date() < deadline {
      if kill(identity.pid, 0) != 0, errno == ESRCH { return .exited }
      if let latest = readProcess(pid: identity.pid), latest.identity != identity {
        return .identityChanged
      }
      try? await Task.sleep(nanoseconds: 150_000_000)
    }
    return .stillRunning
  }

  private struct RawProcess {
    let identity: ProcessStableIdentity
    let name: String
    let path: String?
    let bundleID: String?
    let ownerName: String?
    let parentPID: pid_t
    let totalCPUTime: UInt64
    let residentBytes: UInt64
    let state: ProcessViewerRunState
    let protectionReason: String?
  }

  private func listAllPIDs() -> [pid_t] {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(count) + 64)
    let bytes = Int32(pids.count * MemoryLayout<pid_t>.stride)
    let actual = pids.withUnsafeMutableBytes { buffer in
      proc_listallpids(buffer.baseAddress, bytes)
    }
    return Array(pids.prefix(max(0, Int(actual))))
  }

  private func readProcess(pid: pid_t) -> RawProcess? {
    var bsd = proc_bsdinfo()
    let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize else { return nil }

    var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
    let path = pathLength > 0
      ? String(
        decoding: pathBuffer.prefix(Int(pathLength)).prefix { $0 != 0 }
          .map { UInt8(bitPattern: $0) },
        as: UTF8.self)
      : nil
    let name = withUnsafePointer(to: &bsd.pbi_name) {
      $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { String(cString: $0) }
    }
    let comm = withUnsafePointer(to: &bsd.pbi_comm) {
      $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { String(cString: $0) }
    }
    let displayName = name.isEmpty ? (comm.isEmpty ? "进程 \(pid)" : comm) : name

    var usage = rusage_info_v2()
    let usageResult = withUnsafeMutablePointer(to: &usage) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
      }
    }
    let totalCPU = usageResult == 0 ? usage.ri_user_time + usage.ri_system_time : 0
    let resident = usageResult == 0 ? usage.ri_resident_size : 0
    let uid = uid_t(bsd.pbi_uid)
    let start = UInt64(bsd.pbi_start_tvsec) * 1_000_000 + UInt64(bsd.pbi_start_tvusec)
    let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    let executableIdentity = path ?? bundle ?? ""
    let identity = ProcessStableIdentity(
      pid: pid,
      startTimeMicroseconds: start,
      executableIdentity: executableIdentity,
      uid: uid)
    let protection = protectionReason(
      pid: pid, uid: uid, path: path, identityComplete: start > 0 && !executableIdentity.isEmpty)
    let state: ProcessViewerRunState = bsd.pbi_status == UInt32(SRUN) ? .running : .sleeping
    return RawProcess(
      identity: identity,
      name: displayName,
      path: path,
      bundleID: bundle,
      ownerName: userName(uid: uid),
      parentPID: pid_t(bsd.pbi_ppid),
      totalCPUTime: totalCPU,
      residentBytes: resident,
      state: state,
      protectionReason: protection)
  }

  private func protectionReason(pid: pid_t, uid: uid_t, path: String?, identityComplete: Bool)
    -> String?
  {
    if pid <= 1 || pid == ProcessInfo.processInfo.processIdentifier {
      return pid == ProcessInfo.processInfo.processIdentifier
        ? "这是小龙哥 Mac 哲学必需进程。" : "系统关键进程，不能在这里结束。"
    }
    guard identityComplete else { return "无法确认进程身份，已禁止操作。" }
    guard uid == getuid() else { return "权限不足，未执行任何操作。" }
    if path?.hasPrefix("/System/") == true || path?.hasPrefix("/usr/libexec/") == true {
      return "系统关键进程，不能在这里结束。"
    }
    if let executable = path.map({ URL(fileURLWithPath: $0).lastPathComponent }),
      executable.hasPrefix("aixlg-")
    {
      return "这是小龙哥 Mac 哲学必需进程。"
    }
    return nil
  }

  private func userName(uid: uid_t) -> String? {
    guard let record = getpwuid(uid) else { return nil }
    return String(cString: record.pointee.pw_name)
  }

  private func readMemory() -> ProcessViewerMemorySnapshot {
    let physical = ProcessInfo.processInfo.physicalMemory
    var pageSize: vm_size_t = 0
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
    let statsResult = withUnsafeMutablePointer(to: &stats) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
      }
    }
    let hasStats =
      host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS && statsResult == KERN_SUCCESS
    let compressed = hasStats ? UInt64(stats.compressor_page_count) * UInt64(pageSize) : 0
    let wired = hasStats ? UInt64(stats.wire_count) * UInt64(pageSize) : 0
    let cached =
      hasStats
      ? UInt64(stats.external_page_count + stats.purgeable_count) * UInt64(pageSize)
      : 0
    let appMemory =
      hasStats
      ? UInt64(stats.internal_page_count - min(stats.internal_page_count, stats.purgeable_count))
        * UInt64(pageSize)
      : 0
    let used =
      hasStats
      ? min(
        physical,
        UInt64(stats.internal_page_count + stats.wire_count + stats.compressor_page_count)
          * UInt64(pageSize))
      : 0
    let available =
      hasStats
      ? UInt64(stats.free_count + stats.inactive_count + stats.speculative_count)
        * UInt64(pageSize)
      : physical
    let occupancyRatio =
      physical > 0
      ? min(1, max(0, 1 - Double(min(physical, available)) / Double(physical)))
      : 0

    var swap = xsw_usage()
    var swapSize = MemoryLayout<xsw_usage>.stride
    let swapResult = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)
    return ProcessViewerMemorySnapshot(
      physicalBytes: physical,
      usedBytes: used,
      cachedFilesBytes: cached,
      appMemoryBytes: appMemory,
      wiredBytes: wired,
      compressedBytes: compressed,
      swapUsedBytes: swapResult == 0 ? swap.xsu_used : nil,
      swapTotalBytes: swapResult == 0 ? swap.xsu_total : nil,
      occupancyRatio: occupancyRatio)
  }
}
