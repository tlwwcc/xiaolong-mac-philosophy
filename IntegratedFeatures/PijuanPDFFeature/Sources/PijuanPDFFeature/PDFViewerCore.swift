import Foundation

struct RecentPDFDocument: Codable, Equatable, Identifiable {
  let path: String
  var displayName: String
  var openedAt: Date
  var bookmarkData: Data?

  var id: String { path }
  var url: URL { URL(fileURLWithPath: path) }
}

struct PDFBookmarkResolution: Equatable {
  let url: URL
  let isStale: Bool
}

enum PDFBookmarkPolicy {
  static func makeBookmark(for url: URL) -> Data? {
    try? url.standardizedFileURL.bookmarkData(
      options: .withSecurityScope,
      includingResourceValuesForKeys: nil,
      relativeTo: nil)
  }

  static func resolve(_ data: Data) -> PDFBookmarkResolution? {
    var isStale = false
    guard let url = try? URL(
      resolvingBookmarkData: data,
      options: [.withSecurityScope, .withoutUI],
      relativeTo: nil,
      bookmarkDataIsStale: &isStale)
    else { return nil }
    return PDFBookmarkResolution(url: url.standardizedFileURL, isStale: isStale)
  }
}

enum PDFFilePolicy {
  static func isSupported(_ url: URL) -> Bool {
    url.isFileURL && url.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame
  }
}

enum RecentPDFPolicy {
  static let maximumCount = 10

  static func updating(
    _ documents: [RecentPDFDocument],
    with url: URL,
    bookmarkData: Data? = nil,
    openedAt: Date = Date(),
    maximumCount: Int = maximumCount
  ) -> [RecentPDFDocument] {
    let standardizedURL = url.standardizedFileURL
    let existing = documents.first {
      URL(fileURLWithPath: $0.path).standardizedFileURL.path == standardizedURL.path
    }
    let next = RecentPDFDocument(
      path: standardizedURL.path,
      displayName: standardizedURL.deletingPathExtension().lastPathComponent,
      openedAt: openedAt,
      bookmarkData: bookmarkData ?? existing?.bookmarkData)
    let remaining = documents.filter {
      URL(fileURLWithPath: $0.path).standardizedFileURL.path != standardizedURL.path
    }
    return Array(([next] + remaining).prefix(max(0, maximumCount)))
  }
}

enum ReadingPositionPolicy {
  static func clampedPageIndex(_ savedIndex: Int?, pageCount: Int) -> Int {
    guard pageCount > 0 else { return 0 }
    return min(max(savedIndex ?? 0, 0), pageCount - 1)
  }
}

struct ReadingPositionLedger: Codable, Equatable {
  var pageIndexByPath: [String: Int] = [:]

  func pageIndex(for url: URL) -> Int? {
    pageIndexByPath[url.standardizedFileURL.path]
  }

  mutating func setPageIndex(_ pageIndex: Int, for url: URL) {
    pageIndexByPath[url.standardizedFileURL.path] = max(0, pageIndex)
  }
}

enum PDFZoomPolicy {
  static let minimumScale: CGFloat = 0.10
  static let maximumScale: CGFloat = 8.00
  static let actualSizeScale: CGFloat = 1.00
  static let buttonStepMultiplier: CGFloat = 1.12
  static let preciseScrollSensitivity: CGFloat = 0.003
  static let wheelScrollSensitivity: CGFloat = 0.045
  static let magnificationSensitivity: CGFloat = 0.35

  static func scale(
    from currentScale: CGFloat,
    scrollingDeltaY: CGFloat,
    hasPreciseDeltas: Bool
  ) -> CGFloat {
    guard scrollingDeltaY != 0 else {
      return min(max(currentScale, minimumScale), maximumScale)
    }
    let exponent =
      scrollingDeltaY
      * (hasPreciseDeltas ? preciseScrollSensitivity : wheelScrollSensitivity)
    let proposedScale = currentScale * exp(exponent)
    return min(max(proposedScale, minimumScale), maximumScale)
  }

