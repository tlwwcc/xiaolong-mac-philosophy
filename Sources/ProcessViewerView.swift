import AppKit
import SwiftUI

extension Notification.Name {
  static let processViewerWindowVisibilityChanged = AppRuntimeIdentity.current.notificationName(
    "processViewerWindowVisibilityChanged")
}

struct ProcessViewerWindowRoot: View {
  @AppStorage("processViewerPluginEnabledV1") private var isEnabled = true

  var body: some View {
    ProcessViewerDetailView(isEnabled: $isEnabled)
  }
}

struct ProcessViewerPluginDetailView: View {
  @EnvironmentObject private var model: AppModel
  @Binding var isEnabled: Bool

  var body: some View {
    Form {
      Section {
        LabeledContent {
          Toggle("", isOn: $isEnabled)
            .labelsHidden()
            .toggleStyle(.switch)
            .accessibilityLabel("进程查看器")
        } label: {
          Label("进程查看器", systemImage: "cpu")
        }
        Text("查看本机进程、CPU、内存和交换空间。进程列表只在独立窗口可见时刷新。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section {
        Button {
          model.showProcessViewer()
        } label: {
          Label("打开进程查看器", systemImage: "arrow.up.right.square")
        }
        .disabled(!isEnabled)
      }
    }
    .formStyle(.grouped)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct ProcessViewerDetailView: View {
  @Binding var isEnabled: Bool
  @StateObject private var controller = ProcessViewerController()
  @EnvironmentObject private var model: AppModel
  @Environment(\.controlActiveState) private var controlActiveState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var query = ""
  @State private var sort: ProcessViewerSort = .cpu
  @AppStorage("processViewerShowSystemProcessesV1") private var showSystemProcesses = false
  @State private var expandedIdentity: ProcessStableIdentity?
  @State private var quitCandidate: ProcessViewerProcess?
  @State private var forceCandidate: ProcessViewerProcess?
  @FocusState private var searchFocused: Bool

  private var filteredProcesses: [ProcessViewerProcess] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let filtered = controller.processes.filter { process in
      let matchesSearch =
        trimmed.isEmpty
        || process.name.localizedCaseInsensitiveContains(trimmed)
        || process.bundleIdentifier?.localizedCaseInsensitiveContains(trimmed) == true
        || process.executablePath?.localizedCaseInsensitiveContains(trimmed) == true
        || String(process.identity.pid).hasPrefix(trimmed)
      guard matchesSearch else { return false }
      return showSystemProcesses || !trimmed.isEmpty || !process.isKnownMacOSBackgroundProcess
    }
    return filtered.sorted { lhs, rhs in
      let ordered: Bool?
      switch sort {
      case .cpu: ordered = compare(lhs.cpuPercent ?? -1, rhs.cpuPercent ?? -1, descending: true)
      case .memory: ordered = compare(lhs.residentBytes, rhs.residentBytes, descending: true)
      case .name:
        ordered =
          lhs.name.compare(rhs.name, options: [.caseInsensitive, .numeric]) == .orderedAscending
      case .pid: ordered = lhs.identity.pid < rhs.identity.pid
      case .state: ordered = lhs.state.title < rhs.state.title
      }
      if let ordered, primaryValuesDiffer(lhs, rhs) { return ordered }
      let names = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
      return names == .orderedSame
        ? lhs.identity.pid < rhs.identity.pid : names == .orderedAscending
    }
  }

  var body: some View {
    GeometryReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          header
          memoryOverview(compact: proxy.size.width < 720)
          toolbar(compact: proxy.size.width < 760)
          if hiddenSystemProcessCount > 0 {
            Label(
              "已隐藏 \(hiddenSystemProcessCount) 个 macOS 系统后台；搜索或打开“显示系统后台”即可查看。",
              systemImage: "line.3.horizontal.decrease.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          if controller.reducedFrequency {
            Label("为减少系统占用，已降低刷新频率。", systemImage: "tortoise")
              .font(.caption).foregroundStyle(.secondary)
          }
          if let error = controller.sampleError {
            Label(error, systemImage: "exclamationmark.triangle")
              .font(.caption).foregroundStyle(.secondary)
          }
          processList(compact: proxy.size.width < 760)
        }
        .padding(proxy.size.width < 840 ? 16 : 20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    }
    .background(Color(nsColor: .controlBackgroundColor))
    .onAppear {
      controller.setEnabled(isEnabled)
      controller.setVisible(true)
      controller.setAppActive(NSApp.isActive)
    }
    .onDisappear { controller.setVisible(false) }
    .onChange(of: isEnabled) { controller.setEnabled($0) }
    .onChange(of: controlActiveState) { controller.setAppActive($0 == .key) }
    .onReceive(NotificationCenter.default.publisher(for: .processViewerWindowVisibilityChanged)) {
      notification in
      controller.setVisible(notification.object as? Bool == true)
    }
    .onExitCommand {
      quitCandidate = nil
      forceCandidate = nil
    }
    .alert("退出“\(quitCandidate?.name ?? "进程")”吗？", isPresented: quitAlertPresented) {
      Button("取消", role: .cancel) {}
        .keyboardShortcut(.defaultAction)
      Button("退出进程", role: .destructive) {
        guard let candidate = quitCandidate else { return }
        controller.requestQuit(candidate)
      }
    } message: {
      if let process = quitCandidate {
        Text(
          "PID \(process.identity.pid) · CPU \(percent(process.cpuPercent)) · 内存 \(bytes(process.residentBytes))\n可能丢失未保存的内容。"
        )
      }
    }
    .alert("强制结束“\(forceCandidate?.name ?? "进程")”吗？", isPresented: forceAlertPresented) {
      Button("取消", role: .cancel) {}
        .keyboardShortcut(.defaultAction)
      Button("强制结束", role: .destructive) {
        guard let candidate = forceCandidate else { return }
        controller.requestForceQuit(candidate)
      }
    } message: {
      if let process = forceCandidate {
        Text(
          "强制结束可能丢失未保存内容。只会处理下方这个进程。\nPID \(process.identity.pid)\n\(process.executablePath ?? process.bundleIdentifier ?? "身份不可读取")\n启动标识 \(process.identity.startTimeMicroseconds)"
        )
      }
    }
  }

  private var header: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 4) {
        Text("进程查看器").font(.system(size: 20, weight: .semibold))
        Text("像“照妖镜”一样把后台占用说清楚，但它不是杀毒软件。")
          .font(.system(size: 12)).foregroundStyle(.secondary)
        Label(statusText, systemImage: controller.isPaused ? "pause.circle" : "waveform.path.ecg")
          .font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      Toggle("开启", isOn: $isEnabled).toggleStyle(.switch)
    }
  }

