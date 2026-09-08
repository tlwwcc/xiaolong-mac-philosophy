import AppKit
import Combine
import SwiftUI
@preconcurrency import Translation

@MainActor
final class YoumuControlWindowController: NSObject, NSWindowDelegate {
  typealias CommandHandler = @MainActor (String) -> Void
  typealias ShortcutManagerHandler = @MainActor () -> Void

  private var window: NSWindow?
  private var shortcutManagerHandler: ShortcutManagerHandler?

  func show(
    commandHandler _: @escaping CommandHandler,
    shortcutManagerHandler: ShortcutManagerHandler?
  ) {
    self.shortcutManagerHandler = shortcutManagerHandler

    if let window {
      NSApp.activate(ignoringOtherApps: true)
      window.deminiaturize(nil)
      window.makeKeyAndOrderFront(nil)
      window.orderFrontRegardless()
      return
    }

    let rootView = YoumuControlView(
      canOpenShortcutManager: shortcutManagerHandler != nil,
      openShortcutManager: { [weak self] in
        self?.openShortcutManager()
      })
    let hostingView = NSHostingView(rootView: rootView)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 780, height: 620),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "游目"
    window.contentView = hostingView
    window.contentMinSize = NSSize(width: 680, height: 520)
    window.isReleasedWhenClosed = false
    window.tabbingMode = .disallowed
    window.collectionBehavior.insert(.moveToActiveSpace)
    window.delegate = self
    window.center()

    self.window = window
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }

  private func openShortcutManager() {
    window?.orderOut(nil)
    DispatchQueue.main.async { [weak self] in
      self?.shortcutManagerHandler?()
    }
  }
}

private struct YoumuControlView: View {
  private enum Pane: String, CaseIterable, Identifiable {
    case general
    case translation
    case shortcuts

    var id: String { rawValue }

    var title: String {
      switch self {
      case .general: return "通用"
      case .translation: return "翻译引擎"
      case .shortcuts: return "快捷键"
      }
    }

    var symbol: String {
      switch self {
      case .general: return "slider.horizontal.3"
      case .translation: return "character.book.closed"
      case .shortcuts: return "command"
      }
    }
  }

  private static let customPresetName = "自定义"

  @State private var selectedPane: Pane = .general
  @State private var settings: AppSettings
  @State private var draftConfig: TranslationConfig
  @State private var selectedPreset: String
  @State private var onlineStatus: OnlineConfigurationStatus = .idle
  @State private var showAdvancedTranslationSettings = false

  let canOpenShortcutManager: Bool
  let openShortcutManager: @MainActor () -> Void

  init(
    canOpenShortcutManager: Bool,
    openShortcutManager: @escaping @MainActor () -> Void
  ) {
    let settings = AppSettings.load()
    _settings = State(initialValue: settings)
    _draftConfig = State(initialValue: settings.translationConfig)
    _selectedPreset = State(
      initialValue: Self.matchingPreset(for: settings.translationConfig)
        ?? Self.customPresetName)
    self.canOpenShortcutManager = canOpenShortcutManager
    self.openShortcutManager = openShortcutManager
  }

