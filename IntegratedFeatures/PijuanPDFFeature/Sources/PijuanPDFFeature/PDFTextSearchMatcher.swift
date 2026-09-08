import Foundation

enum PDFTextSearchMatcher {
  static func ranges(
    in text: String,
    query: String,
    maximumCount: Int = .max
  ) -> [NSRange] {
    let source = text as NSString
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty, source.length > 0, maximumCount > 0 else { return [] }
    var result: [NSRange] = []
    var cursor = 0
    while cursor < source.length, result.count < maximumCount {
      let searchRange = NSRange(location: cursor, length: source.length - cursor)
      let match = source.range(of: needle, options: [.caseInsensitive], range: searchRange)
      guard match.location != NSNotFound else { break }
      result.append(match)
      cursor = match.location + max(1, match.length)
    }
    return result
  }
}
