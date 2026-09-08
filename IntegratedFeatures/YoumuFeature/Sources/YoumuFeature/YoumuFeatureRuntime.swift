import BuiltinFeatureCatalog
import Foundation
import PlatformContracts

public enum YoumuCaptureMode: String, CaseIterable, Equatable, Sendable {
  case quickSnapshot
  case annotatedScreenshot
  case longScreenshot
  case pinScreenshot
  case selectionReader
  case imageTranslate
  case ocrTranslate
  case ocrCopy
}

public enum YoumuScreenRecordingPermissionStatus: String, Equatable, Sendable {
  case granted
  case missing
}

public enum YoumuCommandSessionInvalidationReason: Equatable, Sendable {
  case proEntitlementLost
  case screenRecordingPermissionLost
  case inputMonitoringPermissionLost
  case globalInputOwnershipYielded
}

public struct YoumuPermissionSnapshot: Equatable, Sendable {
  public let screenRecording: YoumuScreenRecordingPermissionStatus

  public init(screenRecording: YoumuScreenRecordingPermissionStatus) {
    self.screenRecording = screenRecording
  }
}

public enum YoumuFeatureRuntimeError: LocalizedError, Equatable {
  case unsupportedCommandID(String)
  case hostManagedInterfaceUnavailable

  public var errorDescription: String? {
    switch self {
    case .unsupportedCommandID(let commandID):
      return "游目不支持命令：\(commandID)"
    case .hostManagedInterfaceUnavailable:
      return "游目主界面由宿主应用中心管理，当前尚未注入打开路由。"
    }
  }
}

/// The only host-facing entry point for the embedded Youmu runtime.
///
/// Entitlement and command-specific permission decisions must be completed by Platform's
/// dispatcher before calling `execute`. This target intentionally contains no license gate,
/// purchase flow, updater, or global-hotkey registration.
@MainActor
public final class YoumuFeatureRuntime {
  public typealias HostInterfaceHandler = @MainActor () -> Void
  public typealias ShortcutManagerHandler = @MainActor () -> Void
  public typealias ControlWindowCommandHandler = @MainActor (String) -> Void
  public typealias LongScreenshotActivityHandler = @MainActor (Bool) -> Void

  private let captureHandler: @MainActor (TranslateMode) -> Void
  private let cancelIfActiveHandler: @MainActor (TranslateMode) -> Bool
  private let invalidationHandler: @MainActor (YoumuCommandSessionInvalidationReason) -> Void
  private let hostInterfaceHandler: HostInterfaceHandler?
  private let shortcutManagerHandler: ShortcutManagerHandler?
  private let controlWindowController: YoumuControlWindowController

  public convenience init(
    openMainInterface: HostInterfaceHandler? = nil,
    openShortcutManager: ShortcutManagerHandler? = nil
  ) {
    self.init(
      environment: .current(),
      longScreenshotActivityChanged: nil,
      openMainInterface: openMainInterface,
      openShortcutManager: openShortcutManager
    )
  }

  public init(
    environment: YoumuFeatureEnvironment,
    successfulUse: HostInterfaceHandler? = nil,
    longScreenshotActivityChanged: LongScreenshotActivityHandler? = nil,
    openMainInterface: HostInterfaceHandler? = nil,
    openShortcutManager: ShortcutManagerHandler? = nil
  ) {
    YoumuFeatureEnvironmentStore.shared.configure(environment)
    ScreenCaptureService.shared.successfulUse = successfulUse
    ScreenCaptureService.shared.setLongScreenshotActivityHandler(
      longScreenshotActivityChanged)
    controlWindowController = YoumuControlWindowController()
    captureHandler = { mode in
      ScreenCaptureService.shared.toggleCapture(mode: mode)
    }
    cancelIfActiveHandler = { mode in
      ScreenCaptureService.shared.cancelIfActive(mode: mode)
    }
    invalidationHandler = { reason in
      ScreenCaptureService.shared.invalidateCommandSessions(for: reason)
    }
    hostInterfaceHandler = openMainInterface
    shortcutManagerHandler = openShortcutManager
  }

  init(
    environment: YoumuFeatureEnvironment,
    openMainInterface: HostInterfaceHandler? = nil,
    openShortcutManager: ShortcutManagerHandler? = nil,
    cancelIfActiveHandler: @escaping @MainActor (TranslateMode) -> Bool = { _ in false },
    invalidationHandler: @escaping @MainActor (YoumuCommandSessionInvalidationReason) -> Void = {
      _ in
    },
    captureHandler: @escaping @MainActor (TranslateMode) -> Void
  ) {
    YoumuFeatureEnvironmentStore.shared.configure(environment)
    controlWindowController = YoumuControlWindowController()
    self.captureHandler = captureHandler
    self.cancelIfActiveHandler = cancelIfActiveHandler
    self.invalidationHandler = invalidationHandler
    hostInterfaceHandler = openMainInterface
    shortcutManagerHandler = openShortcutManager
  }

