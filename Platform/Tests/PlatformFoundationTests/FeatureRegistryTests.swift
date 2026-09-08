import BuiltinFeatureCatalog
import Foundation
import PlatformContracts
import PlatformServices
import XCTest

final class FeatureRegistryTests: XCTestCase {
  func testNetworkProbeManifestRegistersWithStableOwnership() throws {
    var builder = makeBuilder()

    try builder.register(NetworkProbeFeatureModule())
    let registry = builder.build()

    XCTAssertEqual(registry.manifests.map(\.id), [NetworkProbeFeatureIDs.feature])
    XCTAssertEqual(
      registry.owner(of: NetworkProbeFeatureIDs.openCommand),
      NetworkProbeFeatureIDs.feature
    )
    XCTAssertEqual(
      registry.owner(of: NetworkProbeFeatureIDs.mainWindow),
      NetworkProbeFeatureIDs.feature
    )
    XCTAssertEqual(
      registry.owner(of: NetworkProbeFeatureIDs.runProbe),
      NetworkProbeFeatureIDs.feature
    )
  }

  func testDuplicateFeatureIDFailsBeforeMutatingRegistry() throws {
    var builder = makeBuilder()
    let module = NetworkProbeFeatureModule()
    try builder.register(module)

    XCTAssertThrowsError(try builder.register(module)) { error in
      XCTAssertEqual(
        error as? FeatureRegistryError,
        .duplicateFeatureID(NetworkProbeFeatureIDs.feature)
      )
    }
    XCTAssertEqual(builder.build().manifests.count, 1)
  }

  func testDuplicateManifestOwnedIDsFailClosed() {
    var manifest = NetworkProbeFeatureModule().manifest
    manifest = FeatureManifest(
      id: manifest.id,
      manifestVersion: manifest.manifestVersion,
      displayName: manifest.displayName,
      summary: manifest.summary,
      category: manifest.category,
      isEnabledByDefault: manifest.isEnabledByDefault,
      activationPolicy: manifest.activationPolicy,
      requiredPermissions: manifest.requiredPermissions,
      accessPolicy: manifest.accessPolicy,
      commands: [manifest.commands[0], manifest.commands[0]],
      windows: manifest.windows,
      operations: manifest.operations,
      settingsSchemaVersion: manifest.settingsSchemaVersion
    )
    var builder = makeBuilder()

    XCTAssertThrowsError(try builder.register(manifest)) { error in
      XCTAssertEqual(
        error as? FeatureRegistryError,
        .duplicateCommandID(NetworkProbeFeatureIDs.openCommand)
      )
    }
    let registry = builder.build()
    XCTAssertTrue(registry.manifests.isEmpty)
    XCTAssertNil(registry.owner(of: NetworkProbeFeatureIDs.openCommand))
    XCTAssertNil(registry.owner(of: NetworkProbeFeatureIDs.mainWindow))
    XCTAssertNil(registry.owner(of: NetworkProbeFeatureIDs.runProbe))
  }

