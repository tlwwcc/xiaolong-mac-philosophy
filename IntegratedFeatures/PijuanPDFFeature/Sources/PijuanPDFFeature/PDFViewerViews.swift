import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct PDFViewerRootView: View {
  @ObservedObject var model: PDFViewerModel
  @ObservedObject var shortcuts: PDFViewerShortcutStore
  let applicationVersionText: String
  let onShowHelp: () -> Void
  @State private var pageInput = ""
  @State private var isDropTargeted = false

  var body: some View {
    Group {
      if model.isPresentationMode, model.pageCount > 0 {
        presentationContent
      } else {
        VStack(spacing: 0) {
          toolbar
          Divider()
          content
          Divider()
          statusBar
        }
      }
    }
    .frame(minWidth: 920, minHeight: 620)
    .background(Color(nsColor: .windowBackgroundColor))
    .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
      handleDrop(providers)
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) {
      notification in
      guard let window = notification.object as? NSWindow,
        window === model.pdfView.window || model.isPresentationMode
      else { return }
      model.handleSystemFullScreenExit()
    }
  }

  private var toolbar: some View {
    HStack(spacing: 8) {
      PDFToolbarGroup {
        PDFToolbarButton(
          title: "打开 PDF",
          systemImage: "folder",
          label: "打开",
          helpText: "打开 PDF（⌘O）",
          identifier: "pdf-open",
          action: model.choosePDF)
        toolbarDivider
        recentMenu
      }

      PDFToolbarGroup {
        PDFToolbarButton(
          title: "上一页",
          systemImage: "chevron.left",
          helpText: "上一页（\(shortcutText(.previousPage))）",
          identifier: "pdf-previous-page",
          action: model.goToPreviousPage)
          .disabled(model.pageCount == 0 || model.pageIndex == 0)

        HStack(spacing: 3) {
          TextField(model.pageCount == 0 ? "—" : String(model.pageIndex + 1), text: $pageInput)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .monospacedDigit()
            .frame(width: 34)
            .onSubmit { submitPage() }
            .accessibilityLabel("跳转页码")
          Text("/ \(model.pageCount == 0 ? "—" : String(model.pageCount))")
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .fixedSize()
        }
        .font(.caption)
        .padding(.horizontal, 5)

        PDFToolbarButton(
          title: "下一页",
          systemImage: "chevron.right",
          helpText: "下一页（\(shortcutText(.nextPage))）",
          identifier: "pdf-next-page",
          action: model.goToNextPage)
          .disabled(model.pageCount == 0 || model.pageIndex + 1 >= model.pageCount)
      }

      PDFToolbarGroup {
        PDFToolbarButton(
          title: "缩小",
          systemImage: "minus.magnifyingglass",
          helpText: "缩小（\(shortcutText(.zoomOut))）",
          identifier: "pdf-zoom-out",
          action: model.zoomOut)
          .disabled(model.pageCount == 0)

        Text("\(model.zoomPercentage)%")
          .font(.caption.monospacedDigit().weight(.semibold))
          .foregroundStyle(model.pageCount == 0 ? Color.secondary : Color.primary)
          .frame(width: 42)
          .accessibilityLabel("当前缩放 \(model.zoomPercentage)%")

        PDFToolbarButton(
          title: "放大",
          systemImage: "plus.magnifyingglass",
          helpText: "放大（\(shortcutText(.zoomIn))）",
          identifier: "pdf-zoom-in",
          action: model.zoomIn)
          .disabled(model.pageCount == 0)

        toolbarDivider

        PDFToolbarButton(
          title: "适合页面",
          systemImage: "rectangle.inset.filled",
          helpText: "适合页面（\(shortcutText(.fitPage))）",
          identifier: "pdf-fit-page",
          action: model.fitPage)
          .disabled(model.pageCount == 0)

        PDFToolbarButton(
          title: "100% 实际大小",
          label: "1:1",
          helpText: "100% 实际大小（\(shortcutText(.actualSize))）",
          identifier: "pdf-actual-size",
          action: model.actualSize)
          .disabled(model.pageCount == 0)
      }

      PDFToolbarGroup {
        PDFToolbarButton(
          title: "向左旋转 90°",
          systemImage: "rotate.left",
          helpText: "向左旋转 90°（\(shortcutText(.rotateLeft))）",
          identifier: "pdf-rotate-left",
          action: model.rotateCurrentPageLeft)
          .disabled(model.pageCount == 0)

        PDFToolbarButton(
          title: "恢复原始方向",
          systemImage: "arrow.counterclockwise",
          helpText: "恢复原始方向（\(shortcutText(.resetRotation))）",
          identifier: "pdf-reset-rotation",
          action: model.resetCurrentPageRotation)
          .disabled(model.pageCount == 0)

        PDFToolbarButton(
          title: "向右旋转 90°",
          systemImage: "rotate.right",
          helpText: "向右旋转 90°（\(shortcutText(.rotateRight))）",
          identifier: "pdf-rotate-right",
          action: model.rotateCurrentPageRight)
          .disabled(model.pageCount == 0)
      }

      PDFToolbarButton(
        title: "投影模式",
        systemImage: "rectangle.on.rectangle",
        label: "投影",
        helpText: "全屏铺满并隐藏分页（\(shortcutText(.togglePresentation))）",
        identifier: "pdf-presentation",
        isProminent: true,
        action: { model.togglePresentationMode() })
        .disabled(model.pageCount == 0)

      Spacer(minLength: 4)
      searchField
    }
    .padding(.horizontal, 10)
    .frame(height: 58)
    .background(.ultraThinMaterial)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Color.primary.opacity(0.08))
        .frame(height: 1)
    }
  }

  private var searchField: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
      TextField("搜索 PDF", text: $model.searchText)
        .textFieldStyle(.plain)
        .frame(minWidth: 76, idealWidth: 126, maxWidth: 170)
        .onSubmit(model.performSearch)
        .onChange(of: model.searchText) { _ in model.searchTextDidChange() }
      if model.isSearching {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("正在搜索")
      }
      if !model.searchText.isEmpty {
        Text(model.searchResultLabel)
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
          .fixedSize()
        Button(action: model.selectPreviousSearchResult) {
          Image(systemName: "chevron.up")
        }
        .buttonStyle(.plain)
        .help("上一处")
        .disabled(model.isSearching || model.searchResultCount == 0)
        .accessibilityLabel("上一处搜索结果")
        Button(action: model.selectNextSearchResult) {
          Image(systemName: "chevron.down")
        }
        .buttonStyle(.plain)
        .help("下一处")
        .disabled(model.isSearching || model.searchResultCount == 0)
        .accessibilityLabel("下一处搜索结果")
      }
    }
    .padding(.horizontal, 9)
    .frame(height: 32)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .stroke(Color.primary.opacity(0.10), lineWidth: 0.75)
    }
    .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
    .help("搜索当前 PDF（⌘F）")
  }

  private var toolbarDivider: some View {
    Rectangle()
      .fill(Color.primary.opacity(0.10))
      .frame(width: 1, height: 18)
      .padding(.horizontal, 1)
  }

  private func shortcutText(_ action: PDFViewerShortcutAction) -> String {
    shortcuts.activeShortcut(for: action)?.displayText ?? "未设置"
  }

  private var recentMenu: some View {
    Menu {
      if model.recentDocuments.isEmpty {
        Text("暂无最近文件")
      } else {
        ForEach(model.recentDocuments) { document in
          Button(document.displayName) { model.openRecentDocument(document) }
        }
      }
    } label: {
      Image(systemName: "clock")
        .font(.system(size: 12, weight: .medium))
        .frame(width: 28, height: 28)
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .frame(width: 30)
    .help("最近打开")
    .accessibilityIdentifier("pdf-recent")
  }

  @ViewBuilder
  private var content: some View {
    if model.pageCount > 0 {
      HSplitView {
        PDFThumbnailRepresentable(pdfView: model.pdfView)
          .frame(minWidth: 130, idealWidth: 170, maxWidth: 230)
        PDFViewRepresentable(pdfView: model.pdfView)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    } else {
      emptyState
    }
  }

  private var emptyState: some View {
    VStack(spacing: 16) {
      Image(systemName: "doc.richtext")
        .font(.system(size: 58, weight: .light))
        .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
      Text(isDropTargeted ? "松开即可打开" : "把 PDF 拖到这里")
        .font(.title2.weight(.semibold))
      Text("双指移动 · 捏合或鼠标滚轮缩放 · 所有文档只在本机处理")
        .foregroundStyle(.secondary)
      Button("选择 PDF") { model.choosePDF() }
        .buttonStyle(.borderedProminent)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(
      RoundedRectangle(cornerRadius: 16)
        .strokeBorder(isDropTargeted ? Color.accentColor : .clear, style: StrokeStyle(lineWidth: 2, dash: [8]))
        .padding(24)
    )
  }

  private var statusBar: some View {
    HStack(spacing: 8) {
      Image(systemName: model.errorText == nil ? "doc.text" : "exclamationmark.triangle.fill")
        .foregroundStyle(model.errorText == nil ? Color.secondary : Color.orange)
      Text(model.statusText)
        .lineLimit(1)
      Spacer()
      if model.pageCount > 0 {
        Text("双指移动  ·  捏合 / 滚轮缩放  ·  \(shortcutText(.actualSize)) 实际大小  ·  \(shortcutText(.togglePresentation)) 投影")
          .foregroundStyle(.tertiary)
      }
      Text(applicationVersionText)
        .foregroundStyle(.tertiary)
        .monospacedDigit()
        .fixedSize()
        .accessibilityIdentifier("pdf-version")
      Button {
        onShowHelp()
      } label: {
        Label("帮助", systemImage: "questionmark.circle")
          .fontWeight(.semibold)
          .foregroundStyle(pdfBrandPurple)
          .padding(.horizontal, 8)
          .frame(height: 22)
          .background(pdfBrandPurple.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      }
      .buttonStyle(.plain)
      .help("查看使用方法和当前快捷键")
      .accessibilityIdentifier("pdf-status-help")
    }
    .font(.caption)
    .padding(.horizontal, 12)
    .frame(height: 28)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
  }

  private var presentationContent: some View {
    ZStack(alignment: .topTrailing) {
      PDFViewRepresentable(pdfView: model.pdfView)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      Button {
        model.exitPresentationMode()
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "rectangle.arrowtriangle.2.outward")
          Text("退出投影")
          Text("Esc")
            .font(.caption2.monospaced())
            .foregroundStyle(.white.opacity(0.72))
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(pdfBrandPurple, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(.white.opacity(0.18), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.20), radius: 8, y: 3)
      }
      .buttonStyle(.plain)
      .keyboardShortcut(.escape, modifiers: [])
      .padding(16)
      .help("退出全屏并恢复分页（Esc 或 \(shortcutText(.togglePresentation))）")
      .accessibilityIdentifier("pdf-exit-presentation")
    }
    .background(Color.black)
  }

  private func submitPage() {
    guard let page = Int(pageInput) else { return }
    model.goToPage(page)
    pageInput = ""
  }

  private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
    guard let provider = providers.first else { return false }
    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
      let url: URL?
      if let data = item as? Data {
        url = URL(dataRepresentation: data, relativeTo: nil)
      } else {
        url = item as? URL
      }
      guard let url else { return }
      DispatchQueue.main.async { model.open(url) }
    }
    return true
  }
}

