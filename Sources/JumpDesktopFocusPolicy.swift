enum JumpDesktopFocusPolicy {
  static func isRemoteCanvas(
    bundleIdentifier: String?,
    windowRole: String?,
    focusedRole: String?,
    focusedChildCount: Int?,
    isModal: Bool,
    isMinimized: Bool
  ) -> Bool {
    guard
      bundleIdentifier == "com.p5sys.jump.mac.viewer.web"
        || bundleIdentifier == "com.p5sys.jump.mac.viewer"
    else {
      return false
    }

    return windowRole == "AXWindow"
      && focusedRole == "AXScrollArea"
      && focusedChildCount == 0
      && !isModal
      && !isMinimized
  }

  static func shouldYieldLocalHotkeys(
    bundleIdentifier: String?,
    windowRole: String?,
    focusedRole: String?,
    focusedChildCount: Int?,
    isModal: Bool?,
    isMinimized: Bool?
  ) -> Bool {
    guard
      bundleIdentifier == "com.p5sys.jump.mac.viewer.web"
        || bundleIdentifier == "com.p5sys.jump.mac.viewer"
    else {
      return false
    }
    guard let windowRole, let focusedRole, let focusedChildCount,
      let isModal, let isMinimized, focusedChildCount >= 0
    else {
      return true
    }
    if isModal || isMinimized { return false }
    guard windowRole == "AXWindow" else { return true }

    if focusedRole == "AXScrollArea" {
      return focusedChildCount == 0
    }
    switch focusedRole {
    case "AXButton", "AXCheckBox", "AXTextField", "AXTextArea", "AXComboBox",
      "AXTable", "AXOutline", "AXPopUpButton", "AXRadioButton", "AXTabGroup",
      "AXWindow", "AXMenuBar", "AXMenuItem":
      return false
    default:
      return true
    }
  }
}
