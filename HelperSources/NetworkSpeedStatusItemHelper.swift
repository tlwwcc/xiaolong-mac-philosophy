import AppKit
import Darwin
import Foundation

private let helperEnvironment = ProcessInfo.processInfo.environment
private let defaultsSuiteName =
  helperEnvironment["AIXLG_DEFAULTS_SUITE"] ?? "invalid.aixlg.helper.defaults"

private struct NetworkSnapshot {
  let downloadBytesPerSecond: Double
  let uploadBytesPerSecond: Double
}

private struct DisplayOptions {
  let showMemory: Bool
  let showCPU: Bool
  let showGPU: Bool
}

private struct StatusMetric {
  let label: String
  let value: String
}

private struct NetworkStatusMenuItemState: Codable {
  let id: String
  let title: String
  let isEnabled: Bool
  let isHidden: Bool
  let toolTip: String?
}

private struct NetworkStatusMenuSnapshot: Codable {
  let items: [NetworkStatusMenuItemState]
}

private struct NetworkStatusHelperMessage: Codable {
  let type: String
  let snapshot: NetworkStatusMenuSnapshot?
  let volume: Double?
}

private enum NetworkHelperProcessRunner {
  private static let maximumCapturedOutputBytes = 1_048_576

  static func run(
    executableURL: URL,
    arguments: [String]
  ) -> (status: Int32, output: Data)? {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
      try process.run()
      try? pipe.fileHandleForWriting.close()

      // Drain while the child is still allowed to run so a full pipe can never block its exit.
      var captured = Data()
      while true {
        let chunk = pipe.fileHandleForReading.readData(ofLength: 64 * 1_024)
        guard !chunk.isEmpty else { break }
        let remaining = maximumCapturedOutputBytes - captured.count
        if remaining > 0 { captured.append(chunk.prefix(remaining)) }
      }
      process.waitUntilExit()
      return (process.terminationStatus, captured)
    } catch {
      try? pipe.fileHandleForWriting.close()
      try? pipe.fileHandleForReading.close()
      return nil
    }
  }
}

#if AIXLG_HELPER_PROCESS_PIPE_FIXTURE
  func runNetworkHelperLargeOutputProcess(
    executableURL: URL,
    arguments: [String]
  ) -> (status: Int32, outputByteCount: Int)? {
    guard let result = NetworkHelperProcessRunner.run(
      executableURL: executableURL,
      arguments: arguments)
    else { return nil }
    return (result.status, result.output.count)
  }
#endif

private enum StatusMenuCommandID {
  static let quickSnapshot = "youmu.quickSnapshot"
  static let annotatedScreenshot = "youmu.annotatedScreenshot"
  static let longScreenshot = "youmu.longScreenshot"
  static let pinScreenshot = "youmu.pinScreenshot"
  static let ocrCopy = "youmu.ocrCopy"
  static let ocrTranslate = "youmu.ocrTranslate"
  static let selectionReader = "youmu.selectionReader"
  static let imageTranslate = "youmu.imageTranslate"
  static let requestMenuSnapshot = "host.requestMenuSnapshot"
  static let phrases = "host.phrases"
  static let networkProbe = "host.networkProbe"
  static let keepAwake = "host.keepAwake"
  static let launcher = "host.launcher"
  static let shortcuts = "host.shortcuts"
  static let processViewer = "host.processViewer"
  static let pijuanPDF = "host.pijuanPDF"
  static let clipboardHistory = "host.clipboardHistory"
  static let pluginCenter = "host.pluginCenter"
  static let menuBarSettings = "host.menuBarSettings"
  static let settings = "host.settings"
  static let checkUpdates = "host.checkUpdates"
  static let togglePaused = "host.togglePaused"
  static let quit = "host.quit"

  static let customizable: Set<String> = [
    quickSnapshot,
    annotatedScreenshot,
    longScreenshot,
    pinScreenshot,
    ocrCopy,
    ocrTranslate,
    selectionReader,
    imageTranslate,
    phrases,
    networkProbe,
    keepAwake,
    launcher,
    shortcuts,
    processViewer,
    pijuanPDF,
    clipboardHistory,
  ]
}

private final class DisplayOptionsReader {
  private let defaults = UserDefaults(suiteName: defaultsSuiteName) ?? .standard

  func read() -> DisplayOptions {
    return DisplayOptions(
      showMemory: boolDefaultingTrue(forKey: "networkSpeedShowMemoryV1"),
      showCPU: defaults.bool(forKey: "networkSpeedShowCPUV1"),
      showGPU: defaults.bool(forKey: "networkSpeedShowGPUV1")
    )
  }

  private func boolDefaultingTrue(forKey key: String) -> Bool {
    guard defaults.object(forKey: key) != nil else { return true }
    return defaults.bool(forKey: key)
  }
}

private final class NetworkSpeedSampler {
  private struct Counters {
    let receivedBytes: UInt64
    let sentBytes: UInt64
    let interfaceNames: Set<String>
  }

  private var previousCounters: Counters?
  private var previousSampleTime: TimeInterval?

  func sample() -> NetworkSnapshot {
    let now = ProcessInfo.processInfo.systemUptime
    let counters = readCounters()
    defer {
      previousCounters = counters
      previousSampleTime = now
    }

    guard let previousCounters, let previousSampleTime,
      previousCounters.interfaceNames == counters.interfaceNames
    else {
      return NetworkSnapshot(downloadBytesPerSecond: 0, uploadBytesPerSecond: 0)
    }

    let elapsed = max(now - previousSampleTime, 0.001)
    return NetworkSnapshot(
      downloadBytesPerSecond: Double(delta(counters.receivedBytes, previousCounters.receivedBytes))
        / elapsed,
      uploadBytesPerSecond: Double(delta(counters.sentBytes, previousCounters.sentBytes)) / elapsed
    )
  }

