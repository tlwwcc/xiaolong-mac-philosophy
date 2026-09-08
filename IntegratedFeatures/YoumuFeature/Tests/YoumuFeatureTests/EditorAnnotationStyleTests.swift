import AppKit
import XCTest

@testable import YoumuFeature

@MainActor
final class EditorAnnotationStyleTests: XCTestCase {
  func testArrowStylePreferencePersistsStableValueAndRejectsUnknownValue() {
    let suiteName = "youmu-arrow-style-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    XCTAssertEqual(ArrowStylePreference.load(from: defaults), .dotGuide)
    ArrowStylePreference.save(.hollow, to: defaults)
    XCTAssertEqual(defaults.string(forKey: ArrowStylePreference.defaultsKey), "hollow")
    XCTAssertEqual(ArrowStylePreference.load(from: defaults), .hollow)

    defaults.set("future-unknown-style", forKey: ArrowStylePreference.defaultsKey)
    XCTAssertEqual(ArrowStylePreference.load(from: defaults), .dotGuide)
  }

  func testArrowLongPressMenuPreviewsAllPresetsAndMarksCurrentOne() {
    let toolbar = EditorToolbarView(frame: CGRect(x: 0, y: 0, width: 900, height: 50))
    toolbar.setArrowStyle(.filled, persist: false, notify: false)

    let menu = toolbar.makeArrowStyleMenu()

    XCTAssertEqual(menu.items.map(\.title), ["空心", "实心", "圆点引导"])
    XCTAssertTrue(menu.items.allSatisfy { $0.image != nil })
    XCTAssertEqual(menu.items.filter { $0.state == .on }.map(\.title), ["实心"])
  }

  func testCanvasCapturesArrowPresetPerAnnotationInsteadOfRetroactivelyChangingIt() throws {
    let image = try XCTUnwrap(makeImage(width: 240, height: 140))
    let canvas = EditorCanvasView(baseCG: image, pixelScale: 1)
    canvas.currentTool = .arrow
    canvas.currentArrowStyle = .hollow

    canvas.handleMouseDown(at: CGPoint(x: 20, y: 30), clickCount: 1, shiftDown: false)
    canvas.handleMouseUp(at: CGPoint(x: 150, y: 90), shiftDown: false)
    canvas.currentArrowStyle = .dotGuide
    canvas.handleMouseDown(at: CGPoint(x: 30, y: 110), clickCount: 1, shiftDown: false)
    canvas.handleMouseUp(at: CGPoint(x: 190, y: 40), shiftDown: false)

    XCTAssertEqual(canvas.annotations.count, 2)
    guard case .arrow(_, _, let firstStyle) = canvas.annotations[0].payload,
          case .arrow(_, _, let secondStyle) = canvas.annotations[1].payload else {
      return XCTFail("Expected two arrow annotations")
    }
    XCTAssertEqual(firstStyle, .hollow)
    XCTAssertEqual(secondStyle, .dotGuide)
  }

  func testRectangleUsesRoundedContinuousPathForPreviewAndExport() {
    let rect = CGRect(x: 12, y: 20, width: 180, height: 92)
    let path = AnnotationRenderer.continuousRoundedRectanglePath(in: rect, lineWidth: 4)

    XCTAssertGreaterThan(path.elementCount, NSBezierPath(rect: rect).elementCount)
    XCTAssertEqual(path.bounds.minX, rect.minX, accuracy: 0.001)
    XCTAssertEqual(path.bounds.minY, rect.minY, accuracy: 0.001)
    XCTAssertEqual(path.bounds.maxX, rect.maxX, accuracy: 0.001)
    XCTAssertEqual(path.bounds.maxY, rect.maxY, accuracy: 0.001)
  }

  private func makeImage(width: Int, height: Int) -> CGImage? {
    let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
    context?.setFillColor(NSColor.white.cgColor)
    context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context?.makeImage()
  }
}