  static func scale(from currentScale: CGFloat, magnification: CGFloat) -> CGFloat {
    let proposedScale = currentScale * exp(magnification * magnificationSensitivity)
    return min(max(proposedScale, minimumScale), maximumScale)
  }

  static func steppedScale(from currentScale: CGFloat, direction: Int) -> CGFloat {
    guard direction != 0 else {
      return min(max(currentScale, minimumScale), maximumScale)
    }
    let multiplier =
      direction > 0 ? buttonStepMultiplier : 1 / buttonStepMultiplier
    return min(max(currentScale * multiplier, minimumScale), maximumScale)
  }

  static func percentage(for scale: CGFloat) -> Int {
    Int((scale * 100).rounded())
  }
}

enum PDFScrollGesturePolicy {
  static func shouldZoom(
    hasPreciseDeltas: Bool,
    optionKeyDown: Bool
  ) -> Bool {
    !hasPreciseDeltas || optionKeyDown
  }
}

enum PDFApplicationVersion {
  static func displayText(version: String?, build: String?) -> String {
    let resolvedVersion = version.flatMap { $0.isEmpty ? nil : $0 } ?? "开发版"
    guard let resolvedBuild = build.flatMap({ $0.isEmpty ? nil : $0 }) else {
      return "版本 \(resolvedVersion)"
    }
    return "版本 \(resolvedVersion)（\(resolvedBuild)）"
  }
}

enum PDFRotationPolicy {
  static func normalized(_ degrees: Int) -> Int {
    let remainder = degrees % 360
    return remainder >= 0 ? remainder : remainder + 360
  }

  static func rotatedLeft(from degrees: Int) -> Int {
    normalized(degrees - 90)
  }

  static func rotatedRight(from degrees: Int) -> Int {
    normalized(degrees + 90)
  }
}

enum PDFViewerShortcutAction: String, CaseIterable, Codable, Hashable {
  case previousPage
  case nextPage
  case zoomOut
  case zoomIn
  case actualSize
  case fitPage
  case rotateLeft
  case rotateRight
  case resetRotation
  case togglePresentation
}

extension PDFViewerShortcutAction {
  var displayName: String {
    switch self {
    case .previousPage: return "上一页"
    case .nextPage: return "下一页"
    case .zoomOut: return "缩小"
    case .zoomIn: return "放大"
    case .actualSize: return "100% 实际大小"
    case .fitPage: return "适合页面"
    case .rotateLeft: return "向左旋转"
    case .rotateRight: return "向右旋转"
    case .resetRotation: return "恢复原始方向"
    case .togglePresentation: return "进入 / 退出投影"
    }
  }

  var categoryName: String {
    switch self {
    case .previousPage, .nextPage: return "翻页"
    case .zoomOut, .zoomIn, .actualSize, .fitPage: return "查看"
    case .rotateLeft, .rotateRight, .resetRotation: return "旋转"
    case .togglePresentation: return "演示"
    }
  }
}

struct PDFViewerShortcutModifiers: OptionSet, Codable, Hashable {
  let rawValue: Int

  static let control = Self(rawValue: 1 << 0)
  static let option = Self(rawValue: 1 << 1)
  static let shift = Self(rawValue: 1 << 2)
  static let command = Self(rawValue: 1 << 3)
  static let supported: Self = [.control, .option, .shift, .command]
  static let primary: Self = [.control, .option, .command]

  init(rawValue: Int) {
    self.rawValue = rawValue
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.init(rawValue: try container.decode(Int.self))
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  var displayText: String {
    var result = ""
    if contains(.control) { result += "⌃" }
    if contains(.option) { result += "⌥" }
    if contains(.shift) { result += "⇧" }
    if contains(.command) { result += "⌘" }
    return result
  }
}

struct PDFViewerShortcutKey: RawRepresentable, Codable, Hashable {
  let rawValue: String

  init(rawValue: String) {
    if rawValue.unicodeScalars.count == 1,
      let scalar = rawValue.unicodeScalars.first,
      (65...90).contains(Int(scalar.value))
    {
      self.rawValue = rawValue.lowercased()
    } else {
      self.rawValue = rawValue
    }
  }

