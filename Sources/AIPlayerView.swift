import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let playerPurple = Color(red: 0.42, green: 0.14, blue: 0.56)
private let playerInk = Color(red: 0.09, green: 0.08, blue: 0.11)
private let playerMuted = Color(red: 0.43, green: 0.41, blue: 0.46)
private let playerCanvas = Color(red: 0.965, green: 0.958, blue: 0.97)

struct AIPlayerView: View {
  @ObservedObject var controller: AIPlayerController
  @State private var isCreatingLibrary = false
  @State private var newLibraryName = ""
  @State private var renameLibrary: AIPlayerLibrary?
  @State private var renameLibraryName = ""
  @State private var pendingTrashItem: AIPlayerMediaItem?

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        sidebar
          .frame(width: 205)
        Divider()
        mediaPane
      }
      Divider()
      miniPlayer
        .frame(height: 88)
    }
    .background(playerCanvas)
    .frame(minWidth: 720, minHeight: 480)
    .onAppear { controller.start() }
    .background(
      AIPlayerKeyboardMonitor { event in handleKey(event) }
        .frame(width: 0, height: 0)
    )
    .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil, perform: handleDrop)
    .sheet(isPresented: $isCreatingLibrary) { createLibrarySheet }
    .sheet(item: $renameLibrary) { library in renameLibrarySheet(library) }
    .confirmationDialog(
      "移到废纸篓？",
      isPresented: Binding(
        get: { pendingTrashItem != nil },
        set: { if !$0 { pendingTrashItem = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("移到废纸篓", role: .destructive) {
        if let pendingTrashItem { controller.moveToTrash(pendingTrashItem) }
        pendingTrashItem = nil
      }
      Button("取消", role: .cancel) { pendingTrashItem = nil }
    } message: {
      Text("文件可以从废纸篓恢复，不会永久删除。")
    }
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 9) {
        Image(systemName: "play.square.stack.fill")
          .font(.system(size: 20, weight: .semibold))
          .foregroundStyle(playerPurple)
        VStack(alignment: .leading, spacing: 1) {
          Text("小龙哥AI播放器")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(playerInk)
          Text(controller.playbackCapabilityText)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(playerMuted)
        }
      }
      .padding(.horizontal, 14)
      .padding(.top, 16)

      VStack(spacing: 3) {
        sidebarButton("最近播放", icon: "clock", filter: .recent)
        sidebarButton("全部文件", icon: "music.note.list", filter: .all)
        sidebarButton("我的收藏", icon: "heart", filter: .favorites)
      }

      HStack {
        Text("媒体库")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(playerMuted)
        Spacer()
        Button {
          newLibraryName = ""
          isCreatingLibrary = true
        } label: {
          Image(systemName: "plus")
        }
        .buttonStyle(.plain)
        .help("新建媒体库")
        .accessibilityLabel("新建媒体库")
      }
      .padding(.horizontal, 15)

      ScrollView {
        VStack(spacing: 3) {
          ForEach(controller.libraries) { library in
            sidebarButton(library.name, icon: "rectangle.stack", filter: .library(library.id))
              .contextMenu {
                Button("重命名") {
                  renameLibraryName = library.name
                  renameLibrary = library
                }
              }
          }
        }
      }

      Spacer(minLength: 0)
      Text("本机历史 · 不上传媒体内容")
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(playerMuted.opacity(0.82))
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }
    .background(Color.white.opacity(0.74))
  }

  private func sidebarButton(_ title: String, icon: String, filter: AIPlayerFilter) -> some View {
    let selected = controller.selectedFilter == filter
    return Button {
      controller.select(filter)
    } label: {
      HStack(spacing: 9) {
        Image(systemName: icon)
          .frame(width: 18)
        Text(title)
          .lineLimit(1)
        Spacer()
      }
      .font(.system(size: 12, weight: selected ? .semibold : .medium))
      .foregroundStyle(selected ? playerPurple : playerInk.opacity(0.82))
      .padding(.horizontal, 13)
      .frame(height: 34)
      .background(
        selected ? playerPurple.opacity(0.10) : Color.clear,
        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
      )
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 7)
    .accessibilityLabel(title)
  }

  private var mediaPane: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text(currentTitle)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(playerInk)
          Text("\(controller.items.count) 个媒体文件")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(playerMuted)
        }
        Spacer()
        Button {
          controller.importFiles()
        } label: {
          Label("加入媒体", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
        .tint(playerPurple)
        .help("选择音频或视频")
      }
      .padding(.horizontal, 20)
      .frame(height: 74)

      Divider()

      if controller.items.isEmpty {
        emptyState
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(controller.items) { item in
              mediaRow(item)
              Divider().padding(.leading, 62)
            }
          }
        }
        .background(Color.white.opacity(0.58))
      }
    }
  }

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "waveform.badge.plus")
        .font(.system(size: 34, weight: .light))
        .foregroundStyle(playerPurple)
      Text("把媒体文件放进来")
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(playerInk)
      Text(
        controller.extendedMediaAvailable
          ? "可拖入常见音频、扩展音频和视频文件。"
          : "MP3、M4A、WAV 可直接播放；其他格式需要扩展组件。"
      )
        .font(.system(size: 11))
        .foregroundStyle(playerMuted)
        .multilineTextAlignment(.center)
      Button("选择文件") { controller.importFiles() }
        .buttonStyle(.bordered)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
  }

  private func mediaRow(_ item: AIPlayerMediaItem) -> some View {
    let selected = controller.selectedItemID == item.id
    let playable = controller.canPlay(item)
    return HStack(spacing: 12) {
      ZStack {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(item.kind == .audio ? playerPurple.opacity(0.10) : Color.blue.opacity(0.10))
        Image(systemName: item.kind == .audio ? "waveform" : "film")
          .foregroundStyle(item.kind == .audio ? playerPurple : .blue)
      }
      .frame(width: 38, height: 38)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Text(item.name)
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
          if item.isFavorite {
            Image(systemName: "heart.fill")
              .font(.system(size: 9))
              .foregroundStyle(playerPurple)
          }
        }
        Text(
          item.isMissing
            ? "文件已不在原位置"
            : (playable ? "\(item.format) · \(item.kind.title)" : "\(item.format) · 当前缺少扩展播放能力")
        )
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(item.isMissing ? Color.red : playerMuted)
      }
      Spacer()
      Text(item.durationText)
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(playerMuted)
      Button {
        controller.play(item: item)
      } label: {
        Image(systemName: "play.fill")
      }
      .buttonStyle(.plain)
      .disabled(item.isMissing || !playable)
      .help("播放")
      .accessibilityLabel("播放 \(item.name)")
    }
    .padding(.horizontal, 18)
    .frame(height: 58)
    .contentShape(Rectangle())
    .opacity(item.isMissing || !playable ? 0.52 : 1)
    .background(selected ? playerPurple.opacity(0.065) : Color.clear)
    .onTapGesture { controller.selectedItemID = item.id }
    .onTapGesture(count: 2) { if playable && !item.isMissing { controller.play(item: item) } }
    .contextMenu { mediaContextMenu(item) }
  }

  @ViewBuilder
  private func mediaContextMenu(_ item: AIPlayerMediaItem) -> some View {
    Button("播放") { controller.play(item: item) }
      .disabled(item.isMissing || !controller.canPlay(item))
    Button(item.isFavorite ? "取消收藏" : "收藏") { controller.toggleFavorite(item) }
    Menu("加入媒体库") {
      if controller.libraries.isEmpty {
        Text("还没有自定义媒体库")
      } else {
        ForEach(controller.libraries) { library in
          Button(library.name) { controller.add(item, to: library) }
        }
      }
    }
    Divider()
    Button("复制绝对路径") { controller.copyAbsolutePath(item) }
    Button("在访达中显示") { controller.reveal(item) }
      .disabled(item.isMissing)
    if case .library = controller.selectedFilter {
      Button("从当前媒体库移除") { controller.removeFromSelectedLibrary(item) }
    }
    Button("从历史移除") { controller.removeFromHistory(item) }
    Divider()
    Button("移到废纸篓", role: .destructive) { pendingTrashItem = item }
      .disabled(item.isMissing)
  }

  private var miniPlayer: some View {
    VStack(spacing: 8) {
      HStack(spacing: 14) {
        VStack(alignment: .leading, spacing: 2) {
          Text(currentPlaybackName)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(playerInk)
            .lineLimit(1)
          Text(controller.statusText)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(playerMuted)
            .lineLimit(1)
        }
        .frame(width: 210, alignment: .leading)

        Spacer()
        Button(action: controller.playPrevious) { Image(systemName: "backward.fill") }
          .buttonStyle(.plain)
          .help("上一项")
          .accessibilityLabel("播放上一项")
        Button(action: controller.togglePlayback) {
          Image(systemName: controller.playback.playback == "playing" ? "pause.fill" : "play.fill")
            .font(.system(size: 15, weight: .bold))
            .frame(width: 34, height: 34)
            .foregroundStyle(.white)
            .background(playerPurple, in: Circle())
        }
        .buttonStyle(.plain)
        .help(controller.playback.playback == "playing" ? "暂停" : "播放")
        .accessibilityLabel(controller.playback.playback == "playing" ? "暂停" : "播放")
        Button(action: controller.playNext) { Image(systemName: "forward.fill") }
          .buttonStyle(.plain)
          .help("下一项")
          .accessibilityLabel("播放下一项")
        Spacer()

        HStack(spacing: 7) {
          Image(systemName: "speaker.wave.1.fill")
            .foregroundStyle(playerMuted)
          Slider(
            value: Binding(
              get: { controller.playback.volume },
              set: { controller.setVolume($0) }
            ),
            in: 0...100
          )
          .frame(width: 90)
          .accessibilityLabel("音量")
          .accessibilityValue("\(Int(controller.playback.volume.rounded()))%")
        }
        .frame(width: 122)
      }

      HStack(spacing: 8) {
        Text(AIPlayerFormatting.duration(controller.playback.positionSeconds))
        Slider(
          value: Binding(
            get: { min(controller.playback.positionSeconds, max(controller.playback.durationSeconds, 1)) },
            set: { value in controller.seek(by: value - controller.playback.positionSeconds) }
          ),
          in: 0...max(controller.playback.durationSeconds, 1)
        )
        .accessibilityLabel("播放进度")
        .accessibilityValue(
          "\(AIPlayerFormatting.duration(controller.playback.positionSeconds)) / \(AIPlayerFormatting.duration(controller.playback.durationSeconds))"
        )
        Text(AIPlayerFormatting.duration(controller.playback.durationSeconds))
      }
      .font(.system(size: 9, design: .monospaced))
      .foregroundStyle(playerMuted)
    }
    .padding(.horizontal, 18)
    .background(Color.white.opacity(0.88))
    .overlay(alignment: .topTrailing) {
      if controller.canUndoTrash {
        Button("撤销移到废纸篓") { controller.undoTrash() }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .padding(.top, 8)
          .padding(.trailing, 16)
      }
    }
  }

  private var currentTitle: String {
    switch controller.selectedFilter {
    case .recent: return "最近播放"
    case .all: return "全部文件"
    case .favorites: return "我的收藏"
    case .library(let id): return controller.libraries.first(where: { $0.id == id })?.name ?? "媒体库"
    }
  }

  private var currentPlaybackName: String {
    guard let path = controller.playback.path else { return "还没有播放媒体" }
    return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
  }

  private var createLibrarySheet: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("新建媒体库").font(.headline)
      TextField("例如：风神播客电台", text: $newLibraryName)
        .textFieldStyle(.roundedBorder)
      HStack {
        Spacer()
        Button("取消") { isCreatingLibrary = false }
        Button("创建") {
          controller.createLibrary(name: newLibraryName)
          isCreatingLibrary = false
        }
        .keyboardShortcut(.defaultAction)
        .disabled(newLibraryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(22)
    .frame(width: 360)
  }

  private func renameLibrarySheet(_ library: AIPlayerLibrary) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("重命名媒体库").font(.headline)
      TextField("媒体库名称", text: $renameLibraryName)
        .textFieldStyle(.roundedBorder)
      HStack {
        Spacer()
        Button("取消") { renameLibrary = nil }
        Button("保存") {
          controller.renameLibrary(library, name: renameLibraryName)
          renameLibrary = nil
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(22)
    .frame(width: 360)
  }

  private func handleDrop(providers: [NSItemProvider]) -> Bool {
    var accepted = false
    for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
      accepted = true
      provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
        let url: URL?
        if let data = data as? Data {
          url = URL(dataRepresentation: data, relativeTo: nil)
        } else {
          url = data as? URL
        }
        if let url {
          DispatchQueue.main.async { controller.addFiles([url], playFirst: true) }
        }
      }
    }
    return accepted
  }

  private func handleKey(_ event: NSEvent) -> Bool {
    guard !(NSApp.keyWindow?.firstResponder is NSTextView) else { return false }
    switch event.keyCode {
    case 49:
      controller.togglePlayback()
    case 123:
      event.modifierFlags.contains(.command) ? controller.playPrevious() : controller.seek(by: -5)
    case 124:
      event.modifierFlags.contains(.command) ? controller.playNext() : controller.seek(by: 5)
    case 125:
      controller.setVolume(controller.playback.volume - 5)
    case 126:
      controller.setVolume(controller.playback.volume + 5)
    default:
      return false
    }
    return true
  }
}

@MainActor
private struct AIPlayerKeyboardMonitor: NSViewRepresentable {
  let handler: (NSEvent) -> Bool

  func makeCoordinator() -> Coordinator { Coordinator(handler: handler) }

  func makeNSView(context: Context) -> NSView {
    context.coordinator.start()
    return NSView(frame: .zero)
  }

  func updateNSView(_ nsView: NSView, context: Context) {}

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.stop()
  }

  @MainActor
  final class Coordinator {
    let handler: (NSEvent) -> Bool
    var monitor: Any?

    init(handler: @escaping (NSEvent) -> Bool) { self.handler = handler }

    func start() {
      guard monitor == nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard NSApp.keyWindow?.title == "小龙哥AI播放器" else { return event }
        return self?.handler(event) == true ? nil : event
      }
    }

    func stop() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
  }
}
