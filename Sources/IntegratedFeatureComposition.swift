import Foundation

@MainActor
func runInstalledTranslationSmoke() async -> [String: String] {
  #if canImport(BuiltinFeatureCatalog) && canImport(PijuanPDFFeature) && canImport(PlatformContracts) && canImport(PlatformServices) && canImport(YoumuFeature)
    return await YoumuTranslationDiagnostics.runInstalledModelSmoke()
  #else
    return ["status": "SKIP", "reason": "本构建未包含游目翻译模块。"]
  #endif
}

#if canImport(BuiltinFeatureCatalog) && canImport(PijuanPDFFeature) && canImport(PlatformContracts) && canImport(PlatformServices) && canImport(YoumuFeature)
  import AppKit
  import BuiltinFeatureCatalog
  import PijuanPDFFeature
  import PlatformContracts
  import PlatformServices
  import YoumuFeature

  @MainActor
  final class IntegratedFeatureComposition {
    private weak var model: AppModel?
    private let runtimeIdentity: AppRuntimeIdentity
    private let youmuRuntime: YoumuFeatureRuntime
    private let pijuanPDF: PijuanPDFFeatureFacade
    private let dispatcher: FeatureDispatcher

    init(model: AppModel) throws {
      self.model = model

      let identity = AppRuntimeIdentity.current
      runtimeIdentity = identity
      let fileManager = FileManager.default
      let environment = YoumuFeatureEnvironment(
        hostBundleIdentifier: identity.bundleIdentifier,
        channelRoot: identity.applicationSupportDirectoryName,
        applicationSupportRoot: fileManager.urls(
          for: .applicationSupportDirectory,
          in: .userDomainMask
        )[0],
        temporaryRoot: fileManager.temporaryDirectory,
        userDefaultsSuiteName: identity.defaultsSuiteName
      )
      let runtime = YoumuFeatureRuntime(
        environment: environment,
        longScreenshotActivityChanged: { [weak model] isActive in
          model?.setLongScreenshotCaptureActive(isActive)
        },
        openMainInterface: { [weak model] in
          model?.selectPlugin(id: "youmu")
          model?.selectedModuleName = "插件中心"
          model?.presentWindowHandler?()
        },
        openShortcutManager: { [weak model] in
          model?.openFeatureShortcutManager(
            commandID: YoumuFeatureShortcutCatalog.quickSnapshot.id)
        }
      )
      youmuRuntime = runtime

      let pdfNamespace = PijuanPDFStorageNamespace(
        channelBundleIdentifier: identity.bundleIdentifier
      )
      guard let pdfDefaults = UserDefaults(suiteName: pdfNamespace.preferencesSuiteName) else {
        throw IntegratedFeatureCompositionError.pdfPreferencesUnavailable
      }
      let pijuanVersion = CustomerVersionFormatter.featureVersion(
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
      let pdfConfiguration = PijuanPDFFeatureConfiguration(
        channel: .stable,
        storageNamespace: pdfNamespace,
        defaultAssociationPolicy: identity.allowsDefaultPDFAssociation
          ? .hostManaged : .disabled,
        version: pijuanVersion.version,
        build: pijuanVersion.build
      )
      pijuanPDF = try PijuanPDFFeatureFacade(
        configuration: pdfConfiguration,
        preferences: PijuanPDFPreferences(
          suiteName: pdfNamespace.preferencesSuiteName,
          defaults: pdfDefaults
        )
      )

      var builder = FeatureRegistryBuilder(
        entitlementChecker: FreeFeatureAccessAdapter(),
        permissionChecker: HostFeaturePermissionAdapter()
      )
      let module = YoumuFeatureModule()
      try builder.register(module)
      let registry = builder.build()
      let accessScope = try registry.accessScope(for: module.manifest.id)
      var handlers = module.manifest.commands.map { descriptor in
        let commandID = descriptor.id
        let action = FeatureAccessAction.execute(commandID)
        return FeatureActionHandlerRegistration(
          featureID: module.manifest.id,
          action: action
        ) {
          try await MainActor.run {
            let finalDecision = accessScope.decision(for: action)
            guard finalDecision == .allowed else {
              throw YoumuFinalAccessRevoked(decision: finalDecision)
            }
            try runtime.execute(commandID: commandID)
          }
        }
      }
      handlers.append(
        FeatureActionHandlerRegistration(
          featureID: module.manifest.id,
          action: .open(YoumuFeatureIDs.controlWindow)
        ) {
          await MainActor.run {
            runtime.openControlWindow { commandID in
              model.executeFeatureCommand(commandID: commandID)
            }
          }
        }
      )
      dispatcher = try FeatureDispatcher(registry: registry, handlers: handlers)
      pijuanPDF.setOpenShortcutManagerHandler { [weak model] in
        model?.openPijuanPDFShortcutManager()
      }
    }

    func installHandlers() {
      model?.globalInputOwnershipWillYieldHandler = { [weak self] in
        self?.youmuRuntime.cancelAllCommandSessions()
      }
      model?.integratedFeaturePermissionsDidChangeHandler = { [weak self] previous, current in
        guard let self else { return }
        if previous.screenRecording, !current.screenRecording {
          youmuRuntime.invalidateCommandSessions(for: .screenRecordingPermissionLost)
        }
        if previous.inputMonitoring, !current.inputMonitoring {
          youmuRuntime.invalidateCommandSessions(for: .inputMonitoringPermissionLost)
        }
      }
      model?.executeFeatureCommandHandler = { [weak self] commandID in
        self?.dispatchYoumu(commandID: commandID)
      }
      model?.showYoumuFeatureHandler = { [weak self] in
        self?.dispatchYoumu(commandID: YoumuFeatureIDs.quickSnapshot.rawValue)
      }
      model?.openYoumuControlCenterHandler = { [weak self] in
        self?.openYoumuControlCenter()
      }
      model?.showPijuanPDFFeatureHandler = { [weak self] in
        self?.showPijuanPDF()
      }
      model?.openPijuanPDFDocumentHandler = { [weak self] url in
        self?.openPijuanPDF(url)
      }
      model?.pijuanPDFShortcutCount = pijuanPDF.shortcutCount
      model?.makePijuanPDFShortcutSettingsViewHandler = { [weak self] in
        self?.pijuanPDF.makeShortcutSettingsView(embedded: true)
      }
    }

    private func dispatchYoumu(commandID: String) {
      let command = CommandID(commandID)
      Task { @MainActor [weak self] in
        guard let self else { return }
        if youmuRuntime.cancelIfActive(commandID: command) {
          model?.statusMessage = "已关闭游目当前动作。"
          return
        }
        guard model?.hasGlobalInputOwnership == true else {
          model?.statusMessage =
            model?.globalInputOwnershipBlockedMessage
            ?? "全局输入独占权尚未取得，游目未执行。"
          return
        }
        do {
          let result = try await dispatcher.dispatch(
            featureID: YoumuFeatureIDs.feature,
            action: .execute(command)
          )
          switch result {
          case .executed:
            model?.statusMessage = "游目动作已开始。"
          case .denied(let reason):
            model?.statusMessage = reason
          case .entitlementDenied(_, let reason):
            model?.statusMessage = reason
          case .permissionDenied(let permissionID, let reason):
            handleYoumuPermissionDenial(permissionID, reason: reason)
          }
        } catch let accessError as YoumuFinalAccessRevoked {
          handleYoumuFinalAccessRevocation(accessError.decision)
        } catch {
          model?.statusMessage = "游目未能执行：\(error.localizedDescription)"
        }
      }
    }

    private func handleYoumuPermissionDenial(_ permissionID: PermissionID, reason: String) {
      model?.statusMessage = reason
      switch permissionID {
      case .screenRecording:
        model?.presentAuthorizationCenter()
        model?.statusMessage = "请在统一授权中心开启屏幕录制，完成后游目会自动恢复。"
      case .inputMonitoring, .accessibility:
        model?.presentAuthorizationCenter()
      default:
        break
      }
    }

    private func handleYoumuFinalAccessRevocation(_ decision: FeatureAccessDecision) {
      switch decision {
      case .allowed:
        break
      case .denied(let reason), .entitlementDenied(_, let reason):
        model?.statusMessage = reason
      case .permissionDenied(let permissionID, let reason):
        handleYoumuPermissionDenial(permissionID, reason: reason)
      }
    }

    private func openYoumuControlCenter() {
      Task { @MainActor [weak self] in
        guard let self else { return }
        do {
          let result = try await dispatcher.dispatch(
            featureID: YoumuFeatureIDs.feature,
            action: .open(YoumuFeatureIDs.controlWindow)
          )
          switch result {
          case .executed:
            model?.statusMessage = "已打开游目。"
          case .denied(let reason), .entitlementDenied(_, let reason):
            model?.statusMessage = reason
          case .permissionDenied(let permissionID, let reason):
            handleYoumuPermissionDenial(permissionID, reason: reason)
          }
        } catch {
          model?.statusMessage = "游目未能打开：\(error.localizedDescription)"
        }
      }
    }

    private func showPijuanPDF() {
      _ = pijuanPDF.showWindow()
      NSApp.activate(ignoringOtherApps: true)
      model?.statusMessage = "已打开披卷。"
    }

    private func openPijuanPDF(_ url: URL) {
      _ = pijuanPDF.showWindow(opening: url)
      NSApp.activate(ignoringOtherApps: true)
      model?.statusMessage = "已用披卷打开 \(url.lastPathComponent)。"
    }
  }

  private enum IntegratedFeatureCompositionError: LocalizedError {
    case pdfPreferencesUnavailable

    var errorDescription: String? {
      "无法建立披卷的独立偏好域。"
    }
  }

  private struct YoumuFinalAccessRevoked: Error, Sendable {
    let decision: FeatureAccessDecision
  }
#endif

/// Builds the modular runtime only when SwiftPM linked every required module.
///
/// The stable direct-compile lane sees the same source file but returns nil, preserving the
/// currently installed stable app while source fixtures are exercised locally.
@MainActor
func installIntegratedFeaturesIfAvailable(into model: AppModel) -> AnyObject? {
  #if canImport(BuiltinFeatureCatalog) && canImport(PijuanPDFFeature) && canImport(PlatformContracts) && canImport(PlatformServices) && canImport(YoumuFeature)
    do {
      let composition = try IntegratedFeatureComposition(model: model)
      composition.installHandlers()
      return composition
    } catch {
      model.statusMessage = "原生功能平台初始化失败：\(error.localizedDescription)"
      return nil
    }
  #else
    return nil
  #endif
}
