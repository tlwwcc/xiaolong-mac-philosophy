import PlatformContracts

public enum NetworkProbeFeatureIDs {
  public static let feature = FeatureID("cn.tlww.aixlg.hotkeys.feature.network-probe")
  public static let openCommand = CommandID(
    "cn.tlww.aixlg.hotkeys.feature.network-probe.command.open"
  )
  public static let mainWindow = WindowID(
    "cn.tlww.aixlg.hotkeys.feature.network-probe.window.main"
  )
  public static let runProbe = OperationID(
    "cn.tlww.aixlg.hotkeys.feature.network-probe.operation.run"
  )
}

public struct NetworkProbeFeatureModule: FeatureModule {
  public let manifest = FeatureManifest(
    id: NetworkProbeFeatureIDs.feature,
    manifestVersion: 3,
    displayName: "测试网速",
    summary: "两个球：网络测速显示下载、上传、延迟和抖动，Codex 连接显示四轮连通与响应。",
    category: .systemUtilities,
    isEnabledByDefault: true,
    activationPolicy: .onDemand,
    requiredPermissions: [],
    accessPolicy: .free,
    commands: [
      FeatureCommandDescriptor(
        id: NetworkProbeFeatureIDs.openCommand,
        displayName: "打开测试网速"
      )
    ],
    windows: [
      FeatureWindowDescriptor(
        id: NetworkProbeFeatureIDs.mainWindow,
        role: .primary
      )
    ],
    operations: [
      FeatureOperationDescriptor(
        id: NetworkProbeFeatureIDs.runProbe,
        displayName: "开始测速"
      )
    ],
    settingsSchemaVersion: 1
  )

  public init() {}
}
