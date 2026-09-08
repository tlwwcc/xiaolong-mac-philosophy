import Foundation

struct ProcessStableIdentity: Hashable, Identifiable {
  let pid: pid_t
  let startTimeMicroseconds: UInt64
  let executableIdentity: String
  let uid: uid_t

  var id: String {
    "\(pid):\(startTimeMicroseconds):\(uid):\(executableIdentity)"
  }
}

enum ProcessViewerRunState: String {
  case running
  case sleeping
  case unknown

  var title: String {
    switch self {
    case .running: return "运行中"
    case .sleeping: return "睡眠"
    case .unknown: return "状态未知"
    }
  }
}

struct ProcessViewerProcess: Identifiable {
  let identity: ProcessStableIdentity
  let name: String
  let executablePath: String?
  let bundleIdentifier: String?
  let ownerName: String?
  let parentPID: pid_t
  let cpuPercent: Double?
  let residentBytes: UInt64
  let state: ProcessViewerRunState
  let protectionReason: String?
  var actionState: ProcessViewerActionState = .idle

  var id: String { identity.id }
  var canQuit: Bool { protectionReason == nil && actionState != .quitting }

  /// macOS 自带的后台服务默认不占据主列表，但用户可随时在界面中展开查看。
  /// 保留 `.app/Contents/MacOS` 内的 Apple 应用，避免把用户主动打开的 Safari、访达等藏掉。
  var isKnownMacOSBackgroundProcess: Bool {
    let path = executablePath ?? ""
    if path.contains(".app/Contents/MacOS/") { return false }
    if path.hasPrefix("/System/Library/") || path.hasPrefix("/usr/libexec/") { return true }
    return Self.macOSBackgroundProcessNames.contains(name)
  }

  private static let macOSBackgroundProcessNames: Set<String> = [
    "kernel_task", "launchd", "WindowServer", "logd", "runningboardd", "launchservicesd",
    "cfprefsd", "distnoted", "opendirectoryd", "powerd", "syslogd", "securityd", "trustd",
    "mds", "mdworker", "mdworker_shared", "corespotlightd", "locationd", "bluetoothd",
    "airportd", "sharingd", "nsurlsessiond", "symptomsd", "analyticsd", "accountsd",
    "cloudd", "bird", "photolibraryd", "softwareupdated", "timed", "notifyd", "hidd"
  ]
}

enum ProcessViewerActionState: Equatable {
  case idle
  case quitting
  case quitFailed(String)
  case forceFailed(String)
  case exited

  var allowsForce: Bool {
    if case .quitFailed = self { return true }
    return false
  }
}

struct ProcessViewerMemorySnapshot {
  let physicalBytes: UInt64
  let usedBytes: UInt64
  let cachedFilesBytes: UInt64
  let appMemoryBytes: UInt64
  let wiredBytes: UInt64
  let compressedBytes: UInt64
  let swapUsedBytes: UInt64?
  let swapTotalBytes: UInt64?
  /// Derived physical-memory occupancy. This is not macOS's kernel memory-pressure signal.
  let occupancyRatio: Double

  static let empty = ProcessViewerMemorySnapshot(
    physicalBytes: 0,
    usedBytes: 0,
    cachedFilesBytes: 0,
    appMemoryBytes: 0,
    wiredBytes: 0,
    compressedBytes: 0,
    swapUsedBytes: nil,
    swapTotalBytes: nil,
    occupancyRatio: 0)
}

struct ProcessViewerSnapshot {
  let processes: [ProcessViewerProcess]
  let memory: ProcessViewerMemorySnapshot
  let sampledAt: Date
  let duration: TimeInterval
}

enum ProcessViewerSort: String, CaseIterable, Identifiable {
  case cpu = "CPU 从高到低"
  case memory = "内存从高到低"
  case name = "名称 A-Z"
  case pid = "PID 从小到大"
  case state = "状态"

  var id: String { rawValue }
}