  func testInvalidAndCrossFeatureIdentifiersFailClosed() {
    let invalidFeature = FeatureManifest(
      id: FeatureID("CN.TLWW.Bad Feature"),
      manifestVersion: 1,
      displayName: "坏清单",
      summary: "用于验证非法 ID。",
      category: .systemUtilities,
      isEnabledByDefault: false,
      activationPolicy: .onDemand,
      requiredPermissions: [],
      accessPolicy: .free,
      commands: [],
      windows: [],
      operations: [],
      settingsSchemaVersion: 1
    )
    var builder = makeBuilder()

    XCTAssertThrowsError(try builder.register(invalidFeature)) { error in
      XCTAssertEqual(
        error as? FeatureRegistryError,
        .invalidIdentifier(kind: "FeatureID", value: "CN.TLWW.Bad Feature")
      )
    }

    let featureID = FeatureID("cn.tlww.aixlg.hotkeys.feature.example")
    let borrowedCommand = CommandID("cn.tlww.aixlg.hotkeys.feature.other.command.open")
    let crossFeatureManifest = FeatureManifest(
      id: featureID,
      manifestVersion: 1,
      displayName: "示例",
      summary: "用于验证命名空间。",
      category: .systemUtilities,
      isEnabledByDefault: false,
      activationPolicy: .onDemand,
      requiredPermissions: [],
      accessPolicy: .free,
      commands: [
        FeatureCommandDescriptor(id: borrowedCommand, displayName: "打开")
      ],
      windows: [],
      operations: [],
      settingsSchemaVersion: 1
    )

    XCTAssertThrowsError(try builder.register(crossFeatureManifest)) { error in
      XCTAssertEqual(
        error as? FeatureRegistryError,
        .commandNotOwned(featureID: featureID, commandID: borrowedCommand)
      )
    }
  }

  func testFeatureAndTypedActionIdentifierShapesFailClosed() {
    let source = NetworkProbeFeatureModule().manifest
    let shortFeatureID = FeatureID("a")
    let nestedFeatureID = FeatureID("\(source.id.rawValue).child")
    let wrongKindCommand = CommandID(source.windows[0].id.rawValue)

    for invalidFeatureID in [shortFeatureID, nestedFeatureID] {
      var builder = makeBuilder()
      XCTAssertThrowsError(
        try builder.register(replacing(source, id: invalidFeatureID))
      ) { error in
        XCTAssertEqual(
          error as? FeatureRegistryError,
          .invalidIdentifier(kind: "FeatureID", value: invalidFeatureID.rawValue)
        )
      }
    }

    var builder = makeBuilder()
    let wrongKindManifest = replacing(
      source,
      commands: [
        FeatureCommandDescriptor(id: wrongKindCommand, displayName: "错误类型")
      ]
    )
    XCTAssertThrowsError(try builder.register(wrongKindManifest)) { error in
      XCTAssertEqual(
        error as? FeatureRegistryError,
        .commandNotOwned(featureID: source.id, commandID: wrongKindCommand)
      )
    }
  }

  func testUnknownPermissionAndEntitlementIDsFailClosed() {
    let source = NetworkProbeFeatureModule().manifest
    let unknownPermission = PermissionID("macos.camera")
    var permissionBuilder = makeBuilder()

    XCTAssertThrowsError(
      try permissionBuilder.register(
        replacing(source, requiredPermissions: [unknownPermission])
      )
    ) { error in
      XCTAssertEqual(
        error as? FeatureRegistryError,
        .unsupportedPermissionID(unknownPermission)
      )
    }

    let unknownEntitlement = EntitlementID("cn.tlww.aixlg.entitlement.typo")
    var entitlementBuilder = makeBuilder()
    XCTAssertThrowsError(
      try entitlementBuilder.register(
        replacing(source, accessPolicy: .anyOf([unknownEntitlement]))
      )
    ) { error in
      XCTAssertEqual(
        error as? FeatureRegistryError,
        .unsupportedEntitlementID(unknownEntitlement)
      )
    }
  }

