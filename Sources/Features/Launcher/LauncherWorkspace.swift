import Combine
import Foundation

/// Owns launcher data, preferences, search and asynchronous scan lifetimes.
/// The host supplies application opening and shortcut priority; this owner never retains AppModel.
@MainActor
final class LauncherWorkspace: ObservableObject {
  typealias Cancellation = @MainActor () -> Void
  typealias ScanScheduler = @MainActor (
    @escaping @Sendable () -> [LauncherApp],
    @escaping @MainActor @Sendable ([LauncherApp]) -> Void
  ) -> Cancellation

  @MainActor
  struct Dependencies {
    var scan: @Sendable ([LauncherApp]) -> [LauncherApp] = {
      AppLauncherScanner.scan(cachedApps: $0)
    }
    var scheduleScan: ScanScheduler = LauncherWorkspace.scheduleInBackground
    var loadIndex: (URL) -> LauncherAppIndex? = AppLauncherScanner.loadIndex
    var saveIndex: ([LauncherApp], URL) -> Void = AppLauncherScanner.saveIndex
    var cachedApps: (LauncherAppIndex) -> [LauncherApp] = AppLauncherScanner.cachedApps
    var shouldRefreshIndex: (LauncherAppIndex?) -> Bool = AppLauncherScanner.shouldRefreshIndex
    var loadHistory: (URL) -> LauncherUsageHistory = LauncherUsageHistory.load
    var saveHistory: (LauncherUsageHistory, URL) -> Void = { $0.save(to: $1) }
    var loadPinned: (URL) -> LauncherPinnedCollection = LauncherPinnedCollection.load
    var savePinned: (LauncherPinnedCollection, URL) -> Void = { $0.save(to: $1) }
    var filter: ([LauncherApp], String, LauncherUsageHistory) -> [LauncherApp] = {
      AppLauncherScanner.filter($0, query: $1, history: $2)
    }
    var now: () -> Date = Date.init
  }

  @Published private(set) var launcherApps: [LauncherApp] = []
  @Published var launcherQuery = ""
  @Published var launcherSearchEngine: LauncherSearchEngine
  @Published private(set) var launcherPinnedRecords: [LauncherPinnedRecord] = []
  @Published private(set) var launcherPinnedStatusText = ""
  @Published private(set) var isLauncherScanning = false
  @Published var launcherDisplayMode: LauncherDisplayMode
  @Published var launcherShowsPinnedNames: Bool
  @Published var launcherPluginEnabled: Bool
  @Published var launcherSelectedResultID: String?
  @Published private(set) var launcherFocusRequestID = 0

  var onStatus: ((String) -> Void)?
  var onHotkeysChanged: (() -> Void)?
  var onPrioritizeApps: (([LauncherApp]) -> [LauncherApp])? {
    didSet { invalidateSearchCache() }
  }

  let launcherIndexURL: URL
  let launcherHistoryURL: URL
  let launcherPinnedURL: URL
  private let defaults: UserDefaults
  private let dependencies: Dependencies
  private(set) var isStopped = false
  private var launcherIndex: LauncherAppIndex?
  private var launcherUsageHistory = LauncherUsageHistory.empty
  private var launcherDataRevision = UUID()
  private var launcherFilterCacheKey = ""
  private var launcherFilterCacheResult: [LauncherApp] = []
  private var scanOwner: UUID?
  private var cancelScan: Cancellation?
  private var scanPerformanceToken: LauncherPerformance.ScanToken?
  private var launcherOpenToken: LauncherPerformance.OpenToken?
  private var launcherOpenDidMarkFirstResults = false
  private var openLearningOwner: UUID?
  private var referenceTransactionOwner: UUID?
  private var canMutateReferences: Bool { !isStopped && referenceTransactionOwner == nil }
  private static let searchEngineKey = "launcherSearchEngineV1"
  private static let displayModeKey = "launcherDisplayModeV1"
  private static let showsPinnedNamesKey = "launcherShowsPinnedNamesV1"
  private static let pluginEnabledKey = "launcherPluginEnabledV1"

