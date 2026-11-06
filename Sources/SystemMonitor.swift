import Darwin
import Foundation
#if canImport(SystemMetricsSupport)
import SystemMetricsSupport
#endif

enum HelperRestartBackoff {
  static let stableRunDuration: TimeInterval = 30

  static func delay(afterConsecutiveFailures failureCount: Int) -> TimeInterval {
    guard failureCount > 0 else { return 0 }
    return min(60, pow(2, Double(min(failureCount - 1, 6))))
  }
}

enum MemoryPressureLevel: String {
  case normal
  case elevated
  case high

  var title: String {
    switch self {
    case .normal: return "正常"
    case .elevated: return "偏高"
    case .high: return "紧张"
    }
  }
}

struct MemoryUsageSnapshot {
  let totalBytes: UInt64
  let usedBytes: UInt64
  let availableBytes: UInt64
  let appBytes: UInt64
  let wiredBytes: UInt64
  let compressedBytes: UInt64
  let pressure: MemoryPressureLevel

  static let empty = MemoryUsageSnapshot(
    totalBytes: 0,
    usedBytes: 0,
    availableBytes: 0,
    appBytes: 0,
    wiredBytes: 0,
    compressedBytes: 0,
    pressure: .normal
  )

  var usedRatio: Double {
    guard totalBytes > 0 else { return 0 }
    return min(1, Double(usedBytes) / Double(totalBytes))
  }
}

struct NetworkUsageSnapshot {
  let downloadBytesPerSecond: Double
  let uploadBytesPerSecond: Double
  let activeInterfaceCount: Int

  static let empty = NetworkUsageSnapshot(
    downloadBytesPerSecond: 0,
    uploadBytesPerSecond: 0,
    activeInterfaceCount: 0
  )
}

struct SystemMonitorSnapshot {
  let memory: MemoryUsageSnapshot
  let network: NetworkUsageSnapshot
  let sampledAt: Date

  static let empty = SystemMonitorSnapshot(
    memory: .empty,
    network: .empty,
    sampledAt: Date(timeIntervalSince1970: 0)
  )
}

final class SystemMonitor {
  private var networkSampler = NetworkTrafficRateSampler()

  func sample() -> SystemMonitorSnapshot {
    let rate = networkSampler.sample(
      counters: NetworkInterfaceTrafficCounterReader.read(),
      at: ProcessInfo.processInfo.systemUptime)
    return SystemMonitorSnapshot(
      memory: Self.readMemoryUsage(),
      network: NetworkUsageSnapshot(
        downloadBytesPerSecond: rate.downloadBytesPerSecond,
        uploadBytesPerSecond: rate.uploadBytesPerSecond,
        activeInterfaceCount: rate.activeInterfaceCount),
      sampledAt: Date())
  }

  private static func readMemoryUsage() -> MemoryUsageSnapshot {
    let totalBytes = readTotalMemoryBytes()
    var pageSize: vm_size_t = 0
    guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS, pageSize > 0 else {
      return MemoryUsageSnapshot(
        totalBytes: totalBytes,
        usedBytes: 0,
        availableBytes: totalBytes,
        appBytes: 0,
        wiredBytes: 0,
        compressedBytes: 0,
        pressure: .normal
      )
    }

    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
    )
    let result = withUnsafeMutablePointer(to: &stats) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
        host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPointer, &count)
      }
    }
    guard result == KERN_SUCCESS else {
      return MemoryUsageSnapshot(
        totalBytes: totalBytes,
        usedBytes: 0,
        availableBytes: totalBytes,
        appBytes: 0,
        wiredBytes: 0,
        compressedBytes: 0,
        pressure: .normal
      )
    }

    let pageBytes = UInt64(pageSize)
    let appBytes = UInt64(stats.internal_page_count) * pageBytes
    let wiredBytes = UInt64(stats.wire_count) * pageBytes
    let compressedBytes = UInt64(stats.compressor_page_count) * pageBytes
    let usedBytes = min(totalBytes, appBytes + wiredBytes + compressedBytes)
    let availableBytes = totalBytes > usedBytes ? totalBytes - usedBytes : 0
    let ratio = totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
    let pressure: MemoryPressureLevel
    if ratio >= 0.90 {
      pressure = .high
    } else if ratio >= 0.75 {
      pressure = .elevated
    } else {
      pressure = .normal
    }

    return MemoryUsageSnapshot(
      totalBytes: totalBytes,
      usedBytes: usedBytes,
      availableBytes: availableBytes,
      appBytes: appBytes,
      wiredBytes: wiredBytes,
      compressedBytes: compressedBytes,
      pressure: pressure
    )
  }

  private static func readTotalMemoryBytes() -> UInt64 {
    var totalBytes: UInt64 = 0
    var size = MemoryLayout<UInt64>.size
    let result = sysctlbyname("hw.memsize", &totalBytes, &size, nil, 0)
    return result == 0 ? totalBytes : 0
  }
}
