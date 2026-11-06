import AppKit
import SwiftUI

struct OnDemandApplicationDetailView: View {
  let productName: String
  let headline: String
  let description: String
  let action: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 7) {
          Text(headline)
            .font(.title3.weight(.semibold))
            .foregroundStyle(ink)
          Text(description)
            .font(.body)
            .foregroundStyle(muted)
            .fixedSize(horizontal: false, vertical: true)
        }

        ApplicationWindowOpenButton(productName: productName, action: action)
      }
      .padding(22)
      .frame(maxWidth: 680, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct ApplicationWindowOpenButton: View {
  let productName: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label("打开窗口", systemImage: "arrow.up.right.square")
    }
    .buttonStyle(.borderedProminent)
    .tint(AppVisualStyle.emphasizedSelection)
    .controlSize(.large)
    .help("打开 \(productName) 窗口")
    .accessibilityLabel("打开 \(productName) 窗口")
  }
}

struct YoumuApplicationDetailView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    Group {
      if let settings = model.makeYoumuSettingsViewHandler?() {
        settings
      } else {
        Text("截图设置暂不可用，请重新打开软件。")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }
}

struct PijuanApplicationDetailView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 7) {
          Text("阅读 PDF")
            .font(.title3.weight(.semibold))
            .foregroundStyle(ink)
          Text("阅读、检索和整理长文档。")
            .font(.body)
            .foregroundStyle(muted)
        }

        HStack(spacing: 12) {
          Button {
            model.showPijuanPDFFeature()
          } label: {
            Label("打开PDF 浏览器", systemImage: "doc.richtext")
          }
          .buttonStyle(.borderedProminent)
          .tint(AppVisualStyle.emphasizedSelection)
          Button {
            model.openPijuanPDFShortcutManager()
          } label: {
            Label("管理快捷键", systemImage: "keyboard")
          }
        }

        FileAssociationControlCard(
          kind: .pdf,
          title: "双击 PDF 直接进入PDF 浏览器",
          detail: "不会默认抢走现有设置；只有你点击按钮后才会关联，之后也能一键恢复原应用。",
          systemImage: "doc.richtext.fill",
          tint: violet)
      }
      .padding(22)
      .frame(maxWidth: 680, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct FileAssociationControlCard: View {
  @EnvironmentObject private var model: AppModel

  let kind: AssociatedFileKind
  let title: String
  let detail: String
  let systemImage: String
  let tint: Color

  private var coverage: FileAssociationStatus.Coverage {
    kind == .pdf ? model.pdfFileAssociationCoverage : model.audioFileAssociationCoverage
  }

  private var canRestore: Bool {
    kind == .pdf ? model.pdfFileAssociationCanRestore : model.audioFileAssociationCanRestore
  }

  private var status: (String, Color) {
    guard model.fileAssociationChangesAllowed else { return ("仅正式安装版可设置", muted) }
    switch coverage {
    case .all: return ("已设为默认打开", teal)
    case .partial: return ("部分已关联", amber)
    case .none: return ("未设为默认", muted)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      HStack(alignment: .top, spacing: 12) {
        IconBadge(systemImage: systemImage, tint: tint, size: 42, iconSize: 18)
        VStack(alignment: .leading, spacing: 5) {
          HStack(spacing: 8) {
            Text(title)
              .font(.headline)
              .foregroundStyle(ink)
            StatusPill(text: status.0, color: status.1)
          }
          Text(detail)
            .font(.callout)
            .foregroundStyle(muted)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 4)
      }

      HStack(spacing: 10) {
        Button {
          model.setAsDefaultApplication(for: kind)
        } label: {
          if model.fileAssociationBusyKind == kind {
            ProgressView().controlSize(.small)
          } else {
            Label(coverage == .all ? "已设为默认" : "设为默认打开", systemImage: "checkmark.circle")
          }
        }
        .buttonStyle(.borderedProminent)
        .tint(AppVisualStyle.emphasizedSelection)
        .disabled(
          !model.fileAssociationChangesAllowed || coverage == .all
            || model.fileAssociationBusyKind != nil)

        if canRestore {
          Button("恢复原打开方式") {
            model.restorePreviousDefaultApplication(for: kind)
          }
          .buttonStyle(.bordered)
          .disabled(model.fileAssociationBusyKind != nil)
        }

        Spacer()
      }

      if model.fileAssociationFeedbackKind == kind,
        !model.fileAssociationFeedbackText.isEmpty
      {
        Text(model.fileAssociationFeedbackText)
          .font(.caption)
          .foregroundStyle(muted)
          .fixedSize(horizontal: false, vertical: true)
      } else if !model.fileAssociationChangesAllowed {
        Text("请从正式安装的应用中更改访达文件打开方式。")
          .font(.caption)
          .foregroundStyle(muted)
      } else {
        Text("macOS 如果询问，确认一次即可；安装本身不会自动更改默认应用。")
          .font(.caption)
          .foregroundStyle(muted)
      }
    }
    .padding(15)
    .background(
      Color(nsColor: .controlBackgroundColor).opacity(0.66),
      in: RoundedRectangle(cornerRadius: 16, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
    )
    .onAppear { model.refreshFileAssociationStatus() }
  }
}

struct NetworkProbeApplicationDetailView: View {
  @EnvironmentObject private var model: AppModel
  let openWindow: () -> Void

  var body: some View {
    Form {
      Section {
        Text("一个球测下载和上传，一个球测 Codex 四轮连通与响应。")
          .font(.body)
          .foregroundStyle(.secondary)

        ApplicationWindowOpenButton(productName: "测试网速", action: openWindow)
      } header: {
        Text("测速")
      }

      Section("快捷键") {
        LabeledContent("当前快捷键", value: model.codexNetworkProbeHotkeySummary)
        Button {
          model.openShortcutManager(action: .showCodexNetworkProbe)
        } label: {
          Label("修改快捷键", systemImage: "keyboard")
        }
      }
    }
    .formStyle(.grouped)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct PermanentUninstallApplicationDetailView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        VStack(alignment: .leading, spacing: 7) {
          Text("卸载前，先看清删除范围")
            .font(.title3.weight(.semibold))
            .foregroundStyle(ink)
          Text("先选择 App，再扫描可识别的关联文件；确认界面会列出具体路径，只有最终确认后才会执行。")
            .font(.body)
            .foregroundStyle(muted)
            .fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: 10) {
          Label("不会因为点了入口就立即删除", systemImage: "checkmark.shield.fill")
          Label("系统 App 和受保护目标会被拦截", systemImage: "checkmark.shield.fill")
          Label("这是本机维护功能，不依赖 Pro 或联网状态", systemImage: "checkmark.shield.fill")
        }
        .font(.callout)
        .foregroundStyle(ink.opacity(0.86))
        .symbolRenderingMode(.hierarchical)

        Button(role: .destructive) {
          model.chooseAppForPermanentUninstall()
        } label: {
          Label("选择要卸载的 App…", systemImage: "trash.slash")
        }
        .buttonStyle(.bordered)
        .tint(ruby)
        .controlSize(.large)
        .help("先扫描可安全识别的范围，再确认是否永久删除")
        .accessibilityLabel("选择要彻底卸载的 App")

        Text("建议先确认重要数据已有备份。确认界面会列出主程序和专属数据的具体路径。")
          .font(.caption)
          .foregroundStyle(muted)
      }
      .padding(22)
      .frame(maxWidth: 680, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct LauncherPluginDetailView: View {
  @EnvironmentObject private var model: AppModel

  private var needsAttention: Bool {
    model.launcherPluginEnabled && model.launcherHotkeySummary != "Caps + Space"
  }

  var body: some View {
    Form {
      Section {
        Toggle(
          "启动器",
          isOn: Binding(
            get: { model.launcherPluginEnabled },
            set: { model.setLauncherPluginEnabled($0) })
        )
        .toggleStyle(.switch)
      } header: {
        Label("启动器", systemImage: "magnifyingglass")
      } footer: {
        Text("快速打开 App、计算和网页。关闭后固定项目、顺序、显示偏好和索引仍保留。")
      }

      Section("显示偏好") {
        Picker(
          "显示方式",
          selection: Binding(
            get: { model.launcherDisplayMode },
            set: { model.setLauncherDisplayMode($0) })
        ) {
          ForEach(LauncherDisplayMode.allCases) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .pickerStyle(.segmented)

        Toggle(
          "显示名称",
          isOn: Binding(
            get: { model.launcherShowsPinnedNames },
            set: { model.setLauncherShowsPinnedNames($0) })
        )
        .accessibilityLabel("显示固定图标名称")
        .accessibilityHint("只影响固定区视觉；工具提示和 VoiceOver 始终保留名称。")
      }

      Section("固定项目") {
        LabeledContent("已固定", value: "\(model.launcherPinnedRecords.count)/8")
        Text("固定、排序和移除仍在启动器对象菜单中完成。对任意 App 右键，还可以直接设置它的快捷键。")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if needsAttention {
        Section("需要处理") {
          Label("Caps + Space 当前有受保护的占用。", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(amber)
          HStack {
            Button("保留原设置") { model.keepCurrentCapsSpaceBehavior() }
            Spacer()
            Button("改为启动器") { model.adoptCapsSpaceForLauncher() }
              .buttonStyle(.borderedProminent)
              .tint(AppVisualStyle.emphasizedSelection)
          }
        }
      }

      Section {
        Button {
          model.showLauncher()
        } label: {
          Label(
            model.launcherPluginEnabled ? "打开启动器" : "预览启动器", systemImage: "arrow.up.right.square")
        }
      }
    }
    .formStyle(.grouped)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
