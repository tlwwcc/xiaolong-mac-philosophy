/// Compatibility hook for the old launch delegate.
/// Installation is owned by the verified, notarized exact-package installer.
/// Launching any App copy must never replace the stable installation.
enum AppSelfInstaller {
  static func launchInstallIfNeeded() -> Bool {
    false
  }
}
