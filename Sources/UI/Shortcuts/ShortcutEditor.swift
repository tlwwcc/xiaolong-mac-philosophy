import AppKit
import SwiftUI

struct ShortcutEditorSheet: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  let presentation: ShortcutEditorPresentation
  @State private var draft: ShortcutItem
  @State private var editingOwner = UUID()
  @State private var recordingOwnerID: UUID?
  @State private var showDeleteConfirmation = false
  @State private var saveErrorMessage: String?

  init(presentation: ShortcutEditorPresentation) {
    self.presentation = presentation
    _draft = State(initialValue: presentation.draft)
  }

  private var canSave: Bool {
    !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && (draft.trigger != nil
        || !draft.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }

  private var isCapturingHotkey: Bool {
    recordingOwnerID != nil && model.isDraftShortcutRecording
      && model.shortcutRecordingSessionID == recordingOwnerID
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        IconBadge(systemImage: "command", tint: accent, size: 42, iconSize: 17)
        VStack(alignment: .leading, spacing: 4) {
          Text(presentation.itemID == nil ? "新增快捷键" : "编辑快捷键")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(ink)
          Text(presentation.itemID == nil ? "保存后才会加入列表。" : draft.name)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(muted)
            .lineLimit(2)
        }
        Spacer()
      }
      .padding(.horizontal, 22)
      .padding(.vertical, 18)
      .background(.bar)
      .overlay(Rectangle().fill(hairline).frame(height: 1), alignment: .bottom)

      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          ShortcutFormTextField(title: "名称", placeholder: "功能名称", text: $draft.name)

          VStack(alignment: .leading, spacing: 6) {
            Text("触发方式")
              .font(.system(size: 11, weight: .bold))
              .foregroundStyle(muted)
            Button {
              beginOrCancelRecording()
            } label: {
              HStack(spacing: 8) {
                Image(systemName: isCapturingHotkey ? "record.circle.fill" : "keyboard")
                Text(
                  isCapturingHotkey
                    ? "按组合键，或连按同一个实体修饰键两次"
                    : draft.displayHotkey
                )
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
              }
              .foregroundStyle(isCapturingHotkey ? accent : ink)
              .padding(.horizontal, 10)
              .frame(height: 38)
              .background(
                AppVisualStyle.surface.opacity(0.78), in: RoundedRectangle(cornerRadius: 8)
              )
              .overlay(
                RoundedRectangle(cornerRadius: 8)
                  .stroke(isCapturingHotkey ? accent.opacity(0.55) : glassLine, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .background(
              KeyCaptureView(ownerID: isCapturingHotkey ? recordingOwnerID : nil) {
                event, ownerID in
                model.applyRecorded(event, ownerID: ownerID)
              })
            Text("支持左／右 Control、Shift、Option 和 Command。再点一下或按 Esc 取消。")
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(muted)
          }

          HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
              Text("动作")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(muted)
              Picker("动作", selection: $draft.action) {
                ForEach(
                  ShortcutAction.allCases.filter {
                    ($0 != .showPanel && $0 != .showLauncher) || $0 == draft.action
                  }
                ) { action in
                  Text(action.title).tag(action)
                }
              }
              .labelsHidden()
              .pickerStyle(.menu)
              .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 6) {
              Text("启用")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(muted)
              Toggle("保存后启用", isOn: $draft.enabled)
                .toggleStyle(.switch)
            }
          }

          ShortcutFormTextField(
            title: "执行内容",
            placeholder: targetPlaceholder,
            text: $draft.target)

          HStack(spacing: 10) {
            if draft.action == .openApp {
              Menu {
                ForEach(model.runningAppChoices().prefix(12)) { choice in
                  Button(choice.name) {
                    applyAppChoice(choice)
                  }
                }
                Divider()
                ForEach(model.installedAppChoices(limit: 16)) { choice in
                  Button(choice.name) {
                    applyAppChoice(choice)
                  }
                }
              } label: {
                Label("选择 App", systemImage: "app.badge")
              }
              .menuStyle(.borderlessButton)

              Button {
                browseTarget()
              } label: {
                Label("文件或文件夹", systemImage: "folder")
              }
              .buttonStyle(GlassLabelButtonStyle(tint: muted))
            }

            Menu {
              Menu("窗口管理") {
                ForEach(WindowPreset.allCases) { preset in
                  Button(preset.title) {
                    draft.action = .windowPreset
                    draft.target = preset.rawValue
                    draft.name = preset.title
                    draft.scope = "窗口"
                    draft.note = "窗口管理"
                  }
                }
              }
              Button("打开 Emoji 与符号") {
                applyPreset(
                  action: .sendShortcut,
                  target: "⌃ ⌘ Space",
                  name: "打开 Emoji 与符号",
                  scope: "常用脚本",
                  note: "打开系统 Emoji 与符号面板。")
              }
              Button("输入井号 #") {
                applyPreset(
                  action: .insertText,
                  target: "#",
                  name: "输入井号 #",
                  scope: "常用脚本",
                  note: "在当前光标处输入 #。")
              }
              Button("切换麦克风") {
                applyPreset(
                  action: .runShell,
                  target: "plugin:mic-toggle.sh",
                  name: "切换麦克风",
                  scope: "常用脚本",
                  note: "Studio Display / DJI 麦克风切换。")
              }
            } label: {
              Label("常用动作", systemImage: "slider.horizontal.3")
            }
            .menuStyle(.borderlessButton)
          }

          ShortcutFormTextField(title: "分类", placeholder: "例如 窗口 / 系统", text: $draft.scope)

          VStack(alignment: .leading, spacing: 6) {
            Text("说明")
              .font(.system(size: 11, weight: .bold))
              .foregroundStyle(muted)
            TextEditor(text: $draft.note)
              .font(.system(size: 13, weight: .medium))
              .frame(minHeight: 82)
              .scrollContentBackground(.hidden)
              .padding(8)
              .background(
                AppVisualStyle.surface.opacity(0.78), in: RoundedRectangle(cornerRadius: 8)
              )
              .overlay(RoundedRectangle(cornerRadius: 8).stroke(glassLine, lineWidth: 1))
          }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
      }

      if let saveErrorMessage {
        HStack(spacing: 8) {
          Image(systemName: "exclamationmark.circle.fill")
          Text(saveErrorMessage)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(ruby)
        .padding(.horizontal, 22)
        .padding(.vertical, 9)
        .background(ruby.opacity(0.07))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("保存失败，\(saveErrorMessage)")
      }

      HStack(spacing: 10) {
        if let itemID = presentation.itemID {
          Button(role: .destructive) {
            showDeleteConfirmation = true
          } label: {
            Label("删除快捷键...", systemImage: "trash")
          }
          .buttonStyle(GlassLabelButtonStyle(tint: ruby))
          .disabled(!model.canDeleteShortcut(id: itemID))
          .help(model.shortcutDeletionHelp(id: itemID))
        }

        Spacer()

        Button("取消") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        .buttonStyle(GlassLabelButtonStyle(tint: muted))

        Button("保存") {
          saveErrorMessage = nil
          let saved: Bool
          if let itemID = presentation.itemID {
            saved = model.updateShortcut(id: itemID, draft: draft, editorOwner: editingOwner)
          } else {
            saved = model.createShortcut(from: draft, editorOwner: editingOwner)
          }
          if saved {
            dismiss()
          } else {
            saveErrorMessage = model.statusMessage
          }
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(GlassLabelButtonStyle(tint: accent, prominent: true))
        .disabled(!canSave || isCapturingHotkey)
      }
      .padding(.horizontal, 22)
      .padding(.vertical, 14)
      .background(.bar)
      .overlay(Rectangle().fill(hairline).frame(height: 1), alignment: .top)
    }
    .frame(width: 580, height: 650)
    .background(AppBackdrop())
    .onExitCommand {
      if isCapturingHotkey {
        cancelOwnedRecording()
      } else {
        dismiss()
      }
    }
    .onAppear {
      model.beginShortcutEditing(owner: editingOwner)
    }
    .onDisappear {
      cancelOwnedRecording()
      model.endShortcutEditing(owner: editingOwner)
    }
    .onChange(of: draft) { _ in
      saveErrorMessage = nil
    }
    .alert("删除这条快捷键？", isPresented: $showDeleteConfirmation) {
      Button("取消", role: .cancel) {}
      Button("删除", role: .destructive) {
        guard let itemID = presentation.itemID else { return }
        model.deleteShortcut(id: itemID)
        dismiss()
      }
    } message: {
      Text("只会移除这条按键绑定，不会删除对应功能；默认快捷键之后仍可恢复。")
    }
  }

  private var targetPlaceholder: String {
    switch draft.action {
    case .openApp: return "App 标识、App 或文件路径"
    case .openURL: return "https://"
    case .runShell: return "Shell 或 plugin:脚本名"
    case .windowPreset: return "窗口动作"
    case .sendShortcut: return "要发送的组合键"
    case .insertText: return "要输入的文字"
    default: return "此动作可留空"
    }
  }

  private func beginOrCancelRecording() {
    if isCapturingHotkey {
      cancelOwnedRecording()
      return
    }
    // The user explicitly starts recording here; any other draft yields to this one.
    if model.isDraftShortcutRecording { model.cancelDraftShortcutRecording() }
    model.toggleDraftShortcutRecording { value in applyRecordedValue(value) }
    recordingOwnerID = model.shortcutRecordingSessionID
  }

  private func cancelOwnedRecording() {
    guard let ownerID = recordingOwnerID else { return }
    model.cancelDraftShortcutRecording(ownerID: ownerID)
    recordingOwnerID = nil
  }

  private func applyRecordedValue(_ value: ShortcutTriggerRecordingValue) {
    if let trigger = value.trigger {
      draft.trigger = trigger
      return
    }
    draft.key = value.key
    draft.modifiers = value.modifiers
    draft.trigger = nil
  }

  private func applyAppChoice(_ choice: AppChoice) {
    draft.action = .openApp
    draft.target = choice.target
    draft.name = "打开 \(choice.name)"
    draft.scope = "App"
    draft.note = "\(choice.source) App：打开 / 置前 / 再按隐藏。"
  }

  private func browseTarget() {
    let panel = NSOpenPanel()
    panel.title = "选择 App、文件或文件夹"
    panel.prompt = "选择"
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let name = url.deletingPathExtension().lastPathComponent
    draft.action = .openApp
    draft.target = url.path
    draft.name = "打开 \(name)"
    draft.scope = url.pathExtension == "app" ? "App" : "文件 / 文件夹"
    draft.note = url.pathExtension == "app" ? "应用程序：打开 / 置前 / 再按隐藏。" : "文件或文件夹"
  }

  private func applyPreset(
    action: ShortcutAction,
    target: String,
    name: String,
    scope: String,
    note: String
  ) {
    draft.action = action
    draft.target = target
    draft.name = name
    draft.scope = scope
    draft.note = note
  }
}