  func testCommandAndOperationOverridePoliciesFailClosed() {
    let source = makeGranularPolicyManifest()
    let inheritedCommand = source.commands[0]
    let inheritedOperation = source.operations[0]

    let commandWithUnknownPermission = FeatureCommandDescriptor(
      id: inheritedCommand.id,
      displayName: inheritedCommand.displayName,
      requiredPermissions: [PermissionID("macos.camera")]
    )
    var unknownPermissionBuilder = makeBuilder()
    XCTAssertThrowsError(
      try unknownPermissionBuilder.register(
        replacing(source, commands: [commandWithUnknownPermission, source.commands[1]])
      )
    ) { error in
      XCTAssertEqual(
        error as? FeatureRegistryError,
        .unsupportedPermissionID(PermissionID("macos.camera"))
      )
    }

    let commandWithDuplicatePermission = FeatureCommandDescriptor(
      id: inheritedCommand.id,
      displayName: inheritedCommand.displayName,
      requiredPermissions: [.screenRecording, .screenRecording]
    )
    var duplicatePermissionBuilder = makeBuilder()
    XCTAssertThrowsError(
      try duplicatePermissionBuilder.register(
        replacing(source, commands: [commandWithDuplicatePermission, source.commands[1]])
      )
    ) { error in
      XCTAssertEqual(
        error as? FeatureRegistryError,
        .duplicatePermissionID(.screenRecording)
      )
    }

    let unknownEntitlement = EntitlementID("cn.tlww.aixlg.entitlement.typo")
    let operationWithUnknownEntitlement = FeatureOperationDescriptor(
      id: inheritedOperation.id,
      displayName: inheritedOperation.displayName,
      accessPolicy: .anyOf([unknownEntitlement])
    )
    var unknownEntitlementBuilder = makeBuilder()
    XCTAssertThrowsError(
      try unknownEntitlementBuilder.register(
        replacing(
          source,
          operations: [operationWithUnknownEntitlement, source.operations[1]]
        )
      )
    ) { error in
      XCTAssertEqual(
        error as? FeatureRegistryError,
        .unsupportedEntitlementID(unknownEntitlement)
      )
    }

    let operationWithEmptyEntitlement = FeatureOperationDescriptor(
      id: inheritedOperation.id,
      displayName: inheritedOperation.displayName,
      accessPolicy: .anyOf([])
    )
    var emptyEntitlementBuilder = makeBuilder()
    XCTAssertThrowsError(
      try emptyEntitlementBuilder.register(
        replacing(source, operations: [operationWithEmptyEntitlement, source.operations[1]])
      )
    ) { error in
      XCTAssertEqual(
        error as? FeatureRegistryError,
        .emptyEntitlementAlternatives(featureID: source.id)
      )
    }

    let operationWithDuplicateEntitlement = FeatureOperationDescriptor(
      id: inheritedOperation.id,
      displayName: inheritedOperation.displayName,
      accessPolicy: .anyOf([.macFull, .macFull])
    )
    var duplicateEntitlementBuilder = makeBuilder()
    XCTAssertThrowsError(
      try duplicateEntitlementBuilder.register(
        replacing(
          source,
          operations: [operationWithDuplicateEntitlement, source.operations[1]]
        )
      )
    ) { error in
      XCTAssertEqual(error as? FeatureRegistryError, .duplicateEntitlementID(.macFull))
    }
  }

  func testDecodedInvalidManifestStillPassesThroughRegistryValidation() throws {
    let source = replacing(
      NetworkProbeFeatureModule().manifest,
      id: FeatureID("cn.tlww.aixlg.hotkeys.feature.bad.child")
    )
    let data = try JSONEncoder().encode(source)
    let decoded = try JSONDecoder().decode(FeatureManifest.self, from: data)
    var builder = makeBuilder()

    XCTAssertThrowsError(try builder.register(decoded)) { error in
      XCTAssertEqual(
        error as? FeatureRegistryError,
        .invalidIdentifier(kind: "FeatureID", value: source.id.rawValue)
      )
    }
  }

  func testFreeFeaturesAreAlwaysAllowedByEntitlementRouter() throws {
    let freeFeatureID = FeatureID("cn.tlww.aixlg.hotkeys.feature.free-example")
    let freeManifest = FeatureManifest(
      id: freeFeatureID,
      manifestVersion: 1,
      displayName: "免费示例",
      summary: "用于验证免费能力不经过 Pro 硬门。",
      category: .files,
      isEnabledByDefault: false,
      activationPolicy: .onDemand,
      requiredPermissions: [],
      accessPolicy: .free,
      commands: [],
      windows: [],
      operations: [],
      settingsSchemaVersion: 1
    )
    var builder = makeBuilder(grantedEntitlements: [])
    try builder.register(freeManifest)
    let registry = builder.build()

    let decision = try registry.accessScope(for: freeFeatureID).decision(for: .start)

    XCTAssertEqual(decision, .allowed)
  }

