import PlatformContracts

public enum YoumuFeatureIDs {
  public static let feature = FeatureID("cn.tlww.aixlg.hotkeys.feature.youmu")

  public static let quickSnapshot = CommandID(
    "cn.tlww.aixlg.hotkeys.feature.youmu.command.quick-snapshot"
  )
  public static let annotatedScreenshot = CommandID(
    "cn.tlww.aixlg.hotkeys.feature.youmu.command.annotated-screenshot"
  )
  public static let longScreenshot = CommandID(
    "cn.tlww.aixlg.hotkeys.feature.youmu.command.long-screenshot"
  )
  public static let pinScreenshot = CommandID(
    "cn.tlww.aixlg.hotkeys.feature.youmu.command.pin-screenshot"
  )
  public static let selectionReader = CommandID(
    "cn.tlww.aixlg.hotkeys.feature.youmu.command.selection-reader"
  )
  public static let imageTranslate = CommandID(
    "cn.tlww.aixlg.hotkeys.feature.youmu.command.image-translate"
  )
  public static let ocrTranslate = CommandID(
    "cn.tlww.aixlg.hotkeys.feature.youmu.command.ocr-translate"
  )
  public static let ocrCopy = CommandID(
    "cn.tlww.aixlg.hotkeys.feature.youmu.command.ocr-copy"
  )
  public static let controlWindow = WindowID(
    "cn.tlww.aixlg.hotkeys.feature.youmu.window.control"
  )

  public static let bundledCommands: Set<CommandID> = [
    quickSnapshot,
    annotatedScreenshot,
    pinScreenshot,
    ocrCopy,
    longScreenshot,
    selectionReader,
    imageTranslate,
    ocrTranslate,
  ]

  public static let freeCommands = bundledCommands
  public static let proCommands: Set<CommandID> = []
}

public struct YoumuFeatureModule: FeatureModule {
  public let manifest = FeatureManifest(
    id: YoumuFeatureIDs.feature,
    manifestVersion: 4,
    displayName: "游目",
    summary: "截图、贴图、识读与图片翻译。",
    category: .captureAndUnderstand,
    isEnabledByDefault: true,
    activationPolicy: .onDemand,
    requiredPermissions: [.screenRecording],
    accessPolicy: .free,
    commands: [
      FeatureCommandDescriptor(
        id: YoumuFeatureIDs.quickSnapshot,
        displayName: "快速截图"
      ),
      FeatureCommandDescriptor(
        id: YoumuFeatureIDs.annotatedScreenshot,
        displayName: "标注截图"
      ),
      FeatureCommandDescriptor(
        id: YoumuFeatureIDs.longScreenshot,
        displayName: "长截图",
        requiredPermissions: [.screenRecording, .inputMonitoring],
        accessPolicy: .free
      ),
      FeatureCommandDescriptor(
        id: YoumuFeatureIDs.pinScreenshot,
        displayName: "贴图",
        requiredPermissions: []
      ),
      FeatureCommandDescriptor(
        id: YoumuFeatureIDs.selectionReader,
        displayName: "选区识读",
        accessPolicy: .free
      ),
      FeatureCommandDescriptor(
        id: YoumuFeatureIDs.imageTranslate,
        displayName: "图片翻译",
        accessPolicy: .free
      ),
      FeatureCommandDescriptor(
        id: YoumuFeatureIDs.ocrTranslate,
        displayName: "OCR 翻译",
        accessPolicy: .free
      ),
      FeatureCommandDescriptor(
        id: YoumuFeatureIDs.ocrCopy,
        displayName: "OCR 复制文字"
      ),
    ],
    windows: [
      FeatureWindowDescriptor(
        id: YoumuFeatureIDs.controlWindow,
        role: .primary,
        requiredPermissions: [],
        accessPolicy: .free
      )
    ],
    operations: [],
    settingsSchemaVersion: 1
  )

  public init() {}
}
