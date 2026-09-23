import AppKit
import Darwin

if let clipboardWorkerStatus = ClipboardPasteboardIsolation.runWorkerIfRequested() {
  exit(clipboardWorkerStatus)
}

private let capsEntryKeyImportArgument = "--import-caps-entry-key"

if !AppRuntimeIdentity.isRuntimeBundleIdentityValid() {
  fputs("App build channel does not match its bundle identity; refusing to start.\n", stderr)
  exit(78)
}

if !ProductReleaseIdentity.matchesPublicationMetadata(
  Bundle.main.object(forInfoDictionaryKey: "AIXLGReleasePublishedAt") as? String
) {
  fputs(
    "App release publication metadata does not match its compiled identity; refusing to start.\n",
    stderr)
  exit(78)
}

private let runtimeIdentity = AppRuntimeIdentity.current

// Fixed-text, installed-binary diagnostic. It neither loads customer settings nor starts
// shortcuts, clipboard capture, networking or model downloads.
if Array(CommandLine.arguments.dropFirst()) == ["--youmu-translation-smoke"] {
  MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    Task { @MainActor in
      let result = await runInstalledTranslationSmoke()
      if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
        let text = String(data: data, encoding: .utf8)
      {
        print(text)
      }
      exit(result["status"] == "PASS" ? 0 : 2)
    }
    app.run()
  }
  exit(2)
}

if CommandLine.arguments.contains(capsEntryKeyImportArgument) {
  let supportURL = FileManager.default.urls(
    for: .applicationSupportDirectory,
    in: .userDomainMask)[0]
    .appendingPathComponent(runtimeIdentity.applicationSupportDirectoryName, isDirectory: true)
  try? FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
  let request = XLGConfigImportRequest.appDefault(
    applicationSupportURL: supportURL,
    shortcutsURL: supportURL.appendingPathComponent("shortcuts.json"),
    phrasesURL: supportURL.appendingPathComponent("phrases.json"))

  do {
    let result = try XLGConfigImporter.importCapsEntryKeyRule(request: request)
    print(result.message)
    if let backupURL = result.backupURL {
      print("原 Karabiner 配置备份：\(backupURL.path)")
    }
    exit(0)
  } catch {
    fputs("\(error.localizedDescription)\n", stderr)
    if case XLGConfigImportError.missingKarabinerElements = error {
      exit(45)
    }
    if case XLGConfigImportError.unreadableKarabinerConfig(_) = error {
      exit(44)
    }
    exit(44)
  }
}

let bundleID = Bundle.main.bundleIdentifier ?? runtimeIdentity.bundleIdentifier
let currentPID = ProcessInfo.processInfo.processIdentifier
let mainExecutableName =
  Bundle.main.executableURL?.lastPathComponent ?? runtimeIdentity.mainExecutableName
let existingApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
  .first {
    $0.processIdentifier != currentPID
      && $0.executableURL?.lastPathComponent == mainExecutableName
  }

if let existingApp {
  DistributedNotificationCenter.default().postNotificationName(
    .showAixlgHotkeysWindow,
    object: nil
  )
  existingApp.activate(options: [.activateIgnoringOtherApps])
  exit(0)
}

let supportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
  .appendingPathComponent(runtimeIdentity.applicationSupportDirectoryName, isDirectory: true)
try? FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
let lockURL = supportURL.appendingPathComponent("app.lock")
let lockFD = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
if lockFD == -1 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
  DistributedNotificationCenter.default().postNotificationName(
    .showAixlgHotkeysWindow,
    object: nil
  )
  exit(0)
}

MainActor.assumeIsolated {
  let app = NSApplication.shared
  DockPresencePreference.migrateLegacyHiddenDefault()
  app.setActivationPolicy(
    DockPresencePreference.activationPolicy(
      forVisibleDockIcon: DockPresencePreference.isVisible()))
  // The current product UI is an intentional paper-white visual system. Keep the whole App in
  // Aqua until every main and auxiliary window has a complete dark palette; otherwise AppKit's
  // semantic surfaces turn dark while the existing fixed ink and card colors stay light-only.
  app.appearance = NSAppearance(named: .aqua)
  RetiredShiftInputSourcePreferences.purge()
  let model = AppModel()
  let delegate = AppDelegate(model: model)
  app.delegate = delegate
  app.finishLaunching()
  delegate.bootstrapIfNeeded()
  DispatchQueue.main.async {
    delegate.showWindowAfterLaunch()
  }
  withExtendedLifetime((model, delegate)) {
    app.run()
  }
}