  public static func captureMode(for commandID: String) -> YoumuCaptureMode? {
    switch commandID {
    case YoumuFeatureIDs.quickSnapshot.rawValue: return .quickSnapshot
    case YoumuFeatureIDs.annotatedScreenshot.rawValue: return .annotatedScreenshot
    case YoumuFeatureIDs.longScreenshot.rawValue: return .longScreenshot
    case YoumuFeatureIDs.pinScreenshot.rawValue: return .pinScreenshot
    case YoumuFeatureIDs.selectionReader.rawValue: return .selectionReader
    case YoumuFeatureIDs.imageTranslate.rawValue: return .imageTranslate
    case YoumuFeatureIDs.ocrTranslate.rawValue: return .ocrTranslate
    case YoumuFeatureIDs.ocrCopy.rawValue: return .ocrCopy
    default: return nil
    }
  }

  public func execute(commandID: String) throws {
    guard let mode = Self.captureMode(for: commandID) else {
      throw YoumuFeatureRuntimeError.unsupportedCommandID(commandID)
    }
    captureHandler(mode.translateMode)
  }

  public func execute(commandID: CommandID) throws {
    try execute(commandID: commandID.rawValue)
  }

  /// Exact-mode toggle preflight. The host must call this before entitlement and permission
  /// checks so a second press can close an existing result after access changes.
  @discardableResult
  public func cancelIfActive(commandID: String) -> Bool {
    guard let mode = Self.captureMode(for: commandID) else { return false }
    return cancelIfActiveHandler(mode.translateMode)
  }

  @discardableResult
  public func cancelIfActive(commandID: CommandID) -> Bool {
    cancelIfActive(commandID: commandID.rawValue)
  }

  public func invalidateCommandSessions(for reason: YoumuCommandSessionInvalidationReason) {
    invalidationHandler(reason)
  }

  public func cancelAllCommandSessions() {
    invalidateCommandSessions(for: .globalInputOwnershipYielded)
  }

  /// Backward-compatible host lease hook. Unlike the old implementation, this drains selecting,
  /// processing, and presenting owners before cross-channel global input is released.
  public func cancelActiveGlobalInputSessions() {
    cancelAllCommandSessions()
  }

  public func openMainInterface() throws {
    guard let hostInterfaceHandler else {
      throw YoumuFeatureRuntimeError.hostManagedInterfaceUnavailable
    }
    hostInterfaceHandler()
  }

  /// Opens Youmu's host-embedded control window.
  ///
  /// Quick actions are returned to the host as stable command IDs so entitlement, permission,
  /// shortcut, and global-input decisions remain centralized in the carrier application.
  public func openControlWindow(
    commandHandler: @escaping ControlWindowCommandHandler
  ) {
    controlWindowController.show(
      commandHandler: commandHandler,
      shortcutManagerHandler: shortcutManagerHandler)
  }

  public func permissionSnapshot() -> YoumuPermissionSnapshot {
    YoumuPermissionSnapshot(screenRecording: Permissions.screenRecordingStatus)
  }

  /// Opens Apple's Screen Recording pane only while access is missing.
  ///
  /// Returns `true` when the System Settings URL was opened and `false` when permission already
  /// exists or macOS rejected the URL. It never resets or mutates TCC records.
  @discardableResult
  public func openScreenRecordingSettingsIfNeeded() -> Bool {
    Permissions.openScreenRecordingSettingsIfNeeded()
  }

  public var settingsURL: URL {
    YoumuFeatureEnvironmentStore.shared.environment.settingsURL
  }

  public var translationKeychainService: String {
    YoumuFeatureEnvironmentStore.shared.environment.translationKeychainService
  }
}

extension YoumuCaptureMode {
  fileprivate var translateMode: TranslateMode {
    switch self {
    case .quickSnapshot: return .quickSnapshot
    case .annotatedScreenshot: return .screenshotEdit
    case .longScreenshot: return .longScreenshot
    case .pinScreenshot: return .pinClipboard
    case .selectionReader: return .selectionReader
    case .imageTranslate: return .imageTranslate
    case .ocrTranslate: return .screenshotTranslate
    case .ocrCopy: return .silentOCR
    }
  }
}
