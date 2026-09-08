import AVFoundation
import Foundation

final class AIPlayerAVFoundationAudioEngine: AIPlayerPlaybackEngine, @unchecked Sendable {
  private let player = AVPlayer()
  private let lock = NSRecursiveLock()
  private var currentURL: URL?
  private var endObserver: NSObjectProtocol?
  private var generation: UInt64 = 0
  private var seekRevision: UInt64 = 0
  private var playing = false
  private var reachedEOF = false
  private var volume = 70.0

  init() {
    player.actionAtItemEnd = .pause
    player.automaticallyWaitsToMinimizeStalling = false
  }

  deinit {
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    player.pause()
  }

  var isAvailable: Bool { true }
  var capabilities: AIPlayerPlaybackCapabilities {
    AIPlayerPlaybackCapabilities(commonAudio: true, extendedMedia: false)
  }
  var requiresMainThreadAccess: Bool { true }

  func load(_ url: URL, resumeAt: Double = 0) throws {
    let url = url.standardizedFileURL
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw AIPlayerError.missingFile(url.path)
    }
    guard AIPlayerPlaybackRoute.resolve(for: url) == .nativeAudio else {
      throw AIPlayerError.unsupportedFormat(url.pathExtension)
    }

    do {
      let audioFile = try AVAudioFile(forReading: url)
      guard audioFile.length > 0, audioFile.fileFormat.channelCount > 0 else {
        throw AIPlayerError.operationFailed("这个音频没有可播放的声音轨道。")
      }
    } catch let error as AIPlayerError {
      throw error
    } catch {
      throw AIPlayerError.operationFailed("系统无法打开这个音频：\(error.localizedDescription)")
    }

    let item = AVPlayerItem(url: url)
    item.audioTimePitchAlgorithm = .timeDomain

    lock.lock()
    generation &+= 1
    seekRevision &+= 1
    let expectedGeneration = generation
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    player.pause()
    player.replaceCurrentItem(with: item)
    player.volume = Float(volume / 100)
    currentURL = url
    playing = true
    reachedEOF = false
    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self, weak item] _ in
      guard let item else { return }
      self?.handleNaturalEnd(item: item, generation: expectedGeneration)
    }
    lock.unlock()

    beginPlayback(at: max(0, resumeAt), generation: expectedGeneration)
  }

  func pause() throws {
    lock.lock()
    playing = false
    player.pause()
    lock.unlock()
  }

  func resume() throws {
    lock.lock()
    guard currentURL != nil else {
      lock.unlock()
      return
    }
    let shouldRestart = reachedEOF
    reachedEOF = false
    playing = true
    let expectedGeneration = generation
    lock.unlock()

    if shouldRestart {
      seek(to: 0, generation: expectedGeneration, resumeAfterSeek: true)
    } else {
      player.play()
    }
  }

  func toggle() throws {
    let shouldPause = lock.withAIPlayerRecursiveLock { playing }
    if shouldPause { try pause() } else { try resume() }
  }

  func seek(seconds: Double) throws {
    lock.lock()
    guard currentURL != nil else {
      lock.unlock()
      return
    }
    let current = finiteSeconds(player.currentTime().seconds)
    let duration = finiteSeconds(player.currentItem?.duration.seconds)
    let target = min(max(current + seconds, 0), duration > 0 ? duration : .greatestFiniteMagnitude)
    reachedEOF = false
    let shouldResume = playing
    let expectedGeneration = generation
    lock.unlock()
    seek(to: target, generation: expectedGeneration, resumeAfterSeek: shouldResume)
  }

  func setVolume(_ value: Double) throws {
    lock.lock()
    volume = min(max(value, 0), 100)
    player.volume = Float(volume / 100)
    lock.unlock()
  }

  func snapshot() throws -> AIPlayerPlaybackSnapshot {
    lock.lock()
    let url = currentURL
    let isPlaying = playing
    let currentVolume = volume
    let position = finiteSeconds(player.currentTime().seconds)
    let duration = finiteSeconds(player.currentItem?.duration.seconds)
    let failure = player.currentItem?.error
    lock.unlock()

    if let failure {
      throw AIPlayerError.operationFailed("系统无法播放这个音频：\(failure.localizedDescription)")
    }
    return AIPlayerPlaybackSnapshot(
      playback: url == nil ? "stopped" : (isPlaying ? "playing" : "paused"),
      path: url?.path,
      positionSeconds: position,
      durationSeconds: duration,
      volume: currentVolume
    )
  }

  func stop() {
    lock.lock()
    generation &+= 1
    seekRevision &+= 1
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    endObserver = nil
    player.pause()
    player.replaceCurrentItem(with: nil)
    currentURL = nil
    playing = false
    reachedEOF = false
    lock.unlock()
  }

  private func beginPlayback(at seconds: Double, generation: UInt64) {
    if seconds > 0 {
      seek(to: seconds, generation: generation, resumeAfterSeek: true)
    } else {
      player.play()
    }
  }

  private func seek(to seconds: Double, generation: UInt64, resumeAfterSeek: Bool) {
    let expectedSeekRevision = lock.withAIPlayerRecursiveLock {
      seekRevision &+= 1
      return seekRevision
    }
    let time = CMTime(seconds: seconds, preferredTimescale: 600)
    player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
      guard finished, let self else { return }
      let shouldResume = self.lock.withAIPlayerRecursiveLock {
        self.generation == generation
          && self.seekRevision == expectedSeekRevision
          && self.currentURL != nil
          && self.playing
          && resumeAfterSeek
      }
      if shouldResume { self.player.play() }
    }
  }

  private func handleNaturalEnd(item: AVPlayerItem, generation: UInt64) {
    lock.lock()
    guard self.generation == generation, player.currentItem === item, currentURL != nil else {
      lock.unlock()
      return
    }
    playing = false
    reachedEOF = true
    lock.unlock()
  }

  private func finiteSeconds(_ value: Double?) -> Double {
    guard let value, value.isFinite, value > 0 else { return 0 }
    return value
  }
}

extension NSRecursiveLock {
  fileprivate func withAIPlayerRecursiveLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