  func testCommandAndOperationRequirementsInheritAndOverrideFeatureDefaults() throws {
    let manifest = makeGranularPolicyManifest()
    var builder = makeBuilder(grantedEntitlements: [], grantedPermissions: [])
    try builder.register(manifest)
    let scope = try builder.build().accessScope(for: manifest.id)

    XCTAssertEqual(
      scope.decision(for: .execute(manifest.commands[0].id)),
      .entitlementDenied([.macFull], "没有匹配权益")
    )
    XCTAssertEqual(
      scope.decision(for: .perform(manifest.operations[0].id)),
      .entitlementDenied([.macFull], "没有匹配权益")
    )
    XCTAssertEqual(scope.decision(for: .execute(manifest.commands[1].id)), .allowed)
    XCTAssertEqual(scope.decision(for: .perform(manifest.operations[1].id)), .allowed)

    var entitlementOnlyBuilder = makeBuilder(
      grantedEntitlements: [],
      grantedPermissions: [.screenRecording]
    )
    try entitlementOnlyBuilder.register(manifest)
    let entitlementOnlyScope = try entitlementOnlyBuilder.build().accessScope(for: manifest.id)
    XCTAssertEqual(
      entitlementOnlyScope.decision(for: .execute(manifest.commands[0].id)),
      .entitlementDenied([.macFull], "没有匹配权益")
    )

    var permissionOnlyBuilder = makeBuilder(
      grantedEntitlements: [.macFull],
      grantedPermissions: []
    )
    try permissionOnlyBuilder.register(manifest)
    let permissionOnlyScope = try permissionOnlyBuilder.build().accessScope(for: manifest.id)
    XCTAssertEqual(
      permissionOnlyScope.decision(for: .execute(manifest.commands[0].id)),
      .permissionDenied(.screenRecording, "缺少系统权限")
    )
  }

  func testYoumuManifestKeepsAllEightCommandsInBasePackage() {
    let manifest = YoumuFeatureModule().manifest

    XCTAssertEqual(manifest.manifestVersion, 4)
    XCTAssertEqual(manifest.accessPolicy, .free)
    XCTAssertEqual(manifest.requiredPermissions, [.screenRecording])
    XCTAssertEqual(manifest.commands.count, 8)
    XCTAssertEqual(
      Set(manifest.commands.map(\.id)),
      YoumuFeatureIDs.freeCommands.union(YoumuFeatureIDs.proCommands)
    )
    XCTAssertEqual(YoumuFeatureIDs.freeCommands.count, 8)
    XCTAssertEqual(YoumuFeatureIDs.proCommands.count, 0)

    for command in manifest.commands where YoumuFeatureIDs.bundledCommands.contains(command.id) {
      XCTAssertTrue(command.accessPolicy == nil || command.accessPolicy == .free)
      if command.id == YoumuFeatureIDs.longScreenshot {
        XCTAssertEqual(command.requiredPermissions, [.screenRecording, .inputMonitoring])
      } else if command.id == YoumuFeatureIDs.pinScreenshot {
        XCTAssertEqual(command.requiredPermissions, [])
      } else {
        XCTAssertNil(command.requiredPermissions)
      }
    }

    let longScreenshot = manifest.commands.first { $0.id == YoumuFeatureIDs.longScreenshot }
    XCTAssertEqual(longScreenshot?.requiredPermissions, [.screenRecording, .inputMonitoring])
    let pinScreenshot = manifest.commands.first { $0.id == YoumuFeatureIDs.pinScreenshot }
    XCTAssertEqual(pinScreenshot?.requiredPermissions, [])
    XCTAssertEqual(
      manifest.windows,
      [
        FeatureWindowDescriptor(
          id: YoumuFeatureIDs.controlWindow,
          role: .primary,
          requiredPermissions: [],
          accessPolicy: .free
        )
      ]
    )
  }

