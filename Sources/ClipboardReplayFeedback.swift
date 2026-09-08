import AppKit

enum ClipboardReplayFeedback {
  private static let successSound: NSSound? = {
    if let sound = NSSound(named: NSSound.Name("Tink")) {
      return sound
    }
    return NSSound(
      contentsOfFile: "/System/Library/Sounds/Tink.aiff",
      byReference: true)
  }()

  /// Replay feedback belongs to the pasteboard commit, not to the click itself. Keeping the
  /// success gate here prevents missing files, a failed write, or a stale request from sounding
  /// like the user's clipboard was changed.
  static func deliver(
    didCommit: Bool,
    play: () -> Void = { successSound?.play() }
  ) {
    guard didCommit else { return }
    play()
  }
}
