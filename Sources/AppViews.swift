import AppKit
import SwiftUI

struct RootView: View {
  @EnvironmentObject private var model: AppModel
  @State private var isKeepAwakePresented = false

  var body: some View {
    let actionCaptureOwnerID = model.shortcutActionCaptureSessionID
    VStack(spacing: 0) {
      AppTopNavigationView(selectedModule: workspaceSelection)
      Divider()
      if let message = model.configurationRecoveryMessage {
        WorkspaceNotice(message: message, symbol: "exclamationmark.shield", tone: .warning)
          .accessibilityIdentifier("configuration.recovery.notice")
      }
      ShortcutGridView(selectedModule: model.selectedModuleName)
        .disabled(model.isChangingShortcutConfiguration)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .toolbar {
      ToolbarItem { MainWindowUpdateToolbarView() }
    }
    .frame(minWidth: 860, minHeight: 600)
    .background(AppBackdrop())
    .sheet(item: $model.softwareShortcutRequest) { request in
      SoftwareShortcutEditorSheet(request: request)
        .environmentObject(model)
    }
    .sheet(
      isPresented: Binding(
        get: { model.isCapturingShortcutAction },
        set: {
          if !$0, let ownerID = actionCaptureOwnerID {
            model.cancelShortcutActionCapture(ownerID: ownerID)
          }
        })
    ) {
      if let ownerID = actionCaptureOwnerID {
        ShortcutActionCaptureSheet(recordingOwnerID: ownerID)
          .id(ownerID)
          .environmentObject(model)
      }
    }
    .sheet(
      isPresented: Binding(
        get: { model.isMenuBarCustomizationPresented },
        set: { model.isMenuBarCustomizationPresented = $0 })
    ) {
      MenuBarCustomizationSheet()
        .environmentObject(model)
    }
    .sheet(
      isPresented: Binding(
        get: { model.isAccessibilityAuthorizationPresented },
        set: { model.isAccessibilityAuthorizationPresented = $0 })
    ) {
      AccessibilityAuthorizationSheetView()
        .environmentObject(model)
    }
    .sheet(isPresented: $model.isCommunityQRCodePresented) {
      VStack(spacing: 12) {
        FeedbackRequestPanelView()
        Button("关闭") { model.isCommunityQRCodePresented = false }
          .keyboardShortcut(.cancelAction)
      }
      .padding(20)
      .frame(width: 380)
    }
    .sheet(isPresented: $isKeepAwakePresented) {
      KeepAwakeSheetView()
        .environmentObject(model)
    }
    .onChange(of: model.sleepPanelRequestID) { _ in
      isKeepAwakePresented = true
    }
    .sheet(
      isPresented: Binding(
        get: { model.isReleaseNotePresented },
        set: { if !$0 { model.markReleaseNoteSeen() } })
    ) {
      if let note = model.pendingReleaseNote {
        ReleaseAnnouncementSheetView(workspace: model.updateWorkspace, note: note)
      }
    }
    .onAppear {
      if model.selectedModuleName == "一键部署" {
        model.selectedModuleName = moduleOptimize
      }
      model.checkForUpdatesIfNeeded()
      model.showReleaseNoteIfNeeded()
    }
  }

  private var workspaceSelection: Binding<String> {
    Binding(
      get: { model.selectedModuleName },
      set: { module in
        guard module != model.selectedModuleName else { return }
        model.cancelRecordingIfNeeded()
        if module == moduleAbout {
          model.showSettings()
        } else {
          model.selectedModuleName = module
        }
      }
    )
  }
}