private struct PDFToolbarGroup<Content: View>: View {
  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    HStack(spacing: 1) {
      content
    }
    .padding(3)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Color.primary.opacity(0.09), lineWidth: 0.75)
    }
    .shadow(color: .black.opacity(0.045), radius: 2, y: 1)
  }
}

private struct PDFToolbarButton: View {
  let title: String
  var systemImage: String?
  var label: String?
  let helpText: String
  let identifier: String
  var isProminent = false
  let action: () -> Void

  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        if let systemImage {
          Image(systemName: systemImage)
        }
        if let label {
          Text(label)
        }
      }
      .font(.system(size: 12, weight: label == nil ? .medium : .semibold))
      .foregroundStyle(isProminent ? Color.white : Color.primary)
      .padding(.horizontal, label == nil ? 7 : 9)
      .frame(height: 28)
      .background(buttonBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .stroke(buttonStroke, lineWidth: 0.65)
      }
      .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
    .buttonStyle(.plain)
    .opacity(isEnabled ? 1 : 0.38)
    .onHover { isHovered = $0 }
    .help(helpText)
    .accessibilityLabel(title)
    .accessibilityIdentifier(identifier)
  }

  private var buttonBackground: Color {
    if isProminent {
      return pdfBrandPurple.opacity(isEnabled ? (isHovered ? 0.88 : 1) : 0.5)
    }
    return isHovered && isEnabled ? pdfBrandPurple.opacity(0.10) : .clear
  }

  private var buttonStroke: Color {
    if isProminent { return .white.opacity(0.16) }
    return isHovered && isEnabled ? pdfBrandPurple.opacity(0.18) : .clear
  }
}

struct PDFViewRepresentable: NSViewRepresentable {
  let pdfView: BlueprintPDFView

  func makeNSView(context: Context) -> BlueprintPDFView { pdfView }
  func updateNSView(_ nsView: BlueprintPDFView, context: Context) {}
}

struct PDFThumbnailRepresentable: NSViewRepresentable {
  let pdfView: PDFView

  func makeNSView(context: Context) -> PDFThumbnailView {
    let thumbnailView = PDFThumbnailView()
    thumbnailView.pdfView = pdfView
    thumbnailView.thumbnailSize = NSSize(width: 112, height: 148)
    thumbnailView.backgroundColor = .controlBackgroundColor
    return thumbnailView
  }

  func updateNSView(_ nsView: PDFThumbnailView, context: Context) {
    nsView.pdfView = pdfView
  }
}