  private func delta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
    current >= previous ? current - previous : 0
  }

  private func readCounters() -> Counters {
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
      return Counters(receivedBytes: 0, sentBytes: 0, interfaceNames: [])
    }
    defer { freeifaddrs(interfaces) }

    var receivedBytes: UInt64 = 0
    var sentBytes: UInt64 = 0
    var interfaceNames: Set<String> = []
    var cursor: UnsafeMutablePointer<ifaddrs>? = firstInterface

    while let interface = cursor {
      defer { cursor = interface.pointee.ifa_next }
      guard let address = interface.pointee.ifa_addr else { continue }
      guard Int32(address.pointee.sa_family) == AF_LINK else { continue }

      let flags = interface.pointee.ifa_flags
      guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
      guard let namePointer = interface.pointee.ifa_name else { continue }
      let interfaceName = String(cString: namePointer)
      guard !interfaceName.hasPrefix("lo") else { continue }
      guard let data = interface.pointee.ifa_data?.assumingMemoryBound(to: if_data.self).pointee
      else {
        continue
      }

      receivedBytes += UInt64(data.ifi_ibytes)
      sentBytes += UInt64(data.ifi_obytes)
      interfaceNames.insert(interfaceName)
    }

    return Counters(
      receivedBytes: receivedBytes,
      sentBytes: sentBytes,
      interfaceNames: interfaceNames)
  }
}

private final class MemoryUsageSampler {
  private let totalBytes = MemoryUsageSampler.readTotalMemoryBytes()
  private let pageBytes = MemoryUsageSampler.readPageSizeBytes()

  func samplePercent() -> Int? {
    guard totalBytes > 0, pageBytes > 0 else { return nil }

    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
    )
    let result = withUnsafeMutablePointer(to: &stats) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
        host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPointer, &count)
      }
    }
    guard result == KERN_SUCCESS else { return nil }

    let usedBytes = min(
      totalBytes,
      (UInt64(stats.internal_page_count) + UInt64(stats.wire_count)
        + UInt64(stats.compressor_page_count)) * pageBytes
    )
    return Int((Double(usedBytes) / Double(totalBytes) * 100).rounded())
  }

  private static func readTotalMemoryBytes() -> UInt64 {
    var totalBytes: UInt64 = 0
    var size = MemoryLayout<UInt64>.size
    let result = sysctlbyname("hw.memsize", &totalBytes, &size, nil, 0)
    return result == 0 ? totalBytes : 0
  }

  private static func readPageSizeBytes() -> UInt64 {
    var pageSize: vm_size_t = 0
    guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS, pageSize > 0 else {
      return 0
    }
    return UInt64(pageSize)
  }
}

private final class CPUUsageSampler {
  private struct Ticks {
    let active: UInt64
    let idle: UInt64
  }

  private var previousTicks: Ticks?
  private var cachedPercent: Int?

  func samplePercent() -> Int? {
    guard let ticks = readTicks() else { return nil }
    defer { previousTicks = ticks }
    guard let previousTicks else { return cachedPercent }

    let activeDelta = ticks.active >= previousTicks.active ? ticks.active - previousTicks.active : 0
    let idleDelta = ticks.idle >= previousTicks.idle ? ticks.idle - previousTicks.idle : 0
    let totalDelta = activeDelta + idleDelta
    guard totalDelta > 0 else { return cachedPercent }
    let percent = Int((Double(activeDelta) / Double(totalDelta) * 100).rounded())
    cachedPercent = min(100, max(0, percent))
    return cachedPercent
  }

  private func readTicks() -> Ticks? {
    var load = host_cpu_load_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
    )
    let result = withUnsafeMutablePointer(to: &load) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
        host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, reboundPointer, &count)
      }
    }
    guard result == KERN_SUCCESS else { return nil }

    let ticks = withUnsafeBytes(of: load.cpu_ticks) { rawBuffer in
      Array(rawBuffer.bindMemory(to: integer_t.self))
    }
    guard ticks.count > Int(CPU_STATE_IDLE) else { return nil }

    let user = UInt64(max(0, ticks[Int(CPU_STATE_USER)]))
    let system = UInt64(max(0, ticks[Int(CPU_STATE_SYSTEM)]))
    let nice = UInt64(max(0, ticks[Int(CPU_STATE_NICE)]))
    let idle = UInt64(max(0, ticks[Int(CPU_STATE_IDLE)]))
    return Ticks(active: user + system + nice, idle: idle)
  }
}

private final class GPUUsageSampler: @unchecked Sendable {
  private let queue = DispatchQueue(
    label: "\(defaultsSuiteName).gpu-sampler",
    qos: .utility)
  private let lock = NSLock()
  private var cachedPercent: Int?
  private var nextSampleAt = Date.distantPast
  private var isSampling = false
  private let successfulSampleInterval: TimeInterval = 15
  private let unsupportedRetryInterval: TimeInterval = 10 * 60

  func samplePercent() -> Int? {
    let now = Date()
    lock.lock()
    let cached = cachedPercent
    let shouldSample = !isSampling && now >= nextSampleAt
    if shouldSample {
      isSampling = true
      nextSampleAt = now.addingTimeInterval(successfulSampleInterval)
    }
    lock.unlock()

    if shouldSample {
      queue.async { [weak self] in
        guard let self else { return }
        let result = Self.readDeviceUtilization()
        self.lock.lock()
        defer { self.lock.unlock() }
        self.cachedPercent = result
        self.nextSampleAt = Date().addingTimeInterval(
          result == nil ? self.unsupportedRetryInterval : self.successfulSampleInterval)
        self.isSampling = false
      }
    }
    return cached
  }

  private static func readDeviceUtilization(timeout: TimeInterval = 2) -> Int? {
    let fileManager = FileManager.default
    let captureDirectory = fileManager.temporaryDirectory.appendingPathComponent(
      "aixlg-gpu-sample-\(UUID().uuidString)",
      isDirectory: true)
    guard
      (try? fileManager.createDirectory(at: captureDirectory, withIntermediateDirectories: true))
        != nil
    else { return nil }
    defer { try? fileManager.removeItem(at: captureDirectory) }
    let outputURL = captureDirectory.appendingPathComponent("stdout")
    guard fileManager.createFile(atPath: outputURL.path, contents: nil),
      let outputHandle = try? FileHandle(forWritingTo: outputURL)
    else { return nil }
    defer { try? outputHandle.close() }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
    process.arguments = [
      "-r", "-c", "IOAccelerator", "-k", "PerformanceStatistics", "-d", "1",
    ]
    process.standardOutput = outputHandle
    process.standardError = FileHandle.nullDevice
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }

    do {
      try process.run()
    } catch {
      return nil
    }
    guard finished.wait(timeout: .now() + timeout) == .success else {
      process.terminate()
      if finished.wait(timeout: .now() + 0.5) != .success, process.isRunning {
        Darwin.kill(process.processIdentifier, SIGKILL)
        _ = finished.wait(timeout: .now() + 0.5)
      }
      return nil
    }
    guard process.terminationStatus == 0 else { return nil }
    try? outputHandle.synchronize()
    guard let data = try? Data(contentsOf: outputURL) else { return nil }
    guard let text = String(data: data, encoding: .utf8),
      let keyRange = text.range(of: "\"Device Utilization %\"=")
    else {
      return nil
    }