  init(
    indexURL: URL, historyURL: URL, pinnedURL: URL, defaults: UserDefaults = .standard,
    dependencies: Dependencies? = nil
  ) {
    launcherIndexURL = indexURL
    launcherHistoryURL = historyURL
    launcherPinnedURL = pinnedURL
    self.defaults = defaults
    self.dependencies = dependencies ?? Dependencies()
    launcherSearchEngine = LauncherSearchEngine(
      rawValue: defaults.string(forKey: Self.searchEngineKey) ?? "") ?? .baidu
    launcherDisplayMode = LauncherDisplayMode(
      rawValue: defaults.string(forKey: Self.displayModeKey)
        ?? LauncherDefaultConfiguration.displayModeRawValue) ?? .icons
    launcherShowsPinnedNames = defaults.object(forKey: Self.showsPinnedNamesKey) == nil
      ? LauncherDefaultConfiguration.showsPinnedNames : defaults.bool(forKey: Self.showsPinnedNamesKey)
    launcherPluginEnabled = defaults.object(forKey: Self.pluginEnabledKey) == nil
      ? true : defaults.bool(forKey: Self.pluginEnabledKey)
  }

  func load() {
    guard !isStopped else { return }
    loadLauncherUsageHistory()
    loadLauncherPinnedItems()
    loadLauncherIndexIfAvailable()
    ensureLauncherAppsReady()
  }

  /// Import refreshes preferences without changing personal index, pins or usage history.
  func loadSettings() {
    guard !isStopped else { return }
    launcherSearchEngine = LauncherSearchEngine(
      rawValue: defaults.string(forKey: Self.searchEngineKey) ?? "") ?? .baidu
    launcherDisplayMode = LauncherDisplayMode(
      rawValue: defaults.string(forKey: Self.displayModeKey)
        ?? LauncherDefaultConfiguration.displayModeRawValue) ?? .icons
    launcherShowsPinnedNames = defaults.object(forKey: Self.showsPinnedNamesKey) == nil
      ? LauncherDefaultConfiguration.showsPinnedNames : defaults.bool(forKey: Self.showsPinnedNamesKey)
    launcherPluginEnabled = defaults.object(forKey: Self.pluginEnabledKey) == nil
      ? true : defaults.bool(forKey: Self.pluginEnabledKey)
  }

  func shutdown() {
    guard !isStopped else { return }
    isStopped = true
    openLearningOwner = nil
    cancelCurrentScan()
    if let token = launcherOpenToken {
      launcherOpenToken = nil
      LauncherPerformance.endOpen(token, resultCount: 0, source: "shutdown")
    }
  }

  /// Keep ordinary history/pin writes out of the same reference transaction as shortcuts.
  /// In-flight learning and scans lose ownership before the transaction snapshots its files.
  func beginReferenceTransaction(ownerID: UUID) -> Bool {
    guard !isStopped, referenceTransactionOwner == nil else { return false }
    referenceTransactionOwner = ownerID
    openLearningOwner = nil
    cancelCurrentScan()
    return !isStopped && referenceTransactionOwner == ownerID
  }

  @discardableResult
  func endReferenceTransaction(ownerID: UUID, completion: () -> Void = {}) -> Bool {
    guard referenceTransactionOwner == ownerID else { return false }
    if !isStopped {
      loadLauncherUsageHistory()
      loadLauncherPinnedItems()
    }
    completion()
    referenceTransactionOwner = nil
    return true
  }

  var filteredLauncherApps: [LauncherApp] {
    let key = "\(launcherDataRevision)#\(launcherQuery)"
    if key == launcherFilterCacheKey { return launcherFilterCacheResult }
    let apps = dependencies.filter(launcherApps, launcherQuery, launcherUsageHistory)
    let result = AppLauncherScanner.normalize(launcherQuery).isEmpty
      ? onPrioritizeApps?(apps) ?? apps : apps
    launcherFilterCacheKey = key
    launcherFilterCacheResult = result
    return result
  }

  var launcherResultApps: [LauncherApp] {
    guard launcherHasEmptyQuery else { return filteredLauncherApps }
    return LauncherPinnedResolver.excludingPinnedApps(filteredLauncherApps, records: launcherPinnedRecords)
  }

  var launcherPinnedItems: [ResolvedLauncherPinnedItem] {
    launcherPinnedRecords.map {
      ResolvedLauncherPinnedItem(record: $0, app: LauncherPinnedResolver.resolve($0, apps: launcherApps))
    }
  }

  var launcherHasEmptyQuery: Bool { AppLauncherScanner.normalize(launcherQuery).isEmpty }
  var launcherCalculatorItem: LauncherUtilityItem? { LauncherCalculator.evaluate(launcherQuery) }
  var launcherUtilityItem: LauncherUtilityItem? {
    if let calculator = launcherCalculatorItem { return calculator }
    if filteredLauncherApps.isEmpty {
      return LauncherWebResolver.destination(for: launcherQuery, searchEngine: launcherSearchEngine)
    }
    return nil
  }

