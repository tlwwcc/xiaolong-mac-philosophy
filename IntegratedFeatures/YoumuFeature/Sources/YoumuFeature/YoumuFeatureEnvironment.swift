import Foundation

/// Host-owned identity and storage roots for the embedded Youmu runtime.
///
/// The standalone Youmu data directory and Keychain service are intentionally never consulted.
public struct YoumuFeatureEnvironment: Equatable, Sendable {
  public static let stableHostBundleIdentifier = "cn.tlww.aixlg.hotkeys"
  public static let developmentHostBundleIdentifier = "cn.tlww.aixlg.hotkeys.dev"

  public let hostBundleIdentifier: String
  public let channelRoot: String
  public let applicationSupportRoot: URL
  public let temporaryRoot: URL
  public let userDefaultsSuiteName: String?

  public init(
    hostBundleIdentifier: String,
    channelRoot: String,
    applicationSupportRoot: URL,
    temporaryRoot: URL,
    userDefaultsSuiteName: String? = nil
  ) {
    self.hostBundleIdentifier = Self.safeIdentifier(
      hostBundleIdentifier,
      fallback: Self.developmentHostBundleIdentifier
    )
    self.channelRoot = Self.safePathComponent(
      channelRoot,
      fallback: "aixlg-hotkeys-dev"
    )
    self.applicationSupportRoot = applicationSupportRoot.standardizedFileURL
    self.temporaryRoot = temporaryRoot.standardizedFileURL
    self.userDefaultsSuiteName = userDefaultsSuiteName
  }

  public static func current(
    bundle: Bundle = .main,
    fileManager: FileManager = .default
  ) -> YoumuFeatureEnvironment {
    let bundleIdentifier = bundle.bundleIdentifier ?? developmentHostBundleIdentifier
    let buildChannel = bundle.object(forInfoDictionaryKey: "AIXLGBuildChannel") as? String
    return YoumuFeatureEnvironment(
      hostBundleIdentifier: bundleIdentifier,
      channelRoot: inferredChannelRoot(
        hostBundleIdentifier: bundleIdentifier,
        buildChannel: buildChannel
      ),
      applicationSupportRoot: fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      )[0],
      temporaryRoot: fileManager.temporaryDirectory
    )
  }

  public static func inferredChannelRoot(
    hostBundleIdentifier: String,
    buildChannel: String?
  ) -> String {
    let normalizedChannel = buildChannel?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    if normalizedChannel == "development"
      || hostBundleIdentifier == developmentHostBundleIdentifier
      || hostBundleIdentifier.hasSuffix(".dev")
    {
      return "aixlg-hotkeys-dev"
    }
    if normalizedChannel == "stable" || hostBundleIdentifier == stableHostBundleIdentifier {
      return "aixlg-hotkeys"
    }
    return safePathComponent(
      hostBundleIdentifier + "-host",
      fallback: "aixlg-hotkeys-dev"
    )
  }

  public var featureNamespace: String {
    hostBundleIdentifier + ".feature.youmu"
  }

  public var featureSupportDirectory: URL {
    applicationSupportRoot
      .appendingPathComponent(channelRoot, isDirectory: true)
      .appendingPathComponent("Features", isDirectory: true)
      .appendingPathComponent("Youmu", isDirectory: true)
  }

  public var settingsURL: URL {
    featureSupportDirectory.appendingPathComponent("settings.json", isDirectory: false)
  }

  public var translationKeychainService: String {
    featureNamespace + ".translation-credentials"
  }

  public var temporaryDirectory: URL {
    temporaryRoot.appendingPathComponent(
      featureNamespace + ".private-temporary-artifacts",
      isDirectory: true
    )
  }

  public func userDefaultsKey(_ suffix: String) -> String {
    featureNamespace + ".defaults." + Self.safeIdentifier(suffix, fallback: "value")
  }

  public func notificationName(_ suffix: String) -> Notification.Name {
    Notification.Name(featureNamespace + ".notification." + Self.safeIdentifier(suffix, fallback: "event"))
  }

  public var pasteboardPixelScaleType: String {
    featureNamespace + ".pasteboard.image-pixel-scale"
  }

  private static func safeIdentifier(_ value: String, fallback: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    let sanitized = value.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
    return sanitized.isEmpty ? fallback : sanitized
  }

  private static func safePathComponent(_ value: String, fallback: String) -> String {
    let sanitized = safeIdentifier(value, fallback: fallback)
    guard sanitized != ".", sanitized != ".." else { return fallback }
    return sanitized
  }
}

final class YoumuFeatureEnvironmentStore: @unchecked Sendable {
  static let shared = YoumuFeatureEnvironmentStore()

  private let lock = NSLock()
  private var storedEnvironment = YoumuFeatureEnvironment.current()

  private init() {}

  func configure(_ environment: YoumuFeatureEnvironment) {
    lock.lock()
    storedEnvironment = environment
    lock.unlock()
  }

  var environment: YoumuFeatureEnvironment {
    lock.lock()
    defer { lock.unlock() }
    return storedEnvironment
  }

  var settingsURL: URL { environment.settingsURL }
  var translationKeychainService: String { environment.translationKeychainService }
  var temporaryDirectory: URL { environment.temporaryDirectory }

  func userDefaultsKey(_ suffix: String) -> String {
    environment.userDefaultsKey(suffix)
  }

  func notificationName(_ suffix: String) -> Notification.Name {
    environment.notificationName(suffix)
  }

  func pasteboardPixelScaleType() -> String {
    environment.pasteboardPixelScaleType
  }

  func userDefaults() -> UserDefaults {
    guard let suiteName = environment.userDefaultsSuiteName,
          let defaults = UserDefaults(suiteName: suiteName)
    else {
      return .standard
    }
    return defaults
  }
}