  func testYoumuControlWindowOpensWithoutCapturePermissionOrProEntitlement() throws {
    var builder = makeBuilder(grantedEntitlements: [], grantedPermissions: [])
    try builder.register(YoumuFeatureModule())
    let registry = builder.build()
    let scope = try registry.accessScope(for: YoumuFeatureIDs.feature)

    XCTAssertEqual(
      registry.owner(of: YoumuFeatureIDs.controlWindow),
      YoumuFeatureIDs.feature
    )
    XCTAssertEqual(scope.decision(for: .open(YoumuFeatureIDs.controlWindow)), .allowed)
    XCTAssertEqual(
      scope.decision(for: .execute(YoumuFeatureIDs.quickSnapshot)),
      .permissionDenied(.screenRecording, "缺少系统权限")
    )
  }

  func testYoumuBaseCommandsAreFreeWithoutAnAccount() throws {
    var builder = makeBuilder(grantedEntitlements: [])
    try builder.register(YoumuFeatureModule())
    let scope = try builder.build().accessScope(for: YoumuFeatureIDs.feature)

    for commandID in YoumuFeatureIDs.bundledCommands {
      XCTAssertTrue(scope.decision(for: .execute(commandID)).isAllowed)
    }
    XCTAssertEqual(YoumuFeatureIDs.proCommands.count, 0)
  }

  func testBaseAccessStillConsultsSystemPermissions() throws {
    let permissionCalls = SynchronousInvocationCounter()
    var builder = FeatureRegistryBuilder(
      entitlementChecker: FeatureEntitlementRouter { _ in
        .allowed
      },
      permissionChecker: FeaturePermissionRouter { _ in
        permissionCalls.increment()
        return .denied("缺少系统权限")
      }
    )
    try builder.register(YoumuFeatureModule())
    let scope = try builder.build().accessScope(for: YoumuFeatureIDs.feature)

    XCTAssertEqual(
      scope.decision(for: .execute(YoumuFeatureIDs.longScreenshot)),
      .permissionDenied(.screenRecording, "缺少系统权限")
    )
    XCTAssertEqual(permissionCalls.value(), 1)
  }

  func testPinScreenshotOverridesFeatureScreenRecordingRequirement() throws {
    var builder = makeBuilder(grantedEntitlements: [.macFull], grantedPermissions: [])
    try builder.register(YoumuFeatureModule())
    let scope = try builder.build().accessScope(for: YoumuFeatureIDs.feature)

    XCTAssertEqual(
      scope.decision(for: .execute(YoumuFeatureIDs.quickSnapshot)),
      .permissionDenied(.screenRecording, "缺少系统权限")
    )
    XCTAssertEqual(scope.decision(for: .execute(YoumuFeatureIDs.pinScreenshot)), .allowed)
  }

  func testBaseNetworkProbeStillDeniesUndeclaredActions() throws {
    var builder = makeBuilder(grantedEntitlements: [.macFull])
    try builder.register(NetworkProbeFeatureModule())
    let registry = builder.build()
    let scope = try registry.accessScope(for: NetworkProbeFeatureIDs.feature)

    XCTAssertEqual(
      scope.decision(for: .start),
      .allowed
    )
    XCTAssertEqual(
      scope.decision(for: .execute(NetworkProbeFeatureIDs.openCommand)),
      .allowed
    )
    XCTAssertFalse(
      scope.decision(
        for: .execute(
          CommandID("cn.tlww.aixlg.hotkeys.feature.network-probe.command.undeclared")
        )
      ).isAllowed
    )
  }