  /// Host shortcut edits change priority even when indexed apps and the query remain identical.
  func invalidateSearchCache() {
    launcherDataRevision = UUID()
    launcherFilterCacheKey = ""
    launcherFilterCacheResult = []
  }

  func matchingLauncherApps(query: String, limit: Int = 20) -> [LauncherApp] {
    if launcherApps.isEmpty, scanOwner == nil { ensureLauncherAppsReady() }
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let apps = query.isEmpty
      ? launcherApps : dependencies.filter(launcherApps, query, launcherUsageHistory)
    return Array(apps.prefix(max(0, limit)))
  }

  func prepareLauncherPresentation() {
    guard !isStopped else { return }
    launcherQuery = ""
    launcherSelectedResultID = nil
    if let token = launcherOpenToken {
      LauncherPerformance.endOpen(token, resultCount: 0, source: "superseded")
    }
    launcherOpenDidMarkFirstResults = false
    launcherOpenToken = LauncherPerformance.beginOpen(
      isWarm: !launcherApps.isEmpty, cachedCount: launcherApps.count)
    launcherFocusRequestID &+= 1
    ensureLauncherAppsReady()
  }

  func markLauncherInteractive() {
    guard !isStopped, let launcherOpenToken else { return }
    LauncherPerformance.markInteractive(launcherOpenToken)
  }

  func markLauncherFirstResultsIfAvailable(source: String) {
    guard !isStopped, !launcherOpenDidMarkFirstResults, let token = launcherOpenToken else { return }
    let count = launcherResultApps.count + (launcherUtilityItem == nil ? 0 : 1)
    guard count > 0 || scanOwner == nil else { return }
    launcherOpenDidMarkFirstResults = true
    launcherOpenToken = nil
    LauncherPerformance.endOpen(token, resultCount: count, source: source)
  }

  func setLauncherSearchEngine(_ engine: LauncherSearchEngine) {
    guard !isStopped else { return }
    launcherSearchEngine = engine
    defaults.set(engine.rawValue, forKey: Self.searchEngineKey)
    announceStatus("启动器网页搜索已切换为 \(engine.title)。")
  }

  func setLauncherDisplayMode(_ mode: LauncherDisplayMode) {
    guard !isStopped, launcherDisplayMode != mode else { return }
    launcherDisplayMode = mode
    defaults.set(mode.rawValue, forKey: Self.displayModeKey)
    LauncherPerformance.markPresentationChange(
      kind: "displayMode", value: mode.rawValue, resultCount: launcherResultApps.count)
  }

  func setLauncherShowsPinnedNames(_ showsNames: Bool) {
    guard !isStopped, launcherShowsPinnedNames != showsNames else { return }
    launcherShowsPinnedNames = showsNames
    defaults.set(showsNames, forKey: Self.showsPinnedNamesKey)
    LauncherPerformance.markPresentationChange(
      kind: "pinnedNames", value: showsNames ? "shown" : "hidden", resultCount: launcherResultApps.count)
  }

  func setLauncherPluginEnabled(_ enabled: Bool) {
    guard !isStopped else { return }
    launcherPluginEnabled = enabled
    defaults.set(enabled, forKey: Self.pluginEnabledKey)
    onHotkeysChanged?()
    announceStatus(
      enabled ? "启动器插件已开启；固定项目、显示偏好和索引保持不变。"
        : "启动器插件已关闭；Caps + Space 已停用，固定项目和设置仍保留。")
  }

  func ensureLauncherAppsReady() {
    guard canMutateReferences else { return }
    if launcherApps.isEmpty { loadLauncherIndexIfAvailable() }
    if launcherApps.isEmpty || dependencies.shouldRefreshIndex(launcherIndex) {
      refreshLauncherApps(force: false)
    }
  }

  func refreshLauncherApps() { refreshLauncherApps(force: true) }

  private func refreshLauncherApps(force: Bool) {
    guard canMutateReferences, scanOwner == nil else { return }
    if !force, !dependencies.shouldRefreshIndex(launcherIndex) { return }
    let owner = UUID()
    scanOwner = owner
    let cachedApps = launcherApps
    isLauncherScanning = cachedApps.isEmpty
    scanPerformanceToken = LauncherPerformance.beginScan(cachedCount: cachedApps.count, forced: force)
    if !cachedApps.isEmpty {
      announceStatus(force ? "正在后台重建启动器索引..." : "正在后台更新启动器索引...")
    }
    guard acceptsScan(owner) else { return }
    let scan = dependencies.scan
    let cancellation = dependencies.scheduleScan({ scan(cachedApps) }) { [weak self] apps in
      self?.receiveScan(apps, owner: owner)
    }
    // A deterministic test scheduler may complete or stop synchronously.
    if acceptsScan(owner) {
      cancelScan = cancellation
    } else {
      cancellation()
    }
  }