    let tail = text[keyRange.upperBound...]
    let digits = tail.prefix { $0.isNumber }
    guard !digits.isEmpty else { return nil }
    return Int(digits).map { min(100, max(0, $0)) }
  }
}

@MainActor
private final class StatusItemRenderer {
  private let uploadColor = NSColor(calibratedRed: 1.0, green: 0.36, blue: 0.31, alpha: 0.96)
  private let downloadColor = NSColor(calibratedRed: 0.18, green: 0.62, blue: 1.0, alpha: 0.96)
  private var statusTextColor: NSColor { NSColor.labelColor.withAlphaComponent(0.94) }

  func image(
    network: NetworkSnapshot,
    metrics: [StatusMetric],
    appearance: NSAppearance? = nil
  ) -> NSImage {
    let upload = menuRateDisplay(network.uploadBytesPerSecond)
    let download = menuRateDisplay(network.downloadBytesPerSecond)
    let rateValueFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
    let rateUnitFont = NSFont.monospacedSystemFont(ofSize: 7.5, weight: .medium)
    let metricLabelFont = NSFont.systemFont(ofSize: 6.2, weight: .regular)
    let metricValueFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)

    // Live values must only redraw inside their slots. Resizing an NSStatusItem every second makes
    // macOS reflow every neighbouring menu bar item whenever a value gains or loses a digit.
    // Value and unit are separate columns so KB/s and MB/s always start at the same x-position.
    let arrowLaneWidth: CGFloat = 6.5
    let arrowTextGap: CGFloat = 2.5
    let valueUnitGap: CGFloat = 1.5
    let rateValueWidth = measure("999", font: rateValueFont)
    let rateUnitWidth =
      ["B/s", "KB/s", "MB/s", "GB/s"]
      .map { measure($0, font: rateUnitFont) }
      .max() ?? 0
    let valueOriginX = arrowLaneWidth + arrowTextGap
    let unitOriginX = valueOriginX + rateValueWidth + valueUnitGap
    let networkWidth = unitOriginX + rateUnitWidth
    let metricWidths = metrics.map {
      max(20, measure($0.label, font: metricLabelFont), measure("100%", font: metricValueFont))
        + 4
    }
    let metricsWidth = metricWidths.reduce(CGFloat(0), +)
    let metricsGap: CGFloat = metrics.isEmpty ? 0 : 5
    let imageWidth = ceil(networkWidth + metricsGap + metricsWidth)
    let imageSize = NSSize(width: imageWidth, height: 22)
    let image = NSImage(size: imageSize)
    image.isTemplate = false

    image.lockFocus()
    // The menu bar may use a dark material while the host application still uses Aqua.
    // Resolve semantic label colors against the status button itself instead of baking the
    // main application's appearance into a bitmap that becomes black on a dark menu bar.
    (appearance ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance {
      NSColor.clear.setFill()
      NSRect(origin: .zero, size: imageSize).fill()

      drawTransferArrow(up: true, color: uploadColor, centerX: 3.2, tipY: 19.0)
      drawTransferArrow(up: false, color: downloadColor, centerX: 3.2, tipY: 3.0)

      drawRate(
        upload,
        baselineY: 9.1,
        valueOriginX: valueOriginX,
        valueWidth: rateValueWidth,
        unitOriginX: unitOriginX,
        valueFont: rateValueFont,
        unitFont: rateUnitFont)
      drawRate(
        download,
        baselineY: -0.2,
        valueOriginX: valueOriginX,
        valueWidth: rateValueWidth,
        unitOriginX: unitOriginX,
        valueFont: rateValueFont,
        unitFont: rateUnitFont)

      var x = networkWidth + metricsGap
      for (index, metric) in metrics.enumerated() {
        draw(
          metric.label, at: CGPoint(x: x, y: 11.3), font: metricLabelFont, color: statusTextColor
        )
        draw(
          metric.value, at: CGPoint(x: x, y: 0.0), font: metricValueFont, color: statusTextColor)
        x += metricWidths[index]
      }
    }
    image.unlockFocus()
    return image
  }

  private func measure(_ text: String, font: NSFont) -> CGFloat {
    (text as NSString).size(withAttributes: [.font: font]).width
  }

  private func draw(_ text: String, at point: CGPoint, font: NSFont, color: NSColor) {
    (text as NSString).draw(
      at: point,
      withAttributes: [
        .font: font,
        .foregroundColor: color,
      ]
    )
  }

  private func drawRate(
    _ rate: MenuRateDisplay,
    baselineY: CGFloat,
    valueOriginX: CGFloat,
    valueWidth: CGFloat,
    unitOriginX: CGFloat,
    valueFont: NSFont,
    unitFont: NSFont
  ) {
    let valueX = valueOriginX + valueWidth - measure(rate.value, font: valueFont)
    draw(
      rate.value, at: CGPoint(x: valueX, y: baselineY), font: valueFont, color: statusTextColor)
    draw(
      rate.unit,
      at: CGPoint(x: unitOriginX, y: baselineY + 0.8),
      font: unitFont,
      color: statusTextColor)
  }

  private func drawTransferArrow(up: Bool, color: NSColor, centerX: CGFloat, tipY: CGFloat) {
    let direction: CGFloat = up ? -1 : 1
    let shoulderY = tipY + (direction * 2.0)
    let stemEndY = tipY + (direction * 6.0)
    let path = NSBezierPath()
    path.lineWidth = 1.15
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.move(to: CGPoint(x: centerX, y: stemEndY))
    path.line(to: CGPoint(x: centerX, y: tipY))
    path.move(to: CGPoint(x: centerX - 2.1, y: shoulderY))
    path.line(to: CGPoint(x: centerX, y: tipY))
    path.line(to: CGPoint(x: centerX + 2.1, y: shoulderY))
    color.setStroke()
    path.stroke()
  }
}

