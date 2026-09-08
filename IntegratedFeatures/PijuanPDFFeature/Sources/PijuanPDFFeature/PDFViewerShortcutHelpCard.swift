import AppKit
import SwiftUI

private let pdfHelpPaper = Color(red: 248.0 / 255.0, green: 247.0 / 255.0, blue: 249.0 / 255.0)
private let pdfHelpInk = Color(red: 23.0 / 255.0, green: 19.0 / 255.0, blue: 25.0 / 255.0)
private let pdfHelpMist = Color(red: 238.0 / 255.0, green: 231.0 / 255.0, blue: 245.0 / 255.0)
private let pdfHelpGlow = Color(red: 241.0 / 255.0, green: 235.0 / 255.0, blue: 246.0 / 255.0)
private let pdfHelpArc = Color(red: 183.0 / 255.0, green: 156.0 / 255.0, blue: 200.0 / 255.0)
private let pdfHelpMuted = Color(red: 104.0 / 255.0, green: 97.0 / 255.0, blue: 108.0 / 255.0)

struct PDFViewerShortcutHelpCard: View {
  let configuration: PDFViewerShortcutConfiguration

  private let shortcutGroupColumns: [[(title: String, actions: [PDFViewerShortcutAction])]] = [
    [
      ("翻页", [.previousPage, .nextPage]),
      ("缩放", [.zoomOut, .zoomIn, .actualSize, .fitPage]),
    ],
    [
      ("方向", [.rotateLeft, .rotateRight, .resetRotation]),
      ("投影", [.togglePresentation]),
    ],
  ]

  var body: some View {
    ZStack {
      pdfHelpPaper
      LinearGradient(
        colors: [pdfHelpPaper, Color.white, pdfHelpGlow],
        startPoint: .topLeading,
        endPoint: .bottomTrailing)
      PDFHelpBlueprintGrid()
        .stroke(pdfBrandPurple.opacity(0.055), lineWidth: 0.7)

      Circle()
        .fill(pdfBrandPurple.opacity(0.07))
        .frame(width: 260, height: 260)
        .blur(radius: 2)
        .offset(x: 310, y: -205)

      PDFHelpCanonicalSmileArc()
        .stroke(
          pdfHelpArc.opacity(0.28),
          style: StrokeStyle(lineWidth: 12, lineCap: .round))
        .frame(width: 300, height: 40)
        .offset(y: 230)

      VStack(spacing: 0) {
        header
        HStack(alignment: .top, spacing: 20) {
          usageColumn
            .frame(width: 224, alignment: .topLeading)
          Rectangle()
            .fill(pdfBrandPurple.opacity(0.12))
            .frame(width: 1)
          shortcutColumns
        }
        .padding(.top, 20)
        .frame(maxHeight: .infinity, alignment: .top)
        footer
      }
      .padding(.horizontal, 28)
      .padding(.top, 25)
      .padding(.bottom, 18)
    }
    .frame(width: 720, height: 480)
    .foregroundStyle(pdfHelpInk)
    .environment(\.colorScheme, .light)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("披卷帮助与当前快捷键")
  }

  private var header: some View {
    HStack(spacing: 13) {
      PDFHelpProductMark()
      .frame(width: 50, height: 50)

      VStack(alignment: .leading, spacing: 2) {
        Text("披卷")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(pdfBrandPurple)
        Text("大图纸，顺手看。")
          .font(.system(size: 28, weight: .bold, design: .serif))
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 6) {
        Text("Mac哲学内置 · 纯本地")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(pdfHelpMuted)
        Label("窗口底部点「帮助」", systemImage: "questionmark.circle")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(pdfBrandPurple)
          .padding(.horizontal, 10)
          .frame(height: 25)
          .background(pdfHelpMist, in: Capsule())
      }
    }
  }