  private func acceptsScan(_ owner: UUID) -> Bool { canMutateReferences && scanOwner == owner }

  private func receiveScan(_ apps: [LauncherApp], owner: UUID) {
    guard acceptsScan(owner) else { return }
    // Only this main-actor owner persists results. The background scanner never writes.
    dependencies.saveIndex(apps, launcherIndexURL)
    guard acceptsScan(owner) else { return }
    let index = dependencies.loadIndex(launcherIndexURL)
    guard acceptsScan(owner) else { return }
    launcherIndex = index
    launcherApps = apps
    invalidateSearchCache()
    pruneLauncherUsageHistoryIfNeeded()
    guard acceptsScan(owner) else { return }
    scanOwner = nil
    cancelScan = nil
    isLauncherScanning = false
    if let token = scanPerformanceToken {
      scanPerformanceToken = nil
      LauncherPerformance.endScan(token, resultCount: apps.count)
    }
    announceStatus("启动器结果已更新。")
    markLauncherFirstResultsIfAvailable(source: "refresh")
  }

  private func cancelCurrentScan() {
    scanOwner = nil
    let cancellation = cancelScan
    cancelScan = nil
    isLauncherScanning = false
    if let token = scanPerformanceToken {
      scanPerformanceToken = nil
      LauncherPerformance.endScan(token, resultCount: 0)
    }
    cancellation?()
  }

  func loadLauncherIndexIfAvailable() {
    guard !isStopped, let index = dependencies.loadIndex(launcherIndexURL) else { return }
    let apps = dependencies.cachedApps(index)
    guard !isStopped else { return }
    launcherIndex = index
    guard !apps.isEmpty else { return }
    launcherApps = apps
    invalidateSearchCache()
    pruneLauncherUsageHistoryIfNeeded()
    announceStatus("启动器已载入固定索引 \(apps.count) 个 App。")
  }

  func loadLauncherUsageHistory() {
    guard !isStopped else { return }
    let history = dependencies.loadHistory(launcherHistoryURL)
    guard !isStopped else { return }
    launcherUsageHistory = history
    invalidateSearchCache()
  }

  private func saveLauncherUsageHistory() {
    guard canMutateReferences else { return }
    dependencies.saveHistory(launcherUsageHistory, launcherHistoryURL)
  }

  func loadLauncherPinnedItems() {
    guard !isStopped else { return }
    let collection = dependencies.loadPinned(launcherPinnedURL)
    guard !isStopped else { return }
    var seenIDs = Set<String>()
    launcherPinnedRecords = collection.items.filter {
      !$0.isAIPlayer && !$0.id.isEmpty && seenIDs.insert($0.id).inserted
    }
  }

  private var launcherPinnedCollection: LauncherPinnedCollection {
    LauncherPinnedCollection(version: LauncherPinnedCollection.currentVersion, items: launcherPinnedRecords)
  }

  private func saveLauncherPinnedItems() {
    guard canMutateReferences else { return }
    dependencies.savePinned(launcherPinnedCollection, launcherPinnedURL)
  }

  func isLauncherAppPinned(_ app: LauncherApp) -> Bool {
    launcherPinnedRecords.contains { $0.id == LauncherPinnedRecord.stableAppID(for: app) }
  }

  @discardableResult
  func pinLauncherApp(_ app: LauncherApp) -> Bool {
    guard canMutateReferences else { return false }
    var collection = launcherPinnedCollection
    switch collection.insert(.app(app)) {
    case .alreadyPresent:
      announceLauncherPinnedStatus("\(app.name) 已固定。")
      return true
    case .maximumReached:
      announceLauncherPinnedStatus("最多固定 8 项，请先取消一个。")
      return false
    case .inserted(let position):
      launcherPinnedRecords = collection.items
      saveLauncherPinnedItems()
      announceLauncherPinnedStatus("已固定 \(app.name)，第 \(position) 项。")
      return true
    }
  }

  func unpinLauncherApp(_ app: LauncherApp) {
    unpinLauncherItem(id: LauncherPinnedRecord.stableAppID(for: app))
  }

