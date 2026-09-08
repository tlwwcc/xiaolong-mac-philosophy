import AppKit
import Foundation

/// Compact AppKit view intended for `NSMenuItem.view`.
/// Status colour is intentionally limited to the small dot and the thin history curve.
final class SystemHealthMenuCard: NSView {
  var openProcessViewer: (() -> Void)?

  private let defaults: UserDefaults
  private let statusDot = SystemHealthStatusDotView()
  private let titleLabel = SystemHealthMenuCard.label(
    font: .systemFont(ofSize: 13, weight: .semibold),
    color: .labelColor)
  private let detailLabel = SystemHealthMenuCard.label(
    font: .systemFont(ofSize: 10.5, weight: .regular),
    color: .secondaryLabelColor)
  private let timeLabel = SystemHealthMenuCard.label(
    font: .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular),
    color: .tertiaryLabelColor,
    alignment: .right)
  private let graph = SystemHealthPressureGraphView()
  private let metricRows = NSStackView()
  private let processButton = NSButton()
  private var metricCells: [SystemHealthMetricView] = []
  private var metricRowViews: [NSStackView] = []
  private var preferredHeight: CGFloat = 230
  private var cardHeightConstraint: NSLayoutConstraint?

  init(
    defaults: UserDefaults = SystemHealthMonitorPreferences.helperDefaults(),
    openProcessViewer: (() -> Void)? = nil
  ) {
    self.defaults = defaults
    self.openProcessViewer = openProcessViewer
    super.init(frame: NSRect(origin: .zero, size: NSSize(width: 344, height: 230)))
    translatesAutoresizingMaskIntoConstraints = false
    setupView()
    _ = refreshEnabledState()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: 344, height: preferredHeight)
  }

  /// Re-reads `systemHealthMonitorEnabledV1`; parent menus can use the return value to hide the
  /// owning menu item as well.
  @discardableResult
  func refreshEnabledState() -> Bool {
    let enabled = SystemHealthMonitorPreferences.isEnabled(in: defaults)
    isHidden = !enabled
    return enabled
  }

  func update(snapshot: SystemHealthSnapshot) {
    let tint = Self.color(for: snapshot.assessment.severity)
    statusDot.color = tint
    titleLabel.stringValue = snapshot.assessment.title
    detailLabel.stringValue = snapshot.assessment.detail
    timeLabel.stringValue = snapshot.sampledAt.formatted(date: .omitted, time: .shortened)
    graph.update(
      points: snapshot.pressureHistory,
      window: 5 * 60,
      endDate: snapshot.sampledAt,
      color: tint)

    var metrics: [(String, String)] = []
    if snapshot.memoryPressure != .unavailable {
      metrics.append(("内存压力", snapshot.memoryPressure.title))
    }
    if let used = snapshot.usedMemoryBytes, let physical = snapshot.physicalMemoryBytes {
      metrics.append(("内存", "\(Self.bytes(used)) / \(Self.bytes(physical))"))
    }
    if let cpu = snapshot.cpuUsagePercent, cpu.isFinite {
      metrics.append(("CPU", Self.percent(cpu)))
    }
    if let gpu = snapshot.gpuUsagePercent, gpu.isFinite {
      metrics.append(("GPU", Self.percent(gpu)))
    }
    if let swapUsed = snapshot.swapUsedBytes {
      let activity: String
      if let rate = snapshot.swapActivityBytesPerSecond {
        activity = rate >= 1 ? "活动 \(Self.rate(rate))" : "无活动"
      } else {
        activity = "正在取样"
      }
      metrics.append(("交换", "\(Self.bytes(swapUsed)) · \(activity)"))
    }
    if snapshot.thermalState != .unavailable {
      metrics.append(("温控", snapshot.thermalState.title))
    }
    if let temperature = snapshot.temperatureCelsius, temperature.isFinite {
      metrics.append(("温度", String(format: "%.0f°C", temperature)))
    }
    if let fanRPM = snapshot.fanRPM, fanRPM.isFinite, fanRPM >= 0 {
      metrics.append(("风扇", "\(Int(fanRPM.rounded())) RPM"))
    }
    applyMetrics(metrics)

    setAccessibilityLabel(
      "系统健康：\(snapshot.assessment.title)。\(snapshot.assessment.detail)。"
        + metrics.map { "\($0.0) \($0.1)" }.joined(separator: "，"))
  }

  private func setupView() {
    wantsLayer = true
    layer?.cornerRadius = 9
    layer?.backgroundColor = NSColor.clear.cgColor

    let headerText = NSStackView(views: [titleLabel, detailLabel])
    headerText.orientation = .vertical
    headerText.alignment = .leading
    headerText.spacing = 1

    let header = NSStackView(views: [statusDot, headerText, timeLabel])
    header.orientation = .horizontal
    header.alignment = .centerY
    header.spacing = 8
    headerText.setHuggingPriority(.defaultLow, for: .horizontal)
    headerText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    timeLabel.setContentHuggingPriority(.required, for: .horizontal)
    timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

    let historyCaption = SystemHealthMenuCard.label(
      font: .systemFont(ofSize: 9.5, weight: .regular),
      color: .tertiaryLabelColor)
    historyCaption.stringValue = "内存压力 · 过去 5 分钟"

    metricRows.orientation = .vertical
    metricRows.alignment = .leading
    metricRows.spacing = 3
    metricRows.distribution = .fillEqually
    for _ in 0..<4 {
      let left = SystemHealthMetricView()
      let right = SystemHealthMetricView()
      metricCells.append(contentsOf: [left, right])
      let row = NSStackView(views: [left, right])
      row.orientation = .horizontal
      row.alignment = .centerY
      row.spacing = 12
      row.distribution = .fillEqually
      metricRows.addArrangedSubview(row)
      metricRowViews.append(row)
      row.widthAnchor.constraint(equalToConstant: 316).isActive = true
      row.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    let divider = NSBox()
    divider.boxType = .separator

    processButton.title = "打开进程查看器"
    processButton.image = NSImage(
      systemSymbolName: "arrow.up.right.square",
      accessibilityDescription: "打开进程查看器")
    processButton.imagePosition = .imageLeading
    processButton.font = .systemFont(ofSize: 11.5, weight: .medium)
    processButton.bezelStyle = .inline
    processButton.controlSize = .small
    processButton.target = self
    processButton.action = #selector(openProcessViewerSelected)
    processButton.setAccessibilityLabel("打开进程查看器")

    let root = NSStackView(views: [
      header, historyCaption, graph, metricRows, divider, processButton,
    ])
    root.orientation = .vertical
    root.alignment = .leading
    root.spacing = 6
    root.translatesAutoresizingMaskIntoConstraints = false
    addSubview(root)

    let heightConstraint = heightAnchor.constraint(equalToConstant: preferredHeight)
    cardHeightConstraint = heightConstraint
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: 344),
      heightConstraint,
      root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
      root.topAnchor.constraint(equalTo: topAnchor, constant: 10),
      root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
      statusDot.widthAnchor.constraint(equalToConstant: 8),
      statusDot.heightAnchor.constraint(equalToConstant: 8),
      header.widthAnchor.constraint(equalToConstant: 316),
      timeLabel.widthAnchor.constraint(equalToConstant: 45),
      graph.widthAnchor.constraint(equalToConstant: 316),
      graph.heightAnchor.constraint(equalToConstant: 42),
      divider.widthAnchor.constraint(equalToConstant: 316),
      processButton.heightAnchor.constraint(equalToConstant: 24),
    ])
  }

  private func applyMetrics(_ metrics: [(String, String)]) {
    for (index, cell) in metricCells.enumerated() {
      if index < metrics.count {
        cell.update(title: metrics[index].0, value: metrics[index].1)
        cell.isHidden = false
      } else {
        cell.isHidden = true
      }
    }
    let visibleRowCount = min(metricRowViews.count, (metrics.count + 1) / 2)
    for (index, row) in metricRowViews.enumerated() {
      row.isHidden = index >= visibleRowCount
    }
    metricRows.isHidden = visibleRowCount == 0

    let metricsHeight =
      visibleRowCount > 0
      ? CGFloat(visibleRowCount * 24 + max(0, visibleRowCount - 1) * 3)
      : 0
    // The fixed header/caption/graph/divider/button stack needs 157 pt before metric rows. Using
    // 151 pt lets Auto Layout compress the secondary status line into a visibly clipped half-line.
    preferredHeight = 157 + metricsHeight
    cardHeightConstraint?.constant = preferredHeight
    frame.size.height = preferredHeight
    invalidateIntrinsicContentSize()
  }

  @objc private func openProcessViewerSelected() {
    openProcessViewer?()
  }

  private static func label(
    font: NSFont,
    color: NSColor,
    alignment: NSTextAlignment = .left
  ) -> NSTextField {
    let label = NSTextField(labelWithString: "")
    label.font = font
    label.textColor = color
    label.alignment = alignment
    label.lineBreakMode = .byTruncatingTail
    return label
  }

  private static func color(for severity: SystemHealthSeverity) -> NSColor {
    switch severity {
    case .healthy: return .systemGreen
    case .warning: return .systemYellow
    case .critical: return .systemRed
    case .unavailable: return .tertiaryLabelColor
    }
  }

  private static func bytes(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
  }

  private static func percent(_ value: Double) -> String {
    String(format: "%.0f%%", min(100, max(0, value)))
  }

  private static func rate(_ value: Double) -> String {
    guard value.isFinite, value >= 1 else { return "0 B/s" }
    return "\(ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file))/s"
  }
}

