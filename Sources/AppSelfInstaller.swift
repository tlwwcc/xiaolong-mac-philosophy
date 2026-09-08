import AppKit
import Foundation

enum AppSelfInstaller {
  private static let identity = AppRuntimeIdentity.current
  private static let installedURL = identity.installURL
  private static let skipArgument = "--skip-self-install"

  static func launchInstallIfNeeded() -> Bool {
    guard identity.allowsSelfInstallation else {
      AppDiagnostics.log("self_install_skipped", ["reason": "build_channel"])
      return false
    }
    // A formal licensed build must finish trusted license/update checks before replacing an
    // installed version. The signed DMG remains a normal drag-to-Applications installer.
    guard !ProductReleaseIdentity.isFormalRelease else { return false }
    guard shouldInstall else { return false }

    do {
      let scriptURL = try writeInstallerScript()
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/zsh")
      process.arguments = [scriptURL.path]
      try process.run()
      return true
    } catch {
      AppDiagnostics.log("self_install_failed error=\(error.localizedDescription)")
      return false
    }
  }

  private static var shouldInstall: Bool {
    guard !CommandLine.arguments.contains(skipArgument) else { return false }
    let currentURL = Bundle.main.bundleURL.standardizedFileURL
    guard currentURL.pathExtension == "app" else { return false }
    guard currentURL.path != installedURL.standardizedFileURL.path else { return false }
    guard !isDevelopmentBuild(currentURL) else { return false }
    return true
  }

  private static func isDevelopmentBuild(_ url: URL) -> Bool {
    let path = url.path
    return path.contains("/outputs/aixlg-hotkeys/build/")
      || path.contains("/.build/")
      || path.contains("/DerivedData/")
  }

  private static func writeInstallerScript() throws -> URL {
    let workURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("aixlg-self-install-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workURL, withIntermediateDirectories: true)
    let scriptURL = workURL.appendingPathComponent("install-self.sh")
    let pid = ProcessInfo.processInfo.processIdentifier
    let currentApp = shellQuote(Bundle.main.bundleURL.path)
    let installedApp = shellQuote(installedURL.path)
    let work = shellQuote(workURL.path)
    let skip = shellQuote(skipArgument)
    let script = """
      #!/bin/zsh
      set -u
      LOG_DIR=\(shellQuote(identity.logDirectoryURL.path))
      /bin/mkdir -p "$LOG_DIR"
      LOG="$LOG_DIR/install.log"
      exec >> "$LOG" 2>&1
      echo "== self install $(/bin/date) =="
      CURRENT_APP=\(currentApp)
      INSTALLED_APP=\(installedApp)
      WORK_DIR=\(work)
      SKIP_ARG=\(skip)
      PID=\(pid)

      for _ in {1..80}; do
        if ! /bin/kill -0 "$PID" 2>/dev/null; then
          break
        fi
        /bin/sleep 0.1
      done
      if /bin/kill -0 "$PID" 2>/dev/null; then
        /bin/kill "$PID" 2>/dev/null || true
        /bin/sleep 0.5
      fi
      if /bin/kill -0 "$PID" 2>/dev/null; then
        /bin/kill -9 "$PID" 2>/dev/null || true
      fi

      /bin/mkdir -p "/Applications"
      BACKUP="${INSTALLED_APP}.backup.$(/bin/date +%s)"
      if [[ -d "$INSTALLED_APP" ]]; then
        /bin/mv "$INSTALLED_APP" "$BACKUP"
      fi
      if /usr/bin/ditto "$CURRENT_APP" "$INSTALLED_APP" && /usr/bin/codesign --verify --deep --strict "$INSTALLED_APP"; then
        /bin/rm -rf "$BACKUP"
        /usr/bin/open "$INSTALLED_APP"
        /bin/rm -rf "$WORK_DIR"
        echo "self install complete"
        exit 0
      fi

      echo "self install failed"
      if [[ -d "$BACKUP" ]]; then
        /bin/rm -rf "$INSTALLED_APP"
        /bin/mv "$BACKUP" "$INSTALLED_APP"
      else
        /bin/rm -rf "$INSTALLED_APP"
      fi
      /usr/bin/open "$CURRENT_APP" --args "$SKIP_ARG"
      exit 1
      """
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    return scriptURL
  }

  private static func shellQuote(_ text: String) -> String {
    "'\(text.replacingOccurrences(of: "'", with: "'\\''"))'"
  }
}