  var body: some View {
    HStack(spacing: 0) {
      sidebar

      Divider()

      VStack(spacing: 0) {
        detailHeader
        Divider()
        detailPane
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(minWidth: 680, minHeight: 520)
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("游目")
        .font(.headline)
        .padding(.horizontal, 10)
        .padding(.bottom, 4)

      ForEach(Pane.allCases) { pane in
        Button {
          selectedPane = pane
        } label: {
          HStack(spacing: 10) {
            Image(systemName: pane.symbol)
              .frame(width: 18)
            Text(pane.title)
            Spacer(minLength: 0)
          }
          .font(.body.weight(selectedPane == pane ? .semibold : .regular))
          .foregroundStyle(selectedPane == pane ? Color.accentColor : Color.primary)
          .padding(.horizontal, 10)
          .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
          .background(
            selectedPane == pane ? Color.accentColor.opacity(0.13) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pane.title)
        .accessibilityHint("切换到游目\(pane.title)设置")
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 14)
    .frame(width: 190, alignment: .topLeading)
    .frame(maxHeight: .infinity, alignment: .topLeading)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var detailHeader: some View {
    HStack(spacing: 9) {
      Image(systemName: selectedPane.symbol)
        .foregroundStyle(Color.accentColor)
      Text(selectedPane.title)
        .font(.headline)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 18)
    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
    .background(Color(nsColor: .controlBackgroundColor))
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private var detailPane: some View {
    switch selectedPane {
    case .general:
      generalPane
    case .translation:
      translationPane
    case .shortcuts:
      YoumuShortcutOwnershipView(
        canOpenShortcutManager: canOpenShortcutManager,
        openShortcutManager: openShortcutManager)
    }
  }

  private var generalPane: some View {
    Form {
      Section("目标语言") {
        Picker("翻译为", selection: $settings.targetLanguage) {
          ForEach(Language.allCases.filter { $0 != .auto }, id: \.self) { language in
            Text(language.displayName).tag(language)
          }
        }
        .onChange(of: settings.targetLanguage) { _ in
          persistSettings()
        }
      }

      Section("截图交互") {
        Toggle(isOn: $settings.quickSnapshotRequiresConfirmation) {
          VStack(alignment: .leading, spacing: 3) {
            Text("框选后等待确认")
            Text(
              settings.quickSnapshotRequiresConfirmation
                ? "松手后按空格复制。" : "默认关闭；Caps + 1 松手立即复制。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }
        .onChange(of: settings.quickSnapshotRequiresConfirmation) { _ in
          persistSettings()
        }

        Toggle(isOn: $settings.ocrCopyRequiresConfirmation) {
          VStack(alignment: .leading, spacing: 3) {
            Text("OCR 复制前等待确认")
            Text(
              settings.ocrCopyRequiresConfirmation
                ? "松手后按空格识别并复制。" : "关闭后，松手立即识别并复制。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }
        .onChange(of: settings.ocrCopyRequiresConfirmation) { _ in
          persistSettings()
        }
      }

      Section("朗读") {
        Picker("朗读方式", selection: $settings.speechBackend) {
          ForEach(SpeechBackendPreference.allCases, id: \.self) { backend in
            Text(backend.displayName).tag(backend)
          }
        }
        .onChange(of: settings.speechBackend) { _ in
          SpeechService.shared.stop()
          persistSettings()
        }

        Text(settings.speechBackend.detail)
          .font(.caption)
          .foregroundStyle(.secondary)

        Picker("中文声音", selection: $settings.speechVoice) {
          ForEach(EdgeSpeechVoice.allCases, id: \.self) { voice in
            Text(voice.displayName).tag(voice)
          }
        }
        .disabled(settings.speechBackend == .macLocal)
        .onChange(of: settings.speechVoice) { _ in
          SpeechService.shared.stop()
          persistSettings()
        }

        HStack {
          Button {
            SpeechService.shared.toggle(
              text: "游目，看见哪里，就从哪里开始理解。",
              language: "zh-CN")
          } label: {
            Label("试听", systemImage: "speaker.wave.2")
          }

          if settings.speechBackend != .macLocal {
            Button("重新选择联网权限") {
              OnlineDataConsentManager.shared.reset(.edgeSpeech)
            }
          }
        }
      }
    }
    .formStyle(.grouped)
  }

  private var translationPane: some View {
    Form {
      Section("翻译方式") {
        Picker("后端", selection: $settings.translationBackend) {
          ForEach(TranslationBackendPreference.allCases, id: \.self) { backend in
            Text(backend.displayName).tag(backend)
          }
        }
        .onChange(of: settings.translationBackend) { _ in
          persistSettings()
        }

        Label(
          settings.translationBackend.detail,
          systemImage: settings.translationBackend == .appleLocal
            ? "lock.shield" : "network"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section("Apple 本机翻译") {
        if #available(macOS 15.0, *) {
          AppleLocalModelControlRow()
        } else {
          Label("需要 macOS 15 或更新版本", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
        }
      }

      Section("在线服务") {
        Picker("服务", selection: $selectedPreset) {
          ForEach(TranslationConfig.presetOrder + [Self.customPresetName], id: \.self) {
            Text($0).tag($0)
          }
        }
        .onChange(of: selectedPreset) { presetName in
          applyPreset(named: presetName)
        }

        SecureField("API Key", text: $draftConfig.apiKey)

        if let message = settings.credentialErrorMessage
          ?? KeychainCredentialStore.shared.lastErrorMessage
        {
          Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
        } else {
          Label("API Key 只保存在 macOS 钥匙串。", systemImage: "key.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        DisclosureGroup("高级设置", isExpanded: $showAdvancedTranslationSettings) {
          TextField("API Endpoint", text: $draftConfig.apiEndpoint)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
          TextField("Model", text: $draftConfig.modelName)
            .textFieldStyle(.roundedBorder)
          VStack(alignment: .leading, spacing: 5) {
            Text("系统提示词")
              .font(.caption)
              .foregroundStyle(.secondary)
            TextEditor(text: $draftConfig.systemPrompt)
              .font(.system(.body, design: .monospaced))
              .frame(minHeight: 110)
          }
        }

        HStack(spacing: 10) {
          Button("测试连接") {
            testOnlineConnection()
          }
          .disabled(onlineStatus == .testing)

          Button("保存在线引擎") {
            saveOnlineConfiguration()
          }
          .buttonStyle(.borderedProminent)

          Button("重新选择联网权限") {
            OnlineDataConsentManager.shared.reset(.translation)
          }
        }

        onlineStatusView
      }
    }
    .formStyle(.grouped)
  }

  @ViewBuilder
  private var onlineStatusView: some View {
    switch onlineStatus {
    case .idle:
      EmptyView()
    case .testing:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("正在测试…")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    case .success(let message):
      Label(message, systemImage: "checkmark.circle.fill")
        .font(.caption)
        .foregroundStyle(.green)
    case .failure(let message):
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .font(.caption)
        .foregroundStyle(.red)
    }
  }

  private func persistSettings() {
    if !settings.save() {
      onlineStatus = .failure("设置未能保存。")
    }
  }

  private func applyPreset(named name: String) {
    guard name != Self.customPresetName,
      let preset = TranslationConfig.presets[name]
    else { return }
    draftConfig.apiEndpoint = preset.endpoint
    draftConfig.modelName = preset.model
    draftConfig.apiKey = settings.presetKeys[name] ?? ""
    onlineStatus = .idle
  }

  private func saveOnlineConfiguration() {
    guard (try? LLMTranslator.validatedEndpoint(draftConfig.apiEndpoint)) != nil else {
      onlineStatus = .failure("API 地址必须使用有效的 HTTPS。")
      return
    }
    guard !draftConfig.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      onlineStatus = .failure("请填写模型名称。")
      return
    }

    settings.translationConfig = draftConfig
    if selectedPreset != Self.customPresetName {
      if draftConfig.apiKey.isEmpty {
        settings.presetKeys.removeValue(forKey: selectedPreset)
      } else {
        settings.presetKeys[selectedPreset] = draftConfig.apiKey
      }
    }
    let saved = settings.save()
    settings.credentialErrorMessage = KeychainCredentialStore.shared.lastErrorMessage
    onlineStatus =
      saved
      ? .success("已保存；API Key 仅在钥匙串中。")
      : .failure(settings.credentialErrorMessage ?? "在线引擎未能保存。")
  }

  private func testOnlineConnection() {
    guard !draftConfig.apiKey.isEmpty else {
      onlineStatus = .failure("请先填写 API Key。")
      return
    }
    guard let endpoint = try? LLMTranslator.validatedEndpoint(draftConfig.apiEndpoint) else {
      onlineStatus = .failure("API 地址必须使用有效的 HTTPS。")
      return
    }

    onlineStatus = .testing
    let config = draftConfig
    Task { @MainActor in
      let startedAt = Date()
      do {
        guard OnlineDataConsentManager.shared.request(.translation, endpoint: endpoint) else {
          throw TranslationError.onlineDataPermissionDenied
        }
        _ = try await LLMTranslator(config: config).translate(
          text: "你好", targetLanguage: "English")
        let elapsed = String(format: "%.1f 秒", Date().timeIntervalSince(startedAt))
        onlineStatus = .success("连接正常 · \(elapsed)")
      } catch {
        onlineStatus = .failure(error.localizedDescription)
      }
    }
  }

  private static func matchingPreset(for config: TranslationConfig) -> String? {
    TranslationConfig.presetOrder.first { name in
      guard let preset = TranslationConfig.presets[name] else { return false }
      return preset.endpoint == config.apiEndpoint && preset.model == config.modelName
    }
  }
}

private enum OnlineConfigurationStatus: Equatable {
  case idle
  case testing
  case success(String)
  case failure(String)
}

private struct YoumuShortcutOwnershipView: View {
  let canOpenShortcutManager: Bool
  let openShortcutManager: @MainActor () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("快捷键只保存一份", systemImage: "link.circle.fill")
        .font(.title3.weight(.semibold))
      Text("游目不再单独注册或保存全局快捷键。请在 Mac 哲学的应用中心或功能快捷键页修改，两处会始终使用同一份配置。")
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button {
        openShortcutManager()
      } label: {
        Label("管理快捷键", systemImage: "arrow.up.right.square")
      }
      .buttonStyle(.borderedProminent)
      .disabled(!canOpenShortcutManager)

      if !canOpenShortcutManager {
        Text("当前宿主未提供快捷键管理入口。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

@available(macOS 15.0, *)
private struct AppleLocalModelControlRow: View {
  @State private var status: AppleLocalModelStatus = .checking
  @State private var configuration: TranslationSession.Configuration?
  @State private var downloadRequested = false
  @State private var failureDetail: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Image(systemName: status.systemImage)
          .foregroundStyle(statusColor)
          .frame(width: 18)
        VStack(alignment: .leading, spacing: 3) {
          Text(AppleLocalModelCatalog.displayName)
            .font(.body.weight(.medium))
          Text(status.displayName)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if status == .checking || status == .downloading {
          ProgressView().controlSize(.small)
        } else if status == .downloadable || status == .failed {
          Button("下载到此 Mac") {
            requestDownload()
          }
        } else {
          Button("重新检查") {
            refreshStatus()
          }
        }
      }

      Text(AppleLocalModelCatalog.privacyDetail)
        .font(.caption)
        .foregroundStyle(.secondary)

      if let failureDetail {
        Text(failureDetail)
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
    .translationTask(configuration) { session in
      guard downloadRequested else { return }
      downloadRequested = false
      do {
        try await session.prepareTranslation()
        await updateStatus()
      } catch {
        failureDetail = error.localizedDescription
        status = .failed
      }
    }
    .onAppear { refreshStatus() }
  }

  private var statusColor: Color {
    switch status {
    case .installed: return .green
    case .downloadable: return .accentColor
    case .checking, .downloading: return .secondary
    case .unsupported, .systemUnavailable, .failed: return .orange
    }
  }

  private func requestDownload() {
    failureDetail = nil
    status = .downloading
    downloadRequested = true
    let source = Locale.Language(identifier: AppleLocalModelCatalog.sourceIdentifier)
    let target = Locale.Language(identifier: AppleLocalModelCatalog.targetIdentifier)
    var next = TranslationSession.Configuration(source: source, target: target)
    if next == configuration { next.invalidate() }
    configuration = next
  }

  private func refreshStatus() {
    status = .checking
    failureDetail = nil
    Task { await updateStatus() }
  }

  @MainActor
  private func updateStatus() async {
    status = await AppleLocalModelAvailability.status()
  }
}
