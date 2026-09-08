import AppKit
import CoreGraphics

enum Permissions {
  static var screenRecordingStatus: YoumuScreenRecordingPermissionStatus {
    CGPreflightScreenCaptureAccess() ? .granted : .missing
  }

  static var inputMonitoringGranted: Bool {
    CGPreflightListenEventAccess()
  }

  @MainActor
  @discardableResult
  static func openScreenRecordingSettingsIfNeeded() -> Bool {
    guard screenRecordingStatus == .missing else { return false }
    guard let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    ) else {
      return false
    }
    return NSWorkspace.shared.open(url)
  }
}
