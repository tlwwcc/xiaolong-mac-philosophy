import AppKit
import Foundation
import SwiftUI

@MainActor
private final class PijuanPDFMainWindowLifecycle: NSObject, NSWindowDelegate {
  private let onWillClose: (NSWindow) -> Void

  init(onWillClose: @escaping (NSWindow) -> Void) {
    self.onWillClose = onWillClose
  }

  func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    onWillClose(window)
  }
}

public enum PijuanPDFReleaseChannel: String, Sendable {
  case development
  case stable
}

public enum PijuanPDFDefaultAssociationPolicy: String, Sendable {
  case disabled
  case hostManaged
}

public struct PijuanPDFStorageNamespace: Equatable, Sendable {
  public let channelBundleIdentifier: String
  public let featureIdentifier: String

  public init(
    channelBundleIdentifier: String,
    featureIdentifier: String = "pijuan-pdf"
  ) {
    self.channelBundleIdentifier = channelBundleIdentifier
    self.featureIdentifier = featureIdentifier
  }

  public var preferencesSuiteName: String {
    "\(channelBundleIdentifier).feature.\(featureIdentifier)"
  }

  fileprivate var storageKeyPrefix: String {
    "feature.\(featureIdentifier)"
  }

  fileprivate var windowAutosavePrefix: String {
    preferencesSuiteName
  }
}

public struct PijuanPDFPreferences {
  public let suiteName: String
  fileprivate let defaults: UserDefaults

  public init(suiteName: String, defaults: UserDefaults) {
    self.suiteName = suiteName
    self.defaults = defaults
  }
}

public struct PijuanPDFFeatureConfiguration: Sendable {
  public let channel: PijuanPDFReleaseChannel
  public let storageNamespace: PijuanPDFStorageNamespace
  public let defaultAssociationPolicy: PijuanPDFDefaultAssociationPolicy
  public let version: String?
  public let build: String?

  public init(
    channel: PijuanPDFReleaseChannel,
    storageNamespace: PijuanPDFStorageNamespace,
    defaultAssociationPolicy: PijuanPDFDefaultAssociationPolicy = .disabled,
    version: String? = nil,
    build: String? = nil
  ) {
    self.channel = channel
    self.storageNamespace = storageNamespace
    self.defaultAssociationPolicy = defaultAssociationPolicy
    self.version = version
    self.build = build
  }
}

public enum PijuanPDFFeatureConfigurationError: Error, Equatable, LocalizedError {
  case emptyChannelBundleIdentifier
  case emptyFeatureIdentifier
  case preferencesSuiteMismatch(expected: String, actual: String)
  case defaultAssociationForbiddenInDevelopment

  public var errorDescription: String? {
    switch self {
    case .emptyChannelBundleIdentifier:
      return "披卷需要宿主提供开发版或稳定版的 Bundle ID。"
    case .emptyFeatureIdentifier:
      return "披卷需要非空的功能标识。"
    case .preferencesSuiteMismatch(let expected, let actual):
      return "披卷偏好域不匹配：期望 \(expected)，实际 \(actual)。"
    case .defaultAssociationForbiddenInDevelopment:
      return "开发版禁止申请系统默认 PDF 打开方式。"
    }
  }
}

@MainActor
public final class PijuanPDFFeatureFacade {
  public let configuration: PijuanPDFFeatureConfiguration

  private let model: PDFViewerModel
  private let shortcuts: PDFViewerShortcutStore
  private var mainWindowController: NSWindowController?
  private var mainWindowLifecycle: PijuanPDFMainWindowLifecycle?
  private var helpWindowController: NSWindowController?
  private var openShortcutManagerHandler: (() -> Void)?

  public init(
    configuration: PijuanPDFFeatureConfiguration,
    preferences: PijuanPDFPreferences
  ) throws {
    let namespace = configuration.storageNamespace
    guard
      !namespace.channelBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        .isEmpty
    else {
      throw PijuanPDFFeatureConfigurationError.emptyChannelBundleIdentifier
    }
    guard !namespace.featureIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw PijuanPDFFeatureConfigurationError.emptyFeatureIdentifier
    }
    guard preferences.suiteName == namespace.preferencesSuiteName else {
      throw PijuanPDFFeatureConfigurationError.preferencesSuiteMismatch(
        expected: namespace.preferencesSuiteName,
        actual: preferences.suiteName)
    }
    if configuration.channel == .development,
      configuration.defaultAssociationPolicy != .disabled
    {
      throw PijuanPDFFeatureConfigurationError.defaultAssociationForbiddenInDevelopment
    }

