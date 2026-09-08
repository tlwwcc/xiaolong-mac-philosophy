import Foundation

/// Every persistent first-party window opened by a shortcut must be registered here.
///
/// UI buttons use an idempotent presentation route. Physical shortcuts use this target to
/// alternate between presented and hidden without relying on timing or key-window guesses.
enum ShortcutWindowTarget: String, CaseIterable, Hashable {
  case main
  case shortcutGuide
  case settings
  case launcher
  case processViewer
  case clipboardHistory
  case networkProbe
  case sleepManagement
  case aiPlayer

  /// Logical routes that share one physical NSWindow must also share restoration ownership.
  var presentationSlot: ShortcutWindowTarget {
    switch self {
    case .main, .shortcutGuide, .settings:
      return .main
    case .launcher, .processViewer, .clipboardHistory, .networkProbe, .sleepManagement, .aiPlayer:
      return self
    }
  }
}

struct ShortcutWindowPresentationSnapshot: Equatable {
  let exists: Bool
  let isVisible: Bool
  let isMiniaturized: Bool
  let appIsHidden: Bool
  let isOnActiveSpace: Bool
  let routeMatches: Bool

  var isPresented: Bool {
    isSystemPresented && routeMatches
  }

  var isSystemPresented: Bool {
    exists
      && isVisible
      && !isMiniaturized
      && !appIsHidden
      && isOnActiveSpace
  }

  /// A visible system state changed around an existing window; restore it without replaying
  /// feature startup side effects such as clearing a launcher query or restarting a speed test.
  var requiresSystemRestoration: Bool {
    exists
      && (isMiniaturized || (isVisible && (appIsHidden || !isOnActiveSpace)))
  }
}

enum ShortcutWindowToggleOutcome: Equatable {
  case shown
  case hidden
  case unavailable
}

struct ShortcutWindowToggleTicket: Equatable {
  let generation: UInt64
  let target: ShortcutWindowTarget
  let wantsPresented: Bool
}

/// O(1) intent coordinator for the whole first-party window family.
///
/// A single generation invalidates delayed work from an older window intent. This matters when
/// the user opens and hides a window again before an asynchronous `makeKeyAndOrderFront` runs.
struct ShortcutWindowToggleState {
  private(set) var generation: UInt64 = 0
  private(set) var pendingTarget: ShortcutWindowTarget?
  private(set) var desiredPresented: Bool?
  private(set) var transitionInFlight = false

  mutating func toggle(
    target: ShortcutWindowTarget,
    snapshot: ShortcutWindowPresentationSnapshot
  ) -> ShortcutWindowToggleTicket {
    let currentlyPresented: Bool
    if transitionInFlight, pendingTarget == target, let desiredPresented {
      currentlyPresented = desiredPresented
    } else {
      currentlyPresented = snapshot.isPresented
    }
    return issue(target: target, wantsPresented: !currentlyPresented)
  }

  mutating func present(target: ShortcutWindowTarget) -> ShortcutWindowToggleTicket {
    issue(target: target, wantsPresented: true)
  }

  mutating func invalidate() {
    generation &+= 1
    pendingTarget = nil
    desiredPresented = nil
    transitionInFlight = false
  }

  mutating func finish(_ ticket: ShortcutWindowToggleTicket) {
    guard accepts(ticket) else { return }
    transitionInFlight = false
  }

  func accepts(_ ticket: ShortcutWindowToggleTicket) -> Bool {
    ticket.generation == generation
  }

  private mutating func issue(
    target: ShortcutWindowTarget,
    wantsPresented: Bool
  ) -> ShortcutWindowToggleTicket {
    generation &+= 1
    pendingTarget = target
    desiredPresented = wantsPresented
    transitionInFlight = true
    return ShortcutWindowToggleTicket(
      generation: generation,
      target: target,
      wantsPresented: wantsPresented)
  }
}
