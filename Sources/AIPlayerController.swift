import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AIPlayerController: ObservableObject {
  private var didReportSuccessfulPlayback = false
  @Published private(set) var items: [AIPlayerMediaItem] = []
  @Published private(set) var libraries: [AIPlayerLibrary] = []
  @Published var selectedFilter: AIPlayerFilter = .recent
  @Published var selectedItemID: String?
  @Published private(set) var playback = AIPlayerPlaybackSnapshot()
  @Published private(set) var statusText = "本机播放器已就绪"
  @Published private(set) var dependencyAvailable = false
  @Published private(set) var extendedMediaAvailable = false
  @Published private(set) var canUndoTrash = false

  private let baseDirectory: URL
  private let store: AIPlayerStore?
  private let playbackEngine: AIPlayerPlaybackEngine
  private let ipc: AIPlayerIPCServer
  private let ipcMainQueueExecutor = AIPlayerIPCMainQueueExecutor()
  private var pollTimer: Timer?
  private var progressSaveCounter = 0
  private var playbackPollInFlight = false
  private var consecutiveSnapshotFailures = 0
  private var playbackGeneration = 0
  private var pendingTrash: (original: URL, trashed: URL)?
  private var undoTrashWorkItem: DispatchWorkItem?
  private var started = false

  init(playbackEngine injectedPlaybackEngine: AIPlayerPlaybackEngine? = nil) {
    baseDirectory = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent(
        AppRuntimeIdentity.current.applicationSupportDirectoryName,
        isDirectory: true
      )
      .appendingPathComponent("player", isDirectory: true)
    try? FileManager.default.createDirectory(
      at: baseDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    store = try? AIPlayerStore(baseDirectory: baseDirectory)
    playbackEngine =
      injectedPlaybackEngine
      ?? AIPlayerPlaybackEngineRouter(baseDirectory: baseDirectory)
    ipc = AIPlayerIPCServer(baseDirectory: baseDirectory)
    dependencyAvailable = playbackEngine.capabilities.commonAudio
    extendedMediaAvailable = playbackEngine.capabilities.extendedMedia
    if store == nil {
      statusText = "播放器历史数据库初始化失败"
    }
  }

  isolated deinit {
    pollTimer?.invalidate()
    undoTrashWorkItem?.cancel()
    ipc.stop()
    playbackEngine.stop()
  }

  func start() {
    guard !started else { return }
    started = true
    reload()
    if store != nil {
      statusText =
        extendedMediaAvailable
        ? "系统原生音频与扩展媒体均已就绪"
        : "系统原生 MP3、M4A、WAV 已就绪"
    }
    do {
      try ipc.start { [weak self] request in
        guard let self else {
          return AIPlayerIPCServer.failureResponse(
            requestID: request["request_id"] as? String,
            message: "播放器已退出。")
        }
        return self.handleIPCFromBackground(request)
      }
    } catch {
      statusText = error.localizedDescription
    }
    pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.pollPlayback() }
    }
  }

  func stop() {
    pollTimer?.invalidate()
    pollTimer = nil
    if let path = playback.path {
      try? store?.updateProgress(
        path: path,
        position: playback.positionSeconds,
        duration: playback.durationSeconds)
    }
    ipc.stop()
    playbackEngine.stop()
    playbackGeneration &+= 1
    playbackPollInFlight = false
    consecutiveSnapshotFailures = 0
    playback = AIPlayerPlaybackSnapshot(volume: playback.volume)
    started = false
  }

  var playbackCapabilityText: String {
    extendedMediaAvailable ? "原生音频 · 扩展媒体已就绪" : "系统原生音频"
  }

  var selectedItem: AIPlayerMediaItem? {
    items.first { $0.id == selectedItemID }
  }

  var playableExtensions: Set<String> {
    var result = AIPlayerPlaybackRoute.nativeAudioExtensions
    if extendedMediaAvailable {
      result.formUnion(AIPlayerFormatting.supportedAudioExtensions)
      result.formUnion(AIPlayerFormatting.supportedVideoExtensions)
    }
    return result
  }

  func canPlay(_ item: AIPlayerMediaItem) -> Bool {
    canPlay(item.url)
  }

  func reload() {
    do {
      libraries = try store?.libraries() ?? []
      switch selectedFilter {
      case .recent, .all:
        items = try store?.history() ?? []
      case .favorites:
        items = try store?.history(favoritesOnly: true) ?? []
      case .library(let id):
        items = try store?.media(inLibrary: id) ?? []
      }
      if let selectedItemID, !items.contains(where: { $0.id == selectedItemID }) {
        self.selectedItemID = nil
      }
    } catch {
      statusText = error.localizedDescription
    }
  }

  func select(_ filter: AIPlayerFilter) {
    selectedFilter = filter
    reload()
  }

  func importFiles() {
    let panel = NSOpenPanel()
    panel.title = "加入小龙哥AI播放器"
    panel.prompt = "加入并播放"
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.allowedContentTypes =
      playableExtensions
      .compactMap { UTType(filenameExtension: $0) }
    guard panel.runModal() == .OK else { return }
    addFiles(panel.urls, playFirst: true)
  }

  func addFiles(_ urls: [URL], playFirst: Bool = false) {
    let valid = urls.compactMap { url -> URL? in
      let standardized = url.standardizedFileURL
      guard AIPlayerFormatting.mediaKind(for: standardized) != nil,
        canPlay(standardized)
      else { return nil }
      return standardized
    }
    guard !valid.isEmpty else {
      statusText =
        extendedMediaAvailable
        ? "没有可加入的受支持媒体文件。"
        : "没有可直接播放的文件；当前支持 MP3、M4A、WAV。"
      return
    }
    do {
      for url in valid {
        try store?.record(url: url)
        if case .library(let id) = selectedFilter {
          try store?.add(path: url.path, toLibrary: id)
        }
      }
      reload()
      statusText = "已加入 \(valid.count) 个媒体文件。"
      if playFirst, let first = valid.first { try play(url: first) }
    } catch {
      statusText = error.localizedDescription
    }
  }

  func play(item: AIPlayerMediaItem) {
    do { try play(url: item.url) } catch { statusText = error.localizedDescription }
  }

  func play(url: URL) throws {
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw AIPlayerError.missingFile(url.path)
    }
    let standardized = url.standardizedFileURL
    guard canPlay(standardized) else {
      if AIPlayerFormatting.mediaKind(for: standardized) != nil {
        throw AIPlayerError.dependencyMissing
      }
      throw AIPlayerError.unsupportedFormat(standardized.pathExtension)
    }
    let savedProgress = try store?.playbackProgress(path: standardized.path)
    let resumePosition = AIPlayerResumePolicy.position(
      lastPosition: savedProgress?.position ?? 0,
      duration: savedProgress?.duration ?? 0)
    try playbackEngine.load(standardized, resumeAt: resumePosition)
    do {
      try store?.record(url: standardized)
    } catch {
      playbackEngine.stop()
      throw error
    }
    playback.path = standardized.path
    playbackGeneration &+= 1
    playbackPollInFlight = false
    consecutiveSnapshotFailures = 0
    playback.playback = "playing"
    playback.positionSeconds = resumePosition
    selectedItemID = AIPlayerFormatting.stableID(for: standardized.path)
    let title = standardized.deletingPathExtension().lastPathComponent
    statusText =
      resumePosition > 0
      ? "从 \(AIPlayerFormatting.duration(resumePosition)) 继续播放：\(title)"
      : "正在播放：\(title)"
    reload()
  }

  func togglePlayback() {
    if playback.playback == "playing" {
      do { try pause() } catch { statusText = error.localizedDescription }
      return
    }
    do {
      if playback.path == nil, let item = selectedItem ?? items.first {
        try play(url: item.url)
      } else {
        try playbackEngine.toggle()
        playback.playback = playback.playback == "playing" ? "paused" : "playing"
      }
    } catch { statusText = error.localizedDescription }
  }

  func pause() throws {
    try playbackEngine.pause()
    playback.playback = "paused"
  }

  func resume() throws {
    try playbackEngine.resume()
    playback.playback = "playing"
  }

  func seek(by seconds: Double) {
    do {
      try playbackEngine.seek(seconds: seconds)
      playback.positionSeconds = max(0, playback.positionSeconds + seconds)
    } catch { statusText = error.localizedDescription }
  }

  func setVolume(_ value: Double) {
    do {
      try playbackEngine.setVolume(value)
      playback.volume = min(max(value, 0), 100)
    } catch { statusText = error.localizedDescription }
  }

  func playPrevious() {
    guard let index = currentIndex, index > items.startIndex else { return }
    play(item: items[index - 1])
  }

  func playNext() {
    guard let index = currentIndex, index + 1 < items.endIndex else { return }
    play(item: items[index + 1])
  }

  func toggleFavorite(_ item: AIPlayerMediaItem) {
    do {
      try store?.setFavorite(path: item.path, isFavorite: !item.isFavorite)
      statusText = item.isFavorite ? "已取消收藏。" : "已收藏。"
      reload()
    } catch { statusText = error.localizedDescription }
  }

  func copyAbsolutePath(_ item: AIPlayerMediaItem) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(item.path, forType: .string)
    statusText = "已复制绝对路径。"
  }

  func reveal(_ item: AIPlayerMediaItem) {
    guard FileManager.default.fileExists(atPath: item.path) else {
      statusText = "文件已不在原位置。"
      return
    }
    NSWorkspace.shared.activateFileViewerSelecting([item.url])
  }

  func removeFromHistory(_ item: AIPlayerMediaItem) {
    do {
      try store?.removeFromHistory(path: item.path)
      statusText = "已从历史移除，原文件未改变。"
      reload()
    } catch { statusText = error.localizedDescription }
  }

  func removeFromSelectedLibrary(_ item: AIPlayerMediaItem) {
    guard case .library(let id) = selectedFilter else { return }
    do {
      try store?.remove(path: item.path, fromLibrary: id)
      statusText = "已从当前媒体库移除，原文件未改变。"
      reload()
    } catch { statusText = error.localizedDescription }
  }

  func moveToTrash(_ item: AIPlayerMediaItem) {
    do {
      let values = try item.url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw AIPlayerError.unsafePath(item.path)
      }
      var resultingURL: NSURL?
      try FileManager.default.trashItem(at: item.url, resultingItemURL: &resultingURL)
      guard let trashedURL = resultingURL as URL? else {
        throw AIPlayerError.operationFailed("系统未返回废纸篓位置。")
      }
      pendingTrash = (item.url, trashedURL)
      canUndoTrash = true
      statusText = "已移到废纸篓，8 秒内可撤销。"
      reload()
      undoTrashWorkItem?.cancel()
      let workItem = DispatchWorkItem { [weak self] in
        self?.pendingTrash = nil
        self?.canUndoTrash = false
      }
      undoTrashWorkItem = workItem
      DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: workItem)
    } catch { statusText = error.localizedDescription }
  }

  func undoTrash() {
    guard let pendingTrash else { return }
    do {
      guard !FileManager.default.fileExists(atPath: pendingTrash.original.path) else {
        throw AIPlayerError.operationFailed("原位置已有同名文件，未覆盖。")
      }
      try FileManager.default.moveItem(at: pendingTrash.trashed, to: pendingTrash.original)
      self.pendingTrash = nil
      canUndoTrash = false
      undoTrashWorkItem?.cancel()
      statusText = "已从废纸篓恢复。"
      reload()
    } catch { statusText = error.localizedDescription }
  }

  func createLibrary(name: String) {
    do {
      let library = try store?.createLibrary(name: name)
      reload()
      if let library { select(.library(library.id)) }
      statusText = "媒体库已创建。"
    } catch { statusText = error.localizedDescription }
  }

  func renameLibrary(_ library: AIPlayerLibrary, name: String) {
    do {
      try store?.renameLibrary(id: library.id, name: name)
      reload()
      statusText = "媒体库已重命名。"
    } catch { statusText = error.localizedDescription }
  }

  func add(_ item: AIPlayerMediaItem, to library: AIPlayerLibrary) {
    do {
      try store?.add(path: item.path, toLibrary: library.id)
      statusText = "已加入“\(library.name)”。"
    } catch { statusText = error.localizedDescription }
  }

  private var currentIndex: Int? {
    guard let path = playback.path else { return nil }
    return items.firstIndex(where: { $0.path == path })
  }

  private func pollPlayback() {
    guard playback.path != nil, !playbackPollInFlight else { return }
    playbackPollInFlight = true
    let generation = playbackGeneration
    let expectedPath = playback.path
    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self else { return }
      let result = Result { try self.playbackEngine.snapshot() }
      DispatchQueue.main.async {
        guard self.playbackGeneration == generation, self.playback.path == expectedPath else {
          return
        }
        self.playbackPollInFlight = false
        switch result {
        case .failure(let error):
          self.consecutiveSnapshotFailures += 1
          self.statusText =
            self.consecutiveSnapshotFailures >= 3
            ? "播放器状态同步失败：\(error.localizedDescription)"
            : "播放器状态同步暂时失败，正在重试…"
          if self.consecutiveSnapshotFailures >= 3 {
            self.playbackEngine.stop()
            self.playbackGeneration &+= 1
            self.playback = AIPlayerPlaybackSnapshot(volume: self.playback.volume)
          }
          return
        case .success(let snapshot):
          self.consecutiveSnapshotFailures = 0
          self.playback = snapshot
          if snapshot.positionSeconds > 0, !self.didReportSuccessfulPlayback {
            self.didReportSuccessfulPlayback = true
          }
        }
        guard case .success(let snapshot) = result else { return }
        self.progressSaveCounter += 1
        if self.progressSaveCounter >= 5, let path = snapshot.path {
          self.progressSaveCounter = 0
          try? self.store?.updateProgress(
            path: path,
            position: snapshot.positionSeconds,
            duration: snapshot.durationSeconds)
        }
      }
    }
  }

  private nonisolated func handleIPCFromBackground(
    _ request: [String: Any]
  ) -> [String: Any] {
    let requestID = request["request_id"] as? String
    return ipcMainQueueExecutor.execute(requestID: requestID) { [weak self] in
      guard let self else {
        return AIPlayerIPCServer.failureResponse(
          requestID: requestID,
          message: "播放器已退出。")
      }
      return self.handleIPC(request)
    }
  }

  private func handleIPC(_ request: [String: Any]) -> [String: Any] {
    let requestID = request["request_id"] as? String
    let command = request["command"] as? String ?? ""
    let arguments = request["args"] as? [String: Any] ?? [:]
    do {
      var data: Any = NSNull()
      switch command {
      case "play":
        guard let path = arguments["path"] as? String else {
          throw AIPlayerError.invalidRequest("play 需要 path。")
        }
        try play(url: URL(fileURLWithPath: path))
      case "pause": try pause()
      case "stop": stop()
      case "undo-trash": undoTrash()
      case "resume": try resume()
      case "toggle": togglePlayback()
      case "seek":
        try playbackEngine.seek(seconds: numeric(arguments["seconds"]))
      case "volume":
        let value = numeric(arguments["value"])
        try playbackEngine.setVolume(value)
        playback.volume = value
      case "status": break
      case "history":
        data = try (store?.history() ?? []).map(mediaDictionary)
      case "library.create":
        guard let name = arguments["name"] as? String else {
          throw AIPlayerError.invalidRequest("library create 需要 name。")
        }
        let library = try store?.createLibrary(name: name)
        reload()
        data = library.map(libraryDictionary) ?? NSNull()
      case "library.rename":
        guard let id = arguments["id"] as? String,
          let name = arguments["name"] as? String
        else { throw AIPlayerError.invalidRequest("library rename 需要 id 和 name。") }
        try store?.renameLibrary(id: id, name: name)
        reload()
      case "library.add":
        guard let id = arguments["id"] as? String,
          let paths = arguments["paths"] as? [String], !paths.isEmpty
        else { throw AIPlayerError.invalidRequest("library add 需要 id 和 paths。") }
        for path in paths {
          let url = URL(fileURLWithPath: path).standardizedFileURL
          guard canPlay(url) else {
            throw AIPlayerFormatting.mediaKind(for: url) == nil
              ? AIPlayerError.unsupportedFormat(url.pathExtension)
              : AIPlayerError.dependencyMissing
          }
          try store?.record(url: url)
          try store?.add(path: url.path, toLibrary: id)
        }
        reload()
      case "reveal":
        guard let path = arguments["path"] as? String else {
          throw AIPlayerError.invalidRequest("reveal 需要 path。")
        }
        let item = try mediaItem(path: path)
        reveal(item)
      case "trash":
        guard (arguments["confirm"] as? Bool) == true,
          let path = arguments["path"] as? String
        else { throw AIPlayerError.invalidRequest("trash 必须传入 --confirm 和 path。") }
        let item = try mediaItem(path: path)
        moveToTrash(item)
        if FileManager.default.fileExists(atPath: path) {
          throw AIPlayerError.operationFailed(statusText)
        }
      default:
        throw AIPlayerError.invalidRequest("未知命令：\(command)")
      }
      let current = playback
      playback = current
      return successResponse(requestID: requestID, state: current, data: data)
    } catch {
      return AIPlayerIPCServer.failureResponse(
        requestID: requestID,
        message: error.localizedDescription)
    }
  }

  private func canPlay(_ url: URL) -> Bool {
    guard AIPlayerFormatting.mediaKind(for: url) != nil else { return false }
    if let router = playbackEngine as? AIPlayerPlaybackEngineRouter {
      return router.supports(url)
    }
    switch AIPlayerPlaybackRoute.resolve(for: url) {
    case .nativeAudio: return playbackEngine.capabilities.commonAudio
    case .mpvFallback: return playbackEngine.capabilities.extendedMedia
    }
  }

  private func successResponse(
    requestID: String?,
    state: AIPlayerPlaybackSnapshot,
    data: Any
  ) -> [String: Any] {
    [
      "ok": true,
      "protocol": 1,
      "request_id": requestID ?? NSNull(),
      "state": [
        "playback": state.playback,
        "path": state.path.map { $0 as Any } ?? NSNull(),
        "position_seconds": state.positionSeconds,
        "duration_seconds": state.durationSeconds,
        "volume": state.volume,
      ],
      "data": data,
    ]
  }

  private func mediaItem(path: String) throws -> AIPlayerMediaItem {
    let standardized = URL(fileURLWithPath: path).standardizedFileURL
    guard let kind = AIPlayerFormatting.mediaKind(for: standardized) else {
      throw AIPlayerError.unsupportedFormat(standardized.pathExtension)
    }
    let known = (try store?.history() ?? []).first { $0.path == standardized.path }
    return known
      ?? AIPlayerMediaItem(
        id: AIPlayerFormatting.stableID(for: standardized.path),
        path: standardized.path,
        name: standardized.deletingPathExtension().lastPathComponent,
        kind: kind,
        format: standardized.pathExtension.uppercased(),
        duration: 0,
        lastPosition: 0,
        lastPlayedAt: Date(),
        isFavorite: false,
        isMissing: !FileManager.default.fileExists(atPath: standardized.path))
  }

  private func numeric(_ value: Any?) -> Double {
    if let value = value as? Double { return value }
    if let value = value as? Int { return Double(value) }
    if let value = value as? NSNumber { return value.doubleValue }
    return 0
  }

  private func mediaDictionary(_ item: AIPlayerMediaItem) -> [String: Any] {
    [
      "id": item.id,
      "path": item.path,
      "name": item.name,
      "kind": item.kind.rawValue,
      "format": item.format,
      "duration_seconds": item.duration,
      "last_position_seconds": item.lastPosition,
      "last_played_at": ISO8601DateFormatter().string(from: item.lastPlayedAt),
      "favorite": item.isFavorite,
      "missing": item.isMissing,
    ]
  }

  private func libraryDictionary(_ library: AIPlayerLibrary) -> [String: Any] {
    ["id": library.id, "name": library.name, "sort_order": library.sortOrder]
  }

}
