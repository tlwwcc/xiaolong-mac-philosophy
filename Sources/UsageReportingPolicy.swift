import Foundation

/// Pure scheduling rules. No timers, preferences, network or user activity monitoring.
struct UsageReportingPolicy {
  private(set) var enabled = false
  private(set) var suspended = false
  private(set) var inFlight = false
  private(set) var failures = 0
  private(set) var nextAttempt: TimeInterval = 0
  private(set) var generation = 0
  private var requestStartedAt: TimeInterval = 0

  mutating func setEnabled(_ value: Bool) {
    enabled = value
    invalidate()
  }

  mutating func setSuspended(_ value: Bool) {
    guard suspended != value else { return }
    suspended = value
    invalidate()
  }

  private mutating func invalidate() {
    generation += 1
    inFlight = false
    failures = 0
    nextAttempt = 0
  }

  mutating func begin(now: TimeInterval) -> Int? {
    guard enabled, !suspended, !inFlight, now >= nextAttempt else { return nil }
    inFlight = true
    requestStartedAt = now
    return generation
  }

  mutating func finish(generation: Int, success: Bool, now: TimeInterval) {
    guard generation == self.generation, inFlight else { return }
    inFlight = false
    failures = success ? 0 : min(failures + 1, 4)
    // Successful requests follow the start-to-start cadence, so a small network
    // delay does not make a 60-second timer skip the next two-minute boundary.
    nextAttempt = success ? requestStartedAt + 120 : now + min(1800, 120 * pow(2, Double(failures)))
  }
}
