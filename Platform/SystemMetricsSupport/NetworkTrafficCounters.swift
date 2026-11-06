import Darwin
import Foundation

/// One interface's native 64-bit byte counters. The interface index distinguishes a removed
/// interface from a new one that reuses the same name.
public struct NetworkInterfaceTrafficCounters: Equatable, Sendable {
  public let index: UInt32
  public let name: String
  public let receivedBytes: UInt64
  public let sentBytes: UInt64

  public init(index: UInt32, name: String, receivedBytes: UInt64, sentBytes: UInt64) {
    self.index = index
    self.name = name
    self.receivedBytes = receivedBytes
    self.sentBytes = sentBytes
  }
}

public struct NetworkTrafficRate: Equatable, Sendable {
  public let downloadBytesPerSecond: Double
  public let uploadBytesPerSecond: Double
  public let activeInterfaceCount: Int

  public init(
    downloadBytesPerSecond: Double,
    uploadBytesPerSecond: Double,
    activeInterfaceCount: Int
  ) {
    self.downloadBytesPerSecond = downloadBytesPerSecond
    self.uploadBytesPerSecond = uploadBytesPerSecond
    self.activeInterfaceCount = activeInterfaceCount
  }
}

/// Keeps the existing all-up, non-loopback interface scope. A missing snapshot, interface
/// change, counter reset, invalid clock or overflowing total starts a new baseline.
public struct NetworkTrafficRateSampler {
  private var previousCounters: [String: NetworkInterfaceTrafficCounters]?
  private var previousSampleTime: TimeInterval?

  public init() {}

  public mutating func sample(
    counters: [NetworkInterfaceTrafficCounters]?,
    at now: TimeInterval
  ) -> NetworkTrafficRate {
    guard let counters, now.isFinite else {
      previousCounters = nil
      previousSampleTime = nil
      return zero(activeInterfaceCount: 0)
    }

    var current: [String: NetworkInterfaceTrafficCounters] = [:]
    var indexes = Set<UInt32>()
    for counter in counters {
      guard counter.index > 0, !counter.name.isEmpty,
        current[counter.name] == nil, indexes.insert(counter.index).inserted
      else {
        previousCounters = nil
        previousSampleTime = nil
        return zero(activeInterfaceCount: 0)
      }
      current[counter.name] = counter
    }
    defer {
      previousCounters = current
      previousSampleTime = now
    }

    guard let previousCounters, let previousSampleTime,
      now > previousSampleTime,
      current.count == previousCounters.count
    else { return zero(activeInterfaceCount: current.count) }

    var receivedDelta: UInt64 = 0
    var sentDelta: UInt64 = 0
    for (name, counter) in current {
      guard let previous = previousCounters[name], previous.index == counter.index,
        counter.receivedBytes >= previous.receivedBytes,
        counter.sentBytes >= previous.sentBytes
      else { return zero(activeInterfaceCount: current.count) }
      let (nextReceived, receivedOverflow) = receivedDelta.addingReportingOverflow(
        counter.receivedBytes - previous.receivedBytes)
      let (nextSent, sentOverflow) = sentDelta.addingReportingOverflow(
        counter.sentBytes - previous.sentBytes)
      guard !receivedOverflow, !sentOverflow else {
        return zero(activeInterfaceCount: current.count)
      }
      receivedDelta = nextReceived
      sentDelta = nextSent
    }

    let elapsed = max(now - previousSampleTime, 0.001)
    return NetworkTrafficRate(
      downloadBytesPerSecond: Double(receivedDelta) / elapsed,
      uploadBytesPerSecond: Double(sentDelta) / elapsed,
      activeInterfaceCount: current.count)
  }

  private func zero(activeInterfaceCount: Int) -> NetworkTrafficRate {
    NetworkTrafficRate(
      downloadBytesPerSecond: 0, uploadBytesPerSecond: 0,
      activeInterfaceCount: activeInterfaceCount)
  }
}

public enum NetworkInterfaceTrafficCounterReader {
  // Interface-list size can change between the size query and the data query. Retries and
  // allocation are both bounded; a failed or partial read must reset the sampling baseline.
  private static let maximumBufferBytes = 4 * 1_024 * 1_024
  private static let maximumReadAttempts = 3

  public static func read() -> [NetworkInterfaceTrafficCounters]? {
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    for _ in 0..<maximumReadAttempts {
      var requiredBytes = 0
      guard sysctl(&mib, u_int(mib.count), nil, &requiredBytes, nil, 0) == 0,
        requiredBytes >= 0, requiredBytes <= maximumBufferBytes
      else { return nil }
      if requiredBytes == 0 { return [] }
      var bytes = [UInt8](repeating: 0, count: requiredBytes)
      var actualBytes = requiredBytes
      let result = bytes.withUnsafeMutableBytes { buffer in
        sysctl(&mib, u_int(mib.count), buffer.baseAddress, &actualBytes, nil, 0)
      }
      let readError = errno
      if result != 0 {
        if readError == ENOMEM { continue }
        return nil
      }
      guard actualBytes >= 0, actualBytes <= bytes.count else { return nil }
      return bytes.withUnsafeBytes { buffer in
        decode(
          UnsafeRawBufferPointer(rebasing: buffer.prefix(actualBytes)),
          resolveName: interfaceName)
      }
    }
    return nil
  }

  // Internal for standalone parser fixtures. Routing messages need not be aligned in the
  // buffer; validate their complete extent before loading a native header without alignment.
  static func decode(
    _ bytes: UnsafeRawBufferPointer,
    resolveName: (UInt32) -> String?
  ) -> [NetworkInterfaceTrafficCounters]? {
    var counters: [NetworkInterfaceTrafficCounters] = []
    var names = Set<String>()
    var indexes = Set<UInt32>()
    var offset = 0
    while offset < bytes.count {
      let remaining = bytes.count - offset
      guard remaining >= 4 else { return nil }
      let messageBytes = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
      guard messageBytes >= 4, messageBytes <= remaining,
        bytes[offset + 2] == UInt8(RTM_VERSION)
      else { return nil }
      defer { offset += messageBytes }
      guard bytes[offset + 3] == UInt8(RTM_IFINFO2) else { continue }
      guard messageBytes >= MemoryLayout<if_msghdr2>.size else { return nil }
      let message = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
      let flags = UInt32(bitPattern: message.ifm_flags)
      guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
      let index = UInt32(message.ifm_index)
      guard index > 0, let name = resolveName(index), !name.isEmpty else { return nil }
      guard !name.hasPrefix("lo") else { continue }
      guard names.insert(name).inserted, indexes.insert(index).inserted else { return nil }
      counters.append(
        NetworkInterfaceTrafficCounters(
          index: index, name: name,
          receivedBytes: message.ifm_data.ifi_ibytes,
          sentBytes: message.ifm_data.ifi_obytes))
    }
    return counters
  }

  private static func interfaceName(index: UInt32) -> String? {
    var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
    guard if_indextoname(index, &name) != nil else { return nil }
    let bytes = name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
  }
}