    self.configuration = configuration
    let keyPrefix = namespace.storageKeyPrefix
    self.model = PDFViewerModel(
      defaults: preferences.defaults,
      recentDocumentsKey: "\(keyPrefix).recent-documents-v1",
      readingPositionsKey: "\(keyPrefix).reading-positions-v1")
    self.shortcuts = PDFViewerShortcutStore(
      defaults: preferences.defaults,
      storageKey: "\(keyPrefix).shortcut-configuration-v1")
  }

  public var preferencesSuiteName: String {
    configuration.storageNamespace.preferencesSuiteName
  }

  public var permitsHostManagedDefaultAssociation: Bool {
    configuration.channel == .stable
      && configuration.defaultAssociationPolicy == .hostManaged
  }

  public var hasOpenDocument: Bool {
    model.fileURL != nil
  }

  public var documentTitle: String {
    model.documentTitle
  }

  public var shortcutCount: Int {
    shortcuts.activeShortcutCount
  }

  public func makeShortcutSettingsView(embedded: Bool = false) -> AnyView {
    AnyView(PDFViewerShortcutSettingsView(shortcuts: shortcuts, embedded: embedded))
  }

  public func setOpenShortcutManagerHandler(_ handler: @escaping () -> Void) {
    openShortcutManagerHandler = handler
  }

  public func makeRootView() -> AnyView {
    AnyView(
      PDFViewerRootView(
        model: model,
        shortcuts: shortcuts,
        applicationVersionText: PDFApplicationVersion.displayText(
          version: configuration.version,
          build: configuration.build),
        onShowHelp: { [weak self] in
          self?.showHelpWindow()
        }))
  }

  @discardableResult
  public func showWindow(opening url: URL? = nil) -> NSWindow {
    if let url {
      model.open(url)
    }

    if let window = mainWindowController?.window {
      window.makeKeyAndOrderFront(nil)
      return window
    }

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false)
    window.title = "披卷"
    window.contentViewController = NSHostingController(rootView: makeRootView())
    window.isReleasedWhenClosed = false
    window.center()
    window.setFrameAutosaveName(
      "\(configuration.storageNamespace.windowAutosavePrefix).main-window")

    let lifecycle = PijuanPDFMainWindowLifecycle { [weak self] closingWindow in
      self?.handleMainWindowWillClose(closingWindow)
    }
    window.delegate = lifecycle

    let controller = NSWindowController(window: window)
    mainWindowLifecycle = lifecycle
    mainWindowController = controller
    controller.showWindow(nil)
    window.makeKeyAndOrderFront(nil)
    return window
  }

  public func openDocument(at url: URL) {
    model.open(url)
  }

  public func closeDocument() {
    model.closeDocument()
  }

  public func showHelpWindow() {
    if let window = helpWindowController?.window {
      window.makeKeyAndOrderFront(nil)
      return
    }

    let content = PDFViewerShortcutHelpPopover(
      shortcuts: shortcuts,
      onShowSettings: { [weak self] in
        self?.openShortcutManagerHandler?()
      },
      onDismiss: { [weak self] in
        self?.helpWindowController?.close()
      })
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 535),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false)
    window.title = "披卷 · 帮助"
    window.contentViewController = NSHostingController(rootView: content)
    window.isReleasedWhenClosed = false
    window.center()
    window.setFrameAutosaveName(
      "\(configuration.storageNamespace.windowAutosavePrefix).help")

    let controller = NSWindowController(window: window)
    helpWindowController = controller
    controller.showWindow(nil)
    window.makeKeyAndOrderFront(nil)
  }

  public func closeAllWindows() {
    helpWindowController?.close()
    mainWindowController?.close()
  }

  private func handleMainWindowWillClose(_ closingWindow: NSWindow) {
    guard mainWindowController?.window === closingWindow else { return }

    // closeDocument records the current page before replacing PDFView, then
    // stops any active security-scoped access held for the document URL.
    model.closeDocument()
    closingWindow.delegate = nil
    mainWindowController = nil
    mainWindowLifecycle = nil
  }
}