@MainActor
private final class NetworkSpeedStatusItemApp: NSObject, NSApplicationDelegate {
  private let optionsReader = DisplayOptionsReader()
  private let networkSampler = NetworkSpeedSampler()
  private let memorySampler = MemoryUsageSampler()
  private let cpuSampler = CPUUsageSampler()
  private let gpuSampler = GPUUsageSampler()
  private let renderer = StatusItemRenderer()
  private let parentPID: pid_t
  private let parentBundleID: String?
  private let parentAppPath: String?
  private let parentExecutableName: String?
  private let helperExecutableName: String?
  private let notificationNamespace: String?
  private let appDisplayName: String
  private var statusItem: NSStatusItem?
  private var statusMenu: NSMenu?
  private var statusMenuItems: [String: NSMenuItem] = [:]
  private var youmuSectionSeparator: NSMenuItem?
  private var managementSectionSeparator: NSMenuItem?
  private var isOpeningStatusMenu = false
  private var parentInputBuffer = Data()
  private var volumeFeedbackResetWorkItem: DispatchWorkItem?
  private var isShowingVolumeFeedback = false
  private var renderedStatusItemLength: CGFloat?
  private var updateTimer: Timer?
  private var parentTimer: Timer?
  private lazy var launchCodeIdentityIsValid: Bool = {
    guard let parentAppPath, let helperExecutableName else { return false }
    let helperPath = URL(fileURLWithPath: parentAppPath, isDirectory: true)
      .appendingPathComponent("Contents/MacOS/\(helperExecutableName)")
      .standardizedFileURL.path
    return Self.codeSignatureChainIsValid(
      parentAppPath: parentAppPath,
      helperPath: helperPath)
  }()

  override init() {
    let environment = ProcessInfo.processInfo.environment
    if let rawPID = ProcessInfo.processInfo.environment["AIXLG_PARENT_PID"],
      let parsedPID = Int32(rawPID)
    {
      parentPID = parsedPID
    } else {
      parentPID = 0
    }
    parentBundleID = Self.nonEmpty(environment["AIXLG_PARENT_BUNDLE_ID"])
    parentAppPath = Self.nonEmpty(environment["AIXLG_PARENT_APP_PATH"])
    parentExecutableName = Self.nonEmpty(environment["AIXLG_PARENT_EXECUTABLE"])
    helperExecutableName = Self.nonEmpty(environment["AIXLG_HELPER_EXECUTABLE"])
    notificationNamespace = Self.nonEmpty(environment["AIXLG_NOTIFICATION_NAMESPACE"])
    appDisplayName =
      Self.nonEmpty(environment["AIXLG_APP_DISPLAY_NAME"])
      ?? "小龙哥Mac哲学"
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard parentIdentityIsValid() else {
      NSApp.terminate(nil)
      return
    }
    NSApp.setActivationPolicy(.accessory)
    buildStatusItem()
    startParentMessageInput()
    startTimers()
    sendParentCommand(StatusMenuCommandID.requestMenuSnapshot)
  }

  func applicationWillTerminate(_ notification: Notification) {
    updateTimer?.invalidate()
    parentTimer?.invalidate()
    volumeFeedbackResetWorkItem?.cancel()
    FileHandle.standardInput.readabilityHandler = nil
  }

  private func buildStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.autosaveName = NSStatusItem.AutosaveName(
      "\(notificationNamespace ?? defaultsSuiteName).primaryNetworkStatusItem.v1")
    item.button?.imagePosition = .imageOnly
    item.button?.toolTip = "点击查看快捷操作"
    item.button?.target = self
    item.button?.action = #selector(statusItemClicked(_:))
    item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    item.isVisible = true

