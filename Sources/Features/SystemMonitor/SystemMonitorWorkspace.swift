import Combine
import Foundation

/// Owns the sampler and its timer. UI visibility may stop/restart sampling; shutdown is terminal.
@MainActor
final class SystemMonitorWorkspace: ObservableObject {
  @Published private(set) var snapshot = SystemMonitorSnapshot.empty
  private let sample: @MainActor () -> SystemMonitorSnapshot
  private let schedule: @MainActor (@escaping @MainActor () -> Void) -> (() -> Void)
  private var cancellation: (() -> Void)?
  private var generation = UUID()
  private var running = false
  private var stopped = false

  init(
    sample: (@MainActor () -> SystemMonitorSnapshot)? = nil,
    schedule: (@MainActor (@escaping @MainActor () -> Void) -> (() -> Void))? = nil
  ) {
    let monitor = SystemMonitor()
    self.sample = sample ?? { monitor.sample() }
    self.schedule = schedule ?? { action in
      let timer = Timer(timeInterval: 1, repeats: true) { _ in
        MainActor.assumeIsolated { action() }
      }
      RunLoop.main.add(timer, forMode: .common)
      return { timer.invalidate() }
    }
  }

  func start() {
    guard !stopped else { return }
    if running {
      refresh()
      return
    }
    running = true
    let owner = UUID()
    generation = owner
    refresh()
    guard !stopped, running, generation == owner else { return }
    let cancel = schedule { [weak self] in
      guard let self, !self.stopped, self.running, self.generation == owner else { return }
      self.refresh()
    }
    guard !stopped, running, generation == owner else { cancel(); return }
    cancellation = cancel
  }

  func refresh() {
    guard !stopped else { return }
    let owner = generation
    let value = sample()
    guard !stopped, generation == owner else { return }
    snapshot = value
  }

  func stop() {
    generation = UUID()
    running = false
    let cancel = cancellation
    cancellation = nil
    cancel?()
  }

  func shutdown() {
    guard !stopped else { return }
    stopped = true
    stop()
  }
}
