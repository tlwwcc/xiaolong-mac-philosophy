import AppKit
import Combine
import Foundation
import PDFKit

enum PDFWorkBudget {
  static let maximumFileBytes: Int64 = 256 * 1_024 * 1_024
  static let maximumPageCount = 20_000
  static let maximumSearchPageCount = 5_000
  static let maximumSearchQueryBytes = 1_024
  static let maximumPageTextUTF16Units = 1_000_000
  static let maximumTotalSearchTextUTF16Units = 32_000_000
  static let maximumSearchResultCount = 1_000
}

private final class PreparedPDFDocument: @unchecked Sendable {
  let document: PDFDocument
  let pageCount: Int

  init(document: PDFDocument) {
    self.document = document
    pageCount = document.pageCount
  }
}

private enum PDFOpenOutcome: Sendable {
  case ready(PreparedPDFDocument)
  case failed(String)
}

private struct PDFSearchHit: Sendable {
  let pageIndex: Int
  let range: NSRange
}

private struct PDFSearchScan: Sendable {
  let hits: [PDFSearchHit]
  let scannedPages: Int
  let wasLimited: Bool
}

@MainActor
final class PDFViewerModel: ObservableObject {
  @Published private(set) var fileURL: URL?
  @Published private(set) var pageIndex = 0
  @Published private(set) var pageCount = 0
  @Published private(set) var recentDocuments: [RecentPDFDocument] = []
  @Published private(set) var searchResultCount = 0
  @Published private(set) var selectedSearchResult = 0
  @Published private(set) var zoomPercentage = 100
  @Published private(set) var isPresentationMode = false
  @Published private(set) var isSearching = false
  @Published var searchText = ""
  @Published var statusText = "拖入 PDF，或者点“打开”。"
  @Published var errorText: String?

  @Published private(set) var pdfView: BlueprintPDFView

  private let defaults: UserDefaults
  private let recentDocumentsKey: String
  private let readingPositionsKey: String
  private var searchSelections: [PDFSelection] = []
  private var activeSearchDocument: PDFDocument?
  private var activeSearchQuery = ""
  private var searchGeneration = 0
  private var searchTask: Task<Void, Never>?
  private var openGeneration = 0
  private var openTask: Task<Void, Never>?
  private var originalPageRotations: [Int: Int] = [:]
  // NotificationCenter delivers both observers on the main queue. `deinit` is nonisolated in
  // Swift 6, but at that point no actor can still access this instance, so cleanup is safe.
  nonisolated(unsafe) private var pageChangeObserver: NSObjectProtocol?
  nonisolated(unsafe) private var scaleChangeObserver: NSObjectProtocol?
  private var securityScopedURL: URL?
  private var isAccessingSecurityScopedURL = false

  init(
    defaults: UserDefaults,
    recentDocumentsKey: String,
    readingPositionsKey: String
  ) {
    self.defaults = defaults
    self.recentDocumentsKey = recentDocumentsKey
    self.readingPositionsKey = readingPositionsKey
    self.pdfView = Self.makePDFView()
    loadPersistence()
    observePageChanges()
  }

  deinit {
    if let pageChangeObserver {
      NotificationCenter.default.removeObserver(pageChangeObserver)
    }
    if let scaleChangeObserver {
      NotificationCenter.default.removeObserver(scaleChangeObserver)
    }
    searchTask?.cancel()
    openTask?.cancel()
    if isAccessingSecurityScopedURL, let securityScopedURL {
      securityScopedURL.stopAccessingSecurityScopedResource()
    }
  }