  init(_ character: Character) {
    self.init(rawValue: String(character))
  }

  static let leftBracket = Self(rawValue: "[")
  static let rightBracket = Self(rawValue: "]")
  static let minus = Self(rawValue: "-")
  static let equal = Self(rawValue: "=")
  static let upArrow = Self(rawValue: "\u{F700}")
  static let downArrow = Self(rawValue: "\u{F701}")
  static let leftArrow = Self(rawValue: "\u{F702}")
  static let rightArrow = Self(rawValue: "\u{F703}")
  static let zero = Self(rawValue: "0")
  static let letterF = Self(rawValue: "f")

  var isSupported: Bool {
    guard rawValue.count == 1 else { return false }
    if Self.specialDisplayText[rawValue] != nil { return true }
    guard let scalar = rawValue.unicodeScalars.first,
      rawValue.unicodeScalars.count == 1
    else { return false }
    return (32...126).contains(Int(scalar.value))
  }

  var displayText: String {
    if let special = Self.specialDisplayText[rawValue] { return special }
    if rawValue == "-" { return "−" }
    return rawValue.uppercased()
  }

  private static let specialDisplayText: [String: String] = [
    "\u{F700}": "↑",
    "\u{F701}": "↓",
    "\u{F702}": "←",
    "\u{F703}": "→",
    "\u{F704}": "F1",
    "\u{F705}": "F2",
    "\u{F706}": "F3",
    "\u{F707}": "F4",
    "\u{F708}": "F5",
    "\u{F709}": "F6",
    "\u{F70A}": "F7",
    "\u{F70B}": "F8",
    "\u{F70C}": "F9",
    "\u{F70D}": "F10",
    "\u{F70E}": "F11",
    "\u{F70F}": "F12",
    "\r": "Return",
    "\t": "Tab",
    " ": "Space",
    "\u{7F}": "Delete",
  ]
}

struct PDFViewerShortcut: Codable, Equatable, Hashable {
  let key: PDFViewerShortcutKey
  let modifiers: PDFViewerShortcutModifiers

  var displayText: String {
    modifiers.displayText + key.displayText
  }
}

struct PDFViewerShortcutSpec: Equatable {
  let action: PDFViewerShortcutAction
  let shortcut: PDFViewerShortcut

  var key: PDFViewerShortcutKey { shortcut.key }
  var displayText: String { shortcut.displayText }
}

enum PDFViewerShortcutPolicy {
  static let ordered: [PDFViewerShortcutSpec] = [
    .init(action: .previousPage, shortcut: .init(key: .leftBracket, modifiers: .option)),
    .init(action: .nextPage, shortcut: .init(key: .rightBracket, modifiers: .option)),
    .init(action: .zoomOut, shortcut: .init(key: .minus, modifiers: .option)),
    .init(action: .zoomIn, shortcut: .init(key: .equal, modifiers: .option)),
    .init(action: .actualSize, shortcut: .init(key: .upArrow, modifiers: .option)),
    .init(action: .fitPage, shortcut: .init(key: .downArrow, modifiers: .option)),
    .init(action: .rotateLeft, shortcut: .init(key: .leftArrow, modifiers: .option)),
    .init(action: .rotateRight, shortcut: .init(key: .rightArrow, modifiers: .option)),
    .init(action: .resetRotation, shortcut: .init(key: .zero, modifiers: .option)),
    .init(action: .togglePresentation, shortcut: .init(key: .letterF, modifiers: .option)),
  ]

  static func shortcut(for action: PDFViewerShortcutAction) -> PDFViewerShortcutSpec {
    guard let shortcut = ordered.first(where: { $0.action == action }) else {
      preconditionFailure("缺少 PDF 查看器快捷键：\(action.rawValue)")
    }
    return shortcut
  }

  static func defaultShortcut(for action: PDFViewerShortcutAction) -> PDFViewerShortcut {
    shortcut(for: action).shortcut
  }