  private func memoryOverview(compact: Bool) -> some View {
    Group {
      if compact {
        VStack(spacing: 0) {
          memoryOccupancyPanel.frame(height: 112)
          Divider()
          LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(minimum: 130), spacing: 16), count: 2),
            spacing: 8
          ) {
            memoryMetric("物理内存", bytes(controller.memory.physicalBytes))
            memoryMetric("已用内存", bytes(controller.memory.usedBytes))
            memoryMetric("缓存文件", bytes(controller.memory.cachedFilesBytes))
            memoryMetric("已用的交换", swapUsedText)
            memoryMetric("App 内存", bytes(controller.memory.appMemoryBytes))
            memoryMetric("联动内存", bytes(controller.memory.wiredBytes))
            memoryMetric("被压缩", bytes(controller.memory.compressedBytes))
          }
          .padding(12)
        }
      } else {
        HStack(spacing: 0) {
          memoryOccupancyPanel
            .frame(minWidth: 240, idealWidth: 320, maxWidth: .infinity)
          Divider()
          memoryMetricColumn([
            ("物理内存", bytes(controller.memory.physicalBytes)),
            ("已使用内存", bytes(controller.memory.usedBytes)),
            ("缓存文件", bytes(controller.memory.cachedFilesBytes)),
            ("已用的交换", swapUsedText),
          ])
          Divider()
          memoryMetricColumn([
            ("App 内存", bytes(controller.memory.appMemoryBytes)),
            ("联动内存", bytes(controller.memory.wiredBytes)),
            ("被压缩", bytes(controller.memory.compressedBytes)),
          ])
        }
        .frame(minHeight: 144)
      }
    }
    .background(Color(nsColor: .textBackgroundColor).opacity(0.72))
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
  }

  private var memoryOccupancyPanel: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("物理内存占用")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Text(memoryOccupancyText)
          .font(.caption)
          .foregroundStyle(memoryOccupancyColor)
      }
      MemoryOccupancyGraph(
        values: controller.memoryOccupancyHistory,
        color: memoryOccupancyColor
      )
      .accessibilityLabel("物理内存占用，\(memoryOccupancyText)")
    }
    .padding(12)
  }

  private func memoryMetricColumn(_ metrics: [(String, String)]) -> some View {
    VStack(spacing: 7) {
      ForEach(Array(metrics.enumerated()), id: \.offset) { _, metric in
        memoryMetric(metric.0, metric.1)
      }
      Spacer(minLength: 0)
    }
    .padding(12)
    .frame(minWidth: 245, maxWidth: 360, alignment: .topLeading)
  }

  private func memoryMetric(_ title: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text("\(title)：")
        .font(.system(size: 13, weight: .medium))
      Spacer(minLength: 8)
      Text(value)
        .font(.system(size: 13, weight: .medium, design: .rounded))
        .monospacedDigit()
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder private func toolbar(compact: Bool) -> some View {
    if compact {
      VStack(alignment: .leading, spacing: 8) {
        searchField
        HStack {
          toolbarControls
          Spacer()
          updateText
        }
      }
    } else {
      HStack(spacing: 10) {
        searchField.frame(maxWidth: 360)
        toolbarControls
        Spacer()
        updateText
      }
    }
  }

  private var searchField: some View {
    TextField("搜索名称、Bundle ID 或 PID", text: $query)
      .textFieldStyle(.roundedBorder)
      .focused($searchFocused)
      .onReceive(NotificationCenter.default.publisher(for: .processViewerFocusSearch)) { _ in
        searchFocused = true
      }
      .background(ProcessViewerCommandFBridge())
  }

  private var toolbarControls: some View {
    Group {
      Toggle("显示系统后台", isOn: $showSystemProcesses)
        .toggleStyle(.switch)
        .help("默认隐藏 macOS 自带后台服务；你主动打开的 Apple 应用仍会显示。")
      Picker("排序", selection: $sort) {
        ForEach(ProcessViewerSort.allCases) { Text($0.rawValue).tag($0) }
      }.labelsHidden().frame(maxWidth: 160)
      Button {
        controller.isPaused.toggle()
      } label: {
        Label(
          controller.isPaused ? "继续" : "暂停",
          systemImage: controller.isPaused ? "play.fill" : "pause.fill")
      }
      Button {
        controller.refresh()
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .help("立即刷新").accessibilityLabel("立即刷新")
      .disabled(controller.isLoading || !isEnabled)
    }
  }

  private var updateText: some View {
    Text(
      controller.sampledAt.map { "更新于 \($0.formatted(date: .omitted, time: .standard))" } ?? "尚未采样"
    )
    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
  }

  private var hiddenSystemProcessCount: Int {
    guard !showSystemProcesses,
      query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return 0 }
    return controller.processes.filter(\.isKnownMacOSBackgroundProcess).count
  }

  private func processList(compact: Bool) -> some View {
    LazyVStack(spacing: 0, pinnedViews: compact ? [] : [.sectionHeaders]) {
      Section {
        if !isEnabled {
          processPlaceholder("进程查看器已关闭", icon: "cpu", detail: "开启插件后才会在此读取本机进程。")
        } else if controller.isLoading && controller.processes.isEmpty {
          ProgressView("正在读取进程…").frame(maxWidth: .infinity, minHeight: 180)
        } else if filteredProcesses.isEmpty {
          processPlaceholder("没有可显示的进程", icon: "magnifyingglass", detail: nil)
        } else {
          ForEach(filteredProcesses) { process in
            processRow(process, compact: compact)
            Divider()
          }
        }
      } header: {
        if !compact {
          HStack {
            Text("进程").frame(maxWidth: .infinity, alignment: .leading)
            Text("CPU").frame(width: 88, alignment: .trailing)
            Text("内存").frame(width: 104, alignment: .trailing)
            Text("状态").frame(width: 116, alignment: .leading)
            Text("").frame(width: 44)
          }
          .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
          .padding(.horizontal, 8).padding(.vertical, 7)
          .background(Color(nsColor: .controlBackgroundColor))
        }
      }
    }
  }

  private func processRow(_ process: ProcessViewerProcess, compact: Bool) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if compact {
        HStack {
          processIdentity(process)
          Spacer()
          processMenu(process)
        }
        Text("CPU \(percent(process.cpuPercent)) · 内存 \(bytes(process.residentBytes))")
          .font(.callout).monospacedDigit()
        processStatus(process)
      } else {
        HStack(spacing: 8) {
          processIdentity(process).frame(maxWidth: .infinity, alignment: .leading)
          Text(percent(process.cpuPercent)).monospacedDigit().frame(width: 88, alignment: .trailing)
          Text(bytes(process.residentBytes)).monospacedDigit().frame(
            width: 104, alignment: .trailing)
          processStatus(process).frame(width: 116, alignment: .leading)
          processMenu(process).frame(width: 44)
        }
      }
      if expandedIdentity == process.identity { processDetails(process) }
    }
    .padding(.horizontal, 8).padding(.vertical, 9)
    .accessibilityElement(children: .contain)
  }

  private func processPlaceholder(_ title: String, icon: String, detail: String?) -> some View {
    VStack(spacing: 8) {
      Image(systemName: icon).font(.system(size: 30)).foregroundStyle(.secondary)
      Text(title).font(.headline)
      if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
    }
    .frame(maxWidth: .infinity, minHeight: 180)
  }

  private func processIdentity(_ process: ProcessViewerProcess) -> some View {
    Button {
      withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
        expandedIdentity = expandedIdentity == process.identity ? nil : process.identity
      }
    } label: {
      HStack(spacing: 9) {
        Image(
          nsImage: NSRunningApplication(processIdentifier: process.identity.pid)?.icon ?? NSImage(
            systemSymbolName: "cpu", accessibilityDescription: nil)!
        )
        .resizable().scaledToFit().frame(width: 28, height: 28).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(process.name).lineLimit(1)
          Text("PID \(process.identity.pid)").font(.caption).foregroundStyle(.secondary)
            .monospacedDigit()
        }
      }.contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(
      "\(process.name)，PID \(process.identity.pid)，CPU \(percent(process.cpuPercent))，内存 \(bytes(process.residentBytes))，\(process.state.title)"
    )
    .accessibilityHint(expandedIdentity == process.identity ? "收起详情" : "展开详情")
  }

  private func processStatus(_ process: ProcessViewerProcess) -> some View {
    Group {
      switch process.actionState {
      case .quitting: Label("正在请求退出…", systemImage: "progress.indicator")
      case .quitFailed(let message), .forceFailed(let message):
        Label(message, systemImage: "exclamationmark.circle")
      case .exited: Label("已退出", systemImage: "checkmark.circle")
      case .idle:
        if process.protectionReason != nil {
          Label("受保护", systemImage: "lock.shield.fill")
        } else {
          Label(
            process.state.title, systemImage: process.state == .running ? "play.circle" : "moon.zzz"
          )
        }
      }
    }.font(.caption).foregroundStyle(.secondary).lineLimit(2)
  }

  private func processMenu(_ process: ProcessViewerProcess) -> some View {
    Menu {
      Button(expandedIdentity == process.identity ? "收起详情" : "展开详情") {
        expandedIdentity = expandedIdentity == process.identity ? nil : process.identity
      }
      Divider()
      Button("退出进程…", role: .destructive) { quitCandidate = process }
        .disabled(!process.canQuit)
      if process.actionState.allowsForce {
        Button("强制结束…", role: .destructive) { forceCandidate = process }
      }
      if let reason = process.protectionReason { Text(reason) }
    } label: {
      Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
    }
    .menuStyle(.borderlessButton).accessibilityLabel("\(process.name)，更多")
  }

  private func processDetails(_ process: ProcessViewerProcess) -> some View {
    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
      detailRow("路径", process.executablePath ?? "不可读取")
      detailRow("Bundle ID", process.bundleIdentifier ?? "不可读取")
      detailRow("用户", process.ownerName ?? "不可读取")
      detailRow("父 PID", String(process.parentPID))
      detailRow("启动标识", String(process.identity.startTimeMicroseconds))
      if let reason = process.protectionReason { detailRow("保护原因", reason) }
    }
    .font(.caption).padding(.leading, 16).padding(.vertical, 6)
  }

  private func detailRow(_ label: String, _ value: String) -> some View {
    GridRow {
      Text(label).foregroundStyle(.secondary)
      Text(value).textSelection(.enabled)
    }
  }

  private var quitAlertPresented: Binding<Bool> {
    Binding(get: { quitCandidate != nil }, set: { if !$0 { quitCandidate = nil } })
  }
  private var forceAlertPresented: Binding<Bool> {
    Binding(get: { forceCandidate != nil }, set: { if !$0 { forceCandidate = nil } })
  }
  private var statusText: String {
    if !isEnabled { return "已关闭 · 未采样" }
    if controller.isPaused {
      return
        "已暂停 · 数据来自 \(controller.sampledAt?.formatted(date: .omitted, time: .standard) ?? "尚未采样")"
    }
    return controller.isLoading ? "正在读取进程…" : "实时更新"
  }
  private var swapText: String {
    guard let used = controller.memory.swapUsedBytes, let total = controller.memory.swapTotalBytes
    else { return "暂不可读" }
    return "\(bytes(used)) / \(bytes(total))"
  }
  private var swapUsedText: String {
    guard let used = controller.memory.swapUsedBytes else { return "暂不可读" }
    return bytes(used)
  }
  private var memoryOccupancyColor: Color {
    switch controller.memory.occupancyRatio {
    case ..<0.72: return Color(nsColor: .systemGreen)
    case ..<0.88: return Color(nsColor: .systemYellow)
    default: return Color(nsColor: .systemRed)
    }
  }
  private var memoryOccupancyText: String {
    switch controller.memory.occupancyRatio {
    case ..<0.72: return "余量充足"
    case ..<0.88: return "占用较多"
    default: return "接近满载"
    }
  }
  private func bytes(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
  }
  private func percent(_ value: Double?) -> String {
    value.map { String(format: "%.1f%%", $0) } ?? "采样中…"
  }
  private func compare<T: Comparable>(_ lhs: T, _ rhs: T, descending: Bool) -> Bool {
    descending ? lhs > rhs : lhs < rhs
  }
  private func primaryValuesDiffer(_ lhs: ProcessViewerProcess, _ rhs: ProcessViewerProcess) -> Bool
  {
    switch sort {
    case .cpu: return lhs.cpuPercent != rhs.cpuPercent
    case .memory: return lhs.residentBytes != rhs.residentBytes
    case .name: return lhs.name.localizedCaseInsensitiveCompare(rhs.name) != .orderedSame
    case .pid: return lhs.identity.pid != rhs.identity.pid
    case .state: return lhs.state != rhs.state
    }
  }
}

