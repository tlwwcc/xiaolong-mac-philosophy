import Foundation

/// Ordinary in-process work only. The accepted relaunch relay deliberately lives outside this owner.
@MainActor
final class AuthorizationFlowSession {
  enum Lane: Hashable { case flow, registration, repair, hotReload, signature, relaunchWatchdog }
  struct Token: Equatable {
    fileprivate let lane: Lane
    fileprivate let sessionID: UUID
    fileprivate let generation: UUID
  }
  typealias Cancellation = @MainActor () -> Void
  typealias Scheduler = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Cancellation
  private struct Resource {
    let token: Token
    var cancel: Cancellation
  }
  private let identity = UUID()
  private var owners: [Lane: Token] = [:]
  private var resources: [UUID: Resource] = [:]
  private(set) var isStopped = false
  var resourceCount: Int { resources.count }

  func current(_ lane: Lane) -> Token? { owners[lane] }
  func isCurrent(_ token: Token) -> Bool {
    !isStopped && token.sessionID == identity && owners[token.lane] == token
  }

  @discardableResult
  func issue(_ lane: Lane) -> Token? {
    guard !isStopped else { return nil }
    let token = Token(lane: lane, sessionID: identity, generation: UUID())
    owners[lane] = token
    cancelResources { $0.token.lane == lane }
    return isCurrent(token) ? token : nil
  }

  func invalidate(_ lane: Lane) {
    owners.removeValue(forKey: lane)
    cancelResources { $0.token.lane == lane }
  }

  func complete(_ token: Token) {
    guard isCurrent(token) else { return }
    invalidate(token.lane)
  }

  func stop() {
    guard !isStopped else { return }
    isStopped = true
    owners.removeAll()
    cancelResources { _ in true }
  }

  @discardableResult
  func retain(_ token: Token, cancel: @escaping Cancellation) -> UUID? {
    guard isCurrent(token) else { cancel(); return nil }
    let id = UUID()
    resources[id] = Resource(token: token, cancel: cancel)
    return id
  }

  func release(_ id: UUID) { resources.removeValue(forKey: id) }

  func schedule(
    _ token: Token, after delay: TimeInterval, scheduler: Scheduler,
    action: @escaping @MainActor () -> Void
  ) {
    guard isCurrent(token) else { return }
    let id = UUID()
    resources[id] = Resource(token: token, cancel: {})
    let cancel = scheduler(delay) { [weak self] in
      guard let self, self.resources.removeValue(forKey: id) != nil,
        self.isCurrent(token) else { return }
      action()
    }
    if resources[id] != nil, isCurrent(token) {
      resources[id]?.cancel = cancel
    } else {
      cancel()
    }
  }

  private func cancelResources(where matches: (Resource) -> Bool) {
    let victims = resources.filter { matches($0.value) }
    for id in victims.keys { resources.removeValue(forKey: id) }
    // Every registration is detached before a cancellation is allowed to reenter.
    for resource in victims.values { resource.cancel() }
  }

  static func scheduleOnMain(
    after delay: TimeInterval, action: @escaping @MainActor () -> Void
  ) -> Cancellation {
    let work = DispatchWorkItem { action() }
    DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: work)
    return { work.cancel() }
  }
}
