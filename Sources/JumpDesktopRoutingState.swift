/// Pure ownership policy. AX reads may revoke a grant; only a verified click
/// may create one. A pointer crossing cannot transfer a held chord.
struct JumpDesktopRoutingState {
  enum Owner: Equatable {
    case local
    case pending(UInt64)
    case remote(UInt64)
  }

  private(set) var owner: Owner = .local
  private(set) var desiredOwner: Owner = .local
  private(set) var chordHeld = false
  private(set) var chordCancelled = false
  private var clickGeneration: UInt64 = 0

  var shouldYieldLocalHotkeys: Bool { owner != .local }
  var allowsChordKeyDown: Bool {
    if chordCancelled { return false }
    if case .pending = owner { return false }
    return true
  }

  mutating func beginClick() -> UInt64 {
    clickGeneration &+= 1
    request(.pending(clickGeneration), cancelHeldChord: true)
    return clickGeneration
  }

  @discardableResult
  mutating func resolveClick(_ generation: UInt64, canvas: UInt64?) -> Bool {
    guard generation == clickGeneration,
      desiredOwner == .pending(generation) else { return false }
    request(canvas.map(Owner.remote) ?? .local, cancelHeldChord: false)
    return true
  }

  mutating func pointerLeftCanvas() {
    clickGeneration &+= 1
    request(.local, cancelHeldChord: false)
  }

  mutating func localInteraction() {
    clickGeneration &+= 1
    let crossesRoute = owner != .local || desiredOwner != .local
    request(.local, cancelHeldChord: crossesRoute)
  }

  mutating func validateCanvas(_ canvas: UInt64?) {
    // A missing/changed canvas invalidates the old session. A later AX read
    // must not re-enable it after a menu closes or the pointer moves back.
    if case .remote(let granted) = desiredOwner, granted != canvas {
      localInteraction()
    }
  }

  mutating func setChordHeld(_ held: Bool) {
    guard held != chordHeld else { return }
    chordHeld = held
    if !held {
      owner = desiredOwner
      chordCancelled = false
    }
  }

  mutating func stop() {
    clickGeneration &+= 1
    owner = .local
    desiredOwner = .local
    chordHeld = false
    chordCancelled = false
  }

  private mutating func request(_ next: Owner, cancelHeldChord: Bool) {
    desiredOwner = next
    if chordHeld {
      if cancelHeldChord { chordCancelled = true }
    } else {
      owner = next
    }
  }
}

/// Balance releases independently of Caps: Caps may be released before the
/// letter. A cancelled repeat must not swallow the up of a delivered down.
struct CapsRoutingKeyLedger {
  private var keys = Set<UInt16>()
  private var suppressed = Set<UInt16>()
  var hasHeldKeys: Bool { !keys.isEmpty }
  func contains(_ key: UInt16) -> Bool { keys.contains(key) }
  mutating func press(_ key: UInt16, cancelled: Bool) -> Bool {
    let began = keys.insert(key).inserted
    if cancelled {
      if began { suppressed.insert(key) }
      return false
    }
    return !suppressed.contains(key)
  }
  mutating func release(_ key: UInt16) -> Bool {
    keys.remove(key)
    return suppressed.remove(key) == nil
  }
  mutating func reset() { keys.removeAll(); suppressed.removeAll() }
}
