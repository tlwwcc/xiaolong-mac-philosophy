import Foundation

struct AIPlayerPlaybackCapabilities: Equatable {
  let commonAudio: Bool
  let extendedMedia: Bool
}

protocol AIPlayerPlaybackEngine: AnyObject, Sendable {
  var isAvailable: Bool { get }
  var capabilities: AIPlayerPlaybackCapabilities { get }
  var requiresMainThreadAccess: Bool { get }

  func load(_ url: URL, resumeAt: Double) throws
  func pause() throws
  func resume() throws
  func toggle() throws
  func seek(seconds: Double) throws
  func setVolume(_ value: Double) throws
  func snapshot() throws -> AIPlayerPlaybackSnapshot
  func stop()
}

enum AIPlayerPlaybackRoute: String, Equatable {
  case nativeAudio = "native-audio"
  case mpvFallback = "mpv-fallback"

  static let nativeAudioExtensions: Set<String> = ["mp3", "m4a", "wav"]

  static func resolve(for url: URL) -> Self {
    nativeAudioExtensions.contains(url.pathExtension.lowercased())
      ? .nativeAudio
      : .mpvFallback
  }
}

/// 常见音频永远使用 macOS 原生播放；mpv 只作为扩展格式与视频的可选后端。
/// 新电脑没有 Homebrew / mpv 时，播放器核心能力仍然完整可用。
final class AIPlayerPlaybackEngineRouter: AIPlayerPlaybackEngine, @unchecked Sendable {
  private let nativeAudioEngine: AIPlayerPlaybackEngine
  private let fallbackEngine: AIPlayerPlaybackEngine
  private let lock = NSLock()
  private var activeEngine: AIPlayerPlaybackEngine?
  private(set) var activeRoute: AIPlayerPlaybackRoute?
  private var volume = 70.0

  init(
    nativeAudioEngine: AIPlayerPlaybackEngine,
    fallbackEngine: AIPlayerPlaybackEngine
  ) {
    self.nativeAudioEngine = nativeAudioEngine
    self.fallbackEngine = fallbackEngine
  }

  convenience init(baseDirectory: URL) {
    self.init(
      nativeAudioEngine: AIPlayerAVFoundationAudioEngine(),
      fallbackEngine: AIPlayerMPV(baseDirectory: baseDirectory)
    )
  }

  var isAvailable: Bool { nativeAudioEngine.isAvailable }

  var capabilities: AIPlayerPlaybackCapabilities {
    AIPlayerPlaybackCapabilities(
      commonAudio: nativeAudioEngine.isAvailable,
      extendedMedia: fallbackEngine.isAvailable
    )
  }

  func supports(_ url: URL) -> Bool {
    switch AIPlayerPlaybackRoute.resolve(for: url) {
    case .nativeAudio:
      return nativeAudioEngine.isAvailable
    case .mpvFallback:
      return fallbackEngine.isAvailable
    }
  }

  var requiresMainThreadAccess: Bool {
    lock.withAIPlayerLock { activeEngine?.requiresMainThreadAccess ?? true }
  }

  func load(_ url: URL, resumeAt: Double = 0) throws {
    let route = AIPlayerPlaybackRoute.resolve(for: url)
    let target = route == .nativeAudio ? nativeAudioEngine : fallbackEngine
    let previous = lock.withAIPlayerLock {
      let previous = activeEngine
      activeEngine = nil
      activeRoute = nil
      return previous
    }

    if let previous, ObjectIdentifier(previous) != ObjectIdentifier(target) {
      previous.stop()
    }

    do {
      try target.setVolume(lock.withAIPlayerLock { volume })
      try target.load(url, resumeAt: resumeAt)
    } catch {
      target.stop()
      throw error
    }

    lock.withAIPlayerLock {
      activeEngine = target
      activeRoute = route
    }
  }

  func pause() throws { try lock.withAIPlayerLock { activeEngine }?.pause() }
  func resume() throws { try lock.withAIPlayerLock { activeEngine }?.resume() }
  func toggle() throws { try lock.withAIPlayerLock { activeEngine }?.toggle() }
  func seek(seconds: Double) throws {
    try lock.withAIPlayerLock { activeEngine }?.seek(seconds: seconds)
  }

  func setVolume(_ value: Double) throws {
    let value = min(max(value, 0), 100)
    let active = lock.withAIPlayerLock {
      volume = value
      return activeEngine
    }
    try active?.setVolume(value)
  }

  func snapshot() throws -> AIPlayerPlaybackSnapshot {
    let state = lock.withAIPlayerLock { (activeEngine, volume) }
    guard let active = state.0 else {
      return AIPlayerPlaybackSnapshot(volume: state.1)
    }
    var snapshot: AIPlayerPlaybackSnapshot
    if active.requiresMainThreadAccess, !Thread.isMainThread {
      snapshot = try DispatchQueue.main.sync { try active.snapshot() }
    } else {
      snapshot = try active.snapshot()
    }
    snapshot.volume = state.1
    return snapshot
  }

  func stop() {
    nativeAudioEngine.stop()
    fallbackEngine.stop()
    lock.withAIPlayerLock {
      activeEngine = nil
      activeRoute = nil
    }
  }
}

extension NSLock {
  fileprivate func withAIPlayerLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
