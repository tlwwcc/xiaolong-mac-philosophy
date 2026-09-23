import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SoftwareShortcutRequest: Identifiable {
  let id = UUID()
  let itemID: String?
  let draft: ShortcutItem
}

/// The editor owns a draft. Selecting an app or recording a key never mutates a saved rule.
struct SoftwareShortcutEditorSheet: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var draft: ShortcutItem
  @State private var itemID: String?
  @State private var query = ""
  @State private var choosingApp: Bool
  @State private var saveError: String?
  @State private var saved = false
  @State private var reusedExisting = false

  init(request: SoftwareShortcutRequest) {
    var draft = request.draft
    if draft.action != .openApp
      || (draft.target.hasPrefix("/") && !draft.target.lowercased().hasSuffix(".app"))
    {
      draft.action = .openApp
      draft.target = ""
      draft.name = ""
    }
    _draft = State(initialValue: draft)
    _itemID = State(initialValue: request.itemID)
    _choosingApp = State(initialValue: draft.target.isEmpty)
  }

  private var recording: Bool { model.isDraftShortcutRecording }
  private var hasKey: Bool { draft.trigger != nil || !draft.key.isEmpty }
  private var issue: ShortcutIssue? {
    guard !draft.target.isEmpty, hasKey else { return nil }
    return model.shortcutIssue(for: draft)
  }
  private var canSave: Bool {
    !draft.target.isEmpty && hasKey && !recording && issue?.kind.isBlocking != true
  }
  private var choices: [AppChoice] {
    var seen = Set<String>()
    let running = model.runningAppChoices()
      .filter { query.isEmpty || $0.name.localizedStandardContains(query) }
    return (running + model.installedAppChoices(matching: query, limit: 200))
      .filter { seen.insert($0.target.lowercased()).inserted }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(saved ? "软件快捷键已保存" : "设置软件快捷键")
        .font(.title2.bold())
      if saved {
        Label("\(draft.name)  ·  \(draft.displayHotkey)", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
        Text(draft.enabled ? "现在可以按这组快捷键打开软件；再按一下隐藏。" : "已保存为停用状态，可在列表中启用。")
        if model.isPaused || !model.advancedListeningAuthorized {
          Text(model.isPaused ? "后台当前已暂停，请恢复运行后使用。" : "请先在设置中完成快捷键所需授权。")
            .font(.callout).foregroundStyle(.secondary)
        }
        Button("完成") { dismiss() }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            GroupBox {
              VStack(alignment: .leading, spacing: 10) {
                Text("1 · 选择软件").font(.headline)
                if !draft.target.isEmpty {
                  HStack {
                    Label(draft.name, systemImage: "app.fill").font(.body.bold())
                    Spacer()
                    Button(choosingApp ? "收起选择" : "更换软件…") {
                      model.cancelDraftShortcutRecording()
                      choosingApp.toggle()
                    }
                  }
                }
                if reusedExisting {
                  Text("已找到这个软件的快捷键，保存会更新原来的设置。")
                    .font(.caption).foregroundStyle(.secondary)
                }
                if choosingApp {
                  TextField("搜索已安装的软件", text: $query)
                    .textFieldStyle(.roundedBorder)
                  if choices.isEmpty {
                    Text(model.isLauncherScanning ? "正在查找软件…" : "没有找到，可从“应用程序”选择。")
                      .foregroundStyle(.secondary)
                  } else {
                    ScrollView {
                      LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(choices) { choice in
                          Button {
                            select(choice)
                          } label: {
                            HStack {
                              Image(systemName: "app")
                              Text(choice.name)
                              Spacer()
                              Text(choice.source).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                          }
                          .buttonStyle(.plain)
                          .accessibilityLabel("选择 \(choice.name)")
                        }
                      }
                    }
                    .frame(height: 140)
                  }
                  Button("从“应用程序”选择…", action: browseApp)
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(6)
            }

            GroupBox {
              VStack(alignment: .leading, spacing: 10) {
                Text("2 · 按下快捷键").font(.headline)
                Button {
                  model.toggleDraftShortcutRecording { value in
                    draft.trigger = value.trigger
                    if value.trigger == nil {
                      draft.key = value.key
                      draft.modifiers = value.modifiers
                    }
                  }
                } label: {
                  Label(
                    recording ? "现在按下你想用的组合键…" : (hasKey ? draft.displayHotkey : "点这里，开始录制"),
                    systemImage: recording ? "record.circle" : "keyboard"
                  )
                  .frame(maxWidth: .infinity, minHeight: 38)
                }
                .buttonStyle(.bordered)
                .disabled(draft.target.isEmpty)
                .background(KeyCaptureView(active: recording) { model.applyRecorded($0) })
                Text(recording ? "按 Esc 或再点一次可取消录制。" : "例如按住 Caps，再按一个字母。也支持连续按两次同一侧的 ⌃、⌥、⇧ 或 ⌘。")
                  .font(.caption).foregroundStyle(.secondary)
                if let issue {
                  Label(
                    "\(issue.kind.label)：\(issue.suggestion)",
                    systemImage: "exclamationmark.triangle"
                  )
                  .font(.callout)
                  .foregroundStyle(issue.kind.isBlocking ? Color.red : Color.secondary)
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(6)
            }

            Toggle("保存后启用", isOn: $draft.enabled)
            if !draft.target.isEmpty, hasKey {
              Text("\(draft.displayHotkey) → \(draft.name)；再按一下隐藏。")
                .font(.callout).foregroundStyle(.secondary)
            } else {
              Text(draft.target.isEmpty ? "先选择一个软件。" : "还差一步：点击录制，再按下快捷键。")
                .font(.callout).foregroundStyle(.secondary)
            }
            if let saveError {
              Label(saveError, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            }
          }
        }
        Divider()
        HStack {
          Button("取消") { dismiss() }
          Spacer()
          Button("保存快捷键", action: save)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave)
        }
      }
    }
    .padding(24)
    .frame(width: 540, height: saved ? 220 : 640)
    .onExitCommand {
      if recording { model.cancelDraftShortcutRecording() } else { dismiss() }
    }
    .onDisappear { model.cancelDraftShortcutRecording() }
    .onChange(of: draft) { _ in saveError = nil }
  }

  private func select(_ choice: AppChoice) {
    model.cancelDraftShortcutRecording()
    if itemID == nil, let existing = model.existingSoftwareShortcut(for: choice.target) {
      draft = existing
      itemID = existing.id
      reusedExisting = true
    } else {
      reusedExisting = false
      draft.action = .openApp
      draft.name = "打开 \(choice.name)"
      draft.target = choice.target
      draft.scope = "App"
      draft.note = "按一下打开或置前，再按一下隐藏。"
    }
    choosingApp = false
  }

  private func browseApp() {
    model.cancelDraftShortcutRecording()
    let panel = NSOpenPanel()
    panel.title = "选择要设置快捷键的软件"
    panel.prompt = "选择软件"
    panel.allowedContentTypes = [.applicationBundle]
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let target = Bundle(url: url)?.bundleIdentifier.map { "bundle:\($0)" } ?? url.path
    select(
      AppChoice(
        id: target, name: url.deletingPathExtension().lastPathComponent, target: target,
        source: "应用程序"))
  }

  private func save() {
    guard canSave else { return }
    let success =
      itemID.map { model.updateShortcut(id: $0, draft: draft) }
      ?? model.createShortcut(from: draft)
    if success {
      model.shortcutGuideRequestedSearchText = draft.name
      model.shortcutGuideFocusRequest &+= 1
      saved = true
    } else {
      saveError = model.statusMessage
    }
  }
}