    buildStatusMenu()
    statusItem = item
    refreshStatusItem()
  }

  private func buildStatusMenu() {
    let menu = NSMenu()
    menu.autoenablesItems = false

    let youmuItems = [
      (StatusMenuCommandID.quickSnapshot, "快速截图", "viewfinder"),
      (StatusMenuCommandID.annotatedScreenshot, "截图并标注", "pencil.and.outline"),
      (StatusMenuCommandID.longScreenshot, "长截图", "arrow.down.to.line"),
      (StatusMenuCommandID.pinScreenshot, "钉截图", "pin.fill"),
      (StatusMenuCommandID.ocrCopy, "OCR 复制", "doc.on.doc"),
      (StatusMenuCommandID.ocrTranslate, "OCR 翻译", "character.bubble"),
      (StatusMenuCommandID.selectionReader, "选区朗读", "speaker.wave.2"),
      (StatusMenuCommandID.imageTranslate, "图片翻译", "photo"),
    ]
    for item in youmuItems {
      menu.addItem(
        makeMenuItem(id: item.0, title: item.1, systemImage: item.2, isEnabled: false))
    }
    let youmuSeparator = NSMenuItem.separator()
    menu.addItem(youmuSeparator)
    youmuSectionSeparator = youmuSeparator
    menu.addItem(
      makeMenuItem(
        id: StatusMenuCommandID.phrases,
        title: "快捷短语",
        systemImage: "text.bubble"))
    menu.addItem(
      makeMenuItem(
        id: StatusMenuCommandID.networkProbe,
        title: "测试网速",
        systemImage: "gauge.with.dots.needle.67percent"))
    menu.addItem(
      makeMenuItem(
        id: StatusMenuCommandID.keepAwake,
        title: "保持唤醒",
        systemImage: "moon.zzz.fill"))
    menu.addItem(
      makeMenuItem(
        id: StatusMenuCommandID.launcher,
        title: "启动器",
        systemImage: "magnifyingglass"))
    menu.addItem(
      makeMenuItem(
        id: StatusMenuCommandID.shortcuts,
        title: "查看快捷键",
        systemImage: "command"))
    menu.addItem(
      makeMenuItem(
        id: StatusMenuCommandID.processViewer,
        title: "进程查看器",
        systemImage: "cpu"))
    menu.addItem(
      makeMenuItem(
        id: StatusMenuCommandID.pijuanPDF,
        title: "披卷",
        systemImage: "doc.richtext",
        isHidden: true))
    menu.addItem(
      makeMenuItem(
        id: StatusMenuCommandID.clipboardHistory,
        title: "剪贴板历史",
        systemImage: "doc.on.clipboard",
        isHidden: true))
    let managementSeparator = NSMenuItem.separator()
    menu.addItem(managementSeparator)
    managementSectionSeparator = managementSeparator
    menu.addItem(
      makeMenuItem(
        id: StatusMenuCommandID.pluginCenter,
        title: "应用中心",
        systemImage: "square.grid.2x2.fill"))
    menu.addItem(
      makeMenuItem(
        id: StatusMenuCommandID.menuBarSettings,
        title: "自定义菜单栏…",
        systemImage: "menubar.rectangle"))
    menu.addItem(
      makeMenuItem(
        id: StatusMenuCommandID.settings,
        title: "设置…",
        systemImage: "gearshape",
        keyEquivalent: ","))
    menu.addItem(
      makeMenuItem(
        id: StatusMenuCommandID.checkUpdates,
        title: "检查更新…",
        systemImage: "arrow.triangle.2.circlepath"))
    menu.addItem(.separator())
    menu.addItem(
      makeMenuItem(
        id: StatusMenuCommandID.togglePaused,
        title: "暂停后台快捷键",
        systemImage: "pause.circle"))
    menu.addItem(.separator())
    menu.addItem(
      makeMenuItem(
        id: StatusMenuCommandID.quit,
        title: "退出",
        systemImage: "xmark.circle",
        keyEquivalent: "q"))
    statusMenu = menu
    refreshMenuSectionSeparators()
  }

  private func makeMenuItem(
    id: String,
    title: String,
    systemImage: String,
    keyEquivalent: String = "",
    isEnabled: Bool = true,
    isHidden: Bool = false
  ) -> NSMenuItem {
    let item = NSMenuItem(
      title: title,
      action: #selector(statusMenuItemSelected(_:)),
      keyEquivalent: keyEquivalent)
    item.target = self
    item.representedObject = id
    item.image = menuImage(systemName: systemImage, accessibilityDescription: title)
    item.isEnabled = isEnabled
    item.isHidden = isHidden
    statusMenuItems[id] = item
    return item
  }

  private func menuImage(systemName: String, accessibilityDescription: String) -> NSImage? {
    let image = NSImage(
      systemSymbolName: systemName,
      accessibilityDescription: accessibilityDescription)
    image?.isTemplate = true
    return image
  }

  private func refreshMenuSectionSeparators() {
    let youmuCommandIDs = [
      StatusMenuCommandID.quickSnapshot,
      StatusMenuCommandID.annotatedScreenshot,
      StatusMenuCommandID.longScreenshot,
      StatusMenuCommandID.pinScreenshot,
      StatusMenuCommandID.ocrCopy,
      StatusMenuCommandID.ocrTranslate,
      StatusMenuCommandID.selectionReader,
      StatusMenuCommandID.imageTranslate,
    ]
    let shortcutCommandIDs = [
      StatusMenuCommandID.phrases,
      StatusMenuCommandID.networkProbe,
      StatusMenuCommandID.keepAwake,
      StatusMenuCommandID.launcher,
      StatusMenuCommandID.shortcuts,
      StatusMenuCommandID.processViewer,
      StatusMenuCommandID.pijuanPDF,
      StatusMenuCommandID.clipboardHistory,
    ]
    let hasVisibleYoumuItem = youmuCommandIDs.contains { commandID in
      statusMenuItems[commandID]?.isHidden == false
    }
    let hasVisibleShortcutItem = shortcutCommandIDs.contains { commandID in
      statusMenuItems[commandID]?.isHidden == false
    }

    // The first separator only divides two populated customizable groups. The second one
    // reflows to divide whichever customizable group remains from the fixed management group.
    youmuSectionSeparator?.isHidden = !(hasVisibleYoumuItem && hasVisibleShortcutItem)
    managementSectionSeparator?.isHidden = !(hasVisibleYoumuItem || hasVisibleShortcutItem)
  }

  private func startTimers() {
    updateTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in self?.refreshStatusItem() }
    }

    parentTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in self?.exitIfParentIsGone() }
    }
  }

  private func refreshStatusItem() {
    guard !isShowingVolumeFeedback else { return }
    let network = networkSampler.sample()
    let options = optionsReader.read()
    let metrics = selectedMetrics(options: options)
    let button = statusItem?.button
    let image = renderer.image(
      network: network,
      metrics: metrics,
      appearance: button?.effectiveAppearance)
    let desiredLength = image.size.width + 4
    if renderedStatusItemLength != desiredLength {
      statusItem?.length = desiredLength
      renderedStatusItemLength = desiredLength
    }
    statusItem?.button?.imagePosition = .imageOnly
    statusItem?.button?.image = image
    statusItem?.button?.title = ""
    statusItem?.button?.toolTip = tooltip(network: network, metrics: metrics)
    let accessibilityLabel =
      "\(appDisplayName)主入口。\(tooltip(network: network, metrics: metrics))"
    statusItem?.button?.setAccessibilityLabel(accessibilityLabel)
  }

  private func selectedMetrics(options: DisplayOptions) -> [StatusMetric] {
    var metrics: [StatusMetric] = []
    if options.showMemory {
      metrics.append(StatusMetric(label: "RAM", value: percentValue(memorySampler.samplePercent())))
    }
    if options.showCPU {
      metrics.append(StatusMetric(label: "CPU", value: percentValue(cpuSampler.samplePercent())))
    }
    if options.showGPU, let percent = gpuSampler.samplePercent() {
      metrics.append(StatusMetric(label: "GPU", value: percentValue(percent)))
    }
    return metrics
  }

  private func percentValue(_ percent: Int?) -> String {
    guard let percent else { return "--" }
    return "\(percent)%"
  }

  private func tooltip(network: NetworkSnapshot, metrics: [StatusMetric]) -> String {
    let metricText = metrics.map { "\($0.label) \($0.value)" }.joined(separator: " · ")
    let base =
      "上传 \(fullRate(network.uploadBytesPerSecond)) · 下载 \(fullRate(network.downloadBytesPerSecond))"
    let values = metricText.isEmpty ? base : "\(base) · \(metricText)"
    return "\(values) · 点击查看快捷操作"
  }

  private func exitIfParentIsGone() {
    guard parentIdentityIsValid() else {
      NSApp.terminate(nil)
      return
    }
  }

  private func parentIdentityIsValid() -> Bool {
    guard parentPID > 1,
      getppid() == parentPID,
      let parentBundleID,
      let parentExecutableName,
      let helperExecutableName,
      notificationNamespace == parentBundleID,
      defaultsSuiteName == parentBundleID,
      let parentAppPath,
      let app = NSRunningApplication(processIdentifier: parentPID),
      !app.isTerminated,
      app.bundleIdentifier == parentBundleID,
      let parentExecutablePath = app.executableURL?.resolvingSymlinksInPath().standardizedFileURL
        .path,
      let helperExecutablePath = Self.currentExecutablePath(),
      app.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path
        == URL(fileURLWithPath: parentAppPath).resolvingSymlinksInPath().standardizedFileURL.path,
      parentExecutablePath
        == URL(fileURLWithPath: parentAppPath, isDirectory: true)
        .appendingPathComponent("Contents/MacOS/\(parentExecutableName)")
        .resolvingSymlinksInPath().standardizedFileURL.path,
      helperExecutablePath
        == URL(fileURLWithPath: parentAppPath, isDirectory: true)
        .appendingPathComponent("Contents/MacOS/\(helperExecutableName)")
        .resolvingSymlinksInPath().standardizedFileURL.path,
      launchCodeIdentityIsValid,
      parentProcessIsAlive()
    else {
      return false
    }
    return true
  }

  @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
    openStatusMenu()
  }

  private func openStatusMenu() {
    guard !isOpeningStatusMenu else { return }
    isOpeningStatusMenu = true
    sendParentCommand(StatusMenuCommandID.requestMenuSnapshot)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
      guard let self, let statusItem = self.statusItem, let statusMenu = self.statusMenu else {
        self?.isOpeningStatusMenu = false
        return
      }
      statusItem.menu = statusMenu
      statusItem.button?.performClick(nil)
      statusItem.menu = nil
      self.isOpeningStatusMenu = false
    }
  }

  @objc private func statusMenuItemSelected(_ sender: NSMenuItem) {
    guard let command = sender.representedObject as? String else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
      self?.sendParentCommand(command)
    }
  }

  private func sendParentCommand(_ command: String) {
    guard let data = "\(command)\n".data(using: .utf8) else { return }
    do {
      try FileHandle.standardOutput.write(contentsOf: data)
    } catch {
      NSApp.terminate(nil)
    }
  }

  private func startParentMessageInput() {
    FileHandle.standardInput.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        handle.readabilityHandler = nil
        return
      }
      DispatchQueue.main.async {
        self?.receiveParentInput(data)
      }
    }
  }

  private func receiveParentInput(_ data: Data) {
    parentInputBuffer.append(data)
    guard parentInputBuffer.count <= 131_072 else {
      parentInputBuffer.removeAll(keepingCapacity: false)
      return
    }
    while let newline = parentInputBuffer.firstIndex(of: 0x0A) {
      let lineData = Data(parentInputBuffer[..<newline])
      parentInputBuffer.removeSubrange(...newline)
      guard !lineData.isEmpty,
        let message = try? JSONDecoder().decode(NetworkStatusHelperMessage.self, from: lineData)
      else { continue }
      applyParentMessage(message)
    }
  }

  private func applyParentMessage(_ message: NetworkStatusHelperMessage) {
    switch message.type {
    case "snapshot":
      if let snapshot = message.snapshot {
        applyMenuSnapshot(snapshot)
      }
    case "volume":
      if let volume = message.volume, volume.isFinite {
        showVolumeFeedback(min(100, max(0, volume)))
      }
    default:
      break
    }
  }

  private func applyMenuSnapshot(_ snapshot: NetworkStatusMenuSnapshot) {
    guard snapshot.items.count <= 32 else { return }
    for state in snapshot.items {
      guard state.title.count <= 160, let item = statusMenuItems[state.id] else { continue }
      item.title = state.title
      item.isEnabled = state.isEnabled
      item.isHidden = StatusMenuCommandID.customizable.contains(state.id) ? state.isHidden : false
      item.toolTip = state.toolTip
      if state.id == StatusMenuCommandID.togglePaused {
        let symbol = state.title.hasPrefix("启用") ? "play.circle" : "pause.circle"
        item.image = menuImage(systemName: symbol, accessibilityDescription: state.title)
      }
    }
    refreshMenuSectionSeparators()
  }

  private func showVolumeFeedback(_ volume: Double) {
    guard let statusItem, let button = statusItem.button else { return }
    let percent = "\(Int(volume.rounded()))%"
    volumeFeedbackResetWorkItem?.cancel()
    isShowingVolumeFeedback = true
    button.image = nil
    button.imagePosition = .noImage
    button.title = percent
    button.font = .monospacedDigitSystemFont(ofSize: percent.count > 4 ? 11 : 13, weight: .semibold)
    button.toolTip = "当前音量：\(percent)"
    button.setAccessibilityLabel("当前音量：\(percent)")

    let reset = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.isShowingVolumeFeedback = false
      self.volumeFeedbackResetWorkItem = nil
      self.refreshStatusItem()
    }
    volumeFeedbackResetWorkItem = reset
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: reset)
  }

  private func parentProcessIsAlive() -> Bool {
    guard parentPID > 0 else { return false }
    return kill(parentPID, 0) == 0
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    return value
  }

  private static func currentExecutablePath() -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 else { return nil }
    let pathBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return URL(fileURLWithPath: String(decoding: pathBytes, as: UTF8.self))
      .resolvingSymlinksInPath().standardizedFileURL.path
  }

  private static func codeSignatureChainIsValid(
    parentAppPath: String,
    helperPath: String
  ) -> Bool {
    guard runCodeSign(["--verify", "--deep", "--strict", parentAppPath])?.status == 0,
      runCodeSign(["--verify", "--strict", helperPath])?.status == 0
    else {
      return false
    }

    let infoPath = URL(fileURLWithPath: parentAppPath, isDirectory: true)
      .appendingPathComponent("Contents/Info.plist").path
    let isFormalRelease =
      (NSDictionary(contentsOfFile: infoPath)?["AIXLGFormalReleaseCompiled"] as? Bool) == true
    guard isFormalRelease else { return true }
    guard
      let parentTeam = codeSigningValue(
        "TeamIdentifier",
        output: runCodeSign(["-dv", "--verbose=4", parentAppPath])?.output),
      parentTeam != "not set",
      let helperTeam = codeSigningValue(
        "TeamIdentifier",
        output: runCodeSign(["-dv", "--verbose=4", helperPath])?.output),
      helperTeam == parentTeam
    else {
      return false
    }
    return true
  }

  private static func runCodeSign(_ arguments: [String]) -> (status: Int32, output: String)? {
    guard
      let result = NetworkHelperProcessRunner.run(
        executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
        arguments: arguments)
    else { return nil }
    return (result.status, String(data: result.output, encoding: .utf8) ?? "")
  }

  private static func codeSigningValue(_ key: String, output: String?) -> String? {
    guard let output else { return nil }
    let prefix = "\(key)="
    return output.split(separator: "\n").compactMap { line -> String? in
      let text = String(line)
      guard text.hasPrefix(prefix) else { return nil }
      let value = String(text.dropFirst(prefix.count))
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return value.isEmpty ? nil : value
    }.first
  }

}

