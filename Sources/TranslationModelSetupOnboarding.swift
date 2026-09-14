import Foundation

/// Offers model preparation once, only after the host's permission flow has settled.
@MainActor
final class TranslationModelSetupOnboarding {
  static let offeredDefaultsKey = "translationModelSetupOfferedV1"
  private let defaults: UserDefaults
  private var isChecking = false
  private var checkedThisLaunch = false

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func offerIfNeeded(
    needsDownload: @escaping @MainActor () async -> Bool,
    canPresent: @escaping @MainActor () -> Bool,
    present: @escaping @MainActor () -> Void
  ) {
    guard !isChecking, !checkedThisLaunch,
      !defaults.bool(forKey: Self.offeredDefaultsKey), canPresent()
    else { return }
    isChecking = true
    Task { @MainActor [weak self] in
      let missing = await needsDownload()
      guard let self else { return }
      isChecking = false
      // Permissions or a restart may have begun while macOS checked its model catalog.
      guard canPresent() else { return }
      checkedThisLaunch = true
      guard missing else { return }
      defaults.set(true, forKey: Self.offeredDefaultsKey)
      present()
    }
  }
}