  func testLegacyYoumuAccountAlsoUsesFreeHostTools() throws {
    var builder = makeBuilder(grantedEntitlements: [.legacyYoumuFull])
    let youmuManifest = YoumuFeatureModule().manifest
    try builder.register(youmuManifest)
    try builder.register(NetworkProbeFeatureModule())
    let registry = builder.build()

    let youmuScope = try registry.accessScope(for: youmuManifest.id)
    for commandID in YoumuFeatureIDs.bundledCommands {
      XCTAssertTrue(youmuScope.decision(for: .execute(commandID)).isAllowed)
    }
    XCTAssertTrue(
      try registry.accessScope(for: NetworkProbeFeatureIDs.feature).decision(for: .start)
        .isAllowed
    )
  }

  func testMacFullEntitlementAllowsYoumu() throws {
    var builder = makeBuilder(grantedEntitlements: [.macFull])
    let youmuManifest = YoumuFeatureModule().manifest
    try builder.register(youmuManifest)
    let registry = builder.build()

    let scope = try registry.accessScope(for: youmuManifest.id)
    for commandID in YoumuFeatureIDs.freeCommands.union(YoumuFeatureIDs.proCommands) {
      XCTAssertEqual(scope.decision(for: .execute(commandID)), .allowed)
    }
  }

  func testAllBundledCommandsAllowMissingBaseEntitlement() throws {
    var builder = makeBuilder(grantedEntitlements: [])
    let youmuManifest = YoumuFeatureModule().manifest
    try builder.register(youmuManifest)
    let registry = builder.build()

    let scope = try registry.accessScope(for: youmuManifest.id)
    for command in youmuManifest.commands {
      XCTAssertTrue(scope.decision(for: .execute(command.id)).isAllowed)
    }
    XCTAssertEqual(YoumuFeatureIDs.proCommands.count, 0)
  }

  func testFeatureScopeRejectsAnotherRegisteredFeaturesActions() throws {
    var builder = makeBuilder()
    let youmuManifest = YoumuFeatureModule().manifest
    try builder.register(NetworkProbeFeatureModule())
    try builder.register(youmuManifest)
    let registry = builder.build()
    let youmuScope = try registry.accessScope(for: YoumuFeatureIDs.feature)

    XCTAssertFalse(
      youmuScope.decision(for: .execute(NetworkProbeFeatureIDs.openCommand)).isAllowed
    )
    XCTAssertFalse(
      youmuScope.decision(for: .open(NetworkProbeFeatureIDs.mainWindow)).isAllowed
    )
    XCTAssertFalse(
      youmuScope.decision(for: .perform(NetworkProbeFeatureIDs.runProbe)).isAllowed
    )
  }

  func testPaidPolicyMustDeclareAtLeastOneEntitlement() {
    let source = NetworkProbeFeatureModule().manifest
    let invalidManifest = FeatureManifest(
      id: source.id,
      manifestVersion: source.manifestVersion,
      displayName: source.displayName,
      summary: source.summary,
      category: source.category,
      isEnabledByDefault: source.isEnabledByDefault,
      activationPolicy: source.activationPolicy,
      requiredPermissions: source.requiredPermissions,
      accessPolicy: .anyOf([]),
      commands: source.commands,
      windows: source.windows,
      operations: source.operations,
      settingsSchemaVersion: source.settingsSchemaVersion
    )
    var builder = makeBuilder()

    XCTAssertThrowsError(try builder.register(invalidManifest)) { error in
      XCTAssertEqual(
        error as? FeatureRegistryError,
        .emptyEntitlementAlternatives(featureID: source.id)
      )
    }
  }

  func testUnknownFeatureCannotReceiveAccessScope() {
    let registry = makeBuilder().build()
    let unknown = FeatureID("cn.tlww.aixlg.hotkeys.feature.unknown")

    XCTAssertThrowsError(try registry.accessScope(for: unknown)) { error in
      XCTAssertEqual(
        error as? FeatureRegistryError,
        .unknownFeatureID(unknown)
      )
    }
  }