private struct MenuRateDisplay {
  let value: String
  let unit: String

  var text: String { "\(value) \(unit)" }
}

private func compactRateValue(_ value: Double) -> String {
  let bounded = min(max(value, 0), 999)
  if bounded < 9.95 {
    return String(format: "%.1f", bounded)
  }
  return "\(min(Int(bounded.rounded()), 999))"
}

private func menuRateDisplay(_ bytesPerSecond: Double) -> MenuRateDisplay {
  guard bytesPerSecond.isFinite, bytesPerSecond > 0 else {
    return MenuRateDisplay(value: "0", unit: "B/s")
  }
  if bytesPerSecond >= 1_000_000_000 {
    return MenuRateDisplay(
      value: compactRateValue(bytesPerSecond / 1_000_000_000), unit: "GB/s")
  }
  if bytesPerSecond >= 1_000_000 {
    return MenuRateDisplay(
      value: compactRateValue(bytesPerSecond / 1_000_000), unit: "MB/s")
  }
  if bytesPerSecond >= 1_000 {
    return MenuRateDisplay(
      value: "\(min(Int((bytesPerSecond / 1_000).rounded()), 999))", unit: "KB/s")
  }
  return MenuRateDisplay(
    value: "\(min(Int(bytesPerSecond.rounded()), 999))", unit: "B/s")
}

