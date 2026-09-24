import Foundation

enum ProductReleaseIdentity {
  static let publishedAt = "2026-09-24T00:00:00+08:00"

  static func matchesPublicationMetadata(_ value: String?) -> Bool {
    !isFormalRelease || value == publishedAt
  }

  #if AIXLG_FORMAL_RELEASE
    static let isFormalRelease = true
  #else
    static let isFormalRelease = false
  #endif
}

enum UpdateReleaseDecision: Equatable, Sendable {
  case allowed
  case denied(String)

  var isAllowed: Bool {
    if case .allowed = self { return true }
    return false
  }

  var denialMessage: String? {
    guard case .denied(let message) = self else { return nil }
    return message
  }
}

/// Updates are free. A valid publication date is still required before package verification.
enum UpdateReleasePolicy {
  static func decision(publishedAt: String) -> UpdateReleaseDecision {
    let value = publishedAt.trimmingCharacters(in: .whitespacesAndNewlines)
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let seconds = ISO8601DateFormatter()
    seconds.formatOptions = [.withInternetDateTime]
    let dateOnly = DateFormatter()
    dateOnly.locale = Locale(identifier: "en_US_POSIX")
    dateOnly.calendar = Calendar(identifier: .gregorian)
    dateOnly.timeZone = TimeZone(secondsFromGMT: 0)
    dateOnly.dateFormat = "yyyy-MM-dd"
    dateOnly.isLenient = false
    let validDateOnly = dateOnly.date(from: value).map { dateOnly.string(from: $0) == value } ?? false
    guard !value.isEmpty,
      fractional.date(from: value) != nil || seconds.date(from: value) != nil || validDateOnly
    else {
      return .denied("新版缺少可信发布日期，暂时不能安装更新。")
    }
    return .allowed
  }
}
