import AppKit
import ApplicationServices

enum AccessibilityWindowQueries {
  static func windowFrame(_ window: AXUIElement) -> CGRect? {
    var rawPosition: CFTypeRef?
    var rawSize: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &rawPosition)
        == .success,
      AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &rawSize) == .success,
      rawPosition != nil,
      rawSize != nil
    else {
      return nil
    }
    guard CFGetTypeID(rawPosition!) == AXValueGetTypeID(),
      CFGetTypeID(rawSize!) == AXValueGetTypeID()
    else {
      return nil
    }
    let positionValue = rawPosition as! AXValue
    let sizeValue = rawSize as! AXValue
    var position = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(positionValue, .cgPoint, &position)
    AXValueGetValue(sizeValue, .cgSize, &size)
    return CGRect(origin: position, size: size)
  }

  static func controllableWindow(for appElement: AXUIElement) -> AXUIElement? {
    let windows = axWindows(for: appElement)
    let focused = focusedWindow(for: appElement)
    let main = mainWindow(for: appElement)
    var candidates: [AXUIElement] = []
    for candidate in [focused, main].compactMap({ $0 }) + windows {
      guard !candidates.contains(where: { CFEqual($0, candidate) }) else { continue }
      candidates.append(candidate)
    }
    if let preferred = candidates.first(where: isControllableWindow) {
      return preferred
    }
    return candidates.first(where: { !isWindowMinimized($0) && windowFrame($0) != nil })
      ?? focused
      ?? main
      ?? windows.first
  }

  static func focusedWindow(for appElement: AXUIElement) -> AXUIElement? {
    var rawWindow: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        appElement, kAXFocusedWindowAttribute as CFString, &rawWindow) == .success,
      let rawWindow,
      CFGetTypeID(rawWindow) == AXUIElementGetTypeID()
    else {
      return nil
    }
    return (rawWindow as! AXUIElement)
  }

  static func mainWindow(for appElement: AXUIElement) -> AXUIElement? {
    var rawWindow: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        appElement, kAXMainWindowAttribute as CFString, &rawWindow) == .success,
      let rawWindow,
      CFGetTypeID(rawWindow) == AXUIElementGetTypeID()
    else {
      return nil
    }
    return (rawWindow as! AXUIElement)
  }

  static func axWindowTitle(_ window: AXUIElement) -> String {
    var rawTitle: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &rawTitle)
        == .success,
      let title = rawTitle as? String
    else {
      return ""
    }
    return title
  }

  static func axWindows(for appElement: AXUIElement) -> [AXUIElement] {
    var rawWindows: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &rawWindows)
        == .success,
      let windows = rawWindows as? [AXUIElement]
    else {
      return []
    }
    return windows
  }

  static func isControllableWindow(_ window: AXUIElement) -> Bool {
    guard !isWindowMinimized(window), let frame = windowFrame(window) else { return false }
    return frame.width >= 320 && frame.height >= 180
  }

  static func isWindowMinimized(_ window: AXUIElement) -> Bool {
    var rawMinimized: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &rawMinimized)
        == .success,
      let rawMinimized
    else {
      return false
    }
    return boolValue(from: rawMinimized)
  }

  static func boolValue(from value: CFTypeRef) -> Bool {
    guard CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
    let boolValue = value as! CFBoolean
    return CFBooleanGetValue(boolValue)
  }

}