  static func validationError(
    for candidate: PDFViewerShortcut,
    action: PDFViewerShortcutAction,
    configuration: PDFViewerShortcutConfiguration
  ) -> PDFViewerShortcutValidationError? {
    if let error = basicValidationError(for: candidate) { return error }
    if let duplicate = PDFViewerShortcutAction.allCases.first(where: {
      $0 != action && configuration.activeShortcut(for: $0) == candidate
    }) {
      return .duplicate(duplicate)
    }
    return nil
  }

  static func basicValidationError(
    for candidate: PDFViewerShortcut
  ) -> PDFViewerShortcutValidationError? {
    guard candidate.key.isSupported else { return .unsupportedKey }
    guard candidate.modifiers.subtracting(.supported).isEmpty else {
      return .unsupportedModifier
    }
    guard !candidate.modifiers.intersection(.primary).isEmpty else {
      return .missingPrimaryModifier
    }
    if isReserved(candidate) { return .reserved }
    return nil
  }

  private static func isReserved(_ shortcut: PDFViewerShortcut) -> Bool {
    let commandOnly = PDFViewerShortcutModifiers.command
    let commandShift = PDFViewerShortcutModifiers.command.union(.shift)
    let commandOption = PDFViewerShortcutModifiers.command.union(.option)
    let commandControl = PDFViewerShortcutModifiers.command.union(.control)

    if shortcut.modifiers == commandOnly,
      ["a", "c", "f", "h", "m", "o", "q", "v", "w", "x", "z", ",", "`", " ", "\t"]
        .contains(shortcut.key.rawValue)
    {
      return true
    }
    if shortcut.modifiers == commandShift,
      ["/", "3", "4", "5", "`", "w", "z"].contains(shortcut.key.rawValue)
    {
      return true
    }
    if shortcut.modifiers == commandOption,
      ["d", "h"].contains(shortcut.key.rawValue)
    {
      return true
    }
    if shortcut.modifiers == commandControl,
      ["f", "q"].contains(shortcut.key.rawValue)
    {
      return true
    }
    if shortcut.modifiers == .control,
      [" ", PDFViewerShortcutKey.upArrow.rawValue, PDFViewerShortcutKey.downArrow.rawValue,
       PDFViewerShortcutKey.leftArrow.rawValue, PDFViewerShortcutKey.rightArrow.rawValue]
        .contains(shortcut.key.rawValue)
    {
      return true
    }
    return false
  }
}

enum PDFViewerShortcutValidationError: Error, Equatable, LocalizedError {
  case unsupportedKey
  case unsupportedModifier
  case missingPrimaryModifier
  case reserved
  case duplicate(PDFViewerShortcutAction)

  var errorDescription: String? {
    switch self {
    case .unsupportedKey:
      return "这个按键暂不支持，请使用字母、数字、常用符号、方向键或 F1–F12。"
    case .unsupportedModifier:
      return "这个修饰键组合暂不支持。"
    case .missingPrimaryModifier:
      return "请至少按住 ⌘、⌥ 或 ⌃ 中的一个，避免影响正常输入。"
    case .reserved:
      return "这个组合已被应用或 macOS 常用功能占用。"
    case .duplicate(let action):
      return "这个组合已经用于“\(action.displayName)”。"
    }
  }
}

struct PDFViewerShortcutConfiguration: Codable, Equatable {
  private(set) var overrides: [String: PDFViewerShortcut]
  private(set) var deletedActionIDs: Set<String>

  init(
    overrides: [String: PDFViewerShortcut] = [:],
    deletedActionIDs: Set<String> = []
  ) {
    self.overrides = overrides
    self.deletedActionIDs = deletedActionIDs
  }

  func shortcut(for action: PDFViewerShortcutAction) -> PDFViewerShortcut {
    overrides[action.rawValue] ?? PDFViewerShortcutPolicy.defaultShortcut(for: action)
  }

