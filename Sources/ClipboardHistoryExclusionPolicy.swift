import CryptoKit
import Foundation

enum ClipboardHistoryExclusionPolicy {
  static let typelessBundleIdentifier = "now.typeless.desktop"

  static let defaultApplications = [
    ClipboardHistoryExcludedApplication(
      bundleIdentifier: typelessBundleIdentifier,
      applicationName: "Typeless",
      applicationPath: "/Applications/Typeless.app")
  ]

  static func isSourceExcluded(
    _ source: ClipboardHistorySource,
    applications: [ClipboardHistoryExcludedApplication]
  ) -> Bool {
    guard let sourceBundleIdentifier = normalizedBundleIdentifier(source.bundleIdentifier) else {
      return false
    }
    return applications.contains {
      normalizedBundleIdentifier($0.bundleIdentifier) == sourceBundleIdentifier
    }
  }

  /// Typeless briefly publishes a transient pasteboard, pastes it, then restores the user's
  /// previous clipboard. The 0.4-second observer can see either the transient marker or only the
  /// final restored value, so both paths must converge on the same skip decision.
  static func shouldSkipTypelessRoundTrip(
    previousFingerprint: String?,
    currentFingerprint: String,
    changeCountDelta: Int,
    observedTransientChange: Bool,
    typelessExcluded: Bool,
    typelessRunning: Bool
  ) -> Bool {
    guard typelessExcluded, typelessRunning,
      let previousFingerprint,
      previousFingerprint == currentFingerprint
    else { return false }
    return observedTransientChange || changeCountDelta > 1
  }

  static func observationFingerprint(for capture: ClipboardHistoryCapture) -> String {
    var hasher = SHA256()
    append(Data("clipboard-observation-v1".utf8), to: &hasher)

    if !capture.files.isEmpty {
      append(Data("files".utf8), to: &hasher)
      for path in capture.files.map({ $0.standardizedFileURL.path }).sorted() {
        append(Data(path.utf8), to: &hasher)
      }
    } else if let imagePNGData = capture.imagePNGData {
      append(Data("image".utf8), to: &hasher)
      append(imagePNGData, to: &hasher)
    } else {
      append(Data("text".utf8), to: &hasher)
      if let text = capture.text { append(Data(text.utf8), to: &hasher) }
      if let richUTI = capture.richUTI { append(Data(richUTI.utf8), to: &hasher) }
      if let richData = capture.richData { append(richData, to: &hasher) }
    }

    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  static func normalizedApplications(
    _ applications: [ClipboardHistoryExcludedApplication]
  ) -> [ClipboardHistoryExcludedApplication] {
    var seen: Set<String> = []
    return applications.compactMap { application in
      guard let bundleIdentifier = normalizedBundleIdentifier(application.bundleIdentifier),
        seen.insert(bundleIdentifier).inserted
      else { return nil }
      let name = application.applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
      return ClipboardHistoryExcludedApplication(
        bundleIdentifier: bundleIdentifier,
        applicationName: name.isEmpty ? bundleIdentifier : name,
        applicationPath: normalizedPath(application.applicationPath))
    }
    .sorted {
      $0.applicationName.localizedStandardCompare($1.applicationName) == .orderedAscending
    }
  }

  static func containsTypeless(_ applications: [ClipboardHistoryExcludedApplication]) -> Bool {
    applications.contains {
      normalizedBundleIdentifier($0.bundleIdentifier) == typelessBundleIdentifier
    }
  }

  private static func normalizedBundleIdentifier(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      !value.isEmpty
    else { return nil }
    return value
  }

  private static func normalizedPath(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return URL(fileURLWithPath: value).standardizedFileURL.path
  }

  private static func append(_ data: Data, to hasher: inout SHA256) {
    var length = UInt64(data.count).bigEndian
    withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
    hasher.update(data: data)
  }
}