private final class SystemHealthStatusDotView: NSView {
  var color: NSColor = .tertiaryLabelColor {
    didSet { needsDisplay = true }
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    color.setFill()
    NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
  }
}

private final class SystemHealthMetricView: NSView {
  private let titleLabel = NSTextField(labelWithString: "")
  private let valueLabel = NSTextField(labelWithString: "")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = .systemFont(ofSize: 9.5, weight: .regular)
    titleLabel.textColor = .secondaryLabelColor
    valueLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
    valueLabel.textColor = .labelColor
    valueLabel.lineBreakMode = .byTruncatingMiddle
    let stack = NSStackView(views: [titleLabel, valueLabel])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 0
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(title: String, value: String) {
    titleLabel.stringValue = title
    valueLabel.stringValue = value
    setAccessibilityLabel("\(title) \(value)")
  }
}

private final class SystemHealthPressureGraphView: NSView {
  private var points: [SystemHealthPressurePoint] = []
  private var historyWindow: TimeInterval = 5 * 60
  private var endDate = Date()
  private var color: NSColor = .tertiaryLabelColor

  func update(
    points: [SystemHealthPressurePoint],
    window: TimeInterval,
    endDate: Date,
    color: NSColor
  ) {
    self.points = points
    historyWindow = max(1, window)
    self.endDate = endDate
    self.color = color
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    let guide = NSBezierPath()
    guide.move(to: CGPoint(x: bounds.minX, y: bounds.midY))
    guide.line(to: CGPoint(x: bounds.maxX, y: bounds.midY))
    guide.lineWidth = 0.5
    NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
    guide.stroke()

    let cutoff = endDate.addingTimeInterval(-historyWindow)
    let visible = points.filter { $0.sampledAt >= cutoff && $0.sampledAt <= endDate }
    guard let first = visible.first else { return }

    func graphPoint(_ point: SystemHealthPressurePoint) -> CGPoint {
      let elapsed = point.sampledAt.timeIntervalSince(cutoff)
      let x = bounds.minX + CGFloat(min(1, max(0, elapsed / historyWindow))) * bounds.width
      let value = SystemHealthMath.clampUnit(point.value)
      let y = bounds.minY + CGFloat(value) * max(1, bounds.height - 2) + 1
      return CGPoint(x: x, y: y)
    }

    let path = NSBezierPath()
    path.lineWidth = 1.35
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.move(to: graphPoint(first))
    for point in visible.dropFirst() {
      path.line(to: graphPoint(point))
    }
    color.setStroke()
    path.stroke()

    if visible.count == 1 {
      color.setFill()
      NSBezierPath(
        ovalIn: NSRect(origin: graphPoint(first), size: .zero).insetBy(dx: -1.6, dy: -1.6)
      )
      .fill()
    }
  }
}
