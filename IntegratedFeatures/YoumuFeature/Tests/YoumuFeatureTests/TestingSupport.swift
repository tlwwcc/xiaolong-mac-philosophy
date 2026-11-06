import Foundation
import Testing

/// A throwing assertion retains the original typed-error inspection closure.
func expectThrowsError<T>(
  _ expression: @autoclosure () throws -> T,
  _ message: @autoclosure () -> String = "",
  sourceLocation: SourceLocation = #_sourceLocation,
  _ inspect: (any Error) -> Void = { _ in }
) {
  do {
    _ = try expression()
    Issue.record(
      Comment(rawValue: "Expected an error. " + message()), sourceLocation: sourceLocation)
  } catch {
    inspect(error)
  }
}

/// Bounded asynchronous event observation. No blocking wait occupies the main actor.
final class TestSignal: @unchecked Sendable {
  let description: String
  private let lock = NSLock()
  private var count = 0
  private var expected = 1

  init(description: String) { self.description = description }

  var expectedFulfillmentCount: Int {
    get { lock.lock(); defer { lock.unlock() }; return expected }
    set { lock.lock(); expected = newValue; lock.unlock() }
  }

  func fulfill() {
    lock.lock()
    count += 1
    lock.unlock()
  }

  var fulfilled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return count >= expected
  }
}

func awaitTestSignals(
  of signals: [TestSignal], timeout: TimeInterval,
  sourceLocation: SourceLocation = #_sourceLocation
) async {
  let deadline = ProcessInfo.processInfo.systemUptime + timeout
  while !signals.allSatisfy(\.fulfilled), ProcessInfo.processInfo.systemUptime < deadline {
    try? await Task.sleep(nanoseconds: 1_000_000)
  }
  let missing = signals.filter { !$0.fulfilled }.map(\.description)
  #expect(missing.isEmpty, Comment(rawValue: "Timed out: " + missing.joined(separator: ", ")),
          sourceLocation: sourceLocation)
}
