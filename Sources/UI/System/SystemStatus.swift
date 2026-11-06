import AppKit
import SwiftUI

struct SystemStatusPanelView: View {
  @EnvironmentObject private var model: AppModel

  private var snapshot: SystemMonitorSnapshot {
    model.systemMonitorSnapshot
  }

  private var memoryTint: Color {
    color(for: snapshot.memory.pressure)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 14) {
          IconBadge(systemImage: "speedometer", tint: accent, size: 48, iconSize: 20)
          VStack(alignment: .leading, spacing: 5) {
            Text("系统状态")
              .font(.system(size: 18, weight: .semibold))
              .foregroundStyle(ink)
            Text("网络与内存")
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(muted)
          }
          Spacer()
          StatusPill(text: snapshot.memory.pressure.title, color: memoryTint)
        }
        .padding(16)
        .premiumPanel(radius: 17)

        LazyVGrid(columns: metricColumns, spacing: 12) {
          SystemStatusMetricCard(
            title: "下载",
            value: formatRate(snapshot.network.downloadBytesPerSecond),
            detail: "实时接收速率",
            systemImage: "arrow.down.circle.fill",
            tint: accent
          )
          SystemStatusMetricCard(
            title: "上传",
            value: formatRate(snapshot.network.uploadBytesPerSecond),
            detail: "实时发送速率",
            systemImage: "arrow.up.circle.fill",
            tint: teal
          )
          SystemStatusMetricCard(
            title: "内存",
            value: "\(Int((snapshot.memory.usedRatio * 100).rounded()))%",
            detail:
              "\(formatBytes(snapshot.memory.usedBytes)) / \(formatBytes(snapshot.memory.totalBytes))",
            systemImage: "memorychip.fill",
            tint: memoryTint
          )
        }

        VStack(alignment: .leading, spacing: 14) {
          HStack(alignment: .firstTextBaseline) {
            Text("内存使用")
              .font(.system(size: 15, weight: .semibold))
              .foregroundStyle(ink)
            Spacer()
            Text("更新 \(sampleTimeText)")
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(muted)
          }

          ProgressView(value: snapshot.memory.usedRatio)
            .tint(memoryTint)
            .controlSize(.small)

          LazyVGrid(columns: detailColumns, spacing: 10) {
            SystemStatusDetailLine(
              title: "已用", value: formatBytes(snapshot.memory.usedBytes), tint: memoryTint)
            SystemStatusDetailLine(
              title: "可用", value: formatBytes(snapshot.memory.availableBytes), tint: muted)
            SystemStatusDetailLine(
              title: "App 内存", value: formatBytes(snapshot.memory.appBytes), tint: accent)
            SystemStatusDetailLine(
              title: "联动内存", value: formatBytes(snapshot.memory.wiredBytes), tint: amber)
            SystemStatusDetailLine(
              title: "压缩",
              value: formatBytes(snapshot.memory.compressedBytes),
              tint: ruby
            )
          }
        }
        .padding(16)
        .premiumPanel(radius: 17)
      }
      .padding(.top, 4)
      .padding(.bottom, 10)
    }
    .scrollIndicators(.visible)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear {
      model.startSystemMonitor()
    }
    .onDisappear {
      model.stopSystemMonitor()
    }
  }

  private var metricColumns: [GridItem] {
    [GridItem(.adaptive(minimum: 220), spacing: 12)]
  }

  private var detailColumns: [GridItem] {
    [GridItem(.adaptive(minimum: 170), spacing: 10)]
  }

  private var sampleTimeText: String {
    guard snapshot.sampledAt.timeIntervalSince1970 > 0 else { return "--:--:--" }
    return DateFormatter.localizedString(
      from: snapshot.sampledAt, dateStyle: .none, timeStyle: .medium)
  }

  private func color(for pressure: MemoryPressureLevel) -> Color {
    switch pressure {
    case .normal: return teal
    case .elevated: return amber
    case .high: return ruby
    }
  }
}

struct SystemStatusMetricCard: View {
  let title: String
  let value: String
  let detail: String
  let systemImage: String
  let tint: Color

  var body: some View {
    HStack(spacing: 12) {
      IconBadge(systemImage: systemImage, tint: tint, size: 42, iconSize: 18, filled: false)
      VStack(alignment: .leading, spacing: 5) {
        Text(title)
          .font(.system(size: 12, weight: .bold))
          .foregroundStyle(muted)
        Text(value)
          .font(.system(size: 24, weight: .semibold, design: .rounded))
          .foregroundStyle(ink)
          .lineLimit(1)
          .minimumScaleFactor(0.72)
        Text(detail)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(muted)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .padding(14)
    .frame(minHeight: 118, alignment: .leading)
    .premiumPanel(radius: 16)
  }
}

struct SystemStatusDetailLine: View {
  let title: String
  let value: String
  let tint: Color

  var body: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(tint)
        .frame(width: 8, height: 8)
      Text(title)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(muted)
      Spacer()
      Text(value)
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(ink)
    }
    .padding(.horizontal, 10)
    .frame(height: 34)
    .background(softSurface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .stroke(line.opacity(0.65), lineWidth: 1)
    )
  }
}

func formatBytes(_ bytes: UInt64) -> String {
  guard bytes > 0 else { return "0 KB" }
  let value = Double(bytes)
  let gb = value / 1_073_741_824
  if gb >= 1 {
    return String(format: "%.1f GB", gb)
  }
  let mb = value / 1_048_576
  if mb >= 1 {
    return String(format: "%.1f MB", mb)
  }
  return String(format: "%.0f KB", value / 1024)
}

func formatRate(_ bytesPerSecond: Double) -> String {
  guard bytesPerSecond > 0 else { return "0 KB/s" }
  let mb = bytesPerSecond / 1_000_000
  if mb >= 1 {
    return String(format: "%.1f MB/s", mb)
  }
  let kb = bytesPerSecond / 1_000
  if kb >= 1 {
    return String(format: "%.0f KB/s", kb)
  }
  return String(format: "%.0f B/s", bytesPerSecond)
}