  func unpinLauncherItem(id: String) {
    guard canMutateReferences else { return }
    var collection = launcherPinnedCollection
    guard let removed = collection.remove(id: id) else { return }
    launcherPinnedRecords = collection.items
    saveLauncherPinnedItems()
    announceLauncherPinnedStatus("已取消固定 \(removed.displayName)。")
  }

  func reportUnavailableLauncherPinnedItem(_ item: ResolvedLauncherPinnedItem) {
    announceLauncherPinnedStatus("\(item.name) 已不可用，可移除固定。")
  }

  func canMoveLauncherPinnedItem(id: String, offset: Int) -> Bool {
    guard let index = launcherPinnedRecords.firstIndex(where: { $0.id == id }) else { return false }
    let (destination, overflow) = index.addingReportingOverflow(offset)
    return !overflow && launcherPinnedRecords.indices.contains(destination)
  }

  func moveLauncherPinnedItem(id: String, offset: Int) {
    guard canMutateReferences, canMoveLauncherPinnedItem(id: id, offset: offset) else { return }
    var collection = launcherPinnedCollection
    guard let destination = collection.move(id: id, offset: offset) else { return }
    launcherPinnedRecords = collection.items
    saveLauncherPinnedItems()
    announceLauncherPinnedStatus("已移动到第 \(destination + 1) 项。")
  }

  func moveLauncherPinnedItem(id: String, before targetID: String) {
    guard canMutateReferences else { return }
    var collection = launcherPinnedCollection
    guard let target = collection.move(id: id, before: targetID) else { return }
    launcherPinnedRecords = collection.items
    saveLauncherPinnedItems()
    announceLauncherPinnedStatus("已移动到第 \(target + 1) 项。")
  }

  private func announceLauncherPinnedStatus(_ message: String) {
    guard !isStopped else { return }
    launcherPinnedStatusText = message
    announceStatus(message)
  }

  func clearLauncherPinnedStatus(ifMatching message: String) {
    guard !isStopped, launcherPinnedStatusText == message else { return }
    launcherPinnedStatusText = ""
  }

  private func announceStatus(_ message: String) {
    guard !isStopped else { return }
    onStatus?(message)
  }

  private func pruneLauncherUsageHistoryIfNeeded() {
    guard canMutateReferences else { return }
    if launcherUsageHistory.pruneUnavailableApps(launcherApps) {
      invalidateSearchCache()
      saveLauncherUsageHistory()
    }
  }

  func beginLauncherOpen() -> UUID? {
    guard canMutateReferences else { return nil }
    let owner = UUID()
    openLearningOwner = owner
    return owner
  }

  func completeLauncherOpen(
    owner: UUID, app: LauncherApp, query: String, succeeded: Bool
  ) {
    guard canMutateReferences, openLearningOwner == owner else { return }
    openLearningOwner = nil
    guard succeeded else {
      announceStatus("无法打开 \(app.name)，未记入使用排序。")
      return
    }
    let openedAt = dependencies.now()
    guard canMutateReferences else { return }
    launcherUsageHistory.recordOpen(app: app, query: query, openedAt: openedAt)
    invalidateSearchCache()
    saveLauncherUsageHistory()
    announceStatus("已切换 \(app.name)。")
  }

  /// Cancels an in-flight scan before it can restore a just-uninstalled app from stale results.
  func reloadReferencesAfterUninstall(targetPath: String) {
    guard !isStopped else { return }
    cancelCurrentScan()
    openLearningOwner = nil
    loadLauncherUsageHistory()
    loadLauncherPinnedItems()
    guard !isStopped else { return }
    let path = URL(fileURLWithPath: targetPath).standardizedFileURL.path
    launcherApps.removeAll { $0.url.standardizedFileURL.path == path }
    invalidateSearchCache()
    dependencies.saveIndex(launcherApps, launcherIndexURL)
    guard !isStopped else { return }
    launcherIndex = dependencies.loadIndex(launcherIndexURL)
  }

  private static func scheduleInBackground(
    scan: @Sendable @escaping () -> [LauncherApp],
    completion: @MainActor @Sendable @escaping ([LauncherApp]) -> Void
  ) -> Cancellation {
    let work = DispatchWorkItem {
      let apps = scan()
      DispatchQueue.main.async { completion(apps) }
    }
    DispatchQueue.global(qos: .userInitiated).async(execute: work)
    return { work.cancel() }
  }
}
