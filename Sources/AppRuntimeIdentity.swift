import Foundation

enum AppBuildChannel: String, Sendable {
  case stable
  case invalid
}

struct GlobalInputRuntimeProcessIdentity: Equatable, Sendable {
  let bundleIdentifier: String?
  let executableName: String?
  let bundlePath: String?
  let isTerminated: Bool
}

/// The single source of truth for every identity-bearing runtime resource.
///
/// Only the exact stable tuple is allowed to run. Bare SwiftPM executables, test fixtures, legacy
/// second identities, partial identities, and unknown explicit values fail closed into an invalid
/// identity so they cannot touch the installed app's data, credentials, update path, or listeners.
struct AppRuntimeIdentity: Equatable, Sendable {
  static let buildChannelInfoKey = "AIXLGBuildChannel"
  static let stableBundleIdentifier = "cn.tlww.aixlg.hotkeys"
  static let stableExecutableName = "aixlg-hotkeys"
  static let stableDeveloperTeamIdentifier = "TG5Z23NAC2"
  let channel: AppBuildChannel

  init(channel: AppBuildChannel) {
    self.channel = channel
  }

  static func resolve(bundle: Bundle = .main) -> AppRuntimeIdentity {
    AppRuntimeIdentity(
      channel: resolveChannel(
        configured: bundle.object(forInfoDictionaryKey: buildChannelInfoKey) as? String,
        bundleIdentifier: bundle.bundleIdentifier,
        executableName: bundle.executableURL?.lastPathComponent
      ))
  }

  static func resolveChannel(
    configured: String?,
    bundleIdentifier: String?,
    executableName: String?
  ) -> AppBuildChannel {
    let isExactStableIdentity =
      bundleIdentifier == stableBundleIdentifier
      && executableName == stableExecutableName

    if let configured {
      let normalized = configured.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      guard normalized == AppBuildChannel.stable.rawValue else { return .invalid }
      return isExactStableIdentity ? .stable : .invalid
    }
    return isExactStableIdentity ? .stable : .invalid
  }

  static func isRuntimeBundleIdentityValid(bundle: Bundle = .main) -> Bool {
    isRuntimeBundleIdentityValid(
      configured: bundle.object(forInfoDictionaryKey: buildChannelInfoKey) as? String,
      bundleIdentifier: bundle.bundleIdentifier,
      executableName: bundle.executableURL?.lastPathComponent
    )
  }

  static func isRuntimeBundleIdentityValid(
    configured: String?,
    bundleIdentifier: String?,
    executableName: String?
  ) -> Bool {
    let isExactStableIdentity =
      bundleIdentifier == stableBundleIdentifier
      && executableName == stableExecutableName
    guard let configured else {
      return isExactStableIdentity
    }
    return configured.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      == AppBuildChannel.stable.rawValue
      && isExactStableIdentity
  }

  static var current: AppRuntimeIdentity { resolve() }

  var isInvalid: Bool { channel == .invalid }
  var buildChannelName: String { channel.rawValue }

  var displayName: String {
    isInvalid ? "无效运行身份" : "小龙哥Mac哲学"
  }

  var appBundleName: String { "\(displayName).app" }

  var bundleIdentifier: String {
    isInvalid ? "invalid.aixlg.runtime" : Self.stableBundleIdentifier
  }

  var mainExecutableName: String {
    isInvalid ? "aixlg-invalid-runtime" : Self.stableExecutableName
  }

  var networkSpeedHelperExecutableName: String {
    isInvalid ? "aixlg-invalid-network-helper" : "aixlg-network-speed-status"
  }

  var sleepStatusHelperExecutableName: String {
    isInvalid ? "aixlg-invalid-sleep-helper" : "aixlg-sleep-status"
  }

  var applicationSupportDirectoryName: String {
    isInvalid ? "aixlg-invalid-runtime" : "aixlg-hotkeys"
  }

  var logDirectoryName: String { applicationSupportDirectoryName }

  var launchAgentIdentifier: String { bundleIdentifier }
  var notificationNamespace: String { bundleIdentifier }
  var defaultsSuiteName: String { bundleIdentifier }
  var sparkleErrorDomain: String { "\(bundleIdentifier).sparkle" }

  var installURL: URL {
    URL(fileURLWithPath: "/Applications", isDirectory: true)
      .appendingPathComponent(appBundleName, isDirectory: true)
  }

  var applicationSupportURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
  }

  var logDirectoryURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs", isDirectory: true)
      .appendingPathComponent(logDirectoryName, isDirectory: true)
  }

  func notificationName(_ suffix: String) -> Notification.Name {
    Notification.Name("\(notificationNamespace).\(suffix)")
  }

  var allowsOnlineUpdates: Bool { !isInvalid }
  var allowsSelfInstallation: Bool { !isInvalid }
  var allowsStablePermissionRepair: Bool { !isInvalid }
  var allowsDefaultPDFAssociation: Bool { !isInvalid }
  var allowsLaunchAtLogin: Bool { !isInvalid }

  func mayRequestGlobalInputLease(
    runningProcesses _: [GlobalInputRuntimeProcessIdentity]
  ) -> Bool {
    guard !isInvalid else { return false }
    return true
  }

  static func isExactStableRuntime(_ process: GlobalInputRuntimeProcessIdentity) -> Bool {
    guard !process.isTerminated else { return false }
    return process.bundleIdentifier == stableBundleIdentifier
      && process.executableName == stableExecutableName
      && process.bundlePath
        == AppRuntimeIdentity(channel: .stable).installURL.standardizedFileURL.path
  }
}