private struct MemoryOccupancyGraph: View {
  let values: [Double]
  let color: Color

  var body: some View {
    GeometryReader { proxy in
      let samples = values.isEmpty ? [0] : values
      let step = samples.count > 1 ? proxy.size.width / CGFloat(samples.count - 1) : 0
      let points = samples.enumerated().map { index, value in
        CGPoint(
          x: CGFloat(index) * step,
          y: proxy.size.height * (1 - CGFloat(min(1, max(0, value)))))
      }
      ZStack(alignment: .bottomLeading) {
        Path { path in
          path.move(to: CGPoint(x: 0, y: proxy.size.height))
          for point in points {
            path.addLine(to: point)
          }
          path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height))
          path.closeSubpath()
        }
        .fill(color.opacity(0.18))
        Path { path in
          guard let first = points.first else { return }
          path.move(to: first)
          for point in points.dropFirst() {
            path.addLine(to: point)
          }
        }
        .stroke(color, lineWidth: 1.5)
      }
    }
  }
}

extension Notification.Name {
  fileprivate static let processViewerFocusSearch = Notification.Name(
    "aixlg.processViewer.focusSearch")
}

private struct ProcessViewerCommandFBridge: NSViewRepresentable {
  final class Coordinator {
    var monitor: Any?
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
  }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
        event.charactersIgnoringModifiers?.lowercased() == "f"
      else { return event }
      NotificationCenter.default.post(name: .processViewerFocusSearch, object: nil)
      return nil
    }
    return view
  }
  func updateNSView(_ nsView: NSView, context: Context) {}
}
