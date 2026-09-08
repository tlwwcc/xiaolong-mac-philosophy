import Darwin
import Foundation

/// Freeze the old generation before launching its replacement. A delayed name-based kill
/// can otherwise terminate the replacement as well and put both menu helpers in a restart loop.
enum StaleHelperProcessCleanup {
  struct Identity: Equatable, Sendable {
    let pid: pid_t
    let ownerUID: uid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let executablePath: String
  }

  /// Only bounded kernel queries run on the caller; no subprocess or exit wait is needed.
  static func snapshot(executableURL: URL) -> [Identity] {
    guard let resolved = realpath(executableURL.path, nil) else { return [] }
    defer { free(resolved) }
    let expectedPath = String(cString: resolved)
    let requiredBytes = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
    let capacity = min(65_536, Int(max(0, requiredBytes)) / MemoryLayout<pid_t>.size + 256)
    var pids = [pid_t](repeating: 0, count: capacity)
    let bytes = pids.withUnsafeMutableBytes {
      proc_listpids(UInt32(PROC_UID_ONLY), getuid(), $0.baseAddress, Int32($0.count))
    }
    guard bytes > 0, Int(bytes) < capacity * MemoryLayout<pid_t>.size else { return [] }
    return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).compactMap { pid in
      guard let candidate = identity(of: pid), candidate.executablePath == expectedPath else {
        return nil
      }
      return candidate
    }
  }

  static func terminate(_ candidates: [Identity]) {
    for candidate in candidates {
      // Recheck birth time as well as PID/path so a delayed cleanup rejects a reused PID.
      guard identity(of: candidate.pid) == candidate else { continue }
      Darwin.kill(candidate.pid, SIGTERM)
    }
  }

  static func identity(of pid: pid_t) -> Identity? {
    guard pid > 1, pid != getpid(), let before = processInfo(pid), before.pbi_uid == getuid()
    else { return nil }
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
      let after = processInfo(pid),
      before.pbi_uid == after.pbi_uid,
      before.pbi_start_tvsec == after.pbi_start_tvsec,
      before.pbi_start_tvusec == after.pbi_start_tvusec
    else { return nil }
    return Identity(
      pid: pid, ownerUID: after.pbi_uid,
      startSeconds: after.pbi_start_tvsec, startMicroseconds: after.pbi_start_tvusec,
      executablePath: String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
  }

  private static func processInfo(_ pid: pid_t) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
      info.pbi_status != 5  // Zombies can no longer execute.
    else { return nil }
    return info
  }
}