  func testDispatcherNeverRunsDeniedHandlerAndRunsAllowedHandlerExactlyOnce() async throws {
    let counter = InvocationCounter()
    let registration = FeatureActionHandlerRegistration(
      featureID: YoumuFeatureIDs.feature,
      action: .execute(YoumuFeatureIDs.longScreenshot)
    ) {
      await counter.increment()
    }

    var deniedBuilder = makeBuilder(grantedEntitlements: [], grantedPermissions: [])
    try deniedBuilder.register(YoumuFeatureModule())
    let deniedDispatcher = try FeatureDispatcher(
      registry: deniedBuilder.build(),
      handlers: [registration]
    )
    let deniedResult = try await deniedDispatcher.dispatch(
      featureID: YoumuFeatureIDs.feature,
      action: .execute(YoumuFeatureIDs.longScreenshot)
    )

    XCTAssertEqual(
      deniedResult,
      .permissionDenied(.screenRecording, "缺少系统权限")
    )
    let deniedCount = await counter.value()
    XCTAssertEqual(deniedCount, 0)

    var permissionDeniedBuilder = makeBuilder(
      grantedEntitlements: [.macFull],
      grantedPermissions: [.screenRecording]
    )
    try permissionDeniedBuilder.register(YoumuFeatureModule())
    let permissionDeniedDispatcher = try FeatureDispatcher(
      registry: permissionDeniedBuilder.build(),
      handlers: [registration]
    )
    let permissionDeniedResult = try await permissionDeniedDispatcher.dispatch(
      featureID: YoumuFeatureIDs.feature,
      action: .execute(YoumuFeatureIDs.longScreenshot)
    )

    XCTAssertEqual(
      permissionDeniedResult,
      .permissionDenied(.inputMonitoring, "缺少系统权限")
    )
    let permissionDeniedCount = await counter.value()
    XCTAssertEqual(permissionDeniedCount, 0)

    var allowedBuilder = makeBuilder(grantedEntitlements: [.macFull])
    try allowedBuilder.register(YoumuFeatureModule())
    let allowedDispatcher = try FeatureDispatcher(
      registry: allowedBuilder.build(),
      handlers: [registration]
    )
    let allowedResult = try await allowedDispatcher.dispatch(
      featureID: YoumuFeatureIDs.feature,
      action: .execute(YoumuFeatureIDs.longScreenshot)
    )

    XCTAssertEqual(allowedResult, .executed)
    let allowedCount = await counter.value()
    XCTAssertEqual(allowedCount, 1)
  }

  func testDispatcherRejectsUnknownAndCrossFeatureActionsBeforeHandler() async throws {
    let counter = InvocationCounter()
    var builder = makeBuilder()
    try builder.register(YoumuFeatureModule())
    try builder.register(NetworkProbeFeatureModule())
    let dispatcher = try FeatureDispatcher(
      registry: builder.build(),
      handlers: [
        FeatureActionHandlerRegistration(
          featureID: YoumuFeatureIDs.feature,
          action: .execute(YoumuFeatureIDs.quickSnapshot)
        ) {
          await counter.increment()
        }
      ]
    )

    let unknownResult = try await dispatcher.dispatch(
      featureID: FeatureID("cn.tlww.aixlg.hotkeys.feature.unknown"),
      action: .execute(YoumuFeatureIDs.quickSnapshot)
    )
    let crossFeatureResult = try await dispatcher.dispatch(
      featureID: YoumuFeatureIDs.feature,
      action: .execute(NetworkProbeFeatureIDs.openCommand)
    )

    XCTAssertEqual(unknownResult, .denied("功能尚未注册，动作未执行。"))
    XCTAssertEqual(crossFeatureResult, .denied("插件试图执行未在自身清单声明的动作。"))
    let invocationCount = await counter.value()
    XCTAssertEqual(invocationCount, 0)
  }

