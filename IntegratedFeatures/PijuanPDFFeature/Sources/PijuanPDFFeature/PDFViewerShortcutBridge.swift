import AppKit
import SwiftUI

extension PDFViewerShortcutModifiers {
  var eventModifiers: EventModifiers {
    var result: EventModifiers = []
    if contains(.control) { result.insert(.control) }
    if contains(.option) { result.insert(.option) }
    if contains(.shift) { result.insert(.shift) }
    if contains(.command) { result.insert(.command) }
    return result
  }

  init(eventFlags: NSEvent.ModifierFlags) {
    var result: Self = []
    let flags = eventFlags.intersection(.deviceIndependentFlagsMask)
    if flags.contains(.control) { result.insert(.control) }
    if flags.contains(.option) { result.insert(.option) }
    if flags.contains(.shift) { result.insert(.shift) }
    if flags.contains(.command) { result.insert(.command) }
    self = result
  }
}

extension PDFViewerShortcutKey {
  var keyEquivalent: KeyEquivalent {
    KeyEquivalent(Character(rawValue))
  }

  init?(specialKeyCode: UInt16) {
    let rawValue: String?
    switch specialKeyCode {
    case 126: rawValue = "\u{F700}"
    case 125: rawValue = "\u{F701}"
    case 123: rawValue = "\u{F702}"
    case 124: rawValue = "\u{F703}"
    case 122: rawValue = "\u{F704}"
    case 120: rawValue = "\u{F705}"
    case 99: rawValue = "\u{F706}"
    case 118: rawValue = "\u{F707}"
    case 96: rawValue = "\u{F708}"
    case 97: rawValue = "\u{F709}"
    case 98: rawValue = "\u{F70A}"
    case 100: rawValue = "\u{F70B}"
    case 101: rawValue = "\u{F70C}"
    case 109: rawValue = "\u{F70D}"
    case 103: rawValue = "\u{F70E}"
    case 111: rawValue = "\u{F70F}"
    default: rawValue = nil
    }
    guard let rawValue else { return nil }
    self.init(rawValue: rawValue)
  }
}

extension PDFViewerShortcut {
  init?(event: NSEvent) {
    let key: PDFViewerShortcutKey
    if let specialKey = PDFViewerShortcutKey(specialKeyCode: event.keyCode) {
      key = specialKey
    } else {
      guard let characters = event.characters(byApplyingModifiers: []),
        characters.count == 1,
        let character = characters.first
      else { return nil }
      key = PDFViewerShortcutKey(character)
    }
    self.init(
      key: key,
      modifiers: PDFViewerShortcutModifiers(eventFlags: event.modifierFlags))
  }
}