  private var usageColumn: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("4 步上手")
        .font(.system(size: 13, weight: .bold))
        .foregroundStyle(pdfBrandPurple)
      PDFHelpStep(number: "01", title: "打开", detail: "拖入 PDF，或按 ⌘O")
      PDFHelpStep(number: "02", title: "缩放", detail: "滚轮直接缩放图纸")
      PDFHelpStep(number: "03", title: "平移", detail: "按住图纸，顺手拖动")
      PDFHelpStep(number: "04", title: "投影", detail: "铺满屏幕，Esc 退出")
    }
  }

  private var shortcutColumns: some View {
    VStack(alignment: .leading, spacing: 11) {
      HStack {
        Text("当前快捷键")
          .font(.system(size: 13, weight: .bold))
          .foregroundStyle(pdfBrandPurple)
        Spacer()
        Text("都可以自定义")
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(pdfHelpMuted)
      }

      HStack(alignment: .top, spacing: 10) {
        ForEach(Array(shortcutGroupColumns.enumerated()), id: \.offset) { _, groups in
          shortcutGroupColumn(groups)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private func shortcutGroupColumn(
    _ groups: [(title: String, actions: [PDFViewerShortcutAction])]
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
        let activeActions = group.actions.filter { !configuration.isDeleted($0) }
        if !activeActions.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            Text(group.title)
              .font(.system(size: 9.5, weight: .bold))
              .foregroundStyle(pdfHelpMuted)
            VStack(spacing: 4) {
              ForEach(activeActions, id: \.self) { action in
                PDFHelpShortcutRow(
                  title: action.displayName,
                  shortcut: configuration.shortcut(for: action).displayText)
              }
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private var footer: some View {
    HStack(spacing: 9) {
      Text("⌘O 打开")
      Text("·")
      Text("⌘F 搜索")
      Text("·")
      Text("⇧⌘W 关闭")
      Spacer()
      Text("披卷 · PDF 阅读")
        .fontWeight(.semibold)
        .foregroundStyle(pdfBrandPurple)
    }
    .font(.system(size: 10.5, weight: .medium))
    .foregroundStyle(pdfHelpMuted)
    .padding(.top, 12)
  }
}

private struct PDFHelpStep: View {
  let number: String
  let title: String
  let detail: String

  var body: some View {
    HStack(spacing: 10) {
      Text(number)
        .font(.system(size: 10, weight: .bold, design: .monospaced))
        .foregroundStyle(pdfBrandPurple)
        .frame(width: 31, height: 31)
        .background(pdfHelpMist, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.system(size: 12, weight: .semibold))
        Text(detail)
          .font(.system(size: 10.5))
          .foregroundStyle(pdfHelpMuted)
      }
    }
  }
}

private struct PDFHelpShortcutRow: View {
  let title: String
  let shortcut: String

  var body: some View {
    HStack(spacing: 7) {
      Text(title)
        .font(.system(size: 10.5, weight: .medium))
        .lineLimit(1)
        .minimumScaleFactor(0.82)
      Spacer(minLength: 3)
      Text(shortcut)
        .font(.system(size: 11, weight: .bold, design: .monospaced))
        .foregroundStyle(pdfBrandPurple)
        .padding(.horizontal, 8)
        .frame(minWidth: 43, minHeight: 23)
        .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .stroke(pdfBrandPurple.opacity(0.16), lineWidth: 0.7)
        }
    }
    .padding(.horizontal, 9)
    .frame(height: 31)
    .background(pdfHelpMist.opacity(0.54), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(title)，\(shortcut)")
  }
}

private struct PDFHelpBlueprintGrid: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    let spacing: CGFloat = 24
    var x = rect.minX
    while x <= rect.maxX {
      path.move(to: CGPoint(x: x, y: rect.minY))
      path.addLine(to: CGPoint(x: x, y: rect.maxY))
      x += spacing
    }
    var y = rect.minY
    while y <= rect.maxY {
      path.move(to: CGPoint(x: rect.minX, y: y))
      path.addLine(to: CGPoint(x: rect.maxX, y: y))
      y += spacing
    }
    return path
  }
}

private struct PDFHelpCanonicalSmileArc: Shape {
  func path(in rect: CGRect) -> Path {
    let scale = min(rect.width / 128, rect.height / 17)
    let width = 128 * scale
    let height = 17 * scale
    let origin = CGPoint(
      x: rect.midX - width / 2,
      y: rect.midY - height / 2)
    var path = Path()
    path.move(to: origin)
    path.addCurve(
      to: CGPoint(x: origin.x + width, y: origin.y),
      control1: CGPoint(x: origin.x + 34 * scale, y: origin.y + height),
      control2: CGPoint(x: origin.x + 94 * scale, y: origin.y + height))
    return path
  }
}

private struct PDFHelpProductMark: View {
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(pdfBrandPurple)
      PDFHelpDocumentGlyph()
        .fill(.white)
        .frame(width: 25, height: 29)
        .offset(y: -2)
      Image(systemName: "viewfinder")
        .font(.system(size: 17, weight: .bold))
        .foregroundStyle(pdfBrandPurple)
        .offset(y: -1)
      PDFHelpCanonicalSmileArc()
        .stroke(.white, style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
        .frame(width: 25, height: 4)
        .offset(y: 18)
    }
  }
}

private struct PDFHelpDocumentGlyph: Shape {
  func path(in rect: CGRect) -> Path {
    let foldWidth = rect.width * 0.28
    let foldHeight = rect.height * 0.24
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX - foldWidth, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + foldHeight))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
    path.closeSubpath()
    return path
  }
}

struct PDFViewerShortcutHelpPopover: View {
  @ObservedObject var shortcuts: PDFViewerShortcutStore
  let onShowSettings: () -> Void
  let onDismiss: () -> Void
  @State private var copyFeedback = "复制帮助图"

  var body: some View {
    VStack(spacing: 0) {
      PDFViewerShortcutHelpCard(configuration: shortcuts.configuration)
      Divider()
      HStack(spacing: 10) {
        Button("前往功能快捷键") {
          onDismiss()
          onShowSettings()
        }
        .accessibilityIdentifier("pdf-help-open-shortcut-manager")

        Button(copyFeedback) {
          copyFeedback = PDFViewerShortcutHelpRenderer.copyToPasteboard(
            configuration: shortcuts.configuration)
            ? "已复制 ✓" : "复制失败"
        }
        .accessibilityIdentifier("pdf-help-copy-image")

        Spacer()

        Button("关闭") { onDismiss() }
          .keyboardShortcut(.cancelAction)
          .accessibilityIdentifier("pdf-help-close")
      }
      .padding(.horizontal, 16)
      .frame(height: 54)
      .background(Color(nsColor: .windowBackgroundColor))
    }
    .frame(width: 720, height: 535)
  }
}

@MainActor
enum PDFViewerShortcutHelpRenderer {
  static func image(configuration: PDFViewerShortcutConfiguration) -> NSImage? {
    let renderer = ImageRenderer(
      content: PDFViewerShortcutHelpCard(configuration: configuration)
        .frame(width: 720, height: 480)
        .environment(\.colorScheme, .light))
    renderer.scale = 2
    return renderer.nsImage
  }

  static func copyToPasteboard(configuration: PDFViewerShortcutConfiguration) -> Bool {
    guard let image = image(configuration: configuration),
      let tiffData = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiffData),
      let pngData = bitmap.representation(using: .png, properties: [:])
    else { return false }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.declareTypes([.png], owner: nil)
    return pasteboard.setData(pngData, forType: .png)
  }
}