private func menuRate(_ bytesPerSecond: Double) -> String {
  menuRateDisplay(bytesPerSecond).text
}

private func fullRate(_ bytesPerSecond: Double) -> String {
  guard bytesPerSecond > 0 else { return "0 KB/s" }
  if bytesPerSecond >= 1_000_000 {
    return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
  }
  if bytesPerSecond >= 1_000 {
    return String(format: "%.0f KB/s", bytesPerSecond / 1_000)
  }
  return String(format: "%.0f B/s", bytesPerSecond)
}

#if AIXLG_NETWORK_STATUS_LAYOUT_FIXTURE
  private func extremeCompositedTextLuminance(
    in image: NSImage,
    pointRect: CGRect,
    backgroundLuminance: CGFloat,
    findMinimum: Bool = false
  ) -> CGFloat {
    guard let tiffData = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiffData),
      image.size.width > 0,
      image.size.height > 0
    else {
      return 0
    }
    let scaleX = CGFloat(bitmap.pixelsWide) / image.size.width
    let scaleY = CGFloat(bitmap.pixelsHigh) / image.size.height
    let lowerX = max(0, Int(floor(pointRect.minX * scaleX)))
    let upperX = min(bitmap.pixelsWide, Int(ceil(pointRect.maxX * scaleX)))
    let lowerY = max(0, Int(floor((image.size.height - pointRect.maxY) * scaleY)))
    let upperY = min(
      bitmap.pixelsHigh, Int(ceil((image.size.height - pointRect.minY) * scaleY)))
    guard lowerX < upperX, lowerY < upperY else { return 0 }

    var extreme: CGFloat = findMinimum ? 1 : 0
    for x in lowerX..<upperX {
      for y in lowerY..<upperY {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
          continue
        }
        let foregroundLuminance =
          color.redComponent * 0.2126 + color.greenComponent * 0.7152
          + color.blueComponent * 0.0722
        let alpha = color.alphaComponent
        let composited = foregroundLuminance * alpha + backgroundLuminance * (1 - alpha)
        extreme = findMinimum ? min(extreme, composited) : max(extreme, composited)
      }
    }
    return extreme
  }

  private func countBrightTextPixels(in image: NSImage) -> Int {
    guard let tiffData = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiffData)
    else {
      return 0
    }
    var count = 0
    // Ignore the colored arrow lane. The remaining opaque pixels belong to rate and metric text.
    for x in 8..<bitmap.pixelsWide {
      for y in 0..<bitmap.pixelsHigh {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
          color.alphaComponent > 0.20
        else { continue }
        let luminance =
          color.redComponent * 0.2126 + color.greenComponent * 0.7152
          + color.blueComponent * 0.0722
        if luminance > 0.65 { count += 1 }
      }
    }
    return count
  }

  @MainActor
  private func writeNetworkStatusFixturePreview(
    renderer: StatusItemRenderer,
    to path: String
  ) -> Bool {
    let statusImage = renderer.image(
      network: NetworkSnapshot(
        downloadBytesPerSecond: 249_000,
        uploadBytesPerSecond: 9_900_000),
      metrics: [
        StatusMetric(label: "RAM", value: "59%"),
        StatusMetric(label: "CPU", value: "67%"),
        StatusMetric(label: "GPU", value: "42%"),
      ],
      appearance: NSAppearance(named: .darkAqua))
    let canvasSize = NSSize(width: statusImage.size.width + 20, height: 30)
    let canvas = NSImage(size: canvasSize)
    canvas.lockFocus()
    NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
    NSRect(origin: .zero, size: canvasSize).fill()
    statusImage.draw(at: CGPoint(x: 10, y: 4), from: .zero, operation: .sourceOver, fraction: 1)
    canvas.unlockFocus()

    guard
      let tiffData = canvas.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiffData),
      let pngData = bitmap.representation(using: .png, properties: [:])
    else {
      return false
    }
    do {
      try pngData.write(to: URL(fileURLWithPath: path), options: .atomic)
      return true
    } catch {
      return false
    }
  }

  @MainActor
  private func runNetworkStatusLayoutFixture() -> Int32 {
    _ = NSApplication.shared
    let renderer = StatusItemRenderer()
    let rates: [Double] = [
      0, 9, 99, 999, 1_000, 9_000, 99_000, 100_000, 999_999, 1_000_000,
      9_900_000, 99_900_000, 999_900_000, 1_000_000_000, 999_900_000_000,
      .infinity, .nan,
    ]
    let metricConfigurations = [
      [StatusMetric](),
      [StatusMetric(label: "RAM", value: "9%")],
      [
        StatusMetric(label: "RAM", value: "9%"),
        StatusMetric(label: "CPU", value: "99%"),
        StatusMetric(label: "GPU", value: "100%"),
      ],
    ]

    for metrics in metricConfigurations {
      let widths = Set(
        rates.map {
          renderer.image(
            network: NetworkSnapshot(downloadBytesPerSecond: $0, uploadBytesPerSecond: $0),
            metrics: metrics
          ).size.width
        })
      guard widths.count == 1 else {
        fputs("network status width changed with a live rate\n", stderr)
        return 1
      }
    }

    let metricWidths = Set(
      ["--", "0%", "9%", "10%", "99%", "100%"].map {
        renderer.image(
          network: NetworkSnapshot(downloadBytesPerSecond: 100_000, uploadBytesPerSecond: 9_000),
          metrics: [StatusMetric(label: "RAM", value: $0)]
        ).size.width
      })
    guard metricWidths.count == 1 else {
      fputs("network status width changed with a live metric\n", stderr)
      return 1
    }

    let rateValueFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
    let reservedRateValueWidth = ("999" as NSString)
      .size(withAttributes: [.font: rateValueFont]).width
    for rate in rates {
      let renderedRateValueWidth = (menuRateDisplay(rate).value as NSString)
        .size(withAttributes: [.font: rateValueFont]).width
      guard renderedRateValueWidth <= reservedRateValueWidth else {
        fputs("formatted network value exceeded its fixed slot\n", stderr)
        return 1
      }
    }

    let expectedRates: [(Double, String)] = [
      (999, "999 B/s"),
      (999_999, "999 KB/s"),
      (1_000_000, "1.0 MB/s"),
      (9_900_000, "9.9 MB/s"),
      (10_000_000, "10 MB/s"),
      (999_999_999, "999 MB/s"),
      (1_000_000_000, "1.0 GB/s"),
      (1_000_000_000_000, "999 GB/s"),
    ]
    for (rate, expected) in expectedRates where menuRate(rate) != expected {
      fputs("unexpected bounded rate format for \(rate)\n", stderr)
      return 1
    }

    guard let darkAppearance = NSAppearance(named: .darkAqua) else {
      fputs("dark menu bar appearance is unavailable\n", stderr)
      return 1
    }
    let fixtureMetrics = [
      StatusMetric(label: "RAM", value: "59%"),
      StatusMetric(label: "CPU", value: "67%"),
      StatusMetric(label: "GPU", value: "42%"),
    ]
    let networkSnapshot = NetworkSnapshot(
      downloadBytesPerSecond: 249_000,
      uploadBytesPerSecond: 9_900_000)
    let darkImage = renderer.image(
      network: networkSnapshot,
      metrics: fixtureMetrics,
      appearance: darkAppearance)
    guard let lightAppearance = NSAppearance(named: .aqua) else {
      fputs("light menu bar appearance is unavailable\n", stderr)
      return 1
    }
    let lightImage = renderer.image(
      network: networkSnapshot,
      metrics: fixtureMetrics,
      appearance: lightAppearance)
    guard countBrightTextPixels(in: darkImage) >= 20 else {
      fputs("network status text is not legible in a dark menu bar appearance\n", stderr)
      return 1
    }

    let fixtureValueFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
    let fixtureUnitFont = NSFont.monospacedSystemFont(ofSize: 7.5, weight: .medium)
    let fixtureMetricLabelFont = NSFont.systemFont(ofSize: 6.2, weight: .regular)
    let fixtureMetricValueFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
    let fixtureValueOriginX: CGFloat = 9.0
    let fixtureValueWidth =
      ("999" as NSString).size(withAttributes: [.font: fixtureValueFont]).width
    let fixtureUnitOriginX = fixtureValueOriginX + fixtureValueWidth + 1.5
    let fixtureUnitWidth =
      ["B/s", "KB/s", "MB/s", "GB/s"]
      .map { ($0 as NSString).size(withAttributes: [.font: fixtureUnitFont]).width }
      .max() ?? 0
    let rateRects = [
      CGRect(x: fixtureValueOriginX, y: 11, width: fixtureValueWidth, height: 11),
      CGRect(x: fixtureUnitOriginX, y: 11, width: fixtureUnitWidth, height: 11),
      CGRect(x: fixtureValueOriginX, y: 0, width: fixtureValueWidth, height: 11),
      CGRect(x: fixtureUnitOriginX, y: 0, width: fixtureUnitWidth, height: 11),
    ]
    var metricRects: [CGRect] = []
    var fixtureMetricOriginX = fixtureUnitOriginX + fixtureUnitWidth + 5
    for metric in fixtureMetrics {
      let width =
        max(
          20,
          (metric.label as NSString).size(withAttributes: [.font: fixtureMetricLabelFont]).width,
          ("100%" as NSString).size(withAttributes: [.font: fixtureMetricValueFont]).width)
        + 4
      metricRects.append(
        CGRect(x: fixtureMetricOriginX, y: 11, width: width, height: 11))
      metricRects.append(
        CGRect(x: fixtureMetricOriginX, y: 0, width: width, height: 11))
      fixtureMetricOriginX += width
    }
    let textRects = rateRects + metricRects
    let darkForegroundPeaks = textRects.map {
      extremeCompositedTextLuminance(in: darkImage, pointRect: $0, backgroundLuminance: 0.16)
    }
    let lightForegroundPeaks = textRects.map {
      extremeCompositedTextLuminance(
        in: lightImage, pointRect: $0, backgroundLuminance: 0.94, findMinimum: true)
    }
    guard darkForegroundPeaks.allSatisfy({ $0 >= 0.92 }),
      (darkForegroundPeaks.max() ?? 0) - (darkForegroundPeaks.min() ?? 0) <= 0.02,
      lightForegroundPeaks.allSatisfy({ $0 <= 0.09 }),
      (lightForegroundPeaks.max() ?? 0) - (lightForegroundPeaks.min() ?? 0) <= 0.02
    else {
      fputs(
        "network rate, unit, RAM, CPU, and GPU text do not share one adaptive foreground color "
          + "(dark=\(darkForegroundPeaks), light=\(lightForegroundPeaks))\n",
        stderr)
      return 1
    }

    if let previewPath = ProcessInfo.processInfo.environment["AIXLG_NETWORK_STATUS_PREVIEW_PATH"],
      !writeNetworkStatusFixturePreview(renderer: renderer, to: previewPath)
    {
      fputs("could not write network status fixture preview\n", stderr)
      return 1
    }

    print("network status fixed-width fixture: PASS")
    return 0
  }

  @main
  private enum NetworkStatusLayoutFixtureMain {
    @MainActor
    static func main() {
      exit(runNetworkStatusLayoutFixture())
    }
  }
#elseif !AIXLG_HELPER_PROCESS_PIPE_FIXTURE
  @main
  private enum NetworkSpeedStatusHelperMain {
    static func main() {
      let delegate = NetworkSpeedStatusItemApp()
      let app = NSApplication.shared
      app.delegate = delegate
      app.run()
    }
  }
#endif
