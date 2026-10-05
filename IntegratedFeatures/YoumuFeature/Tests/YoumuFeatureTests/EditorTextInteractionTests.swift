import AppKit
import XCTest
@testable import YoumuFeature

@MainActor
final class EditorTextInteractionTests: XCTestCase {
    private func canvas(scale: CGFloat = 1) throws -> EditorCanvasView {
        _ = NSApplication.shared
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(640 * scale), height: Int(480 * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 640 * scale, height: 480 * scale))
        return EditorCanvasView(baseCG: try XCTUnwrap(context.makeImage()), pixelScale: scale)
    }

    @discardableResult
    private func start(_ canvas: EditorCanvasView, at point: CGPoint = CGPoint(x: 40, y: 360),
                       string: String = "") throws -> EditorTextView {
        canvas.currentTool = .text
        canvas.handleMouseDown(at: point, clickCount: 1, shiftDown: false)
        let editor = try XCTUnwrap(canvas.textEditor)
        if !string.isEmpty { editor.insertText(string, replacementRange: editor.selectedRange()) }
        return editor
    }

    private func text(_ annotation: Annotation) -> String {
        if case .text(_, let string, _, _) = annotation.payload { return string }
        XCTFail("Expected text annotation")
        return ""
    }

    func testReturnKeepsParagraphOpenAndGrowsDownward() throws {
        let canvas = try canvas()
        let editor = try start(canvas, string: "第一行")
        let oldTop = editor.frame.maxY
        let oldHeight = editor.frame.height
        canvas.handleKeyDown(keyCode: 36, modifiers: [])
        editor.insertText("第二行", replacementRange: editor.selectedRange())
        XCTAssertTrue(canvas.textEditor === editor)
        XCTAssertTrue(canvas.annotations.isEmpty)
        XCTAssertEqual(editor.string, "第一行\n第二行")
        XCTAssertGreaterThan(editor.frame.height, oldHeight)
        XCTAssertEqual(editor.frame.maxY, oldTop, accuracy: 0.01)
        canvas.finishTextEditing(commit: true)
        XCTAssertEqual(text(try XCTUnwrap(canvas.annotations.first)), "第一行\n第二行")
        XCTAssertEqual(canvas.annotations[0].boundingRect.maxY, 360, accuracy: 0.01)
    }

    func testLongPastedParagraphWrapsAtFrozenWidthIncludingBlankLines() throws {
        let canvas = try canvas()
        let editor = try start(canvas, at: CGPoint(x: 400, y: 400),
            string: "长段落 ABC 很长很长很长很长很长\n\n第二段\n")
        let manager = try XCTUnwrap(editor.layoutManager)
        let container = try XCTUnwrap(editor.textContainer)
        let native = EditorTextLayout.size(manager: manager, container: container, font: try XCTUnwrap(editor.font))
        canvas.finishTextEditing(commit: true)
        let annotation = try XCTUnwrap(canvas.annotations.first)
        XCTAssertEqual(annotation.boundingRect.width, native.width, accuracy: 0.01)
        XCTAssertEqual(annotation.boundingRect.height, native.height, accuracy: 0.01)
        XCTAssertLessThanOrEqual(annotation.boundingRect.width, 240)
        XCTAssertGreaterThan(annotation.boundingRect.height, 4 * 24)
        XCTAssertTrue(text(annotation).hasSuffix("\n"))
    }

    func testClickBlankCommitsFirstParagraphAndStartsIndependentSecondParagraph() throws {
        let canvas = try canvas()
        try start(canvas, string: "第一段\n继续")
        canvas.handleMouseDown(at: CGPoint(x: 100, y: 200), clickCount: 1, shiftDown: false)
        let second = try XCTUnwrap(canvas.textEditor)
        second.insertText("另一段", replacementRange: second.selectedRange())
        canvas.finishTextEditing(commit: true)
        XCTAssertEqual(canvas.annotations.map(text), ["第一段\n继续", "另一段"])
        XCTAssertEqual(canvas.annotations[0].boundingRect.maxY, 360, accuracy: 0.01)
        XCTAssertEqual(canvas.annotations[1].boundingRect.maxY, 200, accuracy: 0.01)
        XCTAssertFalse(canvas.annotations[0].boundingRect.intersects(canvas.annotations[1].boundingRect))
    }

    func testClickExistingTextContinuesSameParagraphAndRepeatedEditingDoesNotDrift() throws {
        let canvas = try canvas()
        try start(canvas, string: "Hello\n夸夸")
        canvas.finishTextEditing(commit: true)
        let initial = canvas.annotations[0].boundingRect
        for _ in 0..<5 {
            canvas.handleMouseDown(at: CGPoint(x: initial.midX, y: initial.midY), clickCount: 1, shiftDown: false)
            XCTAssertEqual(canvas.textEditor?.string, "Hello\n夸夸")
            canvas.finishTextEditing(commit: true)
            XCTAssertEqual(canvas.annotations.count, 1)
            XCTAssertEqual(canvas.annotations[0].boundingRect, initial)
        }
        canvas.undo()
        XCTAssertTrue(canvas.annotations.isEmpty, "无改动的重编辑不能产生多余历史")
        canvas.redo()
        XCTAssertEqual(canvas.annotations.count, 1)
    }

    func testToolChangeKeepsTypedParagraphAndOutputCommitsPendingDraft() throws {
        let canvas = try canvas()
        try start(canvas, string: "不能丢失")
        canvas.currentTool = .arrow
        XCTAssertNil(canvas.textEditor)
        XCTAssertEqual(canvas.annotations.map(text), ["不能丢失"])
        canvas.currentColor = .systemBlue
        XCTAssertEqual(canvas.annotations[0].color, EditorColorPreset.red.color,
                       "切换到箭头后改颜色只影响下一笔，不能误改上一段文字")
        try start(canvas, at: CGPoint(x: 40, y: 200), string: "输出前还没结束\n下一行")
        canvas.finishTextEditing(commit: true) // 复制、保存、钉图的共同入口
        XCTAssertEqual(canvas.annotations.count, 2)
        XCTAssertEqual(text(canvas.annotations[1]), "输出前还没结束\n下一行")
    }

    func testCancelRestoresOriginalAndClearingParagraphDeletesWithUndo() throws {
        let canvas = try canvas()
        try start(canvas, string: "原文")
        canvas.finishTextEditing(commit: true)
        let rect = canvas.annotations[0].boundingRect
        canvas.currentTool = .select
        canvas.handleMouseDown(at: CGPoint(x: rect.midX, y: rect.midY), clickCount: 2, shiftDown: false)
        let editor = try XCTUnwrap(canvas.textEditor)
        editor.insertText("修改", replacementRange: NSRange(location: 0, length: 2))
        editor.cancelOperation(nil)
        XCTAssertEqual(canvas.annotations.map(text), ["原文"])
        canvas.handleMouseDown(at: CGPoint(x: rect.midX, y: rect.midY), clickCount: 2, shiftDown: false)
        canvas.textEditor?.insertText("", replacementRange: NSRange(location: 0, length: 2))
        canvas.finishTextEditing(commit: true)
        XCTAssertTrue(canvas.annotations.isEmpty)
        canvas.undo()
        XCTAssertEqual(canvas.annotations.map(text), ["原文"])
    }

    func testEmptyCancelledDraftDoesNotAddAnnotationOrConsumeHistory() throws {
        let canvas = try canvas()
        try start(canvas, string: "   \n")
        canvas.finishTextEditing(commit: true)
        XCTAssertTrue(canvas.annotations.isEmpty)
        try start(canvas, string: "取消")
        canvas.finishTextEditing(commit: false)
        XCTAssertTrue(canvas.annotations.isEmpty)
        XCTAssertNil(canvas.textEditor)
    }

    func testStyleChangesAffectCurrentAndSelectedParagraphAndKeepTopAnchor() throws {
        let canvas = try canvas()
        let editor = try start(canvas, string: "标题\n正文")
        let top = editor.frame.maxY
        canvas.currentColor = .systemBlue
        canvas.setWidth(.thick)
        XCTAssertEqual(editor.textColor, .systemBlue)
        XCTAssertEqual(editor.font?.pointSize, StrokeWidth.thick.fontSize)
        XCTAssertEqual(editor.frame.maxY, top, accuracy: 0.01)
        canvas.finishTextEditing(commit: true)
        XCTAssertEqual(canvas.annotations[0].color, .systemBlue)
        let firstTop = canvas.annotations[0].boundingRect.maxY
        canvas.setWidth(.thin)
        canvas.currentColor = .systemGreen
        XCTAssertEqual(canvas.annotations[0].color, .systemGreen)
        XCTAssertEqual(canvas.annotations[0].boundingRect.maxY, firstTop, accuracy: 0.01)
        canvas.undo()
        XCTAssertEqual(canvas.annotations[0].color, .systemBlue)
    }

    func testReeditUsesOriginalStyleAndSelectDragMovesWholeMultilineBlock() throws {
        let canvas = try canvas()
        try start(canvas, string: "两行\n一起移动")
        canvas.finishTextEditing(commit: true)
        let rect = canvas.annotations[0].boundingRect
        canvas.currentTool = .select
        canvas.handleMouseDown(at: CGPoint(x: 600, y: 20), clickCount: 1, shiftDown: false)
        canvas.currentColor = .systemBlue
        canvas.setWidth(.thick)
        canvas.handleMouseDown(at: CGPoint(x: rect.midX, y: rect.midY), clickCount: 2, shiftDown: false)
        XCTAssertEqual(canvas.textEditor?.textColor, EditorColorPreset.red.color)
        XCTAssertEqual(canvas.textEditor?.font?.pointSize, StrokeWidth.medium.fontSize)
        canvas.finishTextEditing(commit: true)
        let point = CGPoint(x: rect.midX, y: rect.midY)
        canvas.handleMouseDown(at: point, clickCount: 1, shiftDown: false)
        canvas.handleMouseDragged(to: CGPoint(x: point.x + 60, y: point.y - 30), shiftDown: false)
        canvas.handleMouseUp(at: CGPoint(x: point.x + 60, y: point.y - 30), shiftDown: false)
        XCTAssertEqual(canvas.annotations[0].boundingRect, rect.offsetBy(dx: 60, dy: -30))
        canvas.undo()
        XCTAssertEqual(canvas.annotations[0].boundingRect, rect)
        canvas.redo()
        XCTAssertEqual(canvas.annotations[0].boundingRect, rect.offsetBy(dx: 60, dy: -30))
    }

    func testCommandReturnEndsParagraphWithoutConfirmingWholeImageAndTabAlsoCommits() throws {
        let canvas = try canvas()
        var confirmed = 0
        canvas.onConfirm = { confirmed += 1 }
        let editor = try start(canvas, string: "结束本段")
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36))
        editor.keyDown(with: event)
        XCTAssertNil(canvas.textEditor)
        XCTAssertEqual(confirmed, 0)
        try start(canvas, at: CGPoint(x: 40, y: 200), string: "下一段").insertTab(nil)
        XCTAssertEqual(canvas.annotations.count, 2)
        canvas.handleKeyDown(keyCode: 36, modifiers: [])
        XCTAssertEqual(confirmed, 1)
    }

    func testUndoDuringReeditNeverLeavesStaleHiddenAnnotation() throws {
        let canvas = try canvas()
        try start(canvas, string: "第一版")
        canvas.finishTextEditing(commit: true)
        let rect = canvas.annotations[0].boundingRect
        canvas.handleMouseDown(at: CGPoint(x: rect.midX, y: rect.midY), clickCount: 1, shiftDown: false)
        canvas.textEditor?.insertText("第二版", replacementRange: NSRange(location: 0, length: 3))
        canvas.undo()
        XCTAssertNil(canvas.textEditor)
        XCTAssertEqual(canvas.annotations.map(text), ["第一版"])
        canvas.redo()
        XCTAssertEqual(canvas.annotations.map(text), ["第二版"])
    }

    func testNativeEditorAndExportHaveSameGlyphPositionsAtImageCoordinates() throws {
        let canvas = try canvas()
        let editor = try start(canvas, at: CGPoint(x: 80, y: 400), string: "Are you OK?\n夸夸 dsfdsfds\n\n第三行")
        editor.drawsBackground = false
        let native = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: native)
        let before = try XCTUnwrap(redBounds(native))
        canvas.finishTextEditing(commit: true)
        let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 480,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
        let output = try XCTUnwrap(ImageComposer.composedRep(base: try XCTUnwrap(context.makeImage()),
                                                           pixelScale: 1, annotations: canvas.annotations))
        let after = try XCTUnwrap(redBounds(output))
        XCTAssertEqual(before.minX, after.minX, accuracy: 1)
        XCTAssertEqual(before.minY, after.minY, accuracy: 1)
        XCTAssertEqual(before.width, after.width, accuracy: 1)
        XCTAssertEqual(before.height, after.height, accuracy: 1)
        if let dir = ProcessInfo.processInfo.environment["YOUMU_EDITOR_QA_DIR"] {
            try native.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/native-editor.png"))
            try output.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/export.png"))
        }
    }

    func testRetinaAndCanvasZoomKeepTextInImagePointCoordinates() throws {
        let canvas = try canvas(scale: 2)
        canvas.setFrameSize(CGSize(width: 320, height: 240))
        canvas.setBoundsSize(CGSize(width: 640, height: 480))
        let editor = try start(canvas, string: "缩放\n还是原位置")
        let top = editor.frame.maxY - editor.textContainerInset.height
        canvas.finishTextEditing(commit: true)
        XCTAssertEqual(canvas.annotations[0].boundingRect.maxY, top, accuracy: 0.01)
        XCTAssertEqual(canvas.annotations[0].boundingRect.minX, 40)
    }

    func testBottomEdgeParagraphStaysInsideImageAndRightEdgeStillWraps() throws {
        let canvas = try canvas()
        let editor = try start(canvas, at: CGPoint(x: 638, y: 10), string: "第一行\n第二行\n第三行")
        XCTAssertGreaterThanOrEqual(editor.frame.minY + editor.textContainerInset.height, 0)
        canvas.finishTextEditing(commit: true)
        let rect = canvas.annotations[0].boundingRect
        XCTAssertGreaterThanOrEqual(rect.minY, 0)
        XCTAssertLessThanOrEqual(rect.maxX, canvas.imageSizePoints.width)
        XCTAssertLessThanOrEqual(rect.maxY, canvas.imageSizePoints.height)
    }

    func testToolbarFollowsReeditedStyleWithoutMutatingTextOrToolPreset() throws {
        let canvas = try canvas()
        let toolbar = EditorToolbarView(frame: CGRect(x: 0, y: 0, width: 900, height: 50))
        var shownColor: NSColor?, shownWidth: StrokeWidth?, textMode = false
        var styleWrites = 0
        toolbar.onColorSelected = { _ in styleWrites += 1 }
        toolbar.onWidthSelected = { _ in styleWrites += 1 }
        canvas.onStyleDisplayChange = { color, width, forText in
            shownColor = color; shownWidth = width; textMode = forText
            toolbar.setStyleDisplay(color: color, width: width, forText: forText)
        }
        try start(canvas, string: "原红色")
        canvas.finishTextEditing(commit: true)
        let rect = canvas.annotations[0].boundingRect
        canvas.currentTool = .select
        canvas.handleMouseDown(at: CGPoint(x: 620, y: 20), clickCount: 1, shiftDown: false)
        canvas.currentColor = .systemBlue
        canvas.setWidth(.thick)
        canvas.handleMouseDown(at: CGPoint(x: rect.midX, y: rect.midY), clickCount: 2, shiftDown: false)
        XCTAssertEqual(shownColor, EditorColorPreset.red.color)
        XCTAssertEqual(shownWidth, .medium)
        XCTAssertTrue(textMode)
        XCTAssertEqual(canvas.currentColor, .systemBlue)
        XCTAssertEqual(canvas.currentWidth, .thick)
        XCTAssertEqual(styleWrites, 0)
        canvas.finishTextEditing(commit: false)
        XCTAssertEqual(shownColor, .systemBlue)
        XCTAssertEqual(shownWidth, .thick)
        XCTAssertFalse(textMode)
    }

    private func redBounds(_ image: NSBitmapImageRep) -> CGRect? {
        var minX = image.pixelsWide, minY = image.pixelsHigh, maxX = -1, maxY = -1
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.redComponent > 0.7, color.greenComponent < 0.4, color.blueComponent < 0.4 else { continue }
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return nil }
        return CGRect(x: CGFloat(minX) / CGFloat(image.pixelsWide) * 640,
                      y: CGFloat(minY) / CGFloat(image.pixelsHigh) * 480,
                      width: CGFloat(maxX - minX + 1) / CGFloat(image.pixelsWide) * 640,
                      height: CGFloat(maxY - minY + 1) / CGFloat(image.pixelsHigh) * 480)
    }
}