  func activeShortcut(for action: PDFViewerShortcutAction) -> PDFViewerShortcut? {
    isDeleted(action) ? nil : shortcut(for: action)
  }

  func isDeleted(_ action: PDFViewerShortcutAction) -> Bool {
    deletedActionIDs.contains(action.rawValue)
  }

  func setting(
    _ shortcut: PDFViewerShortcut,
    for action: PDFViewerShortcutAction
  ) throws -> Self {
    if let error = PDFViewerShortcutPolicy.validationError(
      for: shortcut,
      action: action,
      configuration: self)
    {
      throw error
    }
    var next = self
    next.deletedActionIDs.remove(action.rawValue)
    if shortcut == PDFViewerShortcutPolicy.defaultShortcut(for: action) {
      next.overrides.removeValue(forKey: action.rawValue)
    } else {
      next.overrides[action.rawValue] = shortcut
    }
    return next
  }

  func resetting(_ action: PDFViewerShortcutAction) throws -> Self {
    try setting(PDFViewerShortcutPolicy.defaultShortcut(for: action), for: action)
  }

  func deleting(_ action: PDFViewerShortcutAction) -> Self {
    var next = self
    next.overrides.removeValue(forKey: action.rawValue)
    next.deletedActionIDs.insert(action.rawValue)
    return next
  }

  func restoringDeleted(_ action: PDFViewerShortcutAction) -> Self {
    var next = self
    next.overrides.removeValue(forKey: action.rawValue)
    next.deletedActionIDs.remove(action.rawValue)
    return next
  }

  func restoringAllDeleted() -> Self {
    var next = self
    for actionID in next.deletedActionIDs {
      next.overrides.removeValue(forKey: actionID)
    }
    next.deletedActionIDs.removeAll()
    return next
  }

  func sanitized() -> Self {
    let knownActions = Set(PDFViewerShortcutAction.allCases.map(\.rawValue))
    var accepted = overrides.filter { knownActions.contains($0.key) }
    let acceptedDeleted = deletedActionIDs.intersection(knownActions)
    for actionID in acceptedDeleted {
      accepted.removeValue(forKey: actionID)
    }
    for action in PDFViewerShortcutAction.allCases {
      guard let shortcut = accepted[action.rawValue] else { continue }
      if shortcut == PDFViewerShortcutPolicy.defaultShortcut(for: action)
        || PDFViewerShortcutPolicy.basicValidationError(for: shortcut) != nil
      {
        accepted.removeValue(forKey: action.rawValue)
      }
    }

    while true {
      let candidate = Self(overrides: accepted, deletedActionIDs: acceptedDeleted)
      let actions = PDFViewerShortcutAction.allCases.filter { !candidate.isDeleted($0) }
      guard let conflictShortcut = actions.lazy.compactMap(candidate.activeShortcut(for:)).first(where: {
        shortcut in actions.filter { candidate.activeShortcut(for: $0) == shortcut }.count > 1
      }) else {
        return candidate
      }
      let conflictingActions = actions.filter {
        candidate.activeShortcut(for: $0) == conflictShortcut
      }
      let owner = conflictingActions.first(where: {
        PDFViewerShortcutPolicy.defaultShortcut(for: $0) == conflictShortcut
      }) ?? conflictingActions[0]
      var removedOverride = false
      for action in conflictingActions where action != owner {
        removedOverride = accepted.removeValue(forKey: action.rawValue) != nil
          || removedOverride
      }
      guard removedOverride else { return Self(deletedActionIDs: acceptedDeleted) }
    }
  }

  private enum CodingKeys: String, CodingKey {
    case overrides
    case deletedActionIDs
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    overrides = try container.decodeIfPresent(
      [String: PDFViewerShortcut].self,
      forKey: .overrides) ?? [:]
    deletedActionIDs = try container.decodeIfPresent(
      Set<String>.self,
      forKey: .deletedActionIDs) ?? []
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(overrides, forKey: .overrides)
    if !deletedActionIDs.isEmpty {
      try container.encode(deletedActionIDs, forKey: .deletedActionIDs)
    }
  }
}
