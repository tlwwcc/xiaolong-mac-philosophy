import Darwin
import Foundation

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
  private struct NetworkCounters {
    let receivedBytes: UInt64
    let sentBytes: UInt64
    let activeInterfaceCount: Int
    let interfaceNames: Set<String>
  }

  private var previousNetworkCounters: NetworkCounters?
  private var previousNetworkSampleTime: TimeInterval?

  func sample() -> SystemMonitorSnapshot {
    let now = ProcessInfo.processInfo.systemUptime
    let counters = Self.readNetworkCounters()
    let network = networkSnapshot(from: counters, now: now)
    previousNetworkCounters = counters
    previousNetworkSampleTime = now

    return SystemMonitorSnapshot(
      memory: Self.readMemoryUsage(),
      network: network,
      sampledAt: Date()
    )
  }

  private func networkSnapshot(
    from counters: NetworkCounters,
    now: TimeInterval
  ) -> NetworkUsageSnapshot {
    guard let previousNetworkCounters, let previousNetworkSampleTime,
      previousNetworkCounters.interfaceNames == counters.interfaceNames
    else {
      return NetworkUsageSnapshot(
        downloadBytesPerSecond: 0,
        uploadBytesPerSecond: 0,
        activeInterfaceCount: counters.activeInterfaceCount
      )
    }

    let elapsed = max(now - previousNetworkSampleTime, 0.001)
    return NetworkUsageSnapshot(
      downloadBytesPerSecond: Double(Self.delta(counters.receivedBytes, previousNetworkCounters.receivedBytes))
        / elapsed,
      uploadBytesPerSecond: Double(Self.delta(counters.sentBytes, previousNetworkCounters.sentBytes))
        / elapsed,
      activeInterfaceCount: counters.activeInterfaceCount
    )
  }

  private static func delta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
    current >= previous ? current - previous : 0
  }

  private static func readNetworkCounters() -> NetworkCounters {
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
      return NetworkCounters(
        receivedBytes: 0,
        sentBytes: 0,
        activeInterfaceCount: 0,
        interfaceNames: [])
    }
    defer { freeifaddrs(interfaces) }

    var receivedBytes: UInt64 = 0
    var sentBytes: UInt64 = 0
    var activeInterfaceCount = 0
    var interfaceNames: Set<String> = []
    var cursor: UnsafeMutablePointer<ifaddrs>? = firstInterface

    while let interface = cursor {
      defer { cursor = interface.pointee.ifa_next }
      guard let address = interface.pointee.ifa_addr else { continue }
      guard Int32(address.pointee.sa_family) == AF_LINK else { continue }

      let flags = interface.pointee.ifa_flags
      guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
      guard let namePointer = interface.pointee.ifa_name else { continue }
      let interfaceName = String(cString: namePointer)
      guard !interfaceName.hasPrefix("lo") else { continue }
      guard let data = interface.pointee.ifa_data?.assumingMemoryBound(to: if_data.self).pointee else {
        continue
      }

      receivedBytes += UInt64(data.ifi_ibytes)
      sentBytes += UInt64(data.ifi_obytes)
      activeInterfaceCount += 1
      interfaceNames.insert(interfaceName)
    }

    return NetworkCounters(
      receivedBytes: receivedBytes,
      sentBytes: sentBytes,
      activeInterfaceCount: activeInterfaceCount,
      interfaceNames: interfaceNames
    )
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
