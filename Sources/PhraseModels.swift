import Foundation

struct PhraseItem: Codable, Equatable, Identifiable {
  var id: String
  var trigger: String
  var output: String
  var enabled: Bool
  var note: String

  var normalizedTrigger: String {
    trigger.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}

func defaultPhrases() -> [PhraseItem] {
  []
}
