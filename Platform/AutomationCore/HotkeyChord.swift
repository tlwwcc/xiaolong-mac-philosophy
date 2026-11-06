import Foundation

/// An unambiguous textual chord. Physical key codes remain the macOS adapter's responsibility.
public struct HotkeyChord: Codable, Equatable, Sendable {
  public let key: String
  public let modifiers: [String]

  public var canonical: String { (modifiers + [key]).joined(separator: "+") }

  public init(key: String, modifiers: [String]) throws {
    let parts = modifiers + [key]
    self = try Self.parse(parts.joined(separator: "+"))
  }

  private enum CodingKeys: String, CodingKey { case key, modifiers }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      key: container.decode(String.self, forKey: .key),
      modifiers: container.decode([String].self, forKey: .modifiers))
  }

  private init(normalizedKey: String, normalizedModifiers: [String]) {
    key = normalizedKey
    modifiers = normalizedModifiers
  }

  public static func parse(_ text: String) throws -> HotkeyChord {
    guard text.utf8.count <= 256 else { throw invalid("快捷键过长。") }
    let tokens = text.components(separatedBy: "+").map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !tokens.isEmpty, tokens.allSatisfy({ !$0.isEmpty }) else {
      throw invalid("请用加号分隔修饰键和一个按键，例如 Caps+K。")
    }
    var modifiers = Set<String>()
    var key: String?
    for token in tokens {
      let lower = token.lowercased()
      if let modifier = modifierAliases[lower] {
        guard key == nil else { throw invalid("修饰键必须写在按键前面。") }
        let additions = modifier == "caps" ? ["control", "option"] : [modifier]
        guard additions.allSatisfy({ !modifiers.contains($0) }) else {
          throw invalid("修饰键重复，Caps 已包含 control 和 option。")
        }
        modifiers.formUnion(additions)
      } else {
        guard key == nil, let normalized = normalizeKey(token) else {
          throw invalid("无法识别按键「\(token)」，未猜测或修改。")
        }
        key = normalized
      }
    }
    guard let key else { throw invalid("快捷键缺少具体按键。") }
    return HotkeyChord(
      normalizedKey: key,
      normalizedModifiers: ["control", "option", "shift", "command"].filter(modifiers.contains))
  }

  private static let modifierAliases = [
    "caps": "caps", "ctrl": "control", "control": "control", "⌃": "control",
    "alt": "option", "opt": "option", "option": "option", "⌥": "option",
    "shift": "shift", "⇧": "shift", "cmd": "command", "command": "command", "⌘": "command",
  ]

  private static let keyAliases = [
    "space": "Space", "spacebar": "Space", "空格": "Space",
    "return": "Return", "enter": "Return", "回车": "Return",
    "tab": "Tab", "escape": "Escape", "esc": "Escape",
    "delete": "Delete", "backspace": "Delete", "forwarddelete": "ForwardDelete",
    "left": "Left", "←": "Left", "right": "Right", "→": "Right",
    "up": "Up", "↑": "Up", "down": "Down", "↓": "Down",
    "home": "Home", "end": "End", "pageup": "PageUp", "pagedown": "PageDown",
    "minus": "-", "equal": "=", "comma": ",", "period": ".",
    "slash": "/", "backslash": "\\", "semicolon": ";", "quote": "'",
    "leftbracket": "[", "rightbracket": "]", "backtick": "`",
  ]

  private static func normalizeKey(_ token: String) -> String? {
    if let known = keyAliases[token.lowercased()] { return known }
    if token.utf8.count == 1, let scalar = token.unicodeScalars.first {
      if (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
        || (48...57).contains(scalar.value) {
        return token.uppercased()
      }
      if "-=,./\\;'[]`".contains(token) { return token }
    }
    let lower = token.lowercased()
    if lower.hasPrefix("f"), let number = Int(lower.dropFirst()),
      (1...20).contains(number), lower == "f\(number)" {
      return "F\(number)"
    }
    return nil
  }

  private static func invalid(_ message: String) -> AutomationError {
    AutomationError(code: "invalid_hotkey", message: message)
  }
}
