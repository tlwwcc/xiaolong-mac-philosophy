import Foundation

enum LauncherUninstallRecoveryRoute {
  static let finderGuidance =
    "你也可以在“应用程序”中找到它，点右键后选择“移到废纸篓”。这只会移动主 App；辅助组件仍可能需要官方卸载器清理。"

  static func revealableApplicationURL(
    _ url: URL,
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
  ) -> URL? {
    let standardizedURL = url.standardizedFileURL
    guard standardizedURL.pathExtension.lowercased() == "app" else { return nil }
    guard fileExists(standardizedURL.path) else { return nil }

    let applicationsRoots = [
      "/Applications",
      URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appendingPathComponent("Applications", isDirectory: true)
        .standardizedFileURL.path,
    ]
    guard
      applicationsRoots.contains(where: { root in
        standardizedURL.path.hasPrefix(root + "/")
      })
    else { return nil }
    return standardizedURL
  }
}
