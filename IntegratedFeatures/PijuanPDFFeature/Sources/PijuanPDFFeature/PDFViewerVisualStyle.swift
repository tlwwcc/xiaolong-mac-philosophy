import AppKit
import SwiftUI

// White-on-purple controls retain the canonical brand fill. Text and icons use a brighter
// purple in dark appearance so they stay legible without recoloring PDF pages or exports.
let pdfBrandFill = Color(red: 107.0 / 255.0, green: 35.0 / 255.0, blue: 142.0 / 255.0)
let pdfBrandPurple = Color(nsColor: NSColor(name: "PijuanBrandAccent") { appearance in
  appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    ? NSColor(calibratedRed: 0.80, green: 0.65, blue: 0.91, alpha: 1)
    : NSColor(calibratedRed: 107.0 / 255.0, green: 35.0 / 255.0, blue: 142.0 / 255.0, alpha: 1)
})
let pdfPanelBorder = Color(nsColor: .separatorColor)
