import AppKit
import SwiftUI

struct PhrasePanelView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    PhraseWorkspaceView(workspace: model.phraseWorkspace)
      .onAppear {
        model.refreshAccessibilityStatus()
        model.reloadPhraseExpander()
      }
  }
}

struct PhraseWorkspaceView: View {
  @ObservedObject var workspace: PhraseWorkspace
  @State private var confirmsDiscard = false
  @State private var copyStatus: String?
  @State private var copyFallbackJSON: String?

  var body: some View {
    VStack(spacing: 12) {
      if let message = workspace.recoveryMessage {
        recoveryNotice(message)
      }
      VStack(spacing: 0) {
        PhraseTableHeader(workspace: workspace)
        if workspace.phrases.isEmpty {
          EmptyPhraseView {
            workspace.addPhrase()
          }
        } else {
          ScrollView {
            LazyVStack(spacing: 10) {
              ForEach(workspace.phrases.map(\.id), id: \.self) { phraseID in
                if let phrase = workspace.bindingForPhrase(id: phraseID) {
                  PhraseCardRow(workspace: workspace, phrase: phrase)
                }
              }
            }
            .padding(12)
          }
        }
      }
      .premiumPanel(radius: 17)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .confirmationDialog("重新读取快捷短语？", isPresented: $confirmsDiscard, titleVisibility: .visible) {
      Button("放弃当前编辑并重新读取", role: .destructive) {
        workspace.reloadFromDisk(discardPendingChanges: true)
      }
      Button("保留当前编辑", role: .cancel) {}
    } message: {
      Text("尚未保存的编辑会被文件中的内容替换。可以先取消，复制当前短语留作副本。")
    }
    .onChange(of: workspace.phrases) { _ in
      copyStatus = nil
      copyFallbackJSON = nil
    }
  }

  private func recoveryNotice(_ message: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(message, systemImage: "exclamationmark.circle")
        .font(.callout)
        .foregroundStyle(AppVisualStyle.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 10) {
        Button("复制当前短语") { copyCurrentDraft() }
          .accessibilityIdentifier("phrases.copyRecoveryDraft")
        Button("重新读取") {
          if workspace.hasUnsavedChanges {
            confirmsDiscard = true
          } else {
            workspace.reloadFromDisk()
          }
        }
        .accessibilityIdentifier("phrases.reloadConfiguration")
        if let copyStatus {
          Text(copyStatus)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .buttonStyle(.bordered)
      if let copyFallbackJSON {
        DisclosureGroup("查看配置并手动复制") {
          ScrollView {
            Text(copyFallbackJSON)
              .font(.system(.caption, design: .monospaced))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 180)
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(AppVisualStyle.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .contain)
  }

  private func copyCurrentDraft() {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      // Preserve the complete draft, including edits that are not valid for activation yet.
      let text = String(decoding: try encoder.encode(workspace.phrases), as: UTF8.self)
      NSPasteboard.general.clearContents()
      if NSPasteboard.general.setString(text, forType: .string) {
        copyStatus = "已复制，可粘贴到本地文本保存"
        copyFallbackJSON = nil
      } else {
        copyStatus = "复制未完成，可展开下方配置手动复制"
        copyFallbackJSON = text
      }
    } catch {
      copyStatus = "暂时无法生成副本：\(error.localizedDescription)"
    }
  }
}

struct PhraseTableHeader: View {
  @ObservedObject var workspace: PhraseWorkspace

  var body: some View {
    HStack(spacing: 12) {
      Text("启用")
        .frame(width: 48, alignment: .leading)
      Text("缩写")
        .frame(width: 140, alignment: .leading)
      Text("输出内容")
        .frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: 6) {
        ToolbarIconButton(systemImage: "plus", title: "新增快捷短语", tint: accent) {
          workspace.addPhrase()
        }
        ToolbarIconButton(systemImage: "trash", title: "删除选中短语", tint: amber) {
          workspace.deleteSelectedPhrase()
        }
        .disabled(workspace.selectedPhraseID == nil)
      }
    }
    .font(.system(size: 12, weight: .medium))
    .foregroundStyle(muted)
    .padding(.horizontal, 14)
    .frame(height: 40)
    .background(
      LinearGradient(
        colors: [chrome, AppVisualStyle.surface.opacity(0.68)], startPoint: .leading,
        endPoint: .trailing)
    )
  }
}

struct PhraseCardRow: View {
  @ObservedObject var workspace: PhraseWorkspace
  @Binding var phrase: PhraseItem
  @State private var hovering = false

  private var selected: Bool {
    workspace.selectedPhraseID == phrase.id
  }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Toggle(
        "",
        isOn: Binding(
          get: { phrase.enabled },
          set: { value in
            phrase.enabled = value
            workspace.selectedPhraseID = phrase.id
            workspace.saveAndReload()
          }
        )
      )
      .toggleStyle(.checkbox)
      .frame(width: 48)
      .padding(.top, 10)

      TextField(
        "ppdz",
        text: Binding(
          get: { phrase.trigger },
          set: { value in
            phrase.trigger = normalizedPhraseTrigger(value)
            workspace.selectedPhraseID = phrase.id
            workspace.scheduleSave(reload: true)
          }
        )
      )
      .font(.system(size: 16, weight: .semibold, design: .monospaced))
      .textFieldStyle(.plain)
      .foregroundStyle(accent)
      .padding(.horizontal, 10)
      .frame(width: 140, height: 38)
      .background(AppVisualStyle.surface.opacity(0.86), in: RoundedRectangle(cornerRadius: 10))
      .overlay(
        RoundedRectangle(cornerRadius: 10).stroke(
          selected ? accent.opacity(0.65) : line, lineWidth: 1)
      )
      .padding(.top, 4)

      TextEditor(
        text: Binding(
          get: { phrase.output },
          set: { value in
            phrase.output = value
            workspace.selectedPhraseID = phrase.id
            workspace.scheduleSave(reload: true)
          }
        )
      )
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(ink)
      .scrollContentBackground(.hidden)
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .frame(minHeight: 70)
      .background(AppVisualStyle.surface.opacity(0.86), in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).stroke(line, lineWidth: 1))
    }
    .padding(10)
    .background(rowBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(
          selected ? accent.opacity(0.45) : AppVisualStyle.surface.opacity(0.70),
          lineWidth: selected ? 1.5 : 1
        )
    )
    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .onTapGesture {
      workspace.selectedPhraseID = phrase.id
    }
    .onHover { inside in hovering = inside }
    .animation(.easeOut(duration: 0.14), value: selected)
    .animation(.easeOut(duration: 0.12), value: hovering)
  }