  func testBuiltRegistryIsAnImmutableSnapshot() throws {
    var builder = makeBuilder()
    try builder.register(NetworkProbeFeatureModule())
    let firstSnapshot = builder.build()

    try builder.register(YoumuFeatureModule())
    let secondSnapshot = builder.build()

    XCTAssertEqual(firstSnapshot.manifests.count, 1)
    XCTAssertEqual(secondSnapshot.manifests.count, 2)
    XCTAssertNil(firstSnapshot.manifest(for: YoumuFeatureIDs.feature))
  }

  private func makeBuilder(
    grantedEntitlements: Set<EntitlementID> = [.macFull],
    grantedPermissions: Set<PermissionID> = PermissionID.supported
  ) -> FeatureRegistryBuilder {
    FeatureRegistryBuilder(
      entitlementChecker: FeatureEntitlementRouter { request in
        if grantedEntitlements.contains(request.entitlementID) {
          return .allowed
        }
        return .denied("没有匹配权益")
      },
      permissionChecker: FeaturePermissionRouter { request in
        if grantedPermissions.contains(request.permissionID) {
          return .allowed
        }
        return .denied("缺少系统权限")
      }
    )
  }

  private func makeGranularPolicyManifest() -> FeatureManifest {
    let featureID = FeatureID("cn.tlww.aixlg.hotkeys.feature.policy-inheritance")
    return FeatureManifest(
      id: featureID,
      manifestVersion: 1,
      displayName: "策略继承夹具",
      summary: "验证命令与操作继承或覆盖功能级权限和权益。",
      category: .systemUtilities,
      isEnabledByDefault: false,
      activationPolicy: .onDemand,
      requiredPermissions: [.screenRecording],
      accessPolicy: .macFullBundledWithHost,
      commands: [
        FeatureCommandDescriptor(
          id: CommandID("\(featureID.rawValue).command.inherit"),
          displayName: "继承命令"
        ),
        FeatureCommandDescriptor(
          id: CommandID("\(featureID.rawValue).command.override"),
          displayName: "覆盖命令",
          requiredPermissions: [],
          accessPolicy: .free
        ),
      ],
      windows: [],
      operations: [
        FeatureOperationDescriptor(
          id: OperationID("\(featureID.rawValue).operation.inherit"),
          displayName: "继承操作"
        ),
        FeatureOperationDescriptor(
          id: OperationID("\(featureID.rawValue).operation.override"),
          displayName: "覆盖操作",
          requiredPermissions: [],
          accessPolicy: .free
        ),
      ],
      settingsSchemaVersion: 1
    )
  }

  private func replacing(
    _ source: FeatureManifest,
    id: FeatureID? = nil,
    requiredPermissions: [PermissionID]? = nil,
    accessPolicy: FeatureAccessPolicy? = nil,
    commands: [FeatureCommandDescriptor]? = nil,
    operations: [FeatureOperationDescriptor]? = nil
  ) -> FeatureManifest {
    FeatureManifest(
      id: id ?? source.id,
      manifestVersion: source.manifestVersion,
      displayName: source.displayName,
      summary: source.summary,
      category: source.category,
      isEnabledByDefault: source.isEnabledByDefault,
      activationPolicy: source.activationPolicy,
      requiredPermissions: requiredPermissions ?? source.requiredPermissions,
      accessPolicy: accessPolicy ?? source.accessPolicy,
      commands: commands ?? source.commands,
      windows: source.windows,
      operations: operations ?? source.operations,
      settingsSchemaVersion: source.settingsSchemaVersion
    )
  }
}

private actor InvocationCounter {
  private var count = 0

  func increment() {
    count += 1
  }

  func value() -> Int {
    count
  }
}

private final class SynchronousInvocationCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }

  func value() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}