  private func observePageChanges() {
    pageChangeObserver = NotificationCenter.default.addObserver(
      forName: .PDFViewPageChanged,
      object: pdfView,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.recordCurrentPage() }
    }
    scaleChangeObserver = NotificationCenter.default.addObserver(
      forName: .PDFViewScaleChanged,
      object: pdfView,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.recordCurrentScale() }
    }
  }

  private func removePageChangeObserver() {
    if let pageChangeObserver {
      NotificationCenter.default.removeObserver(pageChangeObserver)
      self.pageChangeObserver = nil
    }
    if let scaleChangeObserver {
      NotificationCenter.default.removeObserver(scaleChangeObserver)
      self.scaleChangeObserver = nil
    }
  }

  var documentTitle: String {
    fileURL?.deletingPathExtension().lastPathComponent ?? "披卷"
  }

  var pageLabel: String {
    pageCount == 0 ? "— / —" : "\(pageIndex + 1) / \(pageCount)"
  }

  var searchResultLabel: String {
    searchResultCount == 0 ? "0" : "\(selectedSearchResult + 1) / \(searchResultCount)"
  }

  func choosePDF() {
    let panel = NSOpenPanel()
    panel.title = "打开 PDF"
    panel.allowedContentTypes = [.pdf]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    open(url)
  }

  func open(_ url: URL) {
    let standardizedURL = url.standardizedFileURL
    guard PDFFilePolicy.isSupported(standardizedURL) else {
      showError("只能打开 PDF 文件。")
      return
    }
    guard FileManager.default.fileExists(atPath: standardizedURL.path) else {
      removeRecentDocument(at: standardizedURL)
      showError("文件已经移动或删除。")
      return
    }
    // The new document takes ownership before its PDFKit work is queued. A call already inside
    // PDFKit cannot be interrupted cooperatively, but cancelling here stops the old search before
    // it scans any later page and prevents a stale multi-thousand-page scan from delaying open.
    clearSearch()
    openGeneration &+= 1
    let generation = openGeneration
    openTask?.cancel()
    let didStartAccess = standardizedURL.startAccessingSecurityScopedResource()
    statusText = "正在打开 \(standardizedURL.deletingPathExtension().lastPathComponent)…"
    errorText = nil

    openTask = Task { [weak self] in
      let outcome = await PDFSerialWorkGate.shared.run { () -> PDFOpenOutcome in
        guard !Task.isCancelled else { return .failed("已取消打开。") }
        do {
          let values = try standardizedURL.resourceValues(forKeys: [
            .isRegularFileKey, .fileSizeKey,
          ])
          guard values.isRegularFile == true else {
            return .failed("这不是可读取的普通 PDF 文件。")
          }
          let fileBytes = Int64(values.fileSize ?? 0)
          guard fileBytes > 0, fileBytes <= PDFWorkBudget.maximumFileBytes else {
            return .failed("PDF 超过 256 MB 安全上限。")
          }
        } catch {
          return .failed("无法读取 PDF 文件信息。")
        }
        guard !Task.isCancelled, let document = PDFDocument(url: standardizedURL) else {
          return .failed(Task.isCancelled ? "已取消打开。" : "这个 PDF 无法读取，可能已损坏。")
        }
        guard !document.isLocked else {
          return .failed("这个 PDF 受密码保护，当前版本暂不支持解锁。")
        }
        guard document.pageCount > 0 else {
          return .failed("这个 PDF 没有可显示的页面。")
        }
        guard document.pageCount <= PDFWorkBudget.maximumPageCount else {
          return .failed("PDF 超过 20,000 页安全上限。")
        }
        return .ready(PreparedPDFDocument(document: document))
      }
      guard let self else {
        if didStartAccess { standardizedURL.stopAccessingSecurityScopedResource() }
        return
      }
      guard !Task.isCancelled, self.openGeneration == generation else {
        if didStartAccess { standardizedURL.stopAccessingSecurityScopedResource() }
        return
      }
      self.openTask = nil
      switch outcome {
      case .failed(let message):
        if didStartAccess { standardizedURL.stopAccessingSecurityScopedResource() }
        if message != "已取消打开。" { self.showError(message) }
      case .ready(let prepared):
        self.installPreparedDocument(
          prepared,
          url: standardizedURL,
          didStartSecurityScope: didStartAccess)
      }
    }
  }

  private func installPreparedDocument(
    _ prepared: PreparedPDFDocument,
    url: URL,
    didStartSecurityScope: Bool
  ) {
    let document = prepared.document
    recordCurrentPage()
    clearSearch()
    releaseSecurityScopedResource()
    securityScopedURL = url
    isAccessingSecurityScopedURL = didStartSecurityScope
    fileURL = url
    pdfView.document = document
    pageCount = prepared.pageCount
    // Record only pages the user rotates. Walking every page here makes opening a large PDF
    // synchronously O(pageCount) for metadata that is usually never needed.
    originalPageRotations = [:]
    recentDocuments = RecentPDFPolicy.updating(
      recentDocuments,
      with: url,
      bookmarkData: PDFBookmarkPolicy.makeBookmark(for: url))
    saveRecentDocuments()

    let savedIndex = readingPositions().pageIndex(for: url)
    let targetIndex = ReadingPositionPolicy.clampedPageIndex(savedIndex, pageCount: pageCount)
    if let page = document.page(at: targetIndex) {
      pdfView.go(to: page)
    }
    recordCurrentPage()
    pdfView.autoScales = true
    recordCurrentScale()
    statusText = "已打开 \(documentTitle)"
    errorText = nil
    NSDocumentController.shared.noteNewRecentDocumentURL(url)
  }

  func openRecentDocument(_ recentDocument: RecentPDFDocument) {
    if let bookmarkData = recentDocument.bookmarkData,
      let resolution = PDFBookmarkPolicy.resolve(bookmarkData)
    {
      open(resolution.url)
      return
    }
    open(recentDocument.url)
  }

  func closeDocument() {
    openGeneration &+= 1
    openTask?.cancel()
    openTask = nil
    recordCurrentPage()
    clearSearch()
    removePageChangeObserver()
    pdfView = Self.makePDFView()
    observePageChanges()
    fileURL = nil
    pageIndex = 0
    pageCount = 0
    zoomPercentage = 100
    originalPageRotations = [:]
    isPresentationMode = false
    releaseSecurityScopedResource()
    statusText = "拖入 PDF，或者点“打开”。"
  }

  func goToPreviousPage() {
    pdfView.goToPreviousPage(nil)
  }

  func goToNextPage() {
    pdfView.goToNextPage(nil)
  }

  func goToPage(_ oneBasedPage: Int) {
    guard let document = pdfView.document else { return }
    let index = ReadingPositionPolicy.clampedPageIndex(oneBasedPage - 1, pageCount: document.pageCount)
    guard let page = document.page(at: index) else { return }
    pdfView.go(to: page)
  }

  func zoomIn() {
    pdfView.autoScales = false
    pdfView.scaleFactor = PDFZoomPolicy.steppedScale(
      from: pdfView.scaleFactor,
      direction: 1)
    recordCurrentScale()
  }

  func zoomOut() {
    pdfView.autoScales = false
    pdfView.scaleFactor = PDFZoomPolicy.steppedScale(
      from: pdfView.scaleFactor,
      direction: -1)
    recordCurrentScale()
  }

  func fitPage() {
    pdfView.autoScales = true
    recordCurrentScale()
    statusText = "已适合页面"
  }

  func actualSize() {
    pdfView.autoScales = false
    pdfView.scaleFactor = PDFZoomPolicy.actualSizeScale
    recordCurrentScale()
    statusText = "已恢复 100% 实际大小"
  }

  func rotateCurrentPageLeft() {
    guard let document = pdfView.document, let page = pdfView.currentPage else { return }
    rememberOriginalRotation(of: page, in: document)
    page.rotation = PDFRotationPolicy.rotatedLeft(from: page.rotation)
    pdfView.layoutDocumentView()
    statusText = "当前页已向左旋转 90°"
  }

  func rotateCurrentPageRight() {
    guard let document = pdfView.document, let page = pdfView.currentPage else { return }
    rememberOriginalRotation(of: page, in: document)
    page.rotation = PDFRotationPolicy.rotatedRight(from: page.rotation)
    pdfView.layoutDocumentView()
    statusText = "当前页已向右旋转 90°"
  }

  func resetCurrentPageRotation() {
    guard let document = pdfView.document,
      let page = pdfView.currentPage
    else { return }
    let index = document.index(for: page)
    guard let originalRotation = originalPageRotations[index] else {
      statusText = "当前页已是默认方向"
      return
    }
    page.rotation = originalRotation
    pdfView.layoutDocumentView()
    statusText = "当前页已恢复默认方向"
  }

  func enterPresentationMode(toggleSystemFullScreen: Bool = true) {
    guard pageCount > 0, !isPresentationMode else { return }
    isPresentationMode = true
    pdfView.displayMode = .singlePage
    pdfView.displaysPageBreaks = false
    pdfView.autoScales = true
    recordCurrentScale()
    statusText = "投影模式"
    guard toggleSystemFullScreen,
      NSApp.isActive,
      let window = pdfView.window,
      window.isKeyWindow
    else { return }
    DispatchQueue.main.async { [weak window] in
      window?.toggleFullScreen(nil)
    }
  }

  func exitPresentationMode(toggleSystemFullScreen: Bool = true) {
    guard isPresentationMode else { return }
    restoreReadingLayout()
    guard toggleSystemFullScreen,
      let window = pdfView.window,
      window.styleMask.contains(.fullScreen)
    else { return }
    window.toggleFullScreen(nil)
  }

  func handleSystemFullScreenExit() {
    if isPresentationMode {
      restoreReadingLayout()
    }
  }

  func togglePresentationMode(toggleSystemFullScreen: Bool = true) {
    if isPresentationMode {
      exitPresentationMode(toggleSystemFullScreen: toggleSystemFullScreen)
    } else {
      enterPresentationMode(toggleSystemFullScreen: toggleSystemFullScreen)
    }
  }

  func performSearch() {
    guard let displayDocument = pdfView.document, let documentURL = fileURL else { return }
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      clearSearch()
      return
    }
    guard query.utf8.count <= PDFWorkBudget.maximumSearchQueryBytes else {
      clearSearch()
      showError("搜索词过长，请缩短到 1,024 字节以内。")
      return
    }
    clearSearch()
    activeSearchDocument = displayDocument
    activeSearchQuery = query
    isSearching = true
    statusText = "正在搜索“\(query)”…"
    searchGeneration &+= 1
    let generation = searchGeneration
    searchTask = Task { [weak self, weak displayDocument] in
      let scan = await PDFSerialWorkGate.shared.run {
        Self.scanPDF(at: documentURL, query: query)
      }
      guard let self, let displayDocument,
        !Task.isCancelled,
        self.searchGeneration == generation,
        self.activeSearchDocument === displayDocument,
        self.activeSearchQuery == query
      else { return }

      for hit in scan.hits {
        guard !Task.isCancelled,
          self.searchGeneration == generation,
          self.activeSearchDocument === displayDocument else { return }
        if let page = displayDocument.page(at: hit.pageIndex),
           let selection = page.selection(for: hit.range) {
          self.searchSelections.append(selection)
          self.searchResultCount = self.searchSelections.count
          if self.searchSelections.count == 1 {
            self.showSelectedSearchResult()
          }
        }
        if self.searchSelections.count.isMultiple(of: 25) {
          self.statusText = "正在整理“\(query)” · \(self.searchSelections.count) 处"
          await Task.yield()
        }
      }
      guard !Task.isCancelled, self.searchGeneration == generation else { return }
      self.searchTask = nil
      self.isSearching = false
      let limitedSuffix = scan.wasLimited ? "（已到安全扫描上限）" : ""
      self.statusText = self.searchSelections.isEmpty
        ? "没有找到“\(query)”\(limitedSuffix)"
        : "找到 \(self.searchSelections.count) 处\(limitedSuffix)"
    }
  }

  nonisolated private static func scanPDF(at url: URL, query: String) -> PDFSearchScan {
    guard !Task.isCancelled else {
      return PDFSearchScan(hits: [], scannedPages: 0, wasLimited: true)
    }
    let fileBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init)
    guard let fileBytes, fileBytes > 0, fileBytes <= PDFWorkBudget.maximumFileBytes,
      let document = PDFDocument(url: url), !document.isLocked
    else {
      // The displayed file may have been replaced after opening. Reapply the byte gate before a
      // fresh PDFKit parse instead of assuming the original preflight is still current.
      return PDFSearchScan(hits: [], scannedPages: 0, wasLimited: true)
    }
    let pageLimit = min(document.pageCount, PDFWorkBudget.maximumSearchPageCount)
    var hits: [PDFSearchHit] = []
    var totalTextUnits = 0
    var scannedPages = 0
    var wasLimited = document.pageCount > pageLimit
    for index in 0..<pageLimit {
      guard !Task.isCancelled else {
        return PDFSearchScan(hits: [], scannedPages: scannedPages, wasLimited: true)
      }
      guard let page = document.page(at: index), let text = page.string else {
        scannedPages += 1
        continue
      }
      let textUnits = (text as NSString).length
      if textUnits > PDFWorkBudget.maximumPageTextUTF16Units
        || totalTextUnits > PDFWorkBudget.maximumTotalSearchTextUTF16Units - textUnits {
        wasLimited = true
        break
      }
      totalTextUnits += textUnits
      let remaining = PDFWorkBudget.maximumSearchResultCount - hits.count
      guard remaining > 0 else {
        wasLimited = true
        break
      }
      hits.append(contentsOf: PDFTextSearchMatcher.ranges(
        in: text,
        query: query,
        maximumCount: remaining
      ).map { PDFSearchHit(pageIndex: index, range: $0) })
      scannedPages += 1
      if hits.count >= PDFWorkBudget.maximumSearchResultCount {
        wasLimited = true
        break
      }
    }
    return PDFSearchScan(hits: hits, scannedPages: scannedPages, wasLimited: wasLimited)
  }

  func searchTextDidChange() {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard query != activeSearchQuery,
      isSearching || !searchSelections.isEmpty || !activeSearchQuery.isEmpty
    else { return }
    clearSearch()
    statusText = query.isEmpty ? "搜索已清除" : "按回车搜索“\(query)”"
  }

  func selectPreviousSearchResult() {
    guard !searchSelections.isEmpty else { return }
    selectedSearchResult = (selectedSearchResult - 1 + searchSelections.count) % searchSelections.count
    showSelectedSearchResult()
  }

  func selectNextSearchResult() {
    guard !searchSelections.isEmpty else { return }
    selectedSearchResult = (selectedSearchResult + 1) % searchSelections.count
    showSelectedSearchResult()
  }

  func clearSearch() {
    searchGeneration &+= 1
    searchTask?.cancel()
    searchTask = nil
    activeSearchDocument = nil
    activeSearchQuery = ""
    searchSelections = []
    searchResultCount = 0
    selectedSearchResult = 0
    isSearching = false
    pdfView.setCurrentSelection(nil, animate: false)
  }

  private static func makePDFView() -> BlueprintPDFView {
    let pdfView = BlueprintPDFView()
    pdfView.minScaleFactor = PDFZoomPolicy.minimumScale
    pdfView.maxScaleFactor = PDFZoomPolicy.maximumScale
    pdfView.autoScales = true
    pdfView.displayMode = .singlePageContinuous
    pdfView.displayDirection = .vertical
    pdfView.displaysPageBreaks = true
    pdfView.pageBreakMargins = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    pdfView.backgroundColor = NSColor.windowBackgroundColor
    return pdfView
  }

  private func rememberOriginalRotation(of page: PDFPage, in document: PDFDocument) {
    let index = document.index(for: page)
    if originalPageRotations[index] == nil {
      originalPageRotations[index] = PDFRotationPolicy.normalized(page.rotation)
    }
  }

  private func restoreReadingLayout() {
    isPresentationMode = false
    pdfView.displayMode = .singlePageContinuous
    pdfView.displaysPageBreaks = true
    pdfView.autoScales = true
    recordCurrentScale()
    statusText = fileURL == nil ? "拖入 PDF，或者点“打开”。" : "已退出投影模式"
  }

  private func recordCurrentPage() {
    guard let document = pdfView.document,
      let currentPage = pdfView.currentPage,
      let fileURL
    else { return }
    pageIndex = max(0, document.index(for: currentPage))
    pageCount = document.pageCount
    var ledger = readingPositions()
    ledger.setPageIndex(pageIndex, for: fileURL)
    if let data = try? JSONEncoder().encode(ledger) {
      defaults.set(data, forKey: readingPositionsKey)
    }
  }

  private func recordCurrentScale() {
    zoomPercentage = PDFZoomPolicy.percentage(for: pdfView.scaleFactor)
  }

  private func showSelectedSearchResult() {
    guard searchSelections.indices.contains(selectedSearchResult) else {
      pdfView.setCurrentSelection(nil, animate: false)
      return
    }
    let selection = searchSelections[selectedSearchResult]
    pdfView.setCurrentSelection(selection, animate: true)
    pdfView.go(to: selection)
  }

  private func showError(_ message: String) {
    errorText = message
    statusText = message
    NSSound.beep()
  }

  private func loadPersistence() {
    if let data = defaults.data(forKey: recentDocumentsKey),
      let documents = try? JSONDecoder().decode([RecentPDFDocument].self, from: data)
    {
      recentDocuments = Array(documents.prefix(RecentPDFPolicy.maximumCount))
    }
  }

  private func saveRecentDocuments() {
    if let data = try? JSONEncoder().encode(recentDocuments) {
      defaults.set(data, forKey: recentDocumentsKey)
    }
  }

  private func removeRecentDocument(at url: URL) {
    recentDocuments.removeAll { $0.path == url.standardizedFileURL.path }
    saveRecentDocuments()
  }

  private func readingPositions() -> ReadingPositionLedger {
    guard let data = defaults.data(forKey: readingPositionsKey),
      let ledger = try? JSONDecoder().decode(ReadingPositionLedger.self, from: data)
    else { return ReadingPositionLedger() }
    return ledger
  }

  private func releaseSecurityScopedResource() {
    if isAccessingSecurityScopedURL, let securityScopedURL {
      securityScopedURL.stopAccessingSecurityScopedResource()
    }
    securityScopedURL = nil
    isAccessingSecurityScopedURL = false
  }
}