  private var rowBackground: some ShapeStyle {
    if selected {
      return LinearGradient(
        colors: [accent.opacity(0.12), teal.opacity(0.055)], startPoint: .leading,
        endPoint: .trailing)
    }
    if hovering {
      return LinearGradient(
        colors: [glowBlue.opacity(0.045), AppVisualStyle.surface.opacity(0.92)],
        startPoint: .leading,
        endPoint: .trailing)
    }
    return LinearGradient(
      colors: [surface.opacity(0.92), AppVisualStyle.surface.opacity(0.72)],
      startPoint: .topLeading,
      endPoint: .bottomTrailing)
  }
}

struct EmptyPhraseView: View {
  let add: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "text.badge.plus")
        .font(.system(size: 34, weight: .semibold))
        .foregroundStyle(accent)
      Text("还没有快捷短语")
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(ink)
      Text("新增一条后，输入缩写就能自动展开文本。")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(muted)
      Button {
        add()
      } label: {
        Label("新增快捷短语", systemImage: "plus")
      }
      .buttonStyle(GlassLabelButtonStyle(tint: teal, prominent: true))
    }
    .frame(maxWidth: .infinity, minHeight: 260)
  }
}

func normalizedPhraseTrigger(_ value: String) -> String {
  value
    .trimmingCharacters(in: .whitespacesAndNewlines)
    .replacingOccurrences(of: " ", with: "")
    .lowercased()
}
