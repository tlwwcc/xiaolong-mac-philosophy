import Foundation

/// PDFKit parsing and page text extraction are synchronous and do not honor cooperative task
/// cancellation while they are inside the framework. A single process-wide actor therefore owns
/// every expensive PDF operation. New opens and searches wait for the previous operation to leave
/// PDFKit instead of multiplying memory by the number of rapidly cancelled requests.
actor PDFSerialWorkGate {
  static let shared = PDFSerialWorkGate()

  func run<Value: Sendable>(
    _ operation: @Sendable () throws -> Value
  ) rethrows -> Value {
    try operation()
  }
}
