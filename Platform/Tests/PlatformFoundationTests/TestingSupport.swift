import Testing

/// Keep exact error-value checks while reporting a missing throw to Swift Testing.
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
