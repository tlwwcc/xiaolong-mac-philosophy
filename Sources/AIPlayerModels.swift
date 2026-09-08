import Foundation

enum AIPlayerMediaKind: String, Codable, CaseIterable {
  case audio
  case video

  var title: String {
    switch self {
    case .audio: return "音频"
    case .video: return "视频"
    }
  }
}

struct AIPlayerMediaItem: Identifiable, Codable, Hashable {
  let id: String
  let path: String
  var name: String
  var kind: AIPlayerMediaKind
  var format: String
  var duration: Double
  var lastPosition: Double
  var lastPlayedAt: Date
  var isFavorite: Bool
  var isMissing: Bool

  var url: URL { URL(fileURLWithPath: path) }

  var durationText: String {
    AIPlayerFormatting.duration(duration)
  }
}

struct AIPlayerLibrary: Identifiable, Codable, Hashable {
  let id: String
  var name: String
  var sortOrder: Int
  var createdAt: Date
}

struct AIPlayerPlaybackSnapshot: Codable, Equatable {
  var playback: String = "stopped"
  var path: String?
  var positionSeconds: Double = 0
  var durationSeconds: Double = 0
  var volume: Double = 70

  enum CodingKeys: String, CodingKey {
    case playback
    case path
    case positionSeconds = "position_seconds"
    case durationSeconds = "duration_seconds"
    case volume
  }
}

enum AIPlayerFilter: Hashable {
  case recent
  case all
  case favorites
  case library(String)

  var id: String {
    switch self {
    case .recent: return "recent"
    case .all: return "all"
    case .favorites: return "favorites"
    case .library(let id): return "library:\(id)"
    }
  }
}

enum AIPlayerFormatting {
  static let supportedAudioExtensions: Set<String> = ["mp3", "m4a", "wav", "flac", "ogg", "opus"]
  static let supportedVideoExtensions: Set<String> = ["mp4", "mov", "mkv"]

  static func mediaKind(for url: URL) -> AIPlayerMediaKind? {
    let ext = url.pathExtension.lowercased()
    if supportedAudioExtensions.contains(ext) { return .audio }
    if supportedVideoExtensions.contains(ext) { return .video }
    return nil
  }

  static func duration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "--:--" }
    let total = Int(seconds.rounded(.down))
    if total >= 3600 {
      return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
    return String(format: "%d:%02d", total / 60, total % 60)
  }

  static func stableID(for path: String) -> String {
    Data(path.utf8).base64EncodedString()
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "=", with: "")
  }
}

enum AIPlayerResumePolicy {
  static let minimumUsefulPosition: Double = 5
  static let restartWindowAtEnd: Double = 10

  static func position(lastPosition: Double, duration: Double) -> Double {
    guard lastPosition.isFinite, lastPosition >= minimumUsefulPosition else { return 0 }
    guard duration.isFinite, duration > 0 else { return lastPosition }
    let clamped = min(lastPosition, duration)
    return duration - clamped <= restartWindowAtEnd ? 0 : clamped
  }
}

enum AIPlayerError: LocalizedError {
  case dependencyMissing
  case unsupportedFormat(String)
  case missingFile(String)
  case unsafePath(String)
  case invalidRequest(String)
  case operationFailed(String)

  var errorDescription: String? {
    switch self {
    case .dependencyMissing:
      return "这个格式暂需扩展播放组件；MP3、M4A、WAV 可以直接播放。"
    case .unsupportedFormat(let value):
      return "暂不支持该媒体格式：\(value)"
    case .missingFile(let path):
      return "文件不存在：\(path)"
    case .unsafePath(let path):
      return "该路径不能执行此操作：\(path)"
    case .invalidRequest(let message), .operationFailed(let message):
      return message
    }
  }
}
