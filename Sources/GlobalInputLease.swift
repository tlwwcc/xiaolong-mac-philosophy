import Darwin
import Foundation

/// A process-scoped, crash-safe lease for global keyboard and pointer listeners.
///
/// The file contains no user data. `flock` is the source of truth: the kernel releases the lease
/// automatically if an app crashes, so neither build channel can leave a stale owner behind.
final class GlobalInputLease {
  static let sharedDirectoryName = "aixlg-runtime-coordination"
  static let sharedLockFileName = "global-input.lock"

  private let lockURL: URL
  private var lockFileDescriptor: Int32 = -1

  private(set) var isOwned = false
  private(set) var lastFailure = ""

  init(lockURL: URL? = nil) {
    self.lockURL = lockURL ?? Self.defaultLockURL()
  }

  deinit {
    release()
  }

  @discardableResult
  func acquire() -> Bool {
    if isOwned { return true }
    lastFailure = ""

    do {
      try FileManager.default.createDirectory(
        at: lockURL.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } catch {
      lastFailure = "createDirectory:\(error.localizedDescription)"
      return false
    }
    var directoryMetadata = stat()
    guard Darwin.lstat(lockURL.deletingLastPathComponent().path, &directoryMetadata) == 0,
      (directoryMetadata.st_mode & S_IFMT) == S_IFDIR,
      directoryMetadata.st_uid == Darwin.getuid(),
      (directoryMetadata.st_mode & 0o077) == 0
    else {
      lastFailure = "unsafeLockDirectory"
      return false
    }

    let descriptor = Darwin.open(
      lockURL.path,
      O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
      0o600)
    guard descriptor >= 0 else {
      lastFailure = "open:errno=\(errno)"
      return false
    }
    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0,
      (metadata.st_mode & S_IFMT) == S_IFREG,
      metadata.st_uid == Darwin.getuid(),
      (metadata.st_mode & 0o077) == 0
    else {
      lastFailure = "unsafeLockFile"
      Darwin.close(descriptor)
      return false
    }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      lastFailure = "busy"
      Darwin.close(descriptor)
      return false
    }

    lockFileDescriptor = descriptor
    isOwned = true
    return true
  }

  func release() {
    guard lockFileDescriptor >= 0 else {
      isOwned = false
      return
    }
    _ = flock(lockFileDescriptor, LOCK_UN)
    Darwin.close(lockFileDescriptor)
    lockFileDescriptor = -1
    isOwned = false
  }

  private static func defaultLockURL() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent(sharedDirectoryName, isDirectory: true)
      .appendingPathComponent(sharedLockFileName, isDirectory: false)
  }
}
