import Foundation

/// Owns foreground-repair intentions and their scheduled work, independently of AppKit.
/// Cancellation is verified again at delivery, because cancelling a queued callback is not proof
/// that it will never be delivered. The lifetime is terminal: a stopped session cannot restart.
@MainActor
final class ApplicationActivationSession {
  struct Token: Equatable, Hashable, Sendable {
    let key: String
    let value: UInt64
    fileprivate let sessionIdentity: UUID
  }

  typealias Cancellation = @MainActor () -> Void
  typealias Scheduler = @MainActor (
    TimeInterval, @escaping @MainActor @Sendable () -> Void
  ) -> Cancellation

  private struct Job {
    let key: String?
    let activation: Token?
    let execute: @MainActor @Sendable () -> Void
    let onStale: (@MainActor @Sendable () -> Void)?
    var cancel: Cancellation?
  }

  private struct Resource {
    let key: String?
    let cancel: Cancellation
  }

  private let sessionIdentity = UUID()
  private var sequence: UInt64
  private var owners: [String: Token] = [:]
  private var jobs: [UUID: Job] = [:]
  private var resources: [UUID: Resource] = [:]
  private let scheduler: Scheduler
  private(set) var isStopped = false

  /// The sequence injection exists to exercise exhaustion without billions of operations.
  /// A token also belongs to one session, so a new session cannot revive an old token.
  init(
    initialSequence: UInt64 = 0,
    scheduler: @escaping Scheduler = ApplicationActivationSession.mainQueueScheduler
  ) {
    sequence = initialSequence
    self.scheduler = scheduler
  }

  var activeKeys: [String] { owners.keys.sorted() }
  var scheduledCount: Int { jobs.count }
  var resourceCount: Int { resources.count }

  func currentToken(for key: String) -> Token? { owners[key] }

  func issue(for key: String) -> Token? {
    guard !isStopped, !key.isEmpty else { return nil }
    let (next, overflow) = sequence.addingReportingOverflow(1)
    guard !overflow else {
      _ = stop()
      return nil
    }
    sequence = next
    let token = Token(key: key, value: next, sessionIdentity: sessionIdentity)
    // Replace ownership before cancelling detached work. A cancellation may synchronously issue
    // a newer owner; this invocation must not overwrite or return authority over that newer one.
    owners[key] = token
    _ = cancelOwnedWork(for: key)
    return isCurrent(token) ? token : nil
  }

  func isCurrent(_ token: Token?) -> Bool {
    guard !isStopped else { return false }
    // Existing immediate activation routes allow nil ownership, but stopped routes never do.
    guard let token else { return true }
    return token.sessionIdentity == sessionIdentity && owners[token.key] == token
  }

  /// Cancels scheduled work without relinquishing the active owner (used when rescheduling).
  @discardableResult
  func cancelScheduled(for key: String) -> Int {
    cancelWork(jobIDs: jobs.compactMap { $0.value.key == key ? $0.key : nil }, resourceIDs: [])
  }

  @discardableResult
  func invalidate(for key: String) -> Int {
    owners.removeValue(forKey: key)
    return cancelOwnedWork(for: key)
  }

  /// An obsolete completion must never remove a newer owner's token or its scheduled work.
  @discardableResult
  func complete(_ token: Token) -> Int {
    guard isCurrent(token) else { return 0 }
    return invalidate(for: token.key)
  }

  @discardableResult
  func stop() -> Int {
    guard !isStopped else { return 0 }
    isStopped = true
    owners.removeAll()
    return cancelWork(jobIDs: Array(jobs.keys), resourceIDs: Array(resources.keys))
  }

  /// Retains a cancellable operation that has already started, such as an owned child process.
  /// A rejected registration is cancelled immediately, including nil-token work after stop.
  @discardableResult
  func retainResource(
    activation: Token?, fallbackKey: String?, cancel: @escaping Cancellation
  ) -> UUID? {
    guard isCurrent(activation) else {
      cancel()
      return nil
    }
    let id = UUID()
    resources[id] = Resource(key: activation?.key ?? fallbackKey, cancel: cancel)
    return id
  }

  /// Normal completion relinquishes ownership without cancelling a successfully finished action.
  /// A late completion is harmless if cancellation already removed the registration.
  func releaseResource(_ id: UUID) {
    resources.removeValue(forKey: id)
  }

  /// All work belongs to the session, including routes without an app key.
  /// The scheduler retains only a weak session reference and a job ID; cancelling a job releases
  /// its action captures immediately, even if the underlying queue later delivers its trampoline.
  @discardableResult
  func schedule(
    activation: Token?, fallbackKey: String?, delay: TimeInterval,
    execute: @MainActor @Sendable @escaping () -> Void,
    onStale: (@MainActor @Sendable () -> Void)? = nil
  ) -> UUID? {
    guard !isStopped, delay.isFinite, delay >= 0, isCurrent(activation) else {
      onStale?()
      return nil
    }
    let key = activation?.key ?? fallbackKey
    let id = UUID()
    jobs[id] = Job(key: key, activation: activation, execute: execute, onStale: onStale)
    let cancel = scheduler(delay) { [weak self] in
      self?.deliver(id)
    }
    // An injected scheduler may deliver synchronously or stop the session reentrantly.
    if jobs[id] != nil {
      jobs[id]?.cancel = cancel
    } else {
      cancel()
    }
    return id
  }

  private func deliver(_ id: UUID) {
    guard let job = jobs.removeValue(forKey: id) else { return }
    guard !isStopped, isCurrent(job.activation) else {
      job.onStale?()
      return
    }
    job.execute()
  }

  private func cancelOwnedWork(for key: String) -> Int {
    cancelWork(
      jobIDs: jobs.compactMap { $0.value.key == key ? $0.key : nil },
      resourceIDs: resources.compactMap { $0.value.key == key ? $0.key : nil })
  }

  private func cancelWork(jobIDs: [UUID], resourceIDs: [UUID]) -> Int {
    // Detach both collections before invoking any callback: a process cancellation can reenter
    // the session, complete its request or force an already queued callback to be delivered.
    let cancelledJobs = jobIDs.compactMap { jobs.removeValue(forKey: $0) }
    let cancelledResources = resourceIDs.compactMap { resources.removeValue(forKey: $0) }
    for job in cancelledJobs { job.cancel?() }
    for resource in cancelledResources { resource.cancel() }
    return cancelledJobs.count + cancelledResources.count
  }

  private static func mainQueueScheduler(
    delay: TimeInterval, action: @MainActor @Sendable @escaping () -> Void
  ) -> Cancellation {
    let item = DispatchWorkItem {
      MainActor.assumeIsolated { action() }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    return { item.cancel() }
  }
}
