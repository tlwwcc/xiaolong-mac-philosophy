import AppKit
import Testing

@testable import YoumuFeature

@MainActor
@Suite(.serialized)
final class EditorAnnotationStyleTests {
  @Test
  func testArrowStylePreferencePersistsStableValueAndRejectsUnknownValue() {
    let suiteName = "youmu-arrow-style-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect((ArrowStylePreference.load(from: defaults)) == (.dotGuide))
    ArrowStylePreference.save(.hollow, to: defaults)
    #expect((defaults.string(forKey: ArrowStylePreference.defaultsKey)) == ("hollow"))
    #expect((ArrowStylePreference.load(from: defaults)) == (.hollow))

    defaults.set("future-unknown-style", forKey: ArrowStylePreference.defaultsKey)
    #expect((ArrowStylePreference.load(from: defaults)) == (.dotGuide))
  }

  @Test
  func testArrowLongPressMenuPreviewsAllPresetsAndMarksCurrentOne() {
    let toolbar = EditorToolbarView(frame: CGRect(x: 0, y: 0, width: 900, height: 50))
    toolbar.setArrowStyle(.filled, persist: false, notify: false)

    let menu = toolbar.makeArrowStyleMenu()

    #expect((menu.items.map(\.title)) == (["空心", "实心", "圆点引导"]))
    #expect(menu.items.allSatisfy { $0.image != nil })
    #expect((menu.items.filter { $0.state == .on }.map(\.title)) == (["实心"]))
  }

  @Test
  func testCanvasCapturesArrowPresetPerAnnotationInsteadOfRetroactivelyChangingIt() throws {
    let image = try #require(makeImage(width: 240, height: 140))
    let canvas = EditorCanvasView(baseCG: image, pixelScale: 1)
    canvas.currentTool = .arrow
    canvas.currentArrowStyle = .hollow

    canvas.handleMouseDown(at: CGPoint(x: 20, y: 30), clickCount: 1, shiftDown: false)
    canvas.handleMouseUp(at: CGPoint(x: 150, y: 90), shiftDown: false)
    canvas.currentArrowStyle = .dotGuide
    canvas.handleMouseDown(at: CGPoint(x: 30, y: 110), clickCount: 1, shiftDown: false)
    canvas.handleMouseUp(at: CGPoint(x: 190, y: 40), shiftDown: false)

    #expect((canvas.annotations.count) == (2))
    guard case .arrow(_, _, let firstStyle) = canvas.annotations[0].payload,
          case .arrow(_, _, let secondStyle) = canvas.annotations[1].payload else {
      Issue.record(Comment(rawValue: "Expected two arrow annotations")); return
    }
    #expect((firstStyle) == (.hollow))
    #expect((secondStyle) == (.dotGuide))
  }

  @Test
  func testRectangleUsesRoundedContinuousPathForPreviewAndExport() {
    let rect = CGRect(x: 12, y: 20, width: 180, height: 92)
    let path = AnnotationRenderer.continuousRoundedRectanglePath(in: rect, lineWidth: 4)

    #expect((path.elementCount) > (NSBezierPath(rect: rect).elementCount))
    #expect(((path.bounds.minX) == (rect.minX) || abs((path.bounds.minX) - (rect.minX)) <= (0.001)))
    #expect(((path.bounds.minY) == (rect.minY) || abs((path.bounds.minY) - (rect.minY)) <= (0.001)))
    #expect(((path.bounds.maxX) == (rect.maxX) || abs((path.bounds.maxX) - (rect.maxX)) <= (0.001)))
    #expect(((path.bounds.maxY) == (rect.maxY) || abs((path.bounds.maxY) - (rect.maxY)) <= (0.001)))
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
